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
--   .ValidateItemLibrary, .ValidateFeatPack, .ValidateSpellPack,
--   .IsDieNotation

local ADDON, ns = ...

-- Field requirements per record type. Each entry maps a field name to its
-- expected Lua type; everything listed here must be present and well-typed.
local SYSTEM_REQUIRED = { system_name = "string", attributes = "table" }
local ATTRIBUTE_REQUIRED = { id = "string", name = "string" }
local SKILL_REQUIRED = { id = "string", name = "string", attribute = "string" }
local WEAPON_REQUIRED = { id = "string", name = "string" }
local CHAR_REQUIRED = { name = "string", level = "number", attributes = "table" }
local ITEM_REQUIRED = { id = "string", name = "string", kind = "string" }
local FEAT_PACK_REQUIRED = { pack_name = "string", lines = "table" }
local FEAT_LINE_REQUIRED = { id = "string", name = "string", attribute = "string" }
local FEAT_RANK_REQUIRED = { name = "string" }
local SPELL_PACK_REQUIRED = { pack_name = "string", spells = "table" }
local SPELL_SCHOOL_REQUIRED = { id = "string", name = "string" }
local SPELL_REQUIRED = { id = "string", name = "string", school = "string", rank = "number" }

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
local MAX_ITEM_EFFECTS = 10   -- matches the item wizard's row cap

-- Bound on a character's level. Level is the number every other number hangs
-- off - hit dice, the mana formula, and per_level effects, which multiply
-- their (already bounded) value by it - so it is capped as well as required to
-- be finite: at level 1e308 a validated +/-99 effect still lands as inf in the
-- derived stats. The default cap in Modules/CharacterEditor.lua is level 30,
-- so this leaves any system room to spare.
local MAX_LEVEL = 200
-- A character's own free text. `name` rides chat lines, the sheet title, the
-- Cached Sheets rows and a popup argument, and `quote` is concatenated into the
-- sheet subtitle - all reachable from a sheet another player shared, so both
-- need a type and a length, not just a type. Generous next to what anyone types
-- by hand; the point is that 200 KB cannot arrive.
local MAX_CHAR_NAME = 64
local MAX_CHAR_TEXT = 2048

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

-- Checks an optional ac_mod_cap field (both the library item and the wire
-- `resolved` snapshot carry one): numeric within bounds like a bonus, and
-- never negative - a cap limits the AC modifier's benefit, a penalty belongs
-- in an "ac" effect. Out-of-range negatives are already reported by the
-- bounds check, so the negative report covers the in-range ones.
local function CheckCap(value, ctx, issues)
    CheckNumeric(value, ctx, "ac_mod_cap", MAX_BONUS, issues)
    if type(value) == "number" and value < 0 and value >= -MAX_BONUS then
        Report(issues, ctx, "field 'ac_mod_cap' should not be negative")
    end
end

-- True when `value` is single-roll dice notation: "XdY" with an optional flat
-- "+K"/"-K" tail ("1d8", "d6", "2d6+1", "1d10-1"). Bounds mirror the dice
-- roller's caps (Modules/Dice.lua), so anything that validates here parses
-- there. Exported: CharacterSheet gates the damage click-target on it (a die
-- that cannot roll must not render as rollable), and the item wizard uses it
-- for live field feedback.
function Schema.IsDieNotation(value)
    if type(value) ~= "string" then return false end
    local count, sides, flat = value:lower():match("^(%d*)d(%d+)([%+%-]?%d*)$")
    if not sides then return false end
    count = (count == "") and 1 or tonumber(count)
    sides = tonumber(sides)
    if count < 1 or count > 100 or sides < 2 or sides > 1000 then return false end
    if flat ~= "" and (not flat:match("^[%+%-]%d+$") or tonumber(flat:sub(2)) > 999) then
        return false
    end
    return true
end

-- Checks an optional damage-die field: a capped string in die notation. Both
-- the library item and the wire `resolved` snapshot carry these, and the
-- notation feeds the dice roller on click - garbage must be reported, not
-- rolled.
local function CheckDie(value, ctx, field, issues)
    CheckText(value, ctx, field, MAX_ITEM_NAME, issues)
    if type(value) == "string" and not Schema.IsDieNotation(value) then
        Report(issues, ctx, "field '" .. field
            .. "' is not dice notation (like '1d8' or '2d6+1')")
    end
end

