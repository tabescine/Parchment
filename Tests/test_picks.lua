-- Picks: the shared pick ledger - budget from system.progression, spend
-- counted across sphere perks, homebrew, feat ranks and known spells, with
-- stale (non-resolving) entries never counted.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
local ns = T.load({}, "Core.lua")
T.load(ns, "Modules/CharacterSheet.lua")
T.load(ns, "Modules/Picks.lua")
local Picks = ns.Picks

ParchmentSystemDB = {
    system_name = "Mini",
    attributes = { { id = "a", name = "Alpha" } },
    perk_trees = { {
        id = "t1", name = "Tree", governing_attribute = "a",
        perks = { { id = "base", name = "Base" }, { id = "multi", name = "Multi" } },
    } },
}
ParchmentPackDB = {
    feats = { ["F"] = { name = "F", pack = {
        pack_name = "F",
        lines = {
            { id = "grip", name = "Grip", attribute = "a",
                ranks = { { name = "R1" }, { name = "R2" }, { name = "R3" } } },
        },
    } } },
    active_feats = "F",
    spells = { ["S"] = { name = "S", pack = {
        pack_name = "S",
        spells = { { id = "bolt", name = "Bolt", school = "x", rank = 1 },
            { id = "mend", name = "Mend", school = "x", rank = 1 } },
    } } },
    active_spells = "S",
}

-- Budget: defaults reproduce one pick per level; progression reshapes it.
assert(Picks.Budget({ level = 1 }) == 1)
assert(Picks.Budget({ level = 4 }) == 4)
assert(Picks.Budget({}) == 1, "no level counts as level 1")
ParchmentSystemDB.progression = { picks_level_1 = 2, picks_per_level = 1 }
assert(Picks.Budget({ level = 1 }) == 2, "AIAS-style: two picks at level 1")
assert(Picks.Budget({ level = 5 }) == 6)
ParchmentSystemDB.progression = { picks_level_1 = 3, picks_per_level = 2 }
assert(Picks.Budget({ level = 3 }) == 7)
ParchmentSystemDB.progression = nil

-- Spend: every source counts once per rank/spell; stale ids never count.
local char = {
    level = 6,
    perks = { "base", "multi", "ghost_perk" },     -- 2 (ghost does not resolve)
    custom_perks = { { name = "Now", level = 2 }, { name = "Later", level = 9 } }, -- 1
    feats = { grip = 2, ghost_line = 3 },          -- 2 (ghost line skipped)
    spells = { "bolt", "mend", "ghost_spell" },    -- 2
}
assert(Picks.Spent(char) == 7, "expected 7, got " .. Picks.Spent(char))
local spent, budget = Picks.Points(char)
assert(spent == 7 and budget == 6, "Points must pair spend with budget")

-- An over-recorded feat rank is clamped to the ladder's length.
assert(Picks.Spent({ level = 1, feats = { grip = 99 } }) == 3)

-- No packs active: feat and spell picks simply stop counting (stale data
-- must not warn about an overspend the player cannot fix).
ParchmentPackDB.active_feats, ParchmentPackDB.active_spells = nil, nil
assert(Picks.Spent(char) == 3, "only perks + homebrew without packs")

-- Degenerate inputs.
assert(Picks.Spent(nil) == 0)
assert(Picks.Spent({}) == 0)
