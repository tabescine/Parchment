-- Core.lua: shared helpers, the data API, and the migration scaffold.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")

-- Loads a fresh Core with a real db table and runs OnInitialize.
local function boot(dbGlobal, chars, system)
    local db = T.InstallLifecycleStubs(dbGlobal)
    ParchmentCharDB, ParchmentSystemDB = chars, system
    local ns = T.load({}, "Core.lua")
    ns.Addon:OnInitialize()
    return ns, db
end

local ns = boot({}, nil, nil)

-- DeepCopy: recursive, non-aliasing, non-tables pass through.
local orig = { a = 1, nest = { list = { 1, 2 }, flag = true } }
local copy = ns.DeepCopy(orig)
T.assert_deepeq(orig, copy, "DeepCopy")
assert(copy ~= orig and copy.nest ~= orig.nest and copy.nest.list ~= orig.nest.list, "DeepCopy aliases")
copy.nest.list[1] = 99
assert(orig.nest.list[1] == 1, "DeepCopy mutation leaked")
assert(ns.DeepCopy(5) == 5 and ns.DeepCopy("x") == "x" and ns.DeepCopy(nil) == nil)

-- FindById / AttrName / HasSystem.
local list = { { id = "a", name = "Alpha" }, { id = "b", name = "Beta" } }
assert(ns.FindById(list, "b").name == "Beta")
assert(ns.FindById(list, "zz") == nil and ns.FindById(nil, "a") == nil)
assert(not ns.HasSystem(), "empty system should not count as loaded")
ParchmentSystemDB = { attributes = list }
assert(ns.HasSystem())
assert(ns.AttrName("a") == "Alpha")
assert(ns.AttrName("zz") == "zz", "unresolved id should pass through")
assert(ns.AttrName(nil) == "(none)")

-- GetModifier clamps into the table; GetHitDie picks the first band.
ParchmentSystemDB.modifier_table = { -2, 0, 2 }
assert(ns.GetModifier(1) == -2 and ns.GetModifier(2) == 0 and ns.GetModifier(3) == 2)
assert(ns.GetModifier(0) == -2 and ns.GetModifier(99) == 2, "GetModifier must clamp")
ParchmentSystemDB.hit_dice_bands = { { max_mod = -1, die = "d6" }, { max_mod = 2, die = "d8" } }
assert(ns.GetHitDie(-3) == "d6" and ns.GetHitDie(0) == "d8")
assert(ns.GetHitDie(5) == "d4", "above all bands falls back to d4")
ParchmentSystemDB.accomplishment_table = { 1, 2 }
assert(ns.GetAccomplishmentBonus(1) == 1 and ns.GetAccomplishmentBonus(9) == 2)

-- DerivedConfig defaults when the system declares nothing.
ParchmentSystemDB.derived_stats = nil
local cfg = ns.DerivedConfig()
assert(cfg.ac_base == 10 and cfg.save_dc_base == 10 and cfg.actions_base == 2)
assert(cfg.movement_base == 12 and cfg.movement_per_step == 0.5 and cfg.mana_multiplier == 2)
assert(cfg.hit_die_attribute == nil and #cfg.spell_attributes == 0)
assert(cfg.initiative_tiebreaker == nil, "tiebreaker must default to none")
ParchmentSystemDB.derived_stats = { initiative_tiebreaker = "a" }
assert(ns.DerivedConfig().initiative_tiebreaker == "a")
ParchmentSystemDB.derived_stats = nil

-- Character data API.
ParchmentCharDB = {}
assert(ns.NextCharacterKey() == "Character-1")
ns.SetCharacter("Character-1", { name = "A" })
assert(ns.NextCharacterKey() == "Character-2")
assert(ns.NextCharacterKey("NPC") == "NPC-1")
assert(ns.GetCharacter("Character-1").name == "A")
ns.SetCharacter("x", { name = "B" })
assert(ns.GetCharacter("x").name == "B")
assert(ns.SetActiveCharacter("x"))
assert(not ns.SetActiveCharacter("missing"))
local char, key = ns.GetActiveCharacter()
assert(key == "x" and char.name == "B")

-- Migration scaffold: fresh installs are stamped with the current format.
local _, db = boot({}, nil, nil)
assert(db.global.dataFormat == 1, "fresh install not stamped")

-- Current-format data is untouched.
_, db = boot({ dataFormat = 1 }, { characters = {} }, nil)
assert(db.global.dataFormat == 1)

-- Newer-format data (downgrade): warn, never stamp down.
local warned = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) warned[#warned + 1] = m end }
local db2 = T.InstallLifecycleStubs({ dataFormat = 99 })
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) warned[#warned + 1] = m end }
ParchmentCharDB, ParchmentSystemDB = {}, nil
local ns2 = T.load({}, "Core.lua")
ns2.Addon:OnInitialize()
assert(db2.global.dataFormat == 99, "downgrade stamped over newer data")
local found = false
for _, m in ipairs(warned) do
    if m:find("newer Parchment") then found = true end
end
assert(found, "no downgrade warning printed")