-- The wield categories a weapon item may declare (how many hands it takes,
-- and so which wield states the sheet's toggle offers). Optional: an item
-- without one inherits from its linked system weapon, or defaults to a plain
-- one-hander.
local WEAPON_CATEGORIES = { light = true, one_hand = true, versatile = true, two_hand = true }
local WIELD_STATES = { main = true, off = true, two = true }

-- Checks an optional weapon-category field against the enum.
local function CheckCategory(value, ctx, issues)
    if value == nil then return end
    if not WEAPON_CATEGORIES[value] then
        Report(issues, ctx, "field 'category' should be one of light / one_hand /"
            .. " versatile / two_hand, got '" .. tostring(value) .. "'")
    end
end

-- Checks an optional string field for type only. Pack text (descriptions,
-- ranges, types) carries rules prose of arbitrary length, so unlike item text
-- it is not capped - matching how the rest of the rules prose is treated.
local function CheckString(value, ctx, field, issues)
    if value ~= nil and type(value) ~= "string" then
        Report(issues, ctx, "field '" .. field .. "' should be string, got " .. type(value))
    end
end

-- Checks an optional version field: packs and systems stamp these as either
-- "1.01" strings or plain numbers, so both pass.
local function CheckVersion(value, ctx, issues)
    if value ~= nil and type(value) ~= "string" and type(value) ~= "number" then
        Report(issues, ctx, "field 'version' should be string or number, got " .. type(value))
    end
end

-- Checks an optional list of finite numbers (the per-rank requirement tables).
local function CheckNumberList(list, ctx, field, issues)
    if list == nil then return end
    if type(list) ~= "table" then
        Report(issues, ctx, "field '" .. field .. "' should be a list, got " .. type(list))
        return
    end
    for i, n in ipairs(list) do
        CheckNumeric(n, ctx, field .. "[" .. i .. "]", nil, issues)
        if type(n) ~= "number" then
            Report(issues, ctx, field .. "[" .. i .. "] should be number, got " .. type(n))
        end
    end
end

-- Checks an optional list of id strings (a character's origin traits and
-- accomplished lists). The ids resolve against the system wherever one is at
-- hand; here only the container and the entry types are enforced - the sheet
-- iterates these lists on every render, so a scalar in place of one throws.
local function CheckIdList(list, ctx, field, issues)
    if list == nil then return end
    if type(list) ~= "table" then
        Report(issues, ctx, "field '" .. field .. "' should be a list, got " .. type(list))
        return
    end
    for i, id in ipairs(list) do
        if type(id) ~= "string" then
            Report(issues, ctx, field .. "[" .. i .. "] should be string, got " .. type(id))
        end
    end
end

-- Checks an optional cost record ({ ap = n, mana = n }): both fields optional,
-- numeric, finite and non-negative. Costs render on the sheet and pickers, so
-- a malformed one degrades display but must never poison arithmetic.
local function CheckCost(cost, ctx, issues)
    if cost == nil then return end
    if type(cost) ~= "table" then
        Report(issues, ctx, "field 'cost' should be a table, got " .. type(cost))
        return
    end
    for _, field in ipairs({ "ap", "mana" }) do
        local v = cost[field]
        CheckNumeric(v, ctx, "cost." .. field, MAX_BONUS, issues)
        if type(v) == "number" and v < 0 then
            Report(issues, ctx, "cost." .. field .. " must not be negative")
        end
    end
end

-- Checks an optional effects list: each entry must be a table. Effect contents
-- follow the shared vocabulary (Modules/CharacterSheet.lua) where unknown
-- types are informational, so only the container shape is enforced here - plus
-- `per_level`, which is a flag the engine tests for truthiness: a stray
-- `per_level = "no"` would scale the value anyway, inverting what was written.
local function CheckEffects(effects, ctx, issues)
    if effects == nil then return end
    if type(effects) ~= "table" then
        Report(issues, ctx, "field 'effects' should be a list, got " .. type(effects))
        return
    end
    for j, e in ipairs(effects) do
        local ectx = ctx .. ".effects[" .. j .. "]"
        if type(e) ~= "table" then
            Report(issues, ectx, "should be a table, got " .. type(e))
        elseif e.per_level ~= nil and type(e.per_level) ~= "boolean" then
            Report(issues, ectx, "field 'per_level' should be boolean, got " .. type(e.per_level))
        end
    end
end

-- Checks an optional click-to-roll check ({ attribute = id } or
-- { skill = id }, exactly one of the two): the sheet rolls d20 + that
-- modifier when the feat/spell row is clicked. attrIds/skillIds are the
-- system's id sets, or nil when no system is at hand (only the shape is
-- enforced then, as everywhere else in the pack validators).
local function CheckRollCheck(check, ctx, attrIds, skillIds, issues)
    if check == nil then return end
    if type(check) ~= "table" then
        Report(issues, ctx, "field 'check' should be a table, got " .. type(check))
        return
    end
    local hasAttr, hasSkill = check.attribute ~= nil, check.skill ~= nil
    if hasAttr == hasSkill then
        Report(issues, ctx, "field 'check' needs exactly one of 'attribute' or 'skill'")
        return
    end
    if hasAttr then
        if type(check.attribute) ~= "string" then
            Report(issues, ctx, "check.attribute should be a string, got " .. type(check.attribute))
        elseif attrIds and not attrIds[check.attribute] then
            Report(issues, ctx, "unknown check attribute '" .. check.attribute .. "'")
        end
    else
        if type(check.skill) ~= "string" then
            Report(issues, ctx, "check.skill should be a string, got " .. type(check.skill))
        elseif skillIds and not skillIds[check.skill] then
            Report(issues, ctx, "unknown check skill '" .. check.skill .. "'")
        end
    end
