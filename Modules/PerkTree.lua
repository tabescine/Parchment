-- Parchment - Perk Tree (logic)
--
-- The rules engine behind the perk tree viewer: it decides each perk's status
-- (taken / available / locked / exclusive) for a character, validates selecting
-- and deselecting with the system's requirements, and counts invested points.
--
-- A character's perk selections live in char.perks as a flat list of perk ids.
-- A repeatable perk appears once per rank, so its rank is simply how many times
-- its id occurs in the list. This keeps the JSON/TOML schema a plain string list.
--
-- Reads from: ns.GetAttribute (for requirement messages). The caller passes the
--   computed sheet so attribute requirements check final (post-trait) values.
-- Exposes on ns.PerkTree: Status, CanAddRank, Select, Deselect, Points, Rank.

local ADDON, ns = ...

ns.PerkTree = ns.PerkTree or {}
local PT = ns.PerkTree

-- Counts how many times id appears in a list.
local function CountId(list, id)
    local c = 0
    for _, v in ipairs(list or {}) do
        if v == id then c = c + 1 end
    end
    return c
end

-- Finds a perk record by id within a tree.
local function FindPerk(tree, id)
    for _, p in ipairs(tree.perks or {}) do
        if p.id == id then return p end
    end
end

-- Finds a perk by id across every tree (prerequisites may be cross-sphere).
local function FindPerkAnywhere(id)
    local sys = ns.GetSystem and ns.GetSystem()
    for _, tree in ipairs(sys and sys.perk_trees or {}) do
        local p = FindPerk(tree, id)
        if p then return p end
    end
end

-- Returns the final (post-trait) value of an attribute from a computed sheet.
local function AttrFinal(sheet, attrId)
    for _, a in ipairs(sheet.attributes or {}) do
        if a.id == attrId then return a.final end
    end
    return 0
end

-- Human-readable name of an attribute id.
local function AttrNameById(id)
    local attr = ns.GetAttribute and ns.GetAttribute(id)
    return attr and attr.name or (id or "?")
end

-- The attribute a perk's requirement checks against. Most perks use the tree's
-- governing attribute, but some are gated by a different one (req_attribute).
local function ReqAttr(perk, tree)
    return perk.req_attribute or tree.governing_attribute
end

-- True when an "any-of" prerequisite list is satisfied (or absent/empty).
local function AnyTaken(char, list)
    if not list or #list == 0 then return true end
    for _, id in ipairs(list) do
        if CountId(char.perks, id) > 0 then return true end
    end
    return false
end

-- Comma-joined display names for a list of perk ids (resolved in any tree).
local function NamesList(tree, ids)
    local out = {}
    for _, id in ipairs(ids or {}) do
        local p = FindPerk(tree, id) or FindPerkAnywhere(id)
        out[#out + 1] = p and p.name or id
    end
    return table.concat(out, ", ")
end

-- Returns the level required for the given rank (1-based). level_req may be a
-- list (one entry per rank) or a single number (applies to rank 1).
local function LevelForRank(perk, rank)
    local lr = perk.level_req
    if type(lr) == "table" then return lr[rank] end
    if rank == 1 then return lr end
    return nil
end

-- Returns how many ranks of a perk the character has taken.
function PT.Rank(char, perk)
    return CountId(char.perks, perk.id)
end

-- Returns the perk's status string for a character:
--   "taken"     - at least one rank invested
--   "exclusive" - blocked because a mutually-exclusive perk is taken
--   "locked"    - requirements (attribute, level, prerequisites) not met
--   "available" - may be taken
function PT.Status(char, sheet, tree, perk)
    if PT.Rank(char, perk) > 0 then return "taken" end
    for _, exId in ipairs(perk.exclusive_with or {}) do
        if CountId(char.perks, exId) > 0 then return "exclusive" end
    end
    if perk.attribute_req and AttrFinal(sheet, ReqAttr(perk, tree)) < perk.attribute_req then
        return "locked"
    end
    for _, pr in ipairs(perk.prerequisites or {}) do
        if CountId(char.perks, pr) == 0 then return "locked" end
    end
    if not AnyTaken(char, perk.prerequisites_any) then return "locked" end
    local need = LevelForRank(perk, 1)
    if need and (char.level or 1) < need then return "locked" end
    return "available"
end

-- Checks whether the next rank of a perk may be taken.
--
-- Returns ok, reason. reason is a human-readable explanation when ok is false.
function PT.CanAddRank(char, sheet, tree, perk)
    local rank = PT.Rank(char, perk)
    local maxRanks = perk.max_ranks or 1
    if rank >= maxRanks then return false, "Already at maximum rank." end

    -- Exclusivity only blocks the first rank.
    if rank == 0 then
        for _, exId in ipairs(perk.exclusive_with or {}) do
            if CountId(char.perks, exId) > 0 then
                local ex = FindPerk(tree, exId) or FindPerkAnywhere(exId)
                return false, "Exclusive with " .. (ex and ex.name or exId) .. "."
            end
        end
    end

    if perk.attribute_req and AttrFinal(sheet, ReqAttr(perk, tree)) < perk.attribute_req then
        return false, "Requires " .. AttrNameById(ReqAttr(perk, tree)) .. " " .. perk.attribute_req .. "."
    end
    for _, pr in ipairs(perk.prerequisites or {}) do
        if CountId(char.perks, pr) == 0 then
            local p = FindPerk(tree, pr) or FindPerkAnywhere(pr)
            return false, "Requires " .. (p and p.name or pr) .. "."
        end
    end
    if not AnyTaken(char, perk.prerequisites_any) then
        return false, "Requires one of: " .. NamesList(tree, perk.prerequisites_any) .. "."
    end
    local need = LevelForRank(perk, rank + 1)
    if need and (char.level or 1) < need then
        return false, "Requires level " .. need .. "."
    end
    return true
end

-- Selects (or adds a rank to) a perk. Returns ok, reason.
function PT.Select(char, sheet, tree, perk)
    local ok, reason = PT.CanAddRank(char, sheet, tree, perk)
    if not ok then return false, reason end
    char.perks = char.perks or {}
    table.insert(char.perks, perk.id)
    return true
end

-- Removes one rank of a perk. Blocks when another taken perk depends on its
-- last rank. Returns ok, reason.
function PT.Deselect(char, tree, perk)
    local rank = PT.Rank(char, perk)
    if rank == 0 then return false, "Not taken." end

    if rank == 1 then
        for _, id in ipairs(char.perks) do
            local p = FindPerk(tree, id) or FindPerkAnywhere(id)
            for _, pr in ipairs(p and p.prerequisites or {}) do
                if pr == perk.id then
                    return false, "Required by " .. p.name .. "."
                end
            end
            -- Block if this is the last satisfier of an "any-of" requirement.
            if p and p.prerequisites_any then
                local inAny, othersTaken = false, false
                for _, pr in ipairs(p.prerequisites_any) do
                    if pr == perk.id then inAny = true
                    elseif CountId(char.perks, pr) > 0 then othersTaken = true end
                end
                if inAny and not othersTaken then
                    return false, "Required by " .. p.name .. "."
                end
            end
        end
    end

    for i, v in ipairs(char.perks) do
        if v == perk.id then
            table.remove(char.perks, i)
            return true
        end
    end
    return false, "Not taken."
end

-- Returns invested, available perk points. One point is granted per level.
function PT.Points(char)
    return #(char.perks or {}), (char.level or 1)
end
