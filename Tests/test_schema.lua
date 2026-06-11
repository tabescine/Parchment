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
local ok, issues = Schema.ValidateSystem("nope")
assert(not ok)
ok, issues = Schema.ValidateSystem({ attributes = {} })
assert(not ok and findIssue(issues, "system_name"), "missing system_name not reported")

-- Duplicate attribute ids.
local sys = MinimalSystem()
sys.attributes[3] = { id = "a", name = "Again" }
ok, issues = Schema.ValidateSystem(sys)
assert(not ok and findIssue(issues, "duplicate id"))

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
    custom_perks = { { id = "h", name = "H", replaces = "p", effects = { { type = "skill", skill = "s1", add_modifier = "a" } } } },
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
