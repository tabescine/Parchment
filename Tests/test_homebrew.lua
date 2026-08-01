-- Homebrew feats and spells: the Commit/Delete seams, the level gate, pick
-- counting, effect folding into the computed sheet, and the schema shape
-- checks.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
local ns = T.load({}, "Core.lua")
T.load(ns, "Schema.lua")
T.load(ns, "Modules/CharacterSheet.lua")
T.load(ns, "Modules/Picks.lua")
T.load(ns, "Modules/Homebrew.lua")
local HB = ns.Homebrew

ParchmentSystemDB = {
    system_name = "Mini",
    attributes = { { id = "a", name = "Alpha" }, { id = "b", name = "Bravo" } },
    modifier_table = { -1, 0, 1, 2 },
    accomplishment_table = { 2, 2, 2, 2 },
    skills = { { id = "s1", name = "Skill One", attribute = "a" } },
    progression = { picks_level_1 = 1, picks_per_level = 1 },
}
local system = ParchmentSystemDB

-- Commit: append, replace, reject; the two kinds keep separate lists.
local char = { name = "C", level = 2, attributes = { a = 3, b = 2 } }
local feat = { id = HB.NextId(char, "feat"), name = "Brew Feat", level = 1,
    type = "active", cost = { ap = 1 }, effects = { { type = "skill", skill = "s1", value = 2 } } }
assert(HB.NextId(char, "feat") == "hf-1")
assert(HB.Commit(char, "feat", feat) == 1)
local spell = { id = HB.NextId(char, "spell"), name = "Brew Spell", level = 2,
    school = "void", rank = 1, cost = { mana = 2 }, concentration = true,
    effects = { { type = "max_mana", value = 3 } } }
assert(HB.NextId(char, "spell") == "hs-1")
assert(HB.Commit(char, "spell", spell) == 1)
assert(#HB.List(char, "feat") == 1 and #HB.List(char, "spell") == 1)
assert(HB.Commit(char, "feat", { name = "Second", level = 4 }) == 2)
assert(HB.Commit(char, "feat", { name = "Second (edited)", level = 4 }, 2) == 2)
assert(char.custom_feats[2].name == "Second (edited)" and #char.custom_feats == 2)
assert(HB.Commit(nil, "feat", feat) == nil and HB.Commit(char, "nope", feat) == nil)
assert(HB.Commit(char, "feat", "nope") == nil)

-- Active/pending: the level gate.
assert(HB.Active(char, char.custom_feats[1]) == true)
assert(HB.Active(char, char.custom_feats[2]) == false, "level 4 record pending at level 2")
assert(HB.Active(char, char.custom_spells[1]) == true)

-- Picks: only gained records cost a pick (feat L1 + spell L2 = 2; the level-4
-- feat is pending). Budget at level 2 = 2.
local spent, budget = ns.Picks.Points(char)
assert(spent == 2 and budget == 2, "picks " .. spent .. "/" .. budget)

-- Compute folds active homebrew effects (skill +2, max_mana +3) and skips
-- pending ones; homebrew feats/spells do NOT join the custom_perks display.
char.max_mana = 5
local sheet = ns.CharacterSheet.Compute(char, system, {})
local s1
for _, s in ipairs(sheet.skills) do if s.id == "s1" then s1 = s end end
-- Alpha 3 -> modifier +1, unaccomplished, +2 homebrew effect = 3.
assert(s1 and s1.total == 3, "homebrew feat effect must fold into the skill, got "
    .. tostring(s1 and s1.total))
assert(sheet.derived.mana.max == 8, "homebrew spell effect must fold into mana, got "
    .. tostring(sheet.derived.mana.max))

-- Pending record's effects stay out until the level is reached.
char.custom_feats[2].effects = { { type = "ac", value = 5 } }
local acBefore = ns.CharacterSheet.Compute(char, system, {}).derived.ac
char.level = 4
local acAfter = ns.CharacterSheet.Compute(char, system, {}).derived.ac
assert(acAfter == acBefore + 5, "reaching the level must activate the effects")
char.level = 2

-- PACK feat and spell effects fold too: every owned rank of a feat line and
-- every known spell contribute their effects (here: rank I grants skill
-- accomplishment, the known spell +1 AC).
ParchmentPackDB = {
    feats = { P = { name = "P", pack = { pack_name = "P", lines = {
        { id = "watch", name = "Watch", attribute = "a", ranks = {
            { name = "Keen", effects = { { type = "accomplish_skill", skill = "s1" } } },
            { name = "Keener", effects = { { type = "ac", value = 2 } } },
        } },
    } } } },
    active_feats = "P",
    spells = { S = { name = "S", pack = { pack_name = "S", spells = {
        { id = "ward", name = "Ward", school = "x", rank = 1,
            effects = { { type = "ac", value = 1 } } },
    } } } },
    active_spells = "S",
}
char.feats = { watch = 1 }
char.spells = { "ward" }
local packSheet = ns.CharacterSheet.Compute(char, system, {})
local ps1
for _, s in ipairs(packSheet.skills) do if s.id == "s1" then ps1 = s end end
assert(ps1.accomplished, "owned rank-I feat must grant skill accomplishment")
local acBase = ns.CharacterSheet.Compute(
    { name = "X", level = 2, attributes = char.attributes }, system, {}).derived.ac
assert(packSheet.derived.ac == acBase + 1, "known pack spell's effect must fold (+1 AC), got "
    .. packSheet.derived.ac .. " vs base " .. acBase)
char.feats.watch = 2
assert(ns.CharacterSheet.Compute(char, system, {}).derived.ac == acBase + 3,
    "rank II must add its own effect on top")
char.feats, char.spells = nil, nil
ParchmentPackDB = {}

-- Delete shifts later entries down; unknown indexes are refused.
assert(HB.Delete(char, "feat", 1) == true)
assert(#char.custom_feats == 1 and char.custom_feats[1].name == "Second (edited)")
assert(HB.Delete(char, "feat", 9) == false and HB.Delete(char, "feat", nil) == false)
assert(HB.Delete({}, "spell", 1) == false)

-- Schema: valid shapes pass; bad cost, bad effects and unknown saves report.
local probe = { name = "P", level = 1, attributes = { a = 1, b = 1 },
    custom_feats = { { id = "hf-1", name = "F", level = 1, cost = { ap = 1 },
        save = "a", effects = { { type = "skill", skill = "s1", value = 1 } } } },
    custom_spells = { { id = "hs-1", name = "S", level = 2, cost = { mana = 2 } } },
}
local ok, issues = ns.Schema.ValidateCharacter(probe, system)
assert(ok, "clean homebrew must validate: " .. tostring((issues or {})[1]))
local function findIssue(list, pattern)
    for _, issue in ipairs(list or {}) do
        if issue:find(pattern, 1, true) then return issue end
    end
end
probe.custom_feats[1].cost = "1 AP"
ok, issues = ns.Schema.ValidateCharacter(probe, system)
assert(not ok and findIssue(issues, "custom_feats[1]: field 'cost'"), tostring((issues or {})[1]))
probe.custom_feats[1].cost = nil
probe.custom_feats[1].save = "ghost"
ok, issues = ns.Schema.ValidateCharacter(probe, system)
assert(not ok and findIssue(issues, "unknown save attribute 'ghost'"))
probe.custom_feats[1].save = nil
probe.custom_spells[1].effects = { { type = "skill", skill = "nope", value = 1 } }
ok, issues = ns.Schema.ValidateCharacter(probe, system)
assert(not ok and findIssue(issues, "custom_spells[1].effects[1]"))
