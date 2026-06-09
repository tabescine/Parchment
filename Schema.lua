-- Parchment - Schema
--
-- Validates system definitions (ParchmentSystemDB) and character data
-- (ParchmentCharDB entries) against the shape the rest of the addon expects.
-- The addon is data-driven, so this is the one place that knows which fields
-- are required and which cross-references must resolve. Validation is lenient
-- by design: it reports problems as a list of human-readable strings rather
-- than throwing, so a partially-broken import still loads and tells the DM why.
--
-- Reads from: nothing (pure functions over the tables passed in).
-- Exposes on ns.Schema: .ValidateSystem, .ValidateCharacter

local ADDON, ns = ...

-- Field requirements per record type. Each entry maps a field name to its
-- expected Lua type; everything listed here must be present and well-typed.
local SYSTEM_REQUIRED = { system_name = "string", attributes = "table" }
local ATTRIBUTE_REQUIRED = { id = "string", name = "string" }
local SKILL_REQUIRED = { id = "string", name = "string", attribute = "string" }
local PERK_REQUIRED = { id = "string", name = "string" }
local CHAR_REQUIRED = { name = "string", level = "number", attributes = "table" }

ns.Schema = ns.Schema or {}
local Schema = ns.Schema

-- Builds a lookup set { value = true } from a list of records keyed by .id.
local function IdSet(list)
    local set = {}
    for _, record in ipairs(list or {}) do
        if type(record) == "table" and record.id then set[record.id] = true end
    end
    return set
end

