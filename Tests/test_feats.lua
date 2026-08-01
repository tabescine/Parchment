-- Feats: rank ladders, requirement resolution, enforced learn/unlearn against
-- the shared pick ledger, and search.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
local ns = T.load({}, "Core.lua")
T.load(ns, "Modules/CharacterSheet.lua")
T.load(ns, "Modules/Picks.lua")
T.load(ns, "Modules/Feats.lua")
local Feats = ns.Feats

ParchmentSystemDB = {
    system_name = "Mini",
    attributes = { { id = "pow", name = "Power" }, { id = "wit", name = "Wits" } },
    progression = { picks_level_1 = 2, picks_per_level = 1 },
}
local pack = {
    pack_name = "P",
    rank_attribute_req = { 5, 6, 7 },
    lines = {
        { id = "grip", name = "Iron Grip", attribute = "pow", ranks = {
            { name = "Hold", description = "Grab a foe." },
            { name = "Twist" },
            { name = "Throw", attribute_req = 9 },   -- overrides the default 7
        } },
        { id = "study", name = "Keen Study", attribute = "wit", ranks = {
            { name = "Fieldnotes", description = "Sharp memory." },
        } },
    },
}
ParchmentPackDB = {
    feats = { P = { name = "P", pack = pack } }, active_feats = "P",
}

local sheet = { attributes = { { id = "pow", final = 6 }, { id = "wit", final = 4 } } }
local char = { level = 1, feats = {} }   -- budget 2

-- Rank / requirement resolution.
assert(Feats.Rank(char, "grip") == 0)
assert(Feats.RankReq(pack, pack.lines[1], 1) == 5)
assert(Feats.RankReq(pack, pack.lines[1], 3) == 9, "per-rank override must win")
assert(Feats.RankReq({}, pack.lines[2], 1) == nil, "no defaults, no gate")

-- Lines filter and status ladder.
assert(#Feats.Lines(pack) == 2 and #Feats.Lines(pack, "pow") == 1)
assert(Feats.Status(char, pack.lines[1], 1) == "next")
assert(Feats.Status(char, pack.lines[1], 2) == "locked")

-- Learn walks the ladder; attribute gates use the sheet's final values.
assert(Feats.Learn(char, sheet, pack, pack.lines[1]))
assert(Feats.Rank(char, "grip") == 1)
assert(Feats.Status(char, pack.lines[1], 1) == "taken")
local ok, reason = Feats.CanLearn(char, sheet, pack, pack.lines[2])
assert(not ok and reason:find("Wits 5"), tostring(reason))
assert(Feats.Learn(char, sheet, pack, pack.lines[1]))   -- rank 2 (pow 6 = req 6)

-- The ledger is enforced: budget 2 is now spent, so rank 3 is refused for
-- picks (not its steeper attribute gate - reported in gate order).
ok, reason = Feats.CanLearn(char, sheet, pack, pack.lines[1])
assert(not ok and reason:find("Requires Power 9"), tostring(reason))
sheet.attributes[1].final = 9
ok, reason = Feats.CanLearn(char, sheet, pack, pack.lines[1])
assert(not ok and reason:find("No picks left"), tostring(reason))
char.level = 2   -- budget 3
assert(Feats.Learn(char, sheet, pack, pack.lines[1]))
ok, reason = Feats.CanLearn(char, sheet, pack, pack.lines[1])
assert(not ok and reason:find("highest rank"), tostring(reason))

-- Unlearn peels ranks off the top and clears the key at zero.
assert(Feats.Unlearn(char, pack.lines[1]))
assert(Feats.Rank(char, "grip") == 2)
assert(Feats.Unlearn(char, pack.lines[1]))
assert(Feats.Unlearn(char, pack.lines[1]))
assert(char.feats.grip == nil, "rank 0 must clear the entry")
ok, reason = Feats.Unlearn(char, pack.lines[1])
assert(not ok and reason == "Not learned.")

-- Search: line names, rank names and descriptions all match; empty query none.
assert(#Feats.Search(pack, "grip") == 1)
assert(#Feats.Search(pack, "memory") == 1 and Feats.Search(pack, "memory")[1].id == "study")
assert(#Feats.Search(pack, "  THROW ") == 1)
assert(#Feats.Search(pack, "") == 0)

-- FormatCost (Core helper shared by the pickers).
assert(ns.FormatCost({ ap = 1, mana = 2 }) == "1 AP, 2 Mana")
assert(ns.FormatCost({ mana = 3 }) == "3 Mana")
assert(ns.FormatCost({}) == nil and ns.FormatCost(nil) == nil)
