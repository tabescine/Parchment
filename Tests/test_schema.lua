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

-- Duplicate ids in the other id-keyed lists: skills, weapons, perk trees, and
-- perks (globally, across trees - perk_choices and prerequisites key by bare
-- perk id, so a cross-tree duplicate is just as ambiguous as a same-tree one).
sys = MinimalSystem()
sys.skills = { { id = "s", name = "S1", attribute = "a" }, { id = "s", name = "S2", attribute = "a" } }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "duplicate id 's'"), "duplicate skill id not reported")
sys = MinimalSystem()
sys.weapons = { { id = "w", name = "W1" }, { id = "w", name = "W2" } }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "duplicate id 'w'"), "duplicate weapon id not reported")
sys = MinimalSystem()
sys.perk_trees = {
    { id = "t", name = "T1", perks = { { id = "p1", name = "P1" } } },
    { id = "t", name = "T2", perks = { { id = "p1", name = "P1 again" } } },
}
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "duplicate id 't'"), "duplicate tree id not reported")
assert(findIssue(issues, "duplicate perk id 'p1'"), "cross-tree duplicate perk id not reported")

-- Skills and weapons must reference real attributes (lists too).
sys = MinimalSystem()
sys.skills = { { id = "s", name = "S", attribute = "ghost" } }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "unknown attribute 'ghost'"))
sys = MinimalSystem()
sys.weapons = { { id = "w", name = "W", attribute = { "a", "ghost" } } }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "unknown attribute 'ghost'"))

-- Perks: prerequisites resolve across trees; choice.kind is constrained.
sys = MinimalSystem()
sys.perk_trees = {
    { id = "t1", name = "T1", perks = { { id = "p1", name = "P1" } } },
    { id = "t2", name = "T2", perks = { { id = "p2", name = "P2", prerequisites = { "p1" } } } },
}
assert(Schema.ValidateSystem(sys), "cross-tree prerequisite should resolve")
sys.perk_trees[2].perks[1].prerequisites = { "missing" }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "'missing' not found"))
sys.perk_trees[2].perks[1] = { id = "p2", name = "P2", choice = { kind = "hat" } }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "choice.kind invalid"))

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
refSys.perk_trees = { { id = "t", name = "T", perks = { { id = "p", name = "P", choice = { kind = "skill" } } } } }
local char = {
    name = "C", level = 1, attributes = { a = 1 },
    accomplished_skills = { "s1" }, accomplished_saves = { "a" },
    perk_choices = { p = { "s1" } },
    custom_perks = {
        { id = "h", name = "H", replaces = "p",
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
char.custom_perks[1].replaces = "nope"
ok, issues = Schema.ValidateCharacter(char, refSys)
assert(not ok and findIssue(issues, "replaces unknown perk"))
char.custom_perks[1].replaces = "p"
char.perk_choices.p = { "ghost_skill" }
ok, issues = Schema.ValidateCharacter(char, refSys)
assert(not ok and findIssue(issues, "unknown skill 'ghost_skill'"))

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
    function(s) s.perk_trees = 5 end,
    function(s) s.perk_trees = { { id = "t", name = "T", perks = 5 } } end,
    function(s) s.perk_trees = { { id = "t", name = "T", perks = { 5 } } } end,
    function(s) s.perk_trees = { { id = "t", name = "T",
        perks = { { id = "p", name = "P", choice = 5, prerequisites = 5 } } } } end,
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
    s = MinimalSystem()
    s.perk_trees = { { id = "t", name = "T", perks = { { id = "p", name = "P", choice = 5 } } } }
    ok, issues = Schema.ValidateSystem(s)
    assert(not ok and findIssue(issues, "choice should be a table"), "scalar choice not reported")
end

-- Characters: every optional list/table as a truthy scalar.
local badCharSys = MinimalSystem()
badCharSys.perk_trees = { { id = "t", name = "T", perks = { { id = "p", name = "P" } } } }
for _, mutate in ipairs({
    function(c) c.attributes = 5 end,
    function(c) c.accomplished_skills = 5 end,
    function(c) c.accomplished_saves = 5 end,
    function(c) c.custom_perks = 5 end,
    function(c) c.custom_perks = { 5 } end,
    function(c) c.custom_perks = { { id = "h", name = "H", effects = 5 } } end,
    function(c) c.custom_perks = { { id = "h", name = "H", effects = { 5 } } } end,
    function(c) c.perk_choices = 5 end,
    function(c) c.perk_choices = { p = 5 } end,
}) do
    local c = { name = "C", level = 1, attributes = { a = 1 } }
    mutate(c)
    reports(Schema.ValidateCharacter, c, badCharSys)  -- must not throw; verdict is irrelevant
end

-- Homebrew perks (import-authored custom_perks): the shapes such data
-- produces must validate clean against the system its pickers were drawn from.
local wizSys = MinimalSystem()
wizSys.skills = { { id = "s1", name = "S1", attribute = "a" } }
wizSys.spell_schools = { { id = "ev", name = "Evocation" } }
local function wizChar(effects)
    return {
        name = "C", level = 3, attributes = { a = 1 },
        custom_perks = { { id = "hb-1", name = "Wizard Perk", level = 3,
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
assert(ok, "wizard-shaped custom perk should validate: " .. tostring(issues and issues[1]))
-- A perk with no effects at all (text only) is legal.
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
assert(Schema.ValidateItem(Item({ kind = "gear", default_count = 10 })))
ok, issues = Schema.ValidateItem(Item({ kind = "hat" }))
assert(not ok and findIssue(issues, "unknown kind 'hat'"))
ok, issues = Schema.ValidateItem({ name = "No id", kind = "gear" })
assert(not ok and findIssue(issues, "field 'id'"))
ok, issues = Schema.ValidateItem(Item({ bonus = 1 / 0 }))
assert(not ok and findIssue(issues, "not a finite number"), "inf bonus not reported")
ok, issues = Schema.ValidateItem(Item({ ac_bonus = 0 / 0 }))
assert(not ok and findIssue(issues, "not a finite number"), "NaN ac_bonus not reported")
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
for _, bad in ipairs({
    { kind = "hat" },
    { name = string.rep("x", 65) },
    { icon = "..\\..\\Interface\\evil" },
    { icon = string.rep("i", 65) },
    { bonus = 1 / 0 },
    { bonus = 9999 },
    { ac_bonus = -1000 },
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