-- Appends "context: message" to the issues list. Returns nothing; mutates list.
local function Report(issues, context, message)
    issues[#issues + 1] = context .. ": " .. message
end

-- Checks that every field named in `spec` exists on `record` with the right
-- type. Appends one issue per violation. Returns true when the record is clean.
local function CheckRequired(record, spec, context, issues)
    local clean = true
    for field, expected in pairs(spec) do
        local actual = type(record[field])
        if actual ~= expected then
            Report(issues, context, "field '" .. field .. "' should be " ..
                expected .. ", got " .. actual)
            clean = false
        end
    end
    return clean
end

-- Validates a full system definition.
--
-- Returns two values: ok, issues
--   ok     - true when no issues were found
--   issues - list of human-readable problem strings (empty when ok)
--
-- Beyond shape checks this resolves cross-references: every skill, saving
-- throw, perk tree and trait must name attributes that actually exist, and
-- perk prerequisites/exclusions must name perks that exist in the same tree.
function Schema.ValidateSystem(system)
    local issues = {}
    if type(system) ~= "table" then
        return false, { "system: definition is not a table" }
    end

    -- Top-level required fields.
    CheckRequired(system, SYSTEM_REQUIRED, "system", issues)

    -- Attributes, and the id set everything else references.
    local attrIds = {}
    for i, attr in ipairs(system.attributes or {}) do
        local ctx = "attribute[" .. i .. "]"
        if CheckRequired(attr, ATTRIBUTE_REQUIRED, ctx, issues) then
            if attrIds[attr.id] then Report(issues, ctx, "duplicate id '" .. attr.id .. "'") end
            attrIds[attr.id] = true
        end
    end

    -- Skills must point at a real attribute.
    for i, skill in ipairs(system.skills or {}) do
        local ctx = "skill[" .. i .. "]"
        if CheckRequired(skill, SKILL_REQUIRED, ctx, issues) and not attrIds[skill.attribute] then
            Report(issues, ctx, "unknown attribute '" .. tostring(skill.attribute) .. "'")
        end
    end

    -- Derived-stat config: any attribute it names must exist.
    local ds = system.derived_stats
    if type(ds) == "table" then
        for _, field in ipairs({ "hit_die_attribute", "hp_attribute", "mana_attribute", "movement_attribute" }) do
            if ds[field] and not attrIds[ds[field]] then
                Report(issues, "derived_stats", "unknown attribute '" .. tostring(ds[field]) .. "' in " .. field)
            end
        end
        for _, id in ipairs(ds.spell_attributes or {}) do
            if not attrIds[id] then
                Report(issues, "derived_stats", "unknown attribute '" .. tostring(id) .. "' in spell_attributes")
            end
        end
    end

    -- Accomplishment targets: a target may be a number or a table that scales by
    -- an attribute; any attribute it names must exist.
    local at = system.accomplish_targets
    if type(at) == "table" then
        for _, which in ipairs({ "skills", "weapons", "saves" }) do
            local spec = at[which]
            if type(spec) == "table" then
                if spec.attribute and not attrIds[spec.attribute] then
                    Report(issues, "accomplish_targets", "unknown attribute '" .. tostring(spec.attribute) .. "' in " .. which)
                end
                for _, id in ipairs(spec.attribute_max or {}) do
                    if not attrIds[id] then
                        Report(issues, "accomplish_targets", "unknown attribute '" .. tostring(id) .. "' in " .. which .. ".attribute_max")
                    end
                end
            end
        end
    end

    -- Global perk id set: prerequisites and exclusions may reference perks in
    -- other spheres (the ruleset interconnects them), so validate against all.
    local allPerkIds = {}
    for _, tree in ipairs(system.perk_trees or {}) do
        if type(tree) == "table" then
            for id in pairs(IdSet(tree.perks)) do allPerkIds[id] = true end
        end
    end

    -- Perk trees: governing attribute must exist; prereqs/exclusions must
    -- resolve to some perk (in any tree).
    for i, tree in ipairs(system.perk_trees or {}) do
        local ctx = "perk_tree[" .. i .. "]"
        if type(tree) ~= "table" then
            Report(issues, ctx, "tree is not a table")
        else
            if tree.governing_attribute and not attrIds[tree.governing_attribute] then
                Report(issues, ctx, "unknown governing_attribute '" ..
                    tostring(tree.governing_attribute) .. "'")
            end
            for j, perk in ipairs(tree.perks or {}) do
                local pctx = ctx .. ".perk[" .. j .. "]"
                if CheckRequired(perk, PERK_REQUIRED, pctx, issues) then
                    if perk.req_attribute and not attrIds[perk.req_attribute] then
                        Report(issues, pctx, "unknown req_attribute '" .. tostring(perk.req_attribute) .. "'")
                    end
                    if perk.choice then
                        local k = perk.choice.kind
                        if k ~= "skill" and k ~= "weapon" and k ~= "damage_type" then
                            Report(issues, pctx, "choice.kind invalid '" .. tostring(k) .. "'")
                        end
                    end
                    for _, req in ipairs(perk.prerequisites or {}) do
                        if not allPerkIds[req] then
                            Report(issues, pctx, "prerequisite '" .. tostring(req) .. "' not found in any tree")
                        end
                    end
                    for _, req in ipairs(perk.prerequisites_any or {}) do
                        if not allPerkIds[req] then
                            Report(issues, pctx, "prerequisites_any '" .. tostring(req) .. "' not found in any tree")
                        end
                    end
                    for _, exc in ipairs(perk.exclusive_with or {}) do
                        if not allPerkIds[exc] then
                            Report(issues, pctx, "exclusive_with '" .. tostring(exc) .. "' not found in any tree")
                        end
                    end
                end
            end
        end
    end

    return #issues == 0, issues
end

-- Validates a single character against an optional system definition.
--
-- Returns two values: ok, issues
--   ok     - true when no issues were found
--   issues - list of human-readable problem strings (empty when ok)
--
-- When `system` is supplied, attribute keys, the primary/ac attributes,
-- accomplished skills/saves and selected perks are checked against it. When
-- `system` is nil only the character's own shape is validated.
function Schema.ValidateCharacter(char, system)
    local issues = {}
    if type(char) ~= "table" then
        return false, { "character: entry is not a table" }
    end

    CheckRequired(char, CHAR_REQUIRED, "character", issues)

    if type(system) ~= "table" then
        return #issues == 0, issues
    end

    -- Sets of valid ids drawn from the system definition.
    local attrIds = IdSet(system.attributes)
    local skillIds = IdSet(system.skills)
    local perkIds = {}
    for _, tree in ipairs(system.perk_trees or {}) do
        for id in pairs(IdSet(tree.perks)) do perkIds[id] = true end
    end

    -- Base attribute keys must be known attributes.
    for key in pairs(char.attributes or {}) do
        if not attrIds[key] then
            Report(issues, "character.attributes", "unknown attribute '" .. tostring(key) .. "'")
        end
    end

    -- Primary and AC attribute selections.
    if char.primary_attribute and not attrIds[char.primary_attribute] then
        Report(issues, "character", "unknown primary_attribute '" .. tostring(char.primary_attribute) .. "'")
    end
    if char.ac_attribute and not attrIds[char.ac_attribute] then
        Report(issues, "character", "unknown ac_attribute '" .. tostring(char.ac_attribute) .. "'")
    end

    -- Accomplished skills and saves reference real ids.
    for _, id in ipairs(char.accomplished_skills or {}) do
        if not skillIds[id] then
            Report(issues, "character.accomplished_skills", "unknown skill '" .. tostring(id) .. "'")
        end
    end
    for _, id in ipairs(char.accomplished_saves or {}) do
        if not attrIds[id] then
            Report(issues, "character.accomplished_saves", "unknown save attribute '" .. tostring(id) .. "'")
        end
    end

    -- Custom-perk effects must reference real skills/attributes; a `replaces`
    -- target must be a real sphere perk.
    for i, perk in ipairs(char.custom_perks or {}) do
        if perk.replaces and not perkIds[perk.replaces] then
            Report(issues, "custom_perks[" .. i .. "]", "replaces unknown perk '" .. tostring(perk.replaces) .. "'")
        end
        for j, e in ipairs(perk.effects or {}) do
            local ctx = "custom_perks[" .. i .. "].effects[" .. j .. "]"
            if e.type == "skill" and (e.skill or e.id) and not skillIds[e.skill or e.id] then
                Report(issues, ctx, "unknown skill '" .. tostring(e.skill or e.id) .. "'")
            end
            if (e.type == "attribute" or e.type == "save") and e.id and not attrIds[e.id] then
                Report(issues, ctx, "unknown attribute '" .. tostring(e.id) .. "'")
            end
            if e.add_modifier and not attrIds[e.add_modifier] then
                Report(issues, ctx, "unknown add_modifier attribute '" .. tostring(e.add_modifier) .. "'")
            end
        end
    end

    -- Perk choices must key real perks and pick ids valid for the choice kind.
    local weaponIds = IdSet(system.weapons)
    local dmgTypes = {}
    for _, d in ipairs(system.damage_types or {}) do dmgTypes[d] = true end
    for pid, chosen in pairs(char.perk_choices or {}) do
        if not perkIds[pid] then
            Report(issues, "perk_choices", "unknown perk '" .. tostring(pid) .. "'")
        else
            local kind
            for _, tree in ipairs(system.perk_trees or {}) do
                for _, p in ipairs(tree.perks or {}) do
                    if p.id == pid and p.choice then kind = p.choice.kind end
                end
            end
            for _, cid in ipairs(chosen) do
                if kind == "skill" and not skillIds[cid] then
                    Report(issues, "perk_choices[" .. pid .. "]", "unknown skill '" .. tostring(cid) .. "'")
                elseif kind == "weapon" and not weaponIds[cid] then
                    Report(issues, "perk_choices[" .. pid .. "]", "unknown weapon '" .. tostring(cid) .. "'")
                elseif kind == "damage_type" and next(dmgTypes) and not dmgTypes[cid] then
                    Report(issues, "perk_choices[" .. pid .. "]", "unknown damage type '" .. tostring(cid) .. "'")
                end
            end
        end
    end

    return #issues == 0, issues
end