end

-- Checks an optional item effects list. Weapon and equipment items may carry
-- effect records from the shared vocabulary (Modules/CharacterSheet.lua) that
-- fold into the sheet's totals while the item is equipped. Unlike pack effects
-- (CheckEffects above, container shape only), every field here is bounded:
-- item effects also arrive inside a shared inventory's `resolved` snapshot,
-- which is attacker-controlled and reaches saves, skills and attributes.
local function CheckItemEffects(effects, ctx, issues)
    if effects == nil then return end
    if type(effects) ~= "table" then
        Report(issues, ctx, "field 'effects' should be a list, got " .. type(effects))
        return
    end
    if #effects > MAX_ITEM_EFFECTS then
        Report(issues, ctx, "has more than " .. MAX_ITEM_EFFECTS .. " effects")
    end
    for j, e in ipairs(effects) do
        local ectx = ctx .. ".effects[" .. j .. "]"
        if type(e) ~= "table" then
            Report(issues, ectx, "should be a table, got " .. type(e))
        else
            if type(e.type) ~= "string" then
                Report(issues, ectx, "field 'type' should be string, got " .. type(e.type))
            else
                -- Capped like the other item strings: an effect summary is
                -- rendered into the tooltip on every inventory-row hover
                -- (EffectSummary in UI/Widgets.lua), type name included.
                CheckText(e.type, ectx, "type", MAX_ITEM_NAME, issues)
            end
            CheckNumeric(e.value, ectx, "value", MAX_BONUS, issues)
            for _, field in ipairs({ "id", "skill", "school", "add_modifier" }) do
                CheckText(e[field], ectx, field, MAX_ITEM_NAME, issues)
            end
            if e.per_level ~= nil and type(e.per_level) ~= "boolean" then
                Report(issues, ectx,
                    "field 'per_level' should be boolean, got " .. type(e.per_level))
            end
        end
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
    -- ac_bonus is the retired +AC field (now an "ac" effect): still accepted
    -- so old export files import, where the value is folded on the way in.
    CheckNumeric(item.ac_bonus, ctx, "ac_bonus", MAX_BONUS, issues)
    CheckCap(item.ac_mod_cap, ctx, issues)
    CheckNumeric(item.default_count, ctx, "default_count", MAX_COUNT, issues)
    CheckNumeric(item.version, ctx, "version", nil, issues)
    CheckDie(item.die, ctx, "die", issues)
    CheckDie(item.versatile_die, ctx, "versatile_die", issues)
    CheckCategory(item.category, ctx, issues)
    CheckItemEffects(item.effects, ctx, issues)
    -- Gear is counted, never equipped, so its effects would never apply -
    -- almost certainly an authoring slip (the wizard drops them on kind switch).
    if item.kind == "gear" and item.effects ~= nil then
        Report(issues, ctx, "gear cannot carry effects (only equipped items apply them)")
    end
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
    CheckCap(r.ac_mod_cap, ctx, issues)
    CheckDie(r.die, ctx, "die", issues)
    CheckDie(r.versatile_die, ctx, "versatile_die", issues)
    CheckCategory(r.category, ctx, issues)
    CheckItemEffects(r.effects, ctx, issues)
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
            -- How an equipped weapon is held. The enum is checked here; whether
            -- the state suits the item's category is resolved leniently at
            -- render time (an invalid pairing falls back, never errors).
            if entry.wield ~= nil and not WIELD_STATES[entry.wield] then
                Report(issues, ctx, "field 'wield' should be one of main / off / two, got '"
                    .. tostring(entry.wield) .. "'")
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
-- throw and trait must name attributes that actually exist.
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
    -- downstream - accomplished lists, effect targets - keys skills by id, so a
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

    -- Progression config: the pick budget knobs are plain numbers.
    if system.progression ~= nil then
        if type(system.progression) ~= "table" then
            Report(issues, "system", "field 'progression' should be a table, got "
                .. type(system.progression))
        else
            CheckNumeric(system.progression.picks_level_1, "progression", "picks_level_1", nil, issues)
            CheckNumeric(system.progression.picks_per_level, "progression", "picks_per_level", nil, issues)
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
        -- Optional action declarations: the Aim bonus and the death-save
        -- block. Wrong types would reach roll arithmetic and the pip tracker.
        CheckNumeric(ds.aim_bonus, "derived_stats", "aim_bonus", MAX_BONUS, issues)
        if ds.death_saves ~= nil then
            if type(ds.death_saves) ~= "table" then
                Report(issues, "derived_stats",
                    "field 'death_saves' should be a table, got " .. type(ds.death_saves))
            else
                for _, field in ipairs({ "threshold", "successes", "failures" }) do
                    CheckNumeric(ds.death_saves[field], "derived_stats.death_saves",
                        field, MAX_BONUS, issues)
                end
            end
        end
        if ds.fatigue ~= nil then
            if type(ds.fatigue) ~= "table" then
                Report(issues, "derived_stats",
                    "field 'fatigue' should be a table, got " .. type(ds.fatigue))
            else
                for _, field in ipairs({ "max", "penalty_per_level", "speed_half_at" }) do
                    CheckNumeric(ds.fatigue[field], "derived_stats.fatigue",
                        field, MAX_BONUS, issues)
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

    return #issues == 0, issues
