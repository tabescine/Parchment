-- Spells: knowledge, school locks, cast-attribute gates, enforced
-- learn/unlearn against the shared pick ledger, and search.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
local ns = T.load({}, "Core.lua")
T.load(ns, "Modules/CharacterSheet.lua")
T.load(ns, "Modules/Picks.lua")
T.load(ns, "Modules/Spells.lua")
local Spells = ns.Spells

ParchmentSystemDB = {
    system_name = "Mini",
    attributes = { { id = "wit", name = "Wits" }, { id = "spi", name = "Spirit" } },
    progression = { picks_level_1 = 2, picks_per_level = 1 },
}
local pack = {
    pack_name = "S",
    cast_attributes = { "wit", "spi" },
    rank_cast_req = { 6, 8 },
    schools = {
        { id = "ember", name = "Ember", opposed = "frost" },
        { id = "frost", name = "Frost", opposed = "ember" },
        { id = "hearth", name = "Hearth" },
    },
    spells = {
        { id = "veil", name = "Veil", school = "frost", rank = 2 },
        { id = "bolt", name = "Bolt", school = "ember", rank = 1, description = "A fire dart." },
        { id = "mend", name = "Mend", school = "hearth", rank = 1 },
        { id = "bind", name = "Bind", school = "frost", rank = 1 },
    },
}
ParchmentPackDB = { spells = { S = { name = "S", pack = pack } }, active_spells = "S" }

local sheet = { attributes = { { id = "wit", final = 6 }, { id = "spi", final = 3 } } }
local char = { level = 1, cast_attribute = "wit", spells = {} }   -- budget 2

-- Sorting: rank ascending, pack order within a rank.
local all = Spells.SpellsOf(pack)
assert(all[1].id == "bolt" and all[2].id == "mend" and all[3].id == "bind" and all[4].id == "veil")
assert(#Spells.SpellsOf(pack, "frost") == 2)

-- Gates: rank 2 needs cast score 8; rank 1 needs 6.
local ok, reason = Spells.CanLearn(char, sheet, pack, Spells.Spell(pack, "veil"))
assert(not ok and reason:find("Wits 8"), tostring(reason))
assert(Spells.CanLearn(char, sheet, pack, Spells.Spell(pack, "bolt")))

-- No cast attribute chosen: refused while the pack names candidates.
local nocast = { level = 1, spells = {} }
ok, reason = Spells.CanLearn(nocast, sheet, pack, Spells.Spell(pack, "bolt"))
assert(not ok and reason:find("cast attribute"), tostring(reason))

-- Learning the first Ember spell announces the Frost lock, then enforces it.
local wouldLock = Spells.WouldLock(char, pack, Spells.Spell(pack, "bolt"))
assert(wouldLock and wouldLock.id == "frost", "first ember spell must threaten the frost lock")
assert(Spells.WouldLock(char, pack, Spells.Spell(pack, "mend")) == nil, "free schools lock nothing")
assert(Spells.Learn(char, sheet, pack, Spells.Spell(pack, "bolt")))
assert(Spells.Knows(char, "bolt"))
assert(Spells.WouldLock(char, pack, Spells.Spell(pack, "bolt")) == nil, "second spell of a school locks nothing new")
assert(Spells.LockedBy(char, pack, "frost") == "ember")
ok, reason = Spells.CanLearn(char, sheet, pack, Spells.Spell(pack, "bind"))
assert(not ok and reason:find("School locked"), tostring(reason))

-- Duplicates refused; the ledger is enforced once the budget is spent.
ok, reason = Spells.CanLearn(char, sheet, pack, Spells.Spell(pack, "bolt"))
assert(not ok and reason == "Already known.")
assert(Spells.Learn(char, sheet, pack, Spells.Spell(pack, "mend")))
ok, reason = Spells.CanLearn(char, sheet, pack, { id = "x", name = "X", school = "hearth", rank = 1 })
assert(not ok and reason:find("No picks left"), tostring(reason))

-- Unlearning the last Ember spell reopens Frost.
assert(Spells.Unlearn(char, "bolt"))
assert(Spells.LockedBy(char, pack, "frost") == nil, "forgetting the last ember spell must reopen frost")
ok, reason = Spells.Unlearn(char, "bolt")
assert(not ok and reason == "Not known.")

-- Search: name, description and school name all match; empty query none.
assert(#Spells.Search(pack, "bolt") == 1)
assert(#Spells.Search(pack, "fire dart") == 1)
assert(#Spells.Search(pack, "frost") == 2, "school-name search must find its spells")
assert(#Spells.Search(pack, "") == 0)
