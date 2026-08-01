-- Parchment - Feats (logic)
--
-- The rules engine behind the feats browser: which rank of an ability line a
-- character owns, what the next rank requires, and validated learn/unlearn.
-- Feat lines are ladders - rank N implicitly requires rank N-1 (array
-- position IS the prerequisite chain) - so the only gates are the line
-- attribute's score and a free pick in the shared ledger (Modules/Picks.lua).
-- Learning is enforced here, not advisory: a character with no picks left is
-- refused, unlike the historical perk path.
--
-- A character's feat selections live in char.feats as { [lineId] = rank }.
--
-- Reads from: ns.GetFeatPack, ns.Picks, ns.AttrName, ns.FindById.
--   The caller passes the computed sheet so attribute requirements check
--   final (post-trait) values, like the other pickers.
-- Exposes on ns.Feats: Rank, RankReq, Line, Lines, Status, CanLearn, Learn,
--   Unlearn, Search.

local ADDON, ns = ...

ns.Feats = ns.Feats or {}
local Feats = ns.Feats

-- Returns the final (post-trait) value of an attribute from a computed sheet.
local function AttrFinal(sheet, attrId)
    for _, a in ipairs(sheet and sheet.attributes or {}) do
        if a.id == attrId then return a.final end
    end
    return 0
end

-- Returns how many ranks of a line the character owns (0 when none).
function Feats.Rank(char, lineId)
    local r = type(char) == "table" and type(char.feats) == "table" and char.feats[lineId]
    if type(r) == "number" and r >= 1 then return math.floor(r) end
    return 0
end

-- The attribute score a line's rank (1-based index) requires: the rank's own
-- attribute_req when set, else the pack-wide rank_attribute_req default for
-- that index, else nil (no gate).
function Feats.RankReq(pack, line, rankIndex)
    local rank = type(line.ranks) == "table" and line.ranks[rankIndex]
    if type(rank) == "table" and type(rank.attribute_req) == "number" then
        return rank.attribute_req
    end
    local defaults = type(pack) == "table" and pack.rank_attribute_req
    local v = type(defaults) == "table" and defaults[rankIndex]
    if type(v) == "number" then return v end
    return nil
end

-- Finds a line record by id in a pack, or nil.
function Feats.Line(pack, lineId)
    return ns.FindById(type(pack) == "table" and pack.lines or nil, lineId)
end

-- Returns the pack's lines governed by an attribute, or all lines when
-- attrId is nil. Always a fresh list, in pack order.
function Feats.Lines(pack, attrId)
    local out = {}
    for _, line in ipairs(type(pack) == "table" and pack.lines or {}) do
        if type(line) == "table" and (attrId == nil or line.attribute == attrId) then
            out[#out + 1] = line
        end
    end
    return out
end

-- Status of one rank of a line for a character:
--   "taken"     - the character owns this rank
--   "next"      - the next rank up (learnable subject to CanLearn)
--   "locked"    - beyond the next rank
function Feats.Status(char, line, rankIndex)
    local owned = Feats.Rank(char, line.id)
    if rankIndex <= owned then return "taken" end
    if rankIndex == owned + 1 then return "next" end
    return "locked"
end

-- Checks whether the NEXT rank of a line may be learned.
--
-- Returns ok, reason. reason is a human-readable explanation when ok is false.
function Feats.CanLearn(char, sheet, pack, line)
    local owned = Feats.Rank(char, line.id)
    local total = #(type(line.ranks) == "table" and line.ranks or {})
    if owned >= total then return false, "Already at the highest rank." end
    local req = Feats.RankReq(pack, line, owned + 1)
    if req and AttrFinal(sheet, line.attribute) < req then
        return false, "Requires " .. ns.AttrName(line.attribute) .. " " .. req .. "."
    end
    local spent, budget = ns.Picks.Points(char)
    if spent >= budget then
        return false, "No picks left (" .. spent .. " of " .. budget .. " spent)."
    end
    return true
end

-- Learns the next rank of a line. Returns ok, reason.
function Feats.Learn(char, sheet, pack, line)
    local ok, reason = Feats.CanLearn(char, sheet, pack, line)
    if not ok then return false, reason end
    char.feats = char.feats or {}
    char.feats[line.id] = Feats.Rank(char, line.id) + 1
    return true
end

-- Removes the highest owned rank of a line (rank order makes this the only
-- removable one). Returns ok, reason.
function Feats.Unlearn(char, line)
    local owned = Feats.Rank(char, line.id)
    if owned == 0 then return false, "Not learned." end
    char.feats[line.id] = (owned > 1) and (owned - 1) or nil
    return true
end

-- Searches a pack's lines for a query (case-insensitive plain text over the
-- line name and every rank's name + description, whitespace-trimmed).
-- Returns a list of line records in pack order; an empty query matches none.
function Feats.Search(pack, query)
    query = tostring(query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local out = {}
    if query == "" then return out end
    for _, line in ipairs(type(pack) == "table" and pack.lines or {}) do
        local parts = { line.name or "" }
        for _, rank in ipairs(type(line.ranks) == "table" and line.ranks or {}) do
            parts[#parts + 1] = rank.name or ""
            parts[#parts + 1] = rank.description or ""
        end
        if table.concat(parts, "\n"):lower():find(query, 1, true) then
            out[#out + 1] = line
        end
    end
    return out
end
