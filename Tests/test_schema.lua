-- Schema.lua: shape checks, cross-references, and the races validation.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
local ns = T.load({}, "Schema.lua")
local Schema = ns.Schema

local function findIssue(issues, pattern)
    for _, issue in ipairs(issues or {}) do
        if issue:find(pattern, 1, true) then return issue end
    end
end

-- A minimal valid system.
local function MinimalSystem()
    return {
        system_name = "T",
        attributes = { { id = "a", name = "Alpha" }, { id = "b", name = "Beta" } },
    }
end
assert(Schema.ValidateSystem(MinimalSystem()))

-- Not-a-table and missing required fields.
local ok = Schema.ValidateSystem("nope")
assert(not ok)
local issues
ok, issues = Schema.ValidateSystem({ attributes = {} })
assert(not ok and findIssue(issues, "system_name"), "missing system_name not reported")

-- Duplicate attribute ids.
local sys = MinimalSystem()
sys.attributes[3] = { id = "a", name = "Again" }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "duplicate id"))

-- Duplicate ids in the other id-keyed lists: skills and weapons.
sys = MinimalSystem()
sys.skills = { { id = "s", name = "S1", attribute = "a" }, { id = "s", name = "S2", attribute = "a" } }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "duplicate id 's'"), "duplicate skill id not reported")
sys = MinimalSystem()
sys.weapons = { { id = "w", name = "W1" }, { id = "w", name = "W2" } }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "duplicate id 'w'"), "duplicate weapon id not reported")
-- Skills and weapons must reference real attributes (lists too).
sys = MinimalSystem()
sys.skills = { { id = "s", name = "S", attribute = "ghost" } }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "unknown attribute 'ghost'"))
sys = MinimalSystem()
sys.weapons = { { id = "w", name = "W", attribute = { "a", "ghost" } } }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "unknown attribute 'ghost'"))

-- The optional action declarations: aim_bonus is a bounded number, and
-- death_saves a small table of bounded numbers.
sys = MinimalSystem()
sys.derived_stats = { aim_bonus = 2,
    death_saves = { threshold = 10, successes = 3, failures = 3 } }
assert(Schema.ValidateSystem(sys), "aim + death-save config must validate")
sys.derived_stats = { aim_bonus = "loads" }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "aim_bonus"), "a non-numeric aim_bonus must be reported")
sys.derived_stats = { death_saves = 10 }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "death_saves"), "scalar death_saves must be reported")
sys.derived_stats = { death_saves = { threshold = 1 / 0 } }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "not a finite number"), "inf threshold must be reported")
sys.derived_stats = { fatigue = { max = 10, penalty_per_level = 1, speed_half_at = 5 } }
assert(Schema.ValidateSystem(sys), "fatigue config must validate")
sys.derived_stats = { fatigue = "lots" }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "fatigue"), "scalar fatigue config must be reported")
sys.derived_stats = { fatigue = { max = 0 / 0 } }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "not a finite number"), "NaN fatigue max must be reported")

-- derived_stats attribute couplings must resolve (incl. the tiebreaker and
-- the AC/init candidate lists).
sys = MinimalSystem()
sys.derived_stats = { initiative_tiebreaker = "ghost" }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "initiative_tiebreaker"))
sys.derived_stats = { initiative_tiebreaker = "a", ac_attributes = { "a", "ghost" } }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "in ac_attributes"))
sys.derived_stats = { ac_attributes = { "a" }, init_attributes = { "a", "b" } }
assert(Schema.ValidateSystem(sys))

-- A character pick outside the system's candidate list is reported.
local pickSys = MinimalSystem()
pickSys.derived_stats = { init_attributes = { "a" } }
local pickChar = { name = "C", level = 1, attributes = {}, init_attribute = "b" }
ok, issues = Schema.ValidateCharacter(pickChar, pickSys)
assert(not ok and findIssue(issues, "not one of the system's init_attributes"))
pickChar.init_attribute = "a"
assert(Schema.ValidateCharacter(pickChar, pickSys))