end

-- Validates a single character against an optional system definition and
-- optional feat/spell packs.
--
-- Returns two values: ok, issues
--   ok     - true when no issues were found
--   issues - list of human-readable problem strings (empty when ok)
--
-- When `system` is supplied, attribute keys, the primary/ac/cast attributes
-- and accomplished skills/saves are checked against it. When `system` is nil
-- only the character's own shape is validated - but that shape covers every
-- field the sheet computes from (level, resources, the accomplished/trait
-- lists, the inventory and the homebrew records with their effects), because
-- a shared sheet reaches us exactly that way (the comm receive path in
-- Modules/Sharing.lua) and Compute must not throw on what it is handed.
--
-- `packs` is an optional { feats = featPack, spells = spellPack } table (the
-- active packs, see ns.GetFeatPack/GetSpellPack). Pack membership resolves
-- independently of the system: char.feats/char.spells are shape-checked
-- always, and checked against the packs whenever those are at hand.
function Schema.ValidateCharacter(char, system, packs)
    local issues = {}
    if type(char) ~= "table" then
        return false, { "character: entry is not a table" }
    end

    CheckRequired(char, CHAR_REQUIRED, "character", issues)

    -- Level carries a magnitude cap on top of that (see MAX_LEVEL). A missing,
    -- non-numeric or non-finite level was reported just above, so only a usable
    -- number reaches the bounds check.
    if type(char.level) == "number" and char.level == char.level
        and char.level ~= math.huge and char.level ~= -math.huge then
        CheckNumeric(char.level, "character", "level", MAX_LEVEL, issues)
    end

    -- The id sets the system contributes, or nil when there is no system to
    -- resolve against - as in the pack validators, a nil set means "check the
    -- shape, resolve nothing".
    local hasSystem = type(system) == "table"
    local attrIds = hasSystem and IdSet(system.attributes) or nil
    local skillIds = hasSystem and IdSet(system.skills) or nil
    local weaponIds = hasSystem and IdSet(system.weapons) or nil

    -- Free text the UI concatenates. CheckRequired already established that
    -- `name` is a string; these add the bounds. `quote` and `notes` were
    -- previously unchecked entirely - a shared sheet carrying `quote = {}`
    -- validated, computed and cached, then threw in the sheet subtitle on every
    -- open (UI/CharacterSheetUI.lua).
    CheckText(char.name, "character", "name", MAX_CHAR_NAME, issues)
    CheckText(char.quote, "character", "quote", MAX_CHAR_TEXT, issues)
    CheckText(char.notes, "character", "notes", MAX_CHAR_TEXT, issues)

    -- Everything the sheet does arithmetic on or iterates over is checked with
    -- or without a system: a shared character arrives through the comm path,
    -- which validates shape only, and Compute would throw on a string where it
    -- expects a number or a scalar where it expects a list.
    for key, value in pairs(AsTable(char.attributes)) do
        CheckNumeric(value, "character.attributes", tostring(key), nil, issues)
    end
    for _, field in ipairs({ "max_hp", "current_hp", "temp_hp", "max_mana", "current_mana" }) do
        CheckNumeric(char[field], "character", field, nil, issues)
    end
    for _, field in ipairs({ "origin_traits", "accomplished_skills",
        "accomplished_saves", "accomplished_weapons" }) do
        CheckIdList(char[field], "character", field, issues)
    end
    CheckString(char.racial_trait, "character", "racial_trait", issues)

    -- The fatigue counter (only meaningful when the system declares fatigue,
    -- but shape-checked always - a shared sheet carries it over the wire).
    CheckNumeric(char.fatigue, "character", "fatigue", MAX_BONUS, issues)

    -- Death-save pips (only meaningful when the system declares death saves,
    -- but shape-checked always - a shared sheet carries them over the wire).
    if char.death_saves ~= nil then
        if type(char.death_saves) ~= "table" then
            Report(issues, "character",
                "field 'death_saves' should be a table, got " .. type(char.death_saves))
        else
            CheckNumeric(char.death_saves.successes, "character.death_saves",
                "successes", MAX_BONUS, issues)
            CheckNumeric(char.death_saves.failures, "character.death_saves",
                "failures", MAX_BONUS, issues)
            if char.death_saves.stable ~= nil
                and type(char.death_saves.stable) ~= "boolean" then
                Report(issues, "character.death_saves",
                    "field 'stable' should be boolean, got " .. type(char.death_saves.stable))
            end
        end
    end

    -- The inventory is shape-checked with or without a system: it is the one
    -- character field whose contents can arrive from the wire (the `resolved`
    -- snapshots), and the comm receive path validates shape only. The weapon
    -- id set is what the system adds here - see CheckInventory.
    CheckInventory(char, weaponIds, issues)

    -- Feats and spells, like the inventory, are checked with or without a
    -- system - their references live in packs, not the system definition.
    local featPack = type(packs) == "table" and type(packs.feats) == "table" and packs.feats or nil
    local spellPack = type(packs) == "table" and type(packs.spells) == "table" and packs.spells or nil

    -- char.feats is a { [lineId] = rank } map onto the feat pack's lines.
    if char.feats ~= nil then
        if type(char.feats) ~= "table" then
            Report(issues, "character", "field 'feats' should be a table, got " .. type(char.feats))
        else
            for lineId, rank in pairs(char.feats) do
                local ctx = "character.feats[" .. tostring(lineId) .. "]"
                if type(lineId) ~= "string" then
                    Report(issues, "character.feats", "key '" .. tostring(lineId) .. "' should be a string")
                elseif type(rank) ~= "number" or rank ~= rank or rank == math.huge
                    or rank == -math.huge or rank < 1 then
                    Report(issues, ctx, "rank should be a number of at least 1")
                elseif featPack then
                    local line
                    for _, l in ipairs(AsTable(featPack.lines)) do
                        if type(l) == "table" and l.id == lineId then line = l end
                    end
                    if not line then
                        Report(issues, ctx, "unknown feat line")
                    elseif type(line.ranks) == "table" and rank > #line.ranks then
                        Report(issues, ctx, "rank " .. rank .. " exceeds the line's "
                            .. #line.ranks .. " rank(s)")
                    end
                end
            end
        end
    end

    -- char.spells is a flat list of spell ids from the spell pack. Beyond
    -- membership, knowing spells from two mutually-opposed schools violates
    -- the pack's exclusivity locks.
    if char.spells ~= nil then
        if type(char.spells) ~= "table" then
            Report(issues, "character", "field 'spells' should be a table, got " .. type(char.spells))
        else
            local spellById = {}
            if spellPack then
                for _, s in ipairs(AsTable(spellPack.spells)) do
                    if type(s) == "table" and s.id then spellById[s.id] = s end
                end
            end
            local schoolsKnown = {}
            for i, id in ipairs(char.spells) do
                if type(id) ~= "string" then
                    Report(issues, "character.spells[" .. i .. "]", "should be a string, got " .. type(id))
                elseif spellPack then
                    local spell = spellById[id]
                    if not spell then
                        Report(issues, "character.spells", "unknown spell '" .. id .. "'")
                    elseif type(spell.school) == "string" then
                        schoolsKnown[spell.school] = true
                    end
                end
            end
            if spellPack then
                for _, school in ipairs(AsTable(spellPack.schools)) do
                    if type(school) == "table" and schoolsKnown[school.id]
                        and type(school.opposed) == "string" and schoolsKnown[school.opposed]
                        -- Report each opposed pair once, not once per side.
                        and school.id < school.opposed then
                        Report(issues, "character.spells", "knows spells from opposed schools '"
                            .. school.id .. "' and '" .. school.opposed .. "'")
                    end
                end
            end
        end
    end

    -- The cast attribute must be one of the spell pack's candidates when that
    -- pack constrains them (the system-side existence check is below, with
    -- the other attribute picks).
    if char.cast_attribute ~= nil then
        CheckString(char.cast_attribute, "character", "cast_attribute", issues)
        local candidates = spellPack and AsTable(spellPack.cast_attributes) or {}
        if type(char.cast_attribute) == "string" and #candidates > 0 then
            local ok = false
            for _, id in ipairs(candidates) do
                if id == char.cast_attribute then ok = true end
            end
            if not ok then
                Report(issues, "character", "cast_attribute '" .. char.cast_attribute
                    .. "' is not one of the spell pack's cast_attributes")
            end
        end
    end

    -- Homebrew lists (feats and spells). Their shape is checked with or without
    -- a system - they ride the wire inside a shared sheet and their effects fold
    -- into every derived stat - while the id resolution (skills, attributes)
    -- only runs when a system is at hand. The picker metadata (cost, save) is
    -- bounded like the pack equivalents.
    for _, listName in ipairs({ "custom_feats", "custom_spells" }) do
        local list = char[listName]
        if list ~= nil and type(list) ~= "table" then
            Report(issues, "character",
                "field '" .. listName .. "' should be a list, got " .. type(list))
        end
        for i, rec in ipairs(AsTable(list)) do
            local pctx = listName .. "[" .. i .. "]"
            if type(rec) ~= "table" then
                Report(issues, pctx, "should be a table, got " .. type(rec))
            else
                CheckNumeric(rec.level, pctx, "level", MAX_LEVEL, issues)
                CheckCost(rec.cost, pctx, issues)
                CheckString(rec.type, pctx, "type", issues)
                CheckString(rec.range, pctx, "range", issues)
                if attrIds and type(rec.save) == "string" and not attrIds[rec.save] then
                    Report(issues, pctx, "unknown save attribute '" .. rec.save .. "'")
                end
                CheckRollCheck(rec.check, pctx, attrIds, skillIds, issues)
                if rec.effects ~= nil and type(rec.effects) ~= "table" then
                    Report(issues, pctx,
                        "field 'effects' should be a list, got " .. type(rec.effects))
                end
                for j, e in ipairs(AsTable(rec.effects)) do
                    local ctx = pctx .. ".effects[" .. j .. "]"
                    if type(e) ~= "table" then
                        Report(issues, ctx, "should be a table, got " .. type(e))
                    else
                        -- The value is bounded like an item effect's: it is
                        -- summed into saves, skills and attributes, and
                        -- per_level multiplies it by the character's level.
                        CheckNumeric(e.value, ctx, "value", MAX_BONUS, issues)
                        if e.per_level ~= nil and type(e.per_level) ~= "boolean" then
                            Report(issues, ctx,
                                "field 'per_level' should be boolean, got " .. type(e.per_level))
                        end
                        if skillIds and (e.type == "skill" or e.type == "accomplish_skill")
                            and (e.skill or e.id) and not skillIds[e.skill or e.id] then
                            Report(issues, ctx,
                                "unknown skill '" .. tostring(e.skill or e.id) .. "'")
                        end
                        if attrIds and (e.type == "attribute" or e.type == "save")
                            and e.id and not attrIds[e.id] then
                            Report(issues, ctx, "unknown attribute '" .. tostring(e.id) .. "'")
                        end
                        if attrIds and e.add_modifier and not attrIds[e.add_modifier] then
                            Report(issues, ctx, "unknown add_modifier attribute '"
                                .. tostring(e.add_modifier) .. "'")
                        end
                    end
                end
            end
        end
    end

    if not hasSystem then
        return #issues == 0, issues
    end

    -- Base attribute keys must be known attributes (their values were checked
    -- above, with or without a system).
    for key in pairs(AsTable(char.attributes)) do
        if not attrIds[key] then
            Report(issues, "character.attributes", "unknown attribute '" .. tostring(key) .. "'")
        end
    end

    -- Primary, AC and cast attribute selections.
    if char.primary_attribute and not attrIds[char.primary_attribute] then
        Report(issues, "character", "unknown primary_attribute '" .. tostring(char.primary_attribute) .. "'")
    end
    if char.ac_attribute and not attrIds[char.ac_attribute] then
        Report(issues, "character", "unknown ac_attribute '" .. tostring(char.ac_attribute) .. "'")
    end
    if type(char.cast_attribute) == "string" and not attrIds[char.cast_attribute] then
        Report(issues, "character", "unknown cast_attribute '" .. char.cast_attribute .. "'")
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

    return #issues == 0, issues
end

-- Validates a feats pack: an importable collection of ability lines, each a
-- ladder of ranks (rank N implicitly requires rank N-1 - array position IS the
-- prerequisite chain, so no graph is validated here).
--
-- Returns two values: ok, issues (as ValidateSystem).
--
-- `system` is optional: when given, line attributes and rank saves must name
-- attributes that exist in it; when nil (comm receive before adoption, or a
-- pack imported ahead of its system) only the pack's own shape is validated.
function Schema.ValidateFeatPack(pack, system)
    local issues = {}
    if type(pack) ~= "table" then
        return false, { "feat pack: definition is not a table" }
    end
    if pack.kind ~= nil and pack.kind ~= "feats" then
        Report(issues, "feat pack", "field 'kind' should be \"feats\", got '" .. tostring(pack.kind) .. "'")
    end
    CheckRequired(pack, FEAT_PACK_REQUIRED, "feat pack", issues)
    CheckString(pack.for_system, "feat pack", "for_system", issues)
    CheckVersion(pack.version, "feat pack", issues)
    CheckNumberList(pack.rank_attribute_req, "feat pack", "rank_attribute_req", issues)

    local attrIds = (type(system) == "table") and IdSet(system.attributes) or nil
    local skillIds = (type(system) == "table") and IdSet(system.skills) or nil
    local lineSeen = {}
    for i, line in ipairs(AsTable(pack.lines)) do
        local ctx = "line[" .. i .. "]"
        if CheckRequired(line, FEAT_LINE_REQUIRED, ctx, issues) then
            if lineSeen[line.id] then Report(issues, ctx, "duplicate id '" .. line.id .. "'") end
            lineSeen[line.id] = true
            if attrIds and not attrIds[line.attribute] then
                Report(issues, ctx, "unknown attribute '" .. tostring(line.attribute) .. "'")
            end
            CheckString(line.description, ctx, "description", issues)
            if type(line.ranks) ~= "table" then
                Report(issues, ctx, "field 'ranks' should be a table, got " .. type(line.ranks))
            elseif #line.ranks == 0 then
                Report(issues, ctx, "has no ranks")
            else
                for r, rank in ipairs(line.ranks) do
                    local rctx = ctx .. ".rank[" .. r .. "]"
                    if CheckRequired(rank, FEAT_RANK_REQUIRED, rctx, issues) then
                        CheckString(rank.type, rctx, "type", issues)
                        CheckString(rank.range, rctx, "range", issues)
                        CheckString(rank.description, rctx, "description", issues)
                        CheckString(rank.save, rctx, "save", issues)
                        if attrIds and rank.save and not attrIds[rank.save] then
                            Report(issues, rctx, "unknown save attribute '" .. tostring(rank.save) .. "'")
                        end
                        CheckNumeric(rank.attribute_req, rctx, "attribute_req", nil, issues)
                        CheckCost(rank.cost, rctx, issues)
                        CheckEffects(rank.effects, rctx, issues)
                        CheckRollCheck(rank.check, rctx, attrIds, skillIds, issues)
                    end
                end
            end
        end
    end
    return #issues == 0, issues
end

-- Validates a spells pack: schools (with optional mutual exclusion via
-- `opposed`) plus a flat spell list gated by rank and cast attribute.
--
-- Returns two values: ok, issues (as ValidateSystem).
--
-- `system` is optional, exactly as in ValidateFeatPack: cast attributes and
-- spell saves resolve against it only when it is at hand.
function Schema.ValidateSpellPack(pack, system)
    local issues = {}
    if type(pack) ~= "table" then
        return false, { "spell pack: definition is not a table" }
    end
    if pack.kind ~= nil and pack.kind ~= "spells" then
        Report(issues, "spell pack", "field 'kind' should be \"spells\", got '" .. tostring(pack.kind) .. "'")
    end
    CheckRequired(pack, SPELL_PACK_REQUIRED, "spell pack", issues)
    CheckString(pack.for_system, "spell pack", "for_system", issues)
    CheckVersion(pack.version, "spell pack", issues)
    CheckNumberList(pack.rank_cast_req, "spell pack", "rank_cast_req", issues)

    local attrIds = (type(system) == "table") and IdSet(system.attributes) or nil
    local skillIds = (type(system) == "table") and IdSet(system.skills) or nil
    for i, id in ipairs(AsTable(pack.cast_attributes)) do
        if type(id) ~= "string" then
            Report(issues, "spell pack", "cast_attributes[" .. i .. "] should be string, got " .. type(id))
        elseif attrIds and not attrIds[id] then
            Report(issues, "spell pack", "unknown attribute '" .. id .. "' in cast_attributes")
        end
    end

    -- Schools first, so spells and opposition can resolve against the full set.
    local schoolIds, opposedOf = {}, {}
    for i, school in ipairs(AsTable(pack.schools)) do
        local ctx = "school[" .. i .. "]"
        if CheckRequired(school, SPELL_SCHOOL_REQUIRED, ctx, issues) then
            if schoolIds[school.id] then Report(issues, ctx, "duplicate id '" .. school.id .. "'") end
            schoolIds[school.id] = true
            CheckString(school.description, ctx, "description", issues)
            CheckString(school.opposed, ctx, "opposed", issues)
            if type(school.opposed) == "string" then opposedOf[school.id] = school.opposed end
        end
    end
    -- Opposition must point at a real school, never at itself, and must be
    -- declared from both sides - the lock is symmetric in play, so a one-way
    -- declaration is almost certainly an authoring slip.
    for id, opp in pairs(opposedOf) do
        if not schoolIds[opp] then
            Report(issues, "school '" .. id .. "'", "opposed school '" .. opp .. "' not found")
        elseif opp == id then
            Report(issues, "school '" .. id .. "'", "opposes itself")
        elseif opposedOf[opp] ~= id then
            Report(issues, "school '" .. id .. "'", "opposes '" .. opp .. "' but '" .. opp
                .. "' does not oppose it back")
        end
    end

    local hasSchools = next(schoolIds) ~= nil
    local spellSeen = {}
    for i, spell in ipairs(AsTable(pack.spells)) do
        local ctx = "spell[" .. i .. "]"
        if CheckRequired(spell, SPELL_REQUIRED, ctx, issues) then
            if spellSeen[spell.id] then Report(issues, ctx, "duplicate id '" .. spell.id .. "'") end
            spellSeen[spell.id] = true
            if hasSchools and not schoolIds[spell.school] then
                Report(issues, ctx, "unknown school '" .. tostring(spell.school) .. "'")
            end
            if type(spell.rank) == "number" and spell.rank < 1 then
                Report(issues, ctx, "rank must be at least 1")
            end
            CheckString(spell.type, ctx, "type", issues)
            CheckString(spell.range, ctx, "range", issues)
            CheckString(spell.damage, ctx, "damage", issues)
            CheckString(spell.description, ctx, "description", issues)
            CheckString(spell.save, ctx, "save", issues)
            if attrIds and spell.save and not attrIds[spell.save] then
                Report(issues, ctx, "unknown save attribute '" .. tostring(spell.save) .. "'")
            end
            if spell.concentration ~= nil and type(spell.concentration) ~= "boolean" then
                Report(issues, ctx, "field 'concentration' should be boolean, got " .. type(spell.concentration))
            end
            CheckCost(spell.cost, ctx, issues)
            CheckEffects(spell.effects, ctx, issues)
            CheckRollCheck(spell.check, ctx, attrIds, skillIds, issues)
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
