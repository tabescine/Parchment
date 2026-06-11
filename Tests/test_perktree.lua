-- PerkTree: status, rank, requirement, exclusivity, and homebrew-replacement
-- rules of the perk engine.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
local ns = T.load({}, "Core.lua")
T.load(ns, "Modules/PerkTree.lua")
local PT = ns.PerkTree

ParchmentSystemDB = {
    system_name = "Mini",
    attributes = { { id = "a", name = "Alpha" } },
    perk_trees = { {
        id = "t1", name = "Tree", governing_attribute = "a",
        perks = {
            { id = "base", name = "Base" },
            { id = "gated", name = "Gated", attribute_req = 3 },
            { id = "dep", name = "Dependent", prerequisites = { "base" } },
            { id = "anyof", name = "AnyOf", prerequisites_any = { "base", "gated" } },
            { id = "excl", name = "Exclusive", exclusive_with = { "solo" } },
            { id = "solo", name = "Solo", exclusive_with = { "excl" } },
            { id = "multi", name = "Multi", repeatable = true, max_ranks = 2, level_req = { 1, 3 } },
            { id = "choicep", name = "Chooser", repeatable = true, max_ranks = 2,
              choice = { kind = "skill", count = 2 } },
        },
    } },
}
local tree = ParchmentSystemDB.perk_trees[1]
local function perk(id) return ns.FindById(tree.perks, id) end
local sheet = { attributes = { { id = "a", final = 2 } } }  -- Alpha final 2 (< gated's 3)
local char = { level = 1, perks = {} }

-- Availability and gating.
assert(PT.Status(char, sheet, tree, perk("base")) == "available")
assert(PT.Status(char, sheet, tree, perk("gated")) == "locked")
local ok, reason = PT.CanAddRank(char, sheet, tree, perk("gated"))
assert(not ok and reason:find("Alpha 3"), reason)
assert(PT.Status(char, sheet, tree, perk("dep")) == "locked")
assert(PT.Status(char, sheet, tree, perk("anyof")) == "locked")

-- Selecting unlocks dependents; deselecting a depended-on perk is blocked.
assert(PT.Select(char, sheet, tree, perk("base")))
assert(PT.Status(char, sheet, tree, perk("base")) == "taken")
assert(PT.Status(char, sheet, tree, perk("dep")) == "available")
assert(PT.Status(char, sheet, tree, perk("anyof")) == "available")
assert(PT.Select(char, sheet, tree, perk("dep")))
ok, reason = PT.Deselect(char, tree, perk("base"))
assert(not ok and reason:find("Required by Dependent"), tostring(reason))
assert(PT.Deselect(char, tree, perk("dep")))
assert(PT.Deselect(char, tree, perk("base")))

-- Exclusivity blocks both directions.
assert(PT.Select(char, sheet, tree, perk("solo")))
assert(PT.Status(char, sheet, tree, perk("excl")) == "exclusive")
ok, reason = PT.CanAddRank(char, sheet, tree, perk("excl"))
assert(not ok and reason:find("Exclusive with Solo"), tostring(reason))

-- Multi-rank: per-rank level requirements and the max-ranks cap.
assert(PT.Select(char, sheet, tree, perk("multi")))
assert(PT.Rank(char, perk("multi")) == 1)
ok, reason = PT.CanAddRank(char, sheet, tree, perk("multi"))
assert(not ok and reason:find("level 3"), tostring(reason))
char.level = 3
assert(PT.Select(char, sheet, tree, perk("multi")))
assert(PT.Rank(char, perk("multi")) == 2)
ok, reason = PT.CanAddRank(char, sheet, tree, perk("multi"))
assert(not ok and reason:find("maximum rank"), tostring(reason))

-- Choices: max scales with rank for repeatables; deselect trims/clears.
assert(PT.Select(char, sheet, tree, perk("choicep")))
assert(PT.ChoiceMax(char, perk("choicep")) == 2)
assert(PT.Select(char, sheet, tree, perk("choicep")))
assert(PT.ChoiceMax(char, perk("choicep")) == 4)
PT.SetChoices(char, perk("choicep"), { "s1", "s2", "s3" })
assert(PT.Deselect(char, tree, perk("choicep")))
assert(#char.perk_choices.choicep == 2, "choices not trimmed to the lower rank")
assert(PT.Deselect(char, tree, perk("choicep")))
assert(char.perk_choices.choicep == nil, "choices not cleared at rank 0")

-- Homebrew replacement fills a slot: satisfies prerequisites, blocks ranks.
local char2 = { level = 1, perks = {}, custom_perks = { { id = "hb", name = "Homebrew", replaces = "base" } } }
assert(PT.ReplacedBy(char2, "base") ~= nil)
assert(PT.Status(char2, sheet, tree, perk("base")) == "taken")
assert(PT.Status(char2, sheet, tree, perk("dep")) == "available", "replacement must satisfy prerequisites")
ok, reason = PT.CanAddRank(char2, sheet, tree, perk("base"))
assert(not ok and reason:find("Homebrew"), tostring(reason))

-- Points: sphere perks and homebrew both invest; one point per level.
local invested, available = PT.Points({ level = 4, perks = { "base", "multi" }, custom_perks = { {} } })
assert(invested == 3 and available == 4)
