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
-- Exposes on ns.Schema: .ValidateSystem, .ValidateCharacter, .ValidateItem,
--   .ValidateItemLibrary

local ADDON, ns = ...

-- Field requirements per record type. Each entry maps a field name to its
-- expected Lua type; everything listed here must be present and well-typed.
local SYSTEM_REQUIRED = { system_name = "string", attributes = "table" }
local ATTRIBUTE_REQUIRED = { id = "string", name = "string" }
local SKILL_REQUIRED = { id = "string", name = "string", attribute = "string" }
local PERK_REQUIRED = { id = "string", name = "string" }
local WEAPON_REQUIRED = { id = "string", name = "string" }
local CHAR_REQUIRED = { name = "string", level = "number", attributes = "table" }
local ITEM_REQUIRED = { id = "string", name = "string", kind = "string" }

-- The item kinds the sheet knows how to render. A kind outside this set is
-- reported: the mechanics (equip toggle, bonus folding, counter) are chosen by
-- kind, so an unknown one has no behaviour to fall back on.
local ITEM_KINDS = { weapon = true, equipment = true, gear = true }

-- Bounds on item fields. Item text reaches the sheet from two directions: the
-- local library (the player's own data) and, inside a shared character's
-- inventory, the `resolved` display snapshot from the wire - which is
-- attacker-controlled, so every string is capped (mirroring the 64-char name
-- cap used elsewhere) and icons are restricted to plain texture-name characters
-- so no path escape can be smuggled into a SetTexture call. The bonus limit
-- matters most: `resolved` bonuses fold into attack totals and AC.
local MAX_ITEM_NAME = 64
local MAX_ITEM_DESC = 512
local MAX_ICON = 64
local ICON_PATTERN = "^[%w_%-]+$"
local MAX_BONUS = 99
local MAX_COUNT = 9999   -- matches the counter clamp in Modules/Items.lua

ns.Schema = ns.Schema or {}
local Schema = ns.Schema

-- Returns x when it is a table, else an empty table. Used at every optional-list
-- iteration so a field that arrives as a truthy scalar (e.g. `weapons = 5` from a
-- malformed paste or wire payload) is skipped and reported elsewhere rather than
-- throwing from ipairs/pairs - the module contract is "report, never throw".
local function AsTable(x)
    return type(x) == "table" and x or {}
end

-- Builds a lookup set { value = true } from a list of records keyed by .id.
local function IdSet(list)
    local set = {}
    for _, record in ipairs(AsTable(list)) do
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
    if type(record) ~= "table" then
        Report(issues, context, "should be a table, got " .. type(record))
        return false
    end
    local clean = true
    for field, expected in pairs(spec) do
        local value = record[field]
        local actual = type(value)
        if actual ~= expected then
            Report(issues, context, "field '" .. field .. "' should be " ..
                expected .. ", got " .. actual)
            clean = false
        elseif expected == "number" and (value ~= value or value == math.huge
            or value == -math.huge) then
            -- NaN/inf validate as "number" but poison every derived stat they
            -- touch (level -> hp -> ...), so they are a shape error here.
            Report(issues, context, "field '" .. field .. "' is not a finite number")
            clean = false
        end
    end
    return clean
end

-- Checks an optional string field: right type and within `cap` characters.
-- Absent fields pass (optionality is the caller's business).
local function CheckText(value, ctx, field, cap, issues)
    if value == nil then return end
    if type(value) ~= "string" then
        Report(issues, ctx, "field '" .. field .. "' should be string, got " .. type(value))
    elseif #value > cap then
        Report(issues, ctx, "field '" .. field .. "' is longer than " .. cap .. " characters")
    end
end

-- Checks an optional icon field: a capped string of texture-name characters
-- only, so a stored icon can never reach into a texture path.
local function CheckIcon(value, ctx, issues)
    CheckText(value, ctx, "icon", MAX_ICON, issues)
    if type(value) == "string" and #value <= MAX_ICON and not value:match(ICON_PATTERN) then
        Report(issues, ctx,
            "field 'icon' must be a plain texture name (letters, digits, '_' and '-')")
    end
end

-- Checks an optional numeric field: right type, finite, and within +/- `limit`
-- when one is given (nil = any finite number).
local function CheckNumeric(value, ctx, field, limit, issues)
    if value == nil then return end
    if type(value) ~= "number" then
        Report(issues, ctx, "field '" .. field .. "' should be number, got " .. type(value))
    elseif value ~= value or value == math.huge or value == -math.huge then
        Report(issues, ctx, "field '" .. field .. "' is not a finite number")
    elseif limit and (value > limit or value < -limit) then
        Report(issues, ctx,
            "field '" .. field .. "' is outside [-" .. limit .. ", " .. limit .. "]")
    end
end

-- Validates one item-library record (id, name, kind plus the per-kind extras).
-- Bails after the required-field check so a non-record cannot be probed further.
local function CheckItem(item, ctx, issues)
    if not CheckRequired(item, ITEM_REQUIRED, ctx, issues) then return end
    if not ITEM_KINDS[item.kind] then
        Report(issues, ctx, "unknown kind '" .. tostring(item.kind) .. "'")
    end
    CheckText(item.name, ctx, "name", MAX_ITEM_NAME, issues)
    CheckText(item.description, ctx, "description", MAX_ITEM_DESC, issues)
    CheckText(item.weapon_id, ctx, "weapon_id", MAX_ITEM_NAME, issues)
    CheckIcon(item.icon, ctx, issues)
    CheckNumeric(item.bonus, ctx, "bonus", MAX_BONUS, issues)
    CheckNumeric(item.ac_bonus, ctx, "ac_bonus", MAX_BONUS, issues)
    CheckNumeric(item.default_count, ctx, "default_count", MAX_COUNT, issues)
    CheckNumeric(item.version, ctx, "version", nil, issues)
end

-- Validates the `resolved` display snapshot a shared inventory entry carries
-- (see Modules/Sharing.lua): the sender's copy of the item's display fields,
-- used only when our own library cannot resolve the id. Every field is
-- optional - the sender only sends what its item had - but each is bounded,
-- because this block is attacker-controlled and its bonuses reach the totals.
local function CheckResolved(r, ctx, issues)
    if r.kind ~= nil and not ITEM_KINDS[r.kind] then
        Report(issues, ctx, "unknown kind '" .. tostring(r.kind) .. "'")
    end
    CheckText(r.name, ctx, "name", MAX_ITEM_NAME, issues)
    CheckText(r.weapon_id, ctx, "weapon_id", MAX_ITEM_NAME, issues)
    CheckIcon(r.icon, ctx, issues)
    CheckNumeric(r.bonus, ctx, "bonus", MAX_BONUS, issues)
    CheckNumeric(r.ac_bonus, ctx, "ac_bonus", MAX_BONUS, issues)
end

-- Validates char.inventory: thin per-character instances of library items (an
-- item_id reference plus the state that is genuinely per character - `equipped`
-- for weapons/equipment, `count` for gear). Everything else about an item is
-- resolved from the library at render time.
--
-- `weaponIds` is the active system's weapon id set, or nil when validating
-- shape only (no system loaded, or the comm receive path). A weapon link that
-- does not resolve is reported but never fatal in practice: the item simply
-- degrades to a display-only item, exactly as an unlinked one would.
local function CheckInventory(char, weaponIds, issues)
    for i, entry in ipairs(AsTable(char.inventory)) do
        local ctx = "inventory[" .. i .. "]"
        if type(entry) ~= "table" then
            Report(issues, ctx, "should be a table, got " .. type(entry))
        else
            if type(entry.item_id) ~= "string" then
                Report(issues, ctx, "field 'item_id' should be string, got " .. type(entry.item_id))
            end
            CheckNumeric(entry.count, ctx, "count", nil, issues)
            if entry.equipped ~= nil and type(entry.equipped) ~= "boolean" then
                Report(issues, ctx,
                    "field 'equipped' should be boolean, got " .. type(entry.equipped))
            end
            if entry.resolved ~= nil then
                if type(entry.resolved) ~= "table" then
                    Report(issues, ctx .. ".resolved",
                        "should be a table, got " .. type(entry.resolved))
                else
                    CheckResolved(entry.resolved, ctx .. ".resolved", issues)
                    if weaponIds and type(entry.resolved.weapon_id) == "string"
                        and not weaponIds[entry.resolved.weapon_id] then
                        Report(issues, ctx .. ".resolved", "unknown weapon '"
                            .. entry.resolved.weapon_id .. "' (no attack bonus applied)")
                    end
                end
            end
        end
    end
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
    for i, attr in ipairs(AsTable(system.attributes)) do
        local ctx = "attribute[" .. i .. "]"
        if CheckRequired(attr, ATTRIBUTE_REQUIRED, ctx, issues) then
            if attrIds[attr.id] then Report(issues, ctx, "duplicate id '" .. attr.id .. "'") end
            attrIds[attr.id] = true
        end
    end

    -- Skills must point at a real attribute and carry a unique id (everything
    -- downstream - accomplished lists, perk choices - keys skills by id, so a
    -- duplicate resolves last-one-wins with no warning).
    local skillSeen = {}
    for i, skill in ipairs(AsTable(system.skills)) do
        local ctx = "skill[" .. i .. "]"
        if CheckRequired(skill, SKILL_REQUIRED, ctx, issues) then
            if skillSeen[skill.id] then Report(issues, ctx, "duplicate id '" .. skill.id .. "'") end
            skillSeen[skill.id] = true
            if not attrIds[skill.attribute] then
                Report(issues, ctx, "unknown attribute '" .. tostring(skill.attribute) .. "'")
            end
        end
    end

    -- Weapons are optional; when present they need id + name. `attribute`
    -- (governs attack rolls) may be one attribute id or a list of ids - the
    -- best modifier applies, for finesse-style "use either" weapons. All
    -- named attributes must resolve.
    local weaponSeen = {}
    for i, weapon in ipairs(AsTable(system.weapons)) do
        local ctx = "weapon[" .. i .. "]"
        if CheckRequired(weapon, WEAPON_REQUIRED, ctx, issues) then
            if weaponSeen[weapon.id] then Report(issues, ctx, "duplicate id '" .. weapon.id .. "'") end
            weaponSeen[weapon.id] = true
            if weapon.attribute ~= nil then
                local attrs = weapon.attribute
                if type(attrs) ~= "table" then attrs = { attrs } end
                for _, id in ipairs(attrs) do
                    if not attrIds[id] then
                        Report(issues, ctx, "unknown attribute '" .. tostring(id) .. "'")
                    end
                end
            end
        end
    end

    -- Races are free-form strings, but when the system declares a top-level
    -- `races` list, the racial traits' allowed/disallowed lists must use them
    -- (typo catcher; without the list any race name goes).
    if type(system.races) == "table" then
        local raceSet = {}
        for i, r in ipairs(AsTable(system.races)) do
            if type(r) ~= "string" then
                Report(issues, "races[" .. i .. "]", "should be a string, got " .. type(r))
            else
                raceSet[r] = true
            end
        end
        for i, t in ipairs(AsTable(system.racial_traits)) do
            if type(t) == "table" then
                for _, field in ipairs({ "allowed_races", "disallowed_races" }) do
                    for _, r in ipairs(AsTable(t[field])) do
                        if not raceSet[r] then
                            Report(issues, "racial_trait[" .. i .. "]",
                                "unknown race '" .. tostring(r) .. "' in " .. field)
                        end
                    end
                end
            end
        end
    end

    -- Spell schools: plain strings or { id, name } records.
    for i, school in ipairs(AsTable(system.spell_schools)) do
        if type(school) == "table" then
            CheckRequired(school, { id = "string", name = "string" }, "spell_school[" .. i .. "]", issues)
        elseif type(school) ~= "string" then
            Report(issues, "spell_school[" .. i .. "]", "should be a string or { id, name }, got " .. type(school))
        end
    end

    -- Derived-stat config: any attribute it names must exist.
    local ds = system.derived_stats
    if type(ds) == "table" then
        for _, field in ipairs({ "hit_die_attribute", "hp_attribute", "mana_attribute",
            "movement_attribute", "initiative_tiebreaker" }) do
            if ds[field] and not attrIds[ds[field]] then
                Report(issues, "derived_stats", "unknown attribute '" .. tostring(ds[field]) .. "' in " .. field)
            end
        end
        for _, field in ipairs({ "spell_attributes", "ac_attributes", "init_attributes" }) do
            for _, id in ipairs(AsTable(ds[field])) do
                if not attrIds[id] then
                    Report(issues, "derived_stats", "unknown attribute '" .. tostring(id) .. "' in " .. field)
                end
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
                    Report(issues, "accomplish_targets",
                        "unknown attribute '" .. tostring(spec.attribute) .. "' in " .. which)
                end
                for _, id in ipairs(AsTable(spec.attribute_max)) do
                    if not attrIds[id] then
                        Report(issues, "accomplish_targets",
                            "unknown attribute '" .. tostring(id) .. "' in " .. which .. ".attribute_max")
                    end
                end
            end
        end
    end

    -- Global perk id set: prerequisites and exclusions may reference perks in
    -- other spheres (the ruleset interconnects them), so validate against all.
    local allPerkIds = {}
    for _, tree in ipairs(AsTable(system.perk_trees)) do
        if type(tree) == "table" then
            for id in pairs(IdSet(tree.perks)) do allPerkIds[id] = true end
        end
    end

    -- Perk trees: governing attribute must exist; prereqs/exclusions must
    -- resolve to some perk (in any tree). Tree and perk ids must be unique -
    -- perk ids GLOBALLY, across trees, because char.perks, perk_choices kind
    -- resolution and prerequisite sets all key perks by bare id, so a duplicate
    -- resolves last-one-wins with no warning.
    local treeSeen, perkSeen = {}, {}
    for i, tree in ipairs(AsTable(system.perk_trees)) do
        local ctx = "perk_tree[" .. i .. "]"
        if type(tree) ~= "table" then
            Report(issues, ctx, "tree is not a table")
        else
            if tree.id ~= nil then
                if treeSeen[tree.id] then
                    Report(issues, ctx, "duplicate id '" .. tostring(tree.id) .. "'")
                end
                treeSeen[tree.id] = true
            end
            if tree.governing_attribute and not attrIds[tree.governing_attribute] then
                Report(issues, ctx, "unknown governing_attribute '" ..
                    tostring(tree.governing_attribute) .. "'")
            end
            for j, perk in ipairs(AsTable(tree.perks)) do
                local pctx = ctx .. ".perk[" .. j .. "]"
                if CheckRequired(perk, PERK_REQUIRED, pctx, issues) then
                    if perkSeen[perk.id] then
                        Report(issues, pctx, "duplicate perk id '" .. perk.id .. "'")
                    end
                    perkSeen[perk.id] = true
                    if perk.req_attribute and not attrIds[perk.req_attribute] then
                        Report(issues, pctx, "unknown req_attribute '" .. tostring(perk.req_attribute) .. "'")
                    end
                    if type(perk.choice) == "table" then
                        local k = perk.choice.kind
                        if k ~= "skill" and k ~= "weapon" and k ~= "damage_type" then
                            Report(issues, pctx, "choice.kind invalid '" .. tostring(k) .. "'")
                        end
                    elseif perk.choice ~= nil then
                        Report(issues, pctx, "choice should be a table, got " .. type(perk.choice))
                    end
                    for _, req in ipairs(AsTable(perk.prerequisites)) do
                        if not allPerkIds[req] then
                            Report(issues, pctx, "prerequisite '" .. tostring(req) .. "' not found in any tree")
                        end
                    end
                    for _, req in ipairs(AsTable(perk.prerequisites_any)) do
                        if not allPerkIds[req] then
                            Report(issues, pctx, "prerequisites_any '" .. tostring(req) .. "' not found in any tree")
                        end
                    end
                    for _, exc in ipairs(AsTable(perk.exclusive_with)) do
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

    -- The inventory is shape-checked with or without a system: it is the one
    -- character field whose contents can arrive from the wire (the `resolved`
    -- snapshots), and the comm receive path validates shape only. The weapon
    -- id set is what the system adds here - see CheckInventory.
    local weaponIds = (type(system) == "table") and IdSet(system.weapons) or nil
    CheckInventory(char, weaponIds, issues)

    if type(system) ~= "table" then
        return #issues == 0, issues
    end

    -- Sets of valid ids drawn from the system definition.
    local attrIds = IdSet(system.attributes)
    local skillIds = IdSet(system.skills)
    local perkIds = {}
    for _, tree in ipairs(AsTable(system.perk_trees)) do
        for id in pairs(IdSet(tree.perks)) do perkIds[id] = true end
    end

    -- Base attribute keys must be known attributes, and a numeric value must be
    -- finite (the JSON/TOML decoders reject NaN/inf, but the Lua-literal import
    -- path and AceSerializer over the wire deliver them intact, and they would
    -- flow straight into sheet math).
    for key, value in pairs(AsTable(char.attributes)) do
        if not attrIds[key] then
            Report(issues, "character.attributes", "unknown attribute '" .. tostring(key) .. "'")
        end
        if type(value) == "number" and (value ~= value or value == math.huge
            or value == -math.huge) then
            Report(issues, "character.attributes", "'" .. tostring(key) .. "' is not a finite number")
        end
    end

    -- Primary and AC attribute selections.
    if char.primary_attribute and not attrIds[char.primary_attribute] then
        Report(issues, "character", "unknown primary_attribute '" .. tostring(char.primary_attribute) .. "'")
    end
    if char.ac_attribute and not attrIds[char.ac_attribute] then
        Report(issues, "character", "unknown ac_attribute '" .. tostring(char.ac_attribute) .. "'")
    end

    -- When the system constrains AC/initiative to candidate attributes, an
    -- out-of-list pick is reported (the engine would ignore it for the best
    -- candidate, which is probably not what the author meant).
    local ds = system.derived_stats
    if type(ds) == "table" then
        for _, pair in ipairs({ { "ac_attribute", "ac_attributes" }, { "init_attribute", "init_attributes" } }) do
            local pick, listKey = char[pair[1]], pair[2]
            local list = ds[listKey]
            if pick and type(list) == "table" and #list > 0 then
                local ok = false
                for _, id in ipairs(list) do
                    if id == pick then ok = true end
                end
                if not ok then
                    Report(issues, "character", pair[1] .. " '" .. tostring(pick)
                        .. "' is not one of the system's " .. listKey)
                end
            end
        end
    end

    -- Accomplished skills and saves reference real ids.
    for _, id in ipairs(AsTable(char.accomplished_skills)) do
        if not skillIds[id] then
            Report(issues, "character.accomplished_skills", "unknown skill '" .. tostring(id) .. "'")
        end
    end
    for _, id in ipairs(AsTable(char.accomplished_saves)) do
        if not attrIds[id] then
            Report(issues, "character.accomplished_saves", "unknown save attribute '" .. tostring(id) .. "'")
        end
    end

    -- Custom-perk effects must reference real skills/attributes; a `replaces`
    -- target must be a real sphere perk.
    for i, perk in ipairs(AsTable(char.custom_perks)) do
        local pctx = "custom_perks[" .. i .. "]"
        if type(perk) ~= "table" then
            Report(issues, pctx, "should be a table, got " .. type(perk))
        else
            if perk.replaces and not perkIds[perk.replaces] then
                Report(issues, pctx, "replaces unknown perk '" .. tostring(perk.replaces) .. "'")
            end
            for j, e in ipairs(AsTable(perk.effects)) do
                local ctx = pctx .. ".effects[" .. j .. "]"
                if type(e) ~= "table" then
                    Report(issues, ctx, "should be a table, got " .. type(e))
                else
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
        end
    end

    -- Perk choices must key real perks and pick ids valid for the choice kind.
    local dmgTypes = {}
    for _, d in ipairs(AsTable(system.damage_types)) do dmgTypes[d] = true end
    for pid, chosen in pairs(AsTable(char.perk_choices)) do
        if not perkIds[pid] then
            Report(issues, "perk_choices", "unknown perk '" .. tostring(pid) .. "'")
        else
            local kind
            for _, tree in ipairs(AsTable(system.perk_trees)) do
                for _, p in ipairs(AsTable(tree.perks)) do
                    if p.id == pid and type(p.choice) == "table" then kind = p.choice.kind end
                end
            end
            for _, cid in ipairs(AsTable(chosen)) do
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

-- Validates a single item-library record.
--
-- Returns two values: ok, issues
--   ok     - true when no issues were found
--   issues - list of human-readable problem strings (empty when ok)
--
-- The library is global and system-independent, so nothing here resolves
-- against a system: an item's optional weapon_id link is checked where a
-- system is actually at hand (/pmt validate), and a dangling one only costs
-- the item its attack bonus.
function Schema.ValidateItem(item)
    local issues = {}
    CheckItem(item, "item", issues)
    return #issues == 0, issues
end

-- Validates the whole item library ({ [id] = item }).
--
-- Returns two values: ok, issues (as ValidateItem). Beyond each record's shape
-- this checks that every entry is filed under its own id - inventories resolve
-- references by table key, so a record whose `id` disagrees with its key would
-- round-trip through export/import as a different item.
function Schema.ValidateItemLibrary(lib)
    local issues = {}
    if type(lib) ~= "table" then
        return false, { "item library: not a table" }
    end
    for key, item in pairs(lib) do
        local ctx = "item[" .. tostring(key) .. "]"
        if type(key) ~= "string" then
            Report(issues, ctx, "key should be a string, got " .. type(key))
        end
        CheckItem(item, ctx, issues)
        if type(item) == "table" and type(item.id) == "string" and item.id ~= key then
            Report(issues, ctx, "id '" .. item.id .. "' does not match its key")
        end
    end
    return #issues == 0, issues
end