-- Races: cross-checked only when the system declares a races list.
sys = MinimalSystem()
sys.racial_traits = { { id = "t", name = "T", allowed_races = { "elf" } } }
assert(Schema.ValidateSystem(sys), "free-form races must pass without a races list")
sys.races = { "human" }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "unknown race 'elf'"))
sys.races = { "human", "elf" }
sys.racial_traits[1].disallowed_races = { "orc" }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "unknown race 'orc'"))

-- Characters: shape plus references into the system.
local refSys = MinimalSystem()
refSys.skills = { { id = "s1", name = "S1", attribute = "a" } }
local char = {
    name = "C", level = 1, attributes = { a = 1 },
    accomplished_skills = { "s1" }, accomplished_saves = { "a" },
    custom_feats = {
        { id = "h", name = "H", level = 1,
            effects = { { type = "skill", skill = "s1", add_modifier = "a" } } },
    },
}
assert(Schema.ValidateCharacter(char, refSys))
ok, issues = Schema.ValidateCharacter({ name = "C", level = "one", attributes = {} }, refSys)
assert(not ok and findIssue(issues, "field 'level'"))
char.attributes.ghost = 3
ok, issues = Schema.ValidateCharacter(char, refSys)
assert(not ok and findIssue(issues, "unknown attribute 'ghost'"))
char.attributes.ghost = nil
char.custom_feats[1].effects[1].skill = "ghost_skill"
ok, issues = Schema.ValidateCharacter(char, refSys)
assert(not ok and findIssue(issues, "unknown skill 'ghost_skill'"))
char.custom_feats[1].effects[1].skill = "s1"

-- Without a system only the shape is checked.
assert(Schema.ValidateCharacter({ name = "C", level = 1, attributes = { anything = 1 } }, nil))

-- Non-finite numbers validate as "number" by type but poison sheet math, so
-- they are shape errors: required numeric fields and attribute values alike.
-- (The JSON/TOML decoders reject them, but the Lua-literal import path and
-- AceSerializer over the wire deliver them intact.)
ok, issues = Schema.ValidateCharacter({ name = "C", level = 1 / 0, attributes = {} }, nil)
assert(not ok and findIssue(issues, "not a finite number"), "inf level not reported")
ok, issues = Schema.ValidateCharacter({ name = "C", level = 0 / 0, attributes = {} }, nil)
assert(not ok and findIssue(issues, "not a finite number"), "NaN level not reported")
ok, issues = Schema.ValidateCharacter({ name = "C", level = 1, attributes = { a = 1 / 0 } }, refSys)
assert(not ok and findIssue(issues, "not a finite number"), "inf attribute value not reported")
assert(Schema.ValidateCharacter({ name = "C", level = 1, attributes = { a = 3 } }, refSys),
    "finite values must still pass")

-- Type-confused input (a scalar where a list/table is expected) must be REPORTED,
-- never thrown: these fields legally arrive from a hand-edited paste or the wire,
-- and Validate* promises to report problems rather than crash the import path.
local function reports(fn, ...)
    local noThrow, res = pcall(fn, ...)
    assert(noThrow, "validator threw instead of reporting: " .. tostring(res))
    return res  -- the verdict boolean the validator itself returned
end

-- Systems: every optional list/table as a truthy scalar must not throw. Some are
-- reported invalid; others (a scalar where an optional list goes) are leniently
-- treated as empty - both are acceptable, a raw Lua error is not.
for _, mutate in ipairs({
    function(s) s.attributes = { 1 } end,
    function(s) s.attributes = 5 end,
    function(s) s.skills = 5 end,
    function(s) s.weapons = 5 end,
    function(s) s.spell_schools = 5 end,
    function(s) s.racial_traits = { { id = "t", name = "T", allowed_races = 5 } }; s.races = { "x" } end,
    function(s) s.derived_stats = { spell_attributes = 5 } end,
    function(s) s.accomplish_targets = { skills = { attribute_max = 5 } } end,
}) do
    local s = MinimalSystem()
    mutate(s)
    reports(Schema.ValidateSystem, s)  -- must not throw; verdict may be either
end

-- The cases that should be explicitly reported (a non-table record / choice).
do
    local s = MinimalSystem(); s.attributes = { 1 }
    ok, issues = Schema.ValidateSystem(s)
    assert(not ok and findIssue(issues, "should be a table"), "scalar attribute not reported")
