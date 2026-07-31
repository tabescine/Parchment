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

-- Item library API. Keys are allocated like character keys; a dangling id
-- resolves to the shared sentinel rather than nil, and every save bumps the
-- version (what a future item transfer compares to decide whose copy is newer).
ParchmentItemDB = {}
assert(next(ns.GetItemLibrary()) == nil, "a fresh install has an empty library")
assert(ns.NextItemKey() == "itm_1")
local stored = ns.SetItem("itm_1", { name = "Rope", kind = "gear" })
assert(stored.id == "itm_1" and stored.version == 1)
assert(ns.NextItemKey() == "itm_2")
assert(ns.GetItem("itm_1").name == "Rope")
assert(ns.SetItem("itm_1", { name = "Better Rope", kind = "gear" }).version == 2, "saves bump version")
assert(ns.SetItem(nil, {}) == nil and ns.SetItem("itm_2", "nope") == nil)
assert(ns.GetItem("nope") == ns.MISSING_ITEM and ns.GetItem(nil) == ns.MISSING_ITEM)
assert(ns.MISSING_ITEM.missing == true and ns.MISSING_ITEM.name ~= nil)
ns.DeleteItem("itm_1")
assert(ns.GetItem("itm_1") == ns.MISSING_ITEM and ns.NextItemKey() == "itm_1")

-- Persistence strips the wire-only `resolved` snapshots from an inventory:
-- locally the library is the source of truth, so a stored copy would go stale.
ns.SetCharacter("holder", { name = "H", inventory = {
    { item_id = "itm_1", resolved = { name = "From the wire" } },
    { item_id = "itm_2", count = 2 },
    "junk",
} })
local held = ns.GetCharacter("holder")
assert(held.inventory[1].resolved == nil and held.inventory[1].item_id == "itm_1")
assert(held.inventory[2].count == 2, "per-character state is untouched")

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