end

-- Characters: every optional list/table as a truthy scalar.
local badCharSys = MinimalSystem()
for _, mutate in ipairs({
    function(c) c.attributes = 5 end,
    function(c) c.accomplished_skills = 5 end,
    function(c) c.accomplished_saves = 5 end,
    function(c) c.custom_feats = 5 end,
    function(c) c.custom_feats = { 5 } end,
    function(c) c.custom_spells = { { id = "h", name = "H", effects = 5 } } end,
    function(c) c.custom_spells = { { id = "h", name = "H", effects = { 5 } } } end,
}) do
    local c = { name = "C", level = 1, attributes = { a = 1 } }
    mutate(c)
    reports(Schema.ValidateCharacter, c, badCharSys)  -- must not throw; verdict is irrelevant
end

-- Homebrew records (custom_feats/custom_spells): the shapes the wizard
-- produces must validate clean against the system its pickers were drawn from.
local wizSys = MinimalSystem()
wizSys.skills = { { id = "s1", name = "S1", attribute = "a" } }
wizSys.spell_schools = { { id = "ev", name = "Evocation" } }
local function wizChar(effects)
    return {
        name = "C", level = 3, attributes = { a = 1 },
        custom_feats = { { id = "hf-1", name = "Wizard Feat", level = 3,
            description = "Written in game.", effects = effects } },
    }
end
ok, issues = Schema.ValidateCharacter(wizChar({
    { type = "attribute", id = "a", value = 2 },
    { type = "all_attributes", value = 1 },
    { type = "skill", skill = "s1", value = 2 },
    { type = "skill", skill = "s1", add_modifier = "b" },
    { type = "save", id = "b", value = 1, add_modifier = "a" },
    { type = "save_dc", school = "ev", value = 1 },
    { type = "spell_attack", value = 1 },
    { type = "ac", value = -1 },
    { type = "max_hp", value = 5 },
}), wizSys)
assert(ok, "wizard-shaped custom feat should validate: " .. tostring(issues and issues[1]))
-- A record with no effects at all (text only) is legal.
assert(Schema.ValidateCharacter(wizChar({}), wizSys))

-- Item library records: id, name and a known kind are required; the per-kind
-- extras must be finite numbers, the strings are capped, and an icon may only
-- be a plain texture name (a path escape must never reach SetTexture).
local function Item(extra)
    local i = { id = "itm_1", name = "Flame Dagger", kind = "weapon" }
    for k, v in pairs(extra or {}) do i[k] = v end
    return i
end
assert(Schema.ValidateItem(Item({ weapon_id = "w1", bonus = 2, icon = "inv_sword_04",
    description = "Warm.", version = 3 })))
assert(Schema.ValidateItem(Item({ kind = "equipment", ac_bonus = 1 })))
assert(Schema.ValidateItem(Item({ kind = "equipment", ac_bonus = 8, ac_mod_cap = 0 })),
    "heavy armor (cap 0) must validate")
assert(Schema.ValidateItem(Item({ kind = "gear", default_count = 10 })))
ok, issues = Schema.ValidateItem(Item({ kind = "hat" }))
assert(not ok and findIssue(issues, "unknown kind 'hat'"))
ok, issues = Schema.ValidateItem({ name = "No id", kind = "gear" })
assert(not ok and findIssue(issues, "field 'id'"))
ok, issues = Schema.ValidateItem(Item({ bonus = 1 / 0 }))
assert(not ok and findIssue(issues, "not a finite number"), "inf bonus not reported")
ok, issues = Schema.ValidateItem(Item({ ac_bonus = 0 / 0 }))
assert(not ok and findIssue(issues, "not a finite number"), "NaN ac_bonus not reported")
ok, issues = Schema.ValidateItem(Item({ ac_mod_cap = 0 / 0 }))
assert(not ok and findIssue(issues, "not a finite number"), "NaN ac_mod_cap not reported")
ok, issues = Schema.ValidateItem(Item({ ac_mod_cap = -1 }))
assert(not ok and findIssue(issues, "should not be negative"), "negative ac_mod_cap not reported")

-- Weapon die notation and wield category: dice notation the roller can parse
-- (the sheet's damage click feeds it straight to the dice module), a bounded
-- category enum, and the wield state an inventory entry may store.
assert(Schema.IsDieNotation("1d8") and Schema.IsDieNotation("d6")
    and Schema.IsDieNotation("2d6+1") and Schema.IsDieNotation("1d10-1")
    and Schema.IsDieNotation("1D8"), "plain notation must pass")
assert(not Schema.IsDieNotation("banana") and not Schema.IsDieNotation("1d")
    and not Schema.IsDieNotation("d0") and not Schema.IsDieNotation("0d6")
    and not Schema.IsDieNotation("101d6") and not Schema.IsDieNotation("1d1001")
    and not Schema.IsDieNotation("1d6+1000") and not Schema.IsDieNotation("1d6+")
    and not Schema.IsDieNotation(8), "garbage notation must fail")
assert(Schema.ValidateItem(Item({ die = "1d8", versatile_die = "1d10", category = "versatile" })))
ok, issues = Schema.ValidateItem(Item({ die = "banana" }))
assert(not ok and findIssue(issues, "not dice notation"), "a garbage die must be reported")
ok, issues = Schema.ValidateItem(Item({ versatile_die = "1d" }))
assert(not ok and findIssue(issues, "not dice notation"), "a garbage versatile die must be reported")
ok, issues = Schema.ValidateItem(Item({ category = "dual" }))
assert(not ok and findIssue(issues, "field 'category'"), "an unknown category must be reported")
ok, issues = Schema.ValidateItem(Item({ ac_mod_cap = 1000 }))
assert(not ok and findIssue(issues, "outside"), "an absurd ac_mod_cap must be reported")
ok, issues = Schema.ValidateItem(Item({ bonus = 500 }))
assert(not ok and findIssue(issues, "outside"), "an absurd bonus must be reported")
ok, issues = Schema.ValidateItem(Item({ default_count = 1e9 }))
assert(not ok and findIssue(issues, "outside"), "an absurd default_count must be reported")
ok, issues = Schema.ValidateItem(Item({ name = string.rep("x", 65) }))
assert(not ok and findIssue(issues, "longer than 64"))
ok, issues = Schema.ValidateItem(Item({ description = string.rep("x", 513) }))
assert(not ok and findIssue(issues, "longer than 512"))
ok, issues = Schema.ValidateItem(Item({ bonus = "two" }))
assert(not ok and findIssue(issues, "field 'bonus' should be number"))
for _, icon in ipairs({ "..\\..\\Interface\\evil", "Interface/Icons/x", "icon name", "" }) do
    ok, issues = Schema.ValidateItem(Item({ icon = icon }))
    assert(not ok and findIssue(issues, "plain texture name"), "bad icon accepted: " .. icon)
end
assert(Schema.ValidateItem(Item({ icon = "INV_Misc_Bag-08_x" })), "texture-name characters must pass")
assert(not reports(Schema.ValidateItem, "nope"), "a non-record item must be reported, not thrown")

-- The library as a whole: every record valid, filed under its own id.
assert(Schema.ValidateItemLibrary({}), "an empty library is valid")
assert(Schema.ValidateItemLibrary({ itm_1 = Item() }))
ok, issues = Schema.ValidateItemLibrary({ itm_9 = Item() })
assert(not ok and findIssue(issues, "does not match its key"))
ok, issues = Schema.ValidateItemLibrary({ itm_1 = Item({ kind = "hat" }) })
assert(not ok and findIssue(issues, "item[itm_1]"))
assert(not Schema.ValidateItemLibrary("nope"))
assert(not reports(Schema.ValidateItemLibrary, { itm_1 = 5 }))

-- Character inventories: thin references, shape-checked with or without a
-- system (the comm receive path validates shape only).
local function invChar(inventory)
    return { name = "C", level = 1, attributes = { a = 1 }, inventory = inventory }
end
assert(Schema.ValidateCharacter(invChar({
    { item_id = "itm_1", equipped = true },
    { item_id = "itm_2", count = 3 },
}), nil))
ok, issues = Schema.ValidateCharacter(invChar({ { equipped = true } }), nil)
assert(not ok and findIssue(issues, "field 'item_id'"))
ok, issues = Schema.ValidateCharacter(invChar({ { item_id = "i", count = 1 / 0 } }), nil)
assert(not ok and findIssue(issues, "not a finite number"))
ok, issues = Schema.ValidateCharacter(invChar({ { item_id = "i", equipped = "yes" } }), nil)
assert(not ok and findIssue(issues, "field 'equipped' should be boolean"))
-- The wield state is a small enum; the category pairing is resolved leniently
-- at render time, so only the enum is the schema's business.
assert(Schema.ValidateCharacter(invChar({
    { item_id = "i", equipped = true, wield = "off" },
    { item_id = "j", equipped = true, wield = "two" },
}), nil))
ok, issues = Schema.ValidateCharacter(invChar({ { item_id = "i", wield = "backhand" } }), nil)
assert(not ok and findIssue(issues, "field 'wield'"), "an unknown wield must be reported")

-- The fatigue counter: a bounded optional number on the character.
assert(Schema.ValidateCharacter({ name = "C", level = 1, attributes = { a = 1 },
    fatigue = 3 }, nil))
ok, issues = Schema.ValidateCharacter({ name = "C", level = 1, attributes = { a = 1 },
    fatigue = 0 / 0 }, nil)
assert(not ok and findIssue(issues, "field 'fatigue'"), "NaN fatigue must be reported")

-- Death-save pips: a small optional table, shape-checked with or without a
-- system (a shared sheet carries it over the wire).
local pipChar = { name = "C", level = 1, attributes = { a = 1 },
    death_saves = { successes = 2, failures = 1, stable = false } }
assert(Schema.ValidateCharacter(pipChar, nil))
ok, issues = Schema.ValidateCharacter({ name = "C", level = 1, attributes = { a = 1 },
    death_saves = 3 }, nil)
assert(not ok and findIssue(issues, "field 'death_saves'"), "scalar pips must be reported")
ok, issues = Schema.ValidateCharacter({ name = "C", level = 1, attributes = { a = 1 },
    death_saves = { successes = 1 / 0 } }, nil)
assert(not ok and findIssue(issues, "not a finite number"), "inf pips must be reported")
ok, issues = Schema.ValidateCharacter({ name = "C", level = 1, attributes = { a = 1 },
    death_saves = { stable = "yes" } }, nil)
assert(not ok and findIssue(issues, "field 'stable'"), "non-boolean stable must be reported")
-- The wire snapshot carries the die fields too - attacker-controlled, so
-- garbage notation is reported there as well.
assert(Schema.ValidateCharacter(invChar({
    { item_id = "i", resolved = { name = "Axe", kind = "weapon", die = "1d12",
        versatile_die = "2d6", category = "versatile" } },
}), nil))
ok, issues = Schema.ValidateCharacter(invChar({
    { item_id = "i", resolved = { name = "Axe", kind = "weapon", die = "evil()" } },
}), nil)
assert(not ok and findIssue(issues, "not dice notation"), "a wire die must be validated")
-- A type-confused inventory must be reported or leniently skipped, never thrown.
for _, bad in ipairs({ 5, { 5 }, { { item_id = "i", resolved = 5 } } }) do
    reports(Schema.ValidateCharacter, invChar(bad), refSys)
end
ok, issues = Schema.ValidateCharacter(invChar({ 5 }), nil)
assert(not ok and findIssue(issues, "inventory[1]"), "a scalar entry must be reported")
ok, issues = Schema.ValidateCharacter(invChar({ { item_id = "i", resolved = 5 } }), nil)
assert(not ok and findIssue(issues, "resolved"), "a scalar resolved block must be reported")

-- The `resolved` snapshot rides in from the wire AND reaches the totals, so it
-- is bounded on every axis: kind, string length, icon charset, bonus range.
local function resolvedChar(resolved)
    return invChar({ { item_id = "itm_1", equipped = true, resolved = resolved } })
end
assert(Schema.ValidateCharacter(resolvedChar({
    name = "Borrowed Axe", kind = "weapon", icon = "inv_axe_01", weapon_id = "w1", bonus = 3,
}), nil))
assert(Schema.ValidateCharacter(resolvedChar({}), nil), "a snapshot may carry nothing at all")
assert(Schema.ValidateCharacter(resolvedChar({
    name = "Borrowed Plate", kind = "equipment", ac_bonus = 2, ac_mod_cap = 0,
}), nil), "a capped-armor snapshot must validate")
for _, bad in ipairs({
    { kind = "hat" },
    { name = string.rep("x", 65) },
    { icon = "..\\..\\Interface\\evil" },
    { icon = string.rep("i", 65) },
    { bonus = 1 / 0 },
    { bonus = 9999 },
    { ac_bonus = -1000 },
    { ac_mod_cap = -1 },
    { ac_mod_cap = 1 / 0 },
    { bonus = "lots" },
    { weapon_id = 5 },
}) do
    assert(not reports(Schema.ValidateCharacter, resolvedChar(bad), nil),
        "an out-of-bounds resolved field was accepted")
end

-- A resolved weapon link is checked leniently, and only when a system is at
-- hand: a dangling one costs the item its bonus, it does not invalidate a sheet.
local wepSys = MinimalSystem()
wepSys.weapons = { { id = "w1", name = "Club" } }
assert(Schema.ValidateCharacter(resolvedChar({ name = "Axe", kind = "weapon", weapon_id = "w1" }), wepSys))
ok, issues = Schema.ValidateCharacter(resolvedChar({ name = "Axe", kind = "weapon", weapon_id = "w9" }), wepSys)
assert(not ok and findIssue(issues, "unknown weapon 'w9'"))
assert(Schema.ValidateCharacter(resolvedChar({ name = "Axe", kind = "weapon", weapon_id = "w9" }), nil),
    "without a system there is nothing to check the link against")

-- Item effects: bounded on every axis, because they also ride the `resolved`
-- snapshot and fold into saves, skills and attributes while equipped.
assert(Schema.ValidateItem(Item({ kind = "equipment", ac_bonus = 1, effects = {
    { type = "save", id = "a", value = 1 },
    { type = "skill", skill = "s1", value = 2, per_level = true },
    { type = "ac", value = 1, add_modifier = "b" },
} })), "a well-formed effects list must validate")
ok, issues = Schema.ValidateItem(Item({ effects = 5 }))
assert(not ok and findIssue(issues, "'effects' should be a list"))
ok, issues = Schema.ValidateItem(Item({ effects = { 5 } }))
assert(not ok and findIssue(issues, "effects[1]"), "a scalar effect must be reported")
ok, issues = Schema.ValidateItem(Item({ effects = { { value = 1 } } }))
assert(not ok and findIssue(issues, "'type' should be string"))
ok, issues = Schema.ValidateItem(Item({ effects = { { type = "save", id = "a", value = 500 } } }))
assert(not ok and findIssue(issues, "outside"), "an absurd effect value must be reported")
ok, issues = Schema.ValidateItem(Item({ effects = { { type = "save", id = "a", value = 1 / 0 } } }))
assert(not ok and findIssue(issues, "not a finite number"))
ok, issues = Schema.ValidateItem(Item({ effects = { { type = "skill", skill = string.rep("s", 65) } } }))
assert(not ok and findIssue(issues, "longer than 64"))
ok, issues = Schema.ValidateItem(Item({ effects = { { type = "save", id = "a", per_level = "yes" } } }))
assert(not ok and findIssue(issues, "'per_level' should be boolean"))
local many = {}
for i = 1, 11 do many[i] = { type = "ac", value = 1 } end
ok, issues = Schema.ValidateItem(Item({ effects = many }))
assert(not ok and findIssue(issues, "more than 10 effects"))
ok, issues = Schema.ValidateItem(Item({ kind = "gear", effects = { { type = "ac", value = 1 } } }))
assert(not ok and findIssue(issues, "gear cannot carry effects"))
-- The resolved snapshot holds the same line.
assert(Schema.ValidateCharacter(resolvedChar({ kind = "equipment",
    effects = { { type = "save", id = "a", value = 2 } } }), nil))
ok, issues = Schema.ValidateCharacter(resolvedChar({ kind = "equipment",
    effects = { { type = "save", id = "a", value = 500 } } }), nil)
assert(not ok and findIssue(issues, "outside"), "an out-of-bounds resolved effect was accepted")
assert(not reports(Schema.ValidateCharacter, resolvedChar({ effects = "lots" }), nil))

-- Targets the wizard's pickers cannot produce, but a hand-edited paste or a
-- wire payload can: reported, never thrown.
for _, bad in ipairs({
    { { type = "skill", skill = "ghost", value = 1 } },
    { { type = "attribute", id = "ghost", value = 1 } },
    { { type = "save", id = "ghost", value = 1 } },
    { { type = "skill", skill = "s1", add_modifier = "ghost" } },
}) do
    assert(not reports(Schema.ValidateCharacter, wizChar(bad), wizSys),
        "unknown custom-perk target not reported")
end

-- Shape-only validation (a sheet shared by another player arrives with no
-- system, see Modules/Sharing.lua) must type-check every field the sheet
-- computes from, not just the required three and the inventory: without a
-- system there are no ids to resolve, but Compute still iterates the lists and
-- does arithmetic on the numbers, and the payload is attacker-controlled.
local function shapeChar(mutate)
    local c = {
        name = "C", level = 3, attributes = { a = 1 },
        racial_trait = "human", origin_traits = { "o1" },
        accomplished_skills = { "s1" }, accomplished_saves = { "a" },
        accomplished_weapons = { "w1" },
        max_hp = 20, current_hp = 18, temp_hp = 2, max_mana = 6, current_mana = 6,
        custom_feats = { { id = "hf-1", name = "F", level = 2,
            effects = { { type = "max_hp", value = 2, per_level = true } } } },
    }
    mutate(c)
    return c
end
assert(Schema.ValidateCharacter(shapeChar(function() end), nil),
    "a well-formed sheet must still validate with no system at hand")
for _, case in ipairs({
    { "origin_traits as a scalar", function(c) c.origin_traits = "x" end },
    { "origin_traits holding a non-id", function(c) c.origin_traits = { 5 } end },
    { "accomplished_skills as a scalar", function(c) c.accomplished_skills = "x" end },
    { "accomplished_saves as a scalar", function(c) c.accomplished_saves = "x" end },
    { "accomplished_weapons as a scalar", function(c) c.accomplished_weapons = "x" end },
    { "a non-string racial_trait", function(c) c.racial_trait = 5 end },
    { "a table attribute value", function(c) c.attributes = { a = {} } end },
    { "a string attribute value", function(c) c.attributes = { a = "zz" } end },
    { "a table max_hp", function(c) c.max_hp = {} end },
    { "a table max_mana", function(c) c.max_mana = {} end },
    { "a string current_hp", function(c) c.current_hp = "18" end },
    { "a table temp_hp", function(c) c.temp_hp = {} end },
    { "a string current_mana", function(c) c.current_mana = "6" end },
    { "custom_feats as a scalar", function(c) c.custom_feats = "x" end },
    { "a numeric custom_feats record", function(c) c.custom_feats = { 1 } end },
    { "a boolean custom_feats record", function(c) c.custom_feats = { true } end },
    { "custom_feats effects as a scalar", function(c) c.custom_feats[1].effects = "no" end },
    { "a scalar custom_feats effect", function(c) c.custom_feats[1].effects = { 5 } end },
    { "a table effect value", function(c) c.custom_feats[1].effects[1].value = {} end },
    { "an infinite effect value", function(c) c.custom_feats[1].effects[1].value = 1 / 0 end },
    { "an absurd effect value", function(c) c.custom_feats[1].effects[1].value = 500 end },
    { "a scalar custom_spells record", function(c) c.custom_spells = { 1 } end },
    -- Free text the UI concatenates. quote/notes were unchecked entirely: a
    -- shared sheet carrying quote = {} validated, computed and cached, then
    -- threw in the sheet subtitle on every open.
    { "a table quote", function(c) c.quote = {} end },
    { "a table notes", function(c) c.notes = {} end },
    { "a numeric quote", function(c) c.quote = 5 end },
    { "an unbounded name", function(c) c.name = string.rep("x", 200000) end },
    { "an unbounded quote", function(c) c.quote = string.rep("x", 200000) end },
    { "an unbounded notes", function(c) c.notes = string.rep("x", 200000) end },
}) do
    assert(not reports(Schema.ValidateCharacter, shapeChar(case[2]), nil),
        "shape-only validation accepted " .. case[1])
end

-- Level is capped, not merely required-finite: per_level effects multiply
-- their value by it (ApplyEffect in Modules/CharacterSheet.lua), so a shared
-- sheet at level 1e308 turns a validated +/-99 bonus into inf in the derived
-- stats - the same poisoning the finite checks exist to prevent.
ok, issues = Schema.ValidateCharacter({ name = "C", level = 1e308, attributes = {} }, nil)
assert(not ok and findIssue(issues, "field 'level' is outside"), "an absurd level was accepted")
ok, issues = Schema.ValidateCharacter({ name = "C", level = -1e9, attributes = {} }, nil)
assert(not ok and findIssue(issues, "field 'level' is outside"), "an absurd negative level")
ok, issues = Schema.ValidateCharacter({ name = "C", level = 1e6, attributes = { a = 1 } }, refSys)
assert(not ok and findIssue(issues, "field 'level' is outside"),
    "the cap must hold on the full path too")
assert(Schema.ValidateCharacter({ name = "C", level = 30, attributes = {} }, nil),
    "an ordinary level must still pass")
-- Homebrew records carry a gained-at level of their own, capped the same way.
local hbLevel = wizChar({})
hbLevel.custom_feats[1].level = 1e12
ok, issues = Schema.ValidateCharacter(hbLevel, wizSys)
assert(not ok and findIssue(issues, "custom_feats[1]: field 'level' is outside"),
    "an absurd homebrew level was accepted")

-- An effect's `type` is capped like the other item strings: the effect summary
-- goes into GameTooltip on every inventory-row hover (EffectSummary in
-- UI/Widgets.lua), type name and all, from the library and the wire alike.
local hugeType = string.rep("t", 100000)
ok, issues = Schema.ValidateItem(Item({ effects = { { type = hugeType, value = 1 } } }))
assert(not ok and findIssue(issues, "field 'type' is longer than 64"),
    "a 100KB effect type was accepted")
ok, issues = Schema.ValidateCharacter(resolvedChar({ kind = "equipment",
    effects = { { type = hugeType, value = 1 } } }), nil)
assert(not ok and findIssue(issues, "field 'type' is longer than 64"),
    "a 100KB effect type rode in on a resolved snapshot")

-- `per_level` belongs to the shared effect vocabulary, so it is checked on
-- every effect source, not just items: the engine tests it for truthiness, so
-- a non-boolean scales the value anyway and silently inverts the author's
-- intent.
local function featPackWith(effects)
    return { pack_name = "P", lines = { { id = "l1", name = "L", attribute = "a",
        ranks = { { name = "R1", effects = effects } } } } }
end
assert(Schema.ValidateFeatPack(featPackWith({ { type = "ac", value = 1, per_level = true } })),
    "a per_level rank effect must validate")
ok, issues = Schema.ValidateFeatPack(featPackWith({ { type = "ac", value = 1, per_level = "no" } }))
assert(not ok and findIssue(issues, "field 'per_level' should be boolean"),
    "a non-boolean per_level on a feat rank was accepted")

local function spellPackWith(effects)
    return { pack_name = "P", schools = { { id = "ev", name = "Evocation" } },
        spells = { { id = "sp", name = "S", school = "ev", rank = 1, effects = effects } } }
end
assert(Schema.ValidateSpellPack(spellPackWith({ { type = "ac", value = 1, per_level = false } })),
    "a per_level spell effect must validate")
ok, issues = Schema.ValidateSpellPack(spellPackWith({ { type = "ac", value = 1, per_level = 1 } }))
assert(not ok and findIssue(issues, "field 'per_level' should be boolean"),
    "a non-boolean per_level on a spell was accepted")

assert(Schema.ValidateCharacter(
    wizChar({ { type = "max_hp", value = 1, per_level = true } }), wizSys),
    "a per_level homebrew effect must validate")
ok, issues = Schema.ValidateCharacter(
    wizChar({ { type = "max_hp", value = 1, per_level = "yes" } }), wizSys)
assert(not ok and findIssue(issues, "field 'per_level' should be boolean"),
    "a non-boolean per_level on a homebrew effect was accepted")
