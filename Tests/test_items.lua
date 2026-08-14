-- Items: reference resolution (library -> wire snapshot -> missing sentinel),
-- instantiation and the per-character mutations, plus what an equipped item
-- does to a computed sheet. The library is always passed in, so nothing here
-- touches SavedVariables.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
local ns = T.load({}, "Core.lua")
T.load(ns, "Modules/Items.lua")
T.load(ns, "Modules/CharacterSheet.lua")
local Items = ns.Items

ParchmentSystemDB = {
    system_name = "Items Mini",
    attributes = { { id = "a", name = "Alpha" } },
    modifier_table = { 0 },                     -- every score has modifier 0
    accomplishment_table = { 2 },               -- level 1 -> +2
    hit_dice_bands = { { max_mod = 9, die = "d6" } },
    derived_stats = { ac_base = 10 },
    weapons = {
        { id = "w1", name = "Club", attribute = "a", damage = "1d6" },
        { id = "w2", name = "Knife", attribute = "a", damage = "1d4" },
    },
}
local system = ParchmentSystemDB

-- A library covering every kind, both weapon links (real and dangling), and
-- two magic weapons pointing at the SAME system weapon (the dual-wield case:
-- each carries its own attack total).
local function Library()
    return {
        itm_1 = { id = "itm_1", name = "Flame Dagger", kind = "weapon",
                  weapon_id = "w1", bonus = 2, icon = "inv_sword_04",
                  description = "Warm to the touch." },
        itm_2 = { id = "itm_2", name = "Bright Blade", kind = "weapon", weapon_id = "w1", bonus = 1 },
        itm_3 = { id = "itm_3", name = "Chainmail", kind = "equipment", ac_bonus = 1 },
        itm_4 = { id = "itm_4", name = "Buckler", kind = "equipment", ac_bonus = 2 },
        itm_5 = { id = "itm_5", name = "Rope", kind = "gear", default_count = 3 },
        itm_6 = { id = "itm_6", name = "Cursed Fork", kind = "weapon", weapon_id = "ghost", bonus = 5 },
    }
end

local function Char(inventory)
    return {
        name = "Holder", level = 1, attributes = { a = 1 },
        accomplished_weapons = { "w1", "w2" },
        inventory = inventory,
    }
end

-- Resolution precedence: the local library first, then the wire snapshot a
-- shared sheet carries, then the shared missing sentinel (identity, not a copy -
-- the UI dims a row by testing item == ns.MISSING_ITEM).
local lib = Library()
local item, source = Items.Resolve({ item_id = "itm_1" }, lib)
assert(item == lib.itm_1 and source == "library")
item, source = Items.Resolve({ item_id = "gone", resolved = { name = "Borrowed", kind = "gear" } }, lib)
assert(item.name == "Borrowed" and source == "wire", "a dangling id must fall to the wire snapshot")
item = Items.Resolve({ item_id = "itm_1", resolved = { name = "Stale" } }, lib)
assert(item == lib.itm_1, "our own library outranks the sender's snapshot")
item, source = Items.Resolve({ item_id = "gone" }, lib)
assert(item == ns.MISSING_ITEM and source == "missing")
assert(Items.Resolve({ item_id = "itm_1" }, nil) == ns.MISSING_ITEM, "no library resolves as missing")
assert(Items.Resolve(nil, lib) == ns.MISSING_ITEM and Items.Resolve(5, lib) == ns.MISSING_ITEM)
assert(Items.Resolve({ item_id = 5 }, lib) == ns.MISSING_ITEM, "a non-string id resolves as missing")

-- Instantiation: weapons and equipment start stashed, gear starts at its
-- default count (1 when the item names none).
local entry = Items.Instantiate(lib.itm_1)
assert(entry.item_id == "itm_1" and entry.equipped == false and entry.count == nil)
assert(Items.Instantiate(lib.itm_3).equipped == false)
assert(Items.Instantiate(lib.itm_5).count == 3 and Items.Instantiate(lib.itm_5).equipped == nil)
assert(Items.Instantiate({ id = "x", kind = "gear" }).count == 1, "no default_count seeds 1")
assert(Items.Instantiate({ name = "no id", kind = "gear" }) == nil, "an item needs an id to reference")
assert(Items.Instantiate(nil) == nil and Items.Instantiate("itm_1") == nil)

-- Equip toggle: flips and reports the new state; an index naming no entry is a
-- no-op (a stale click from a refreshing UI must not throw).
local toggling = Char({ { item_id = "itm_1", equipped = false } })
assert(Items.ToggleEquipped(toggling, 1) == true and toggling.inventory[1].equipped == true)
assert(Items.ToggleEquipped(toggling, 1) == false and toggling.inventory[1].equipped == false)
assert(Items.ToggleEquipped(toggling, 9) == nil and Items.ToggleEquipped(toggling, nil) == nil)
assert(Items.ToggleEquipped({}, 1) == nil and Items.ToggleEquipped(nil, 1) == nil)

-- Gear counter: clamped into [0, MAX_COUNT], whole numbers only, and untouched
-- by anything that is not a number.
local counting = Char({ { item_id = "itm_5", count = 3 } })
assert(Items.SetCount(counting, 1, 7) == 7 and counting.inventory[1].count == 7)
assert(Items.SetCount(counting, 1, "12") == 12, "a numeric string from an edit box is accepted")
assert(Items.SetCount(counting, 1, -5) == 0, "counts clamp at zero")
assert(Items.SetCount(counting, 1, 1e9) == Items.MAX_COUNT and Items.MAX_COUNT == 9999)
assert(Items.SetCount(counting, 1, math.huge) == Items.MAX_COUNT)
assert(Items.SetCount(counting, 1, 2.7) == 2, "counts are whole")
assert(Items.SetCount(counting, 1, "abc") == nil and counting.inventory[1].count == 2)
assert(Items.SetCount(counting, 1, 0 / 0) == nil and counting.inventory[1].count == 2)
assert(Items.SetCount(counting, 9, 1) == nil and Items.SetCount(nil, 1, 1) == nil)

-- Removal: the entry goes and the rest shift down, which is why a UI holding an
-- index must re-render rather than reuse it. An index naming no entry is a
-- no-op, not an error (the same stale-click guard as the toggle).
local shrinking = Char({
    { item_id = "itm_1" }, { item_id = "itm_3" }, { item_id = "itm_5", count = 2 },
})
assert(Items.Remove(shrinking, 1) == true and #shrinking.inventory == 2)
assert(shrinking.inventory[1].item_id == "itm_3", "later entries shift down")
assert(Items.Remove(shrinking, 9) == false and Items.Remove(shrinking, nil) == false)
assert(Items.Remove({}, 1) == false and Items.Remove(nil, 1) == false)
assert(Items.Remove(shrinking, 2) == true and #shrinking.inventory == 1)
assert(Items.Remove(shrinking, 1) == true and #shrinking.inventory == 0)
assert(Items.Remove(shrinking, 1) == false, "an emptied inventory removes nothing")

-- The computed sheet. Weapon items never touch the weapon proficiency rows -
-- each carries its own attack total instead (the linked weapon's bare total plus
-- its own bonus), so two blades linking the same weapon are two separate rolls.
local char = Char({
    { item_id = "itm_1", equipped = true },     -- +2 to w1
    { item_id = "itm_2", equipped = true },     -- +1 to w1 as well
    { item_id = "itm_3", equipped = true },     -- +1 AC
    { item_id = "itm_4", equipped = true },     -- +2 AC
    { item_id = "itm_5", count = 12 },          -- gear
    { item_id = "itm_6", equipped = true },     -- links a weapon this system lacks
    { item_id = "itm_99" },                     -- not in the library at all
})
local sheet = ns.CharacterSheet.Compute(char, system, lib)
local weapons = {}
for _, w in ipairs(sheet.weapons) do weapons[w.id] = w end
assert(weapons.w1.attack_total == 2, "a proficiency row is the bare skill: accomplishment (+2)")
assert(weapons.w1.item_bonus == nil and weapons.w2.item_bonus == nil, "no item folds into a row")
assert(weapons.w2.attack_total == 2, "an unlinked weapon reads the same as a linked one")

-- Each equipped weapon item rolls for itself: both daggers link w1, and both
-- carry the weapon row's total plus their OWN bonus - nothing is picked as best.
local held = sheet.inventory.weapons
assert(held[1].attack_total == 4 and held[2].attack_total == 3, "each item keeps its own total")
assert(held[1].attack_parts.base == weapons.w1.attack_total, "the base is the proficiency total")
assert(held[1].attack_parts.bonus == 2 and held[2].attack_parts.bonus == 1)

-- Equipment AC stacks across pieces and is broken out by name, so the tooltip
-- can say where the points came from; the total still folds into derived.ac.
assert(sheet.derived.ac == 13, "10 base + 1 chainmail + 2 buckler, got " .. sheet.derived.ac)
local ace = sheet.derived.ac_equipment
assert(ace and ace.total == 3 and #ace.sources == 2)
assert(ace.sources[1] == "Chainmail" and ace.sources[2] == "Buckler")

-- Display entries: grouped by kind, carrying their index into char.inventory
-- (the UI's handle for toggling) and never the library table itself.
local inv = sheet.inventory
assert(#inv.weapons == 3 and #inv.equipment == 2 and #inv.gear == 2)
assert(inv.weapons[1].index == 1 and inv.weapons[1].name == "Flame Dagger")
assert(inv.weapons[1].icon == "inv_sword_04" and inv.weapons[1].description == "Warm to the touch.")
assert(inv.weapons[1].equipped == true and inv.weapons[1].bonus == 2)
assert(inv.weapons[1].weapon_name == "Club", "a resolved link names its weapon for the tooltip")
assert(inv.weapons[1] ~= lib.itm_1, "display entries must not hand out library tables")
assert(inv.gear[1].name == "Rope" and inv.gear[1].count == 12, "the stored count wins over the default")

-- A dangling weapon_id degrades to a display-only item: it keeps its bonus on
-- the row for the tooltip, but there is no weapon skill for it to ride on, so
-- it gets no attack total of its own and reaches no row.
local cursed = inv.weapons[3]
assert(cursed.name == "Cursed Fork" and cursed.bonus == 5)
assert(cursed.weapon_id == "ghost" and cursed.weapon_name == nil)
assert(cursed.attack_total == nil and cursed.attack_parts == nil)
assert(weapons.w1.attack_total == 2 and weapons.w2.attack_total == 2, "a dangling link must land nowhere")

-- A dangling item_id renders as a missing row (the sentinel has no kind of its
-- own, so it lands in the catch-all gear group) instead of breaking the sheet.
local missing = inv.gear[2]
assert(missing.index == 7 and missing.missing == true and missing.source == "missing")
assert(missing.name == ns.MISSING_ITEM.name)

-- Retro-editing: inventories hold references, so editing the library item is
-- reflected the next time the sheet is computed - no per-character rewrite.
lib.itm_1.bonus = 4
lib.itm_1.name = "Inferno Dagger"
local edited = ns.CharacterSheet.Compute(char, system, lib)
local dagger = edited.inventory.weapons[1]
assert(dagger.name == "Inferno Dagger" and dagger.attack_total == 6, "library edits propagate")
assert(edited.weapons[1].attack_total == 2, "the proficiency row stays bare through it all")
-- Deleting it leaves the character alone: the row goes missing, nothing throws.
lib.itm_1 = nil
local deleted = ns.CharacterSheet.Compute(char, system, lib)
assert(deleted.inventory.weapons[1].attack_total == 3, "the other dagger is unaffected")
assert(deleted.inventory.gear[1].missing, "the deleted one falls to a missing row")
assert(#char.inventory == 7, "resolution must never rewrite the character's inventory")

-- A stashed weapon still computes its total (the UI simply shows no number for
-- one that is in the bag); nothing it carries reaches a row or derived stat.
local stashed = ns.CharacterSheet.Compute(Char({
    { item_id = "itm_2", equipped = false },
    { item_id = "itm_3", equipped = false },
}), system, Library())
assert(stashed.weapons[1].attack_total == 2 and stashed.weapons[1].item_bonus == nil)
assert(stashed.inventory.weapons[1].equipped == false)
assert(stashed.inventory.weapons[1].attack_total == 3, "a stashed weapon knows its own total")
assert(stashed.derived.ac == 10 and stashed.derived.ac_equipment == nil)

-- Parity with the proficiency rows: a weapon the character is not accomplished
-- with has no row and no total, so an item linking it has none either.
local untrained = ns.CharacterSheet.Compute({
    name = "Novice", level = 1, attributes = { a = 1 },
    inventory = { { item_id = "itm_1", equipped = true } },
}, system, Library())
assert(#untrained.weapons == 0 and untrained.inventory.weapons[1].attack_total == nil)

-- A shared sheet: our library knows none of the sender's ids, so the wire
-- snapshots are what render the rows and carry the bonuses.
local shared = ns.CharacterSheet.Compute(Char({
    { item_id = "their_1", equipped = true,
      resolved = { name = "Borrowed Axe", kind = "weapon", weapon_id = "w1", bonus = 3 } },
    { item_id = "their_2", equipped = true,
      resolved = { name = "Borrowed Plate", kind = "equipment", ac_bonus = 2 } },
}), system, {})
assert(shared.inventory.weapons[1].name == "Borrowed Axe")
assert(shared.inventory.weapons[1].attack_total == 5, "a wire bonus reaches its own total")
assert(shared.weapons[1].attack_total == 2, "and never the proficiency row")
assert(shared.derived.ac == 12 and shared.derived.ac_equipment.sources[1] == "Borrowed Plate")
assert(shared.inventory.weapons[1].source == "wire" and not shared.inventory.weapons[1].missing)

-- Malformed inventories (a scalar list, scalar entries, a count where a bool
-- belongs) must compute, not throw: this data can arrive from the wire.
assert(ns.CharacterSheet.Compute(Char(5), system, lib), "a scalar inventory must not throw")
local junk = ns.CharacterSheet.Compute(Char({
    5,
    { item_id = "itm_5", count = "many" },
    { item_id = "itm_5", count = 1e12 },
}), system, lib)
assert(#junk.inventory.gear == 3 and junk.inventory.gear[1].missing)
assert(junk.inventory.gear[2].count == 3, "an unusable count falls back to the item's default")
assert(junk.inventory.gear[3].count == Items.MAX_COUNT, "an absurd stored count renders clamped")

-- Non-finite bonuses in a hand-edited (or hostile) item never reach a total.
local poisoned = { itm_x = { id = "itm_x", name = "Broken", kind = "weapon",
    weapon_id = "w1", bonus = 1 / 0 } }
local safe = ns.CharacterSheet.Compute(Char({ { item_id = "itm_x", equipped = true } }),
    system, poisoned)
assert(safe.weapons[1].attack_total == 2 and safe.inventory.weapons[1].bonus == 0)
assert(safe.inventory.weapons[1].attack_total == 2, "a poisoned bonus contributes nothing")

-- Worn-armor modifier caps (ac_mod_cap): an equipped equipment piece may cap
-- the AC attribute's contribution - heavy armor is cap 0, medium cap 2/3,
-- absent means the full modifier. The lowest worn cap binds, a cap never
-- raises a low modifier, and a stashed piece caps nothing. Needs nonzero
-- modifiers, so the shared table is swapped and restored around the block.
system.modifier_table = { 0, 1, 2, 3, 4, 5 }        -- score N -> N-1
local armory = {
    heavy  = { id = "heavy", name = "Heavy Plate", kind = "equipment",
               ac_bonus = 8, ac_mod_cap = 0 },
    medium = { id = "medium", name = "Scale Mail", kind = "equipment",
               ac_bonus = 4, ac_mod_cap = 2 },
    light  = { id = "light", name = "Leathers", kind = "equipment", ac_bonus = 1 },
    cursed = { id = "cursed", name = "Cursed Girdle", kind = "equipment", ac_mod_cap = -7 },
    broken = { id = "broken", name = "Broken Circlet", kind = "equipment", ac_mod_cap = 0 / 0 },
}
local function Nimble(inventory)
    return { name = "Nimble", level = 1, attributes = { a = 6 },   -- +5 modifier
             ac_attribute = "a", inventory = inventory }
end

-- Heavy armor suppresses the +5 entirely; its own ac_bonus still lands:
-- 10 base + 0 (capped) + 8 plate.
local plated = ns.CharacterSheet.Compute(Nimble({ { item_id = "heavy", equipped = true } }),
    system, armory)
assert(plated.derived.ac == 18, "heavy armor must suppress the modifier, got " .. plated.derived.ac)
assert(plated.derived.ac_attribute_mod == 0, "the used modifier term is exposed post-cap")
assert(plated.derived.ac_mod_cap.value == 0 and plated.derived.ac_mod_cap.source == "Heavy Plate")
assert(plated.inventory.equipment[1].ac_mod_cap == 0, "the display entry carries its cap")

-- Stashed, the same plate neither caps nor adds.
local carried = ns.CharacterSheet.Compute(Nimble({ { item_id = "heavy", equipped = false } }),
    system, armory)
assert(carried.derived.ac == 15 and carried.derived.ac_mod_cap == nil)
assert(carried.derived.ac_attribute_mod == 5)

-- Layered pieces: the lowest worn cap binds and is the one named.
local layered = ns.CharacterSheet.Compute(Nimble({
    { item_id = "medium", equipped = true },
    { item_id = "light", equipped = true },
}), system, armory)
assert(layered.derived.ac == 17, "10 + capped 2 + 4 mail + 1 leathers, got " .. layered.derived.ac)
assert(layered.derived.ac_mod_cap.value == 2 and layered.derived.ac_mod_cap.source == "Scale Mail")

-- A cap never raises: a modifier already below it passes through untouched.
local modest = ns.CharacterSheet.Compute({
    name = "Modest", level = 1, attributes = { a = 1 }, ac_attribute = "a",
    inventory = { { item_id = "medium", equipped = true } },
}, system, armory)
assert(modest.derived.ac == 14 and modest.derived.ac_attribute_mod == 0,
    "a +2 cap must not lift a +0 modifier")

-- Hostile/hand-edited caps: a negative cap reads as 0 (a penalty belongs in
-- ac_bonus), a NaN cap caps nothing at all.
local girdled = ns.CharacterSheet.Compute(Nimble({ { item_id = "cursed", equipped = true } }),
    system, armory)
assert(girdled.derived.ac == 10, "a negative cap must read as 0, got " .. girdled.derived.ac)
local circlet = ns.CharacterSheet.Compute(Nimble({ { item_id = "broken", equipped = true } }),
    system, armory)
assert(circlet.derived.ac == 15 and circlet.derived.ac_mod_cap == nil, "a NaN cap caps nothing")

-- A wire snapshot's cap applies exactly like a library one - the shared-sheet
-- path holds the same line as the local one.
local wireCapped = ns.CharacterSheet.Compute(Nimble({
    { item_id = "their_plate", equipped = true,
      resolved = { name = "Borrowed Plate", kind = "equipment", ac_bonus = 2, ac_mod_cap = 0 } },
}), system, {})
assert(wireCapped.derived.ac == 12 and wireCapped.derived.ac_mod_cap.source == "Borrowed Plate")
system.modifier_table = { 0 }

-- Item effects: an equipped weapon/equipment item folds its effect list like
-- a trait (saves, attributes, initiative, ...) - but only while equipped, and
-- never from gear. The ordering guarantee (an item's attribute effect reaching
-- modifiers and weapon attacks) lives in test_charactersheet.lua.
local charmed = Library()
charmed.itm_7 = { id = "itm_7", name = "Sentry Ring", kind = "equipment",
    effects = {
        { type = "save", id = "a", value = 2 },
        { type = "initiative", value = 1 },
        { type = "attribute", id = "a", value = 3 },
    } }
local worn = ns.CharacterSheet.Compute(Char({ { item_id = "itm_7", equipped = true } }),
    system, charmed)
assert(worn.saves[1].total == 2, "an equipped item's save effect must fold")
assert(worn.saves[1].sources[1] == "Sentry Ring", "the save names its source")
assert(worn.derived.initiative == 1, "an equipped item's initiative effect must fold")
assert(worn.attributes[1].final == 4 and worn.attributes[1].bonus == 3,
    "an item's attribute effect lands like a trait's")
local pocketed = ns.CharacterSheet.Compute(Char({ { item_id = "itm_7", equipped = false } }),
    system, charmed)
assert(pocketed.saves[1].total == 0 and pocketed.derived.initiative == 0
    and pocketed.attributes[1].final == 1, "a stashed item's effects must not fold")
assert(type(pocketed.inventory.equipment[1].effects) == "table",
    "the display entry still lists the effects for the tooltip")

-- Gear never applies effects, even when a hand-edit smuggles a list (and an
-- equipped flag) onto it.
charmed.itm_8 = { id = "itm_8", name = "Odd Pebble", kind = "gear",
    effects = { { type = "save", id = "a", value = 5 } } }
local pebbled = ns.CharacterSheet.Compute(Char({
    { item_id = "itm_8", count = 1, equipped = true },
}), system, charmed)
assert(pebbled.saves[1].total == 0, "gear effects must never fold")

-- Wire-resolved effects fold exactly like library ones, and hostile values
-- (non-finite numbers, scalar entries) coerce to nothing instead of poisoning
-- the totals or throwing.
local borrowed = ns.CharacterSheet.Compute(Char({
    { item_id = "their_ring", equipped = true,
      resolved = { name = "Borrowed Ring", kind = "equipment",
        effects = { { type = "save", id = "a", value = 1 },
                    { type = "initiative", value = 1 / 0 },
                    "junk" } } },
}), system, {})
assert(borrowed.saves[1].total == 1, "a wire effect must fold while equipped")
assert(borrowed.derived.initiative == 0, "a non-finite wire value must coerce to 0")

-- A wire snapshot may carry effects and no name at all (the schema calls `name`
-- optional, so this passes validation and is cached before it is ever
-- displayed): the item's name is what an attribute effect's provenance line
-- concatenates, so it needs a fallback or the whole sheet throws - on every
-- view, until the cache is cleared.
local ok, nameless = pcall(ns.CharacterSheet.Compute, Char({
    { item_id = "their_nameless", equipped = true,
      resolved = { kind = "equipment",
        effects = { { type = "attribute", id = "a", value = 1 } } } },
}), system, {})
assert(ok, "a nameless equipped item must not throw: " .. tostring(nameless))
assert(nameless.attributes[1].bonus == 1, "a nameless item's effect must still fold")
assert(type(nameless.attributes[1].sources[1]) == "string", "the bonus source names something")
assert(type(nameless.inventory.equipment[1].name) == "string", "a nameless row still has a label")

-- Absurd wire effect values clamp to the item-bonus limit (+/- 99) instead of
-- reaching a total, and an equipped item whose whole effect list is junk simply
-- folds nothing.
local greedy = ns.CharacterSheet.Compute(Char({
    { item_id = "their_greedy", equipped = true,
      resolved = { name = "Greedy Band", kind = "equipment",
        effects = { { type = "save", id = "a", value = 1e12 },
                    { type = "ac", value = -1e308 } } } },
    { item_id = "their_junk", equipped = true,
      resolved = { name = "Junk Band", kind = "equipment", effects = { 5, "e", true } } },
}), system, {})
assert(greedy.saves[1].total == 99, "an absurd wire value must clamp to 99, got "
    .. greedy.saves[1].total)
assert(greedy.derived.ac == 10 - 99, "an absurd negative value must clamp to -99, got "
    .. greedy.derived.ac)

-- Item ids are library-local: ns.NextItemKey hands out "itm_1", "itm_2", ... per
-- library, so EVERY player's first item is "itm_1". A foreign sheet's ids
-- therefore collide with ours by construction, and resolving them against our
-- library would show our items on their sheet - and fold our item effects into
-- their totals. The sheet UI computes a viewed character with no library at all,
-- so the wire snapshot is the only thing that can answer.
local collide = Library()
collide.itm_1 = { id = "itm_1", name = "My Dagger", kind = "weapon", weapon_id = "w1",
    bonus = 5, effects = { { type = "ac", value = 7 } } }
local theirs = Char({
    { item_id = "itm_1", equipped = true,
      resolved = { name = "Her Axe", kind = "weapon", weapon_id = "w1", bonus = 1 } },
})
local ours = ns.CharacterSheet.Compute(theirs, system, collide)
assert(ours.inventory.weapons[1].name == "My Dagger",
    "sanity: with a library, a colliding id resolves to OUR item")
local foreign = ns.CharacterSheet.Compute(theirs, system, nil)
assert(foreign.inventory.weapons[1].name == "Her Axe",
    "a foreign sheet must show the sender's item, not ours")
assert(foreign.inventory.weapons[1].source == "wire")
-- Their axe carries no effects, so their AC must match a bare character's -
-- proving our "+7 AC" item contributed nothing to their sheet.
local bare = ns.CharacterSheet.Compute(Char({}), system, nil)
assert(foreign.derived.ac == bare.derived.ac,
    "our item's effects must not fold into their totals")
assert(ours.derived.ac ~= foreign.derived.ac,
    "the two paths must genuinely differ, or this test proves nothing")

-- MigrateAC: the retired equipment ac_bonus field folds into an "ac" effect -
-- Core's load-time migration, the import path and the wizard draft all run
-- items through this, so an old library keeps its +AC.
local mail = { id = "m", name = "Chainmail", kind = "equipment", ac_bonus = 2,
    effects = { { type = "initiative", value = 1 } } }
Items.MigrateAC(mail)
assert(mail.ac_bonus == nil and #mail.effects == 2, "ac_bonus must fold into the effects list")
assert(mail.effects[2].type == "ac" and mail.effects[2].value == 2)
Items.MigrateAC(mail)
assert(#mail.effects == 2, "re-running the migration must not fold twice")

-- The field starts the list on an item without one; a zero folds to nothing.
local shirt = { id = "s", name = "Shirt", kind = "equipment", ac_bonus = 1 }
Items.MigrateAC(shirt)
assert(shirt.effects[1].type == "ac" and shirt.effects[1].value == 1)
local plain = { id = "p", name = "Plain Coat", kind = "equipment", ac_bonus = 0 }
Items.MigrateAC(plain)
assert(plain.ac_bonus == nil and plain.effects == nil, "a zero bonus folds to nothing")

-- On any other kind the field was dormant (nothing ever read it), so it is
-- dropped rather than turned into a live effect; unusable values drop too.
local oddKnife = { id = "k", name = "Knife", kind = "weapon", ac_bonus = 3 }
Items.MigrateAC(oddKnife)
assert(oddKnife.ac_bonus == nil and oddKnife.effects == nil, "a weapon's ac_bonus was dormant")
local haunted = { id = "h", name = "Haunted Helm", kind = "equipment", ac_bonus = 0 / 0 }
Items.MigrateAC(haunted)
assert(haunted.ac_bonus == nil and haunted.effects == nil, "a NaN bonus folds to nothing")

-- A full effects list keeps the field instead (10 is the schema's cap): the
-- sheet's legacy fold still applies it, so nothing is silently lost.
local crowded = { id = "c", name = "Crowded Cloak", kind = "equipment", ac_bonus = 1, effects = {} }
for i = 1, 10 do crowded.effects[i] = { type = "initiative", value = 1 } end
Items.MigrateAC(crowded)
assert(crowded.ac_bonus == 1 and #crowded.effects == 10, "a full list keeps the legacy field")

-- The ac effect folds into AC with provenance: derived.ac_effects names each
-- grant for the AC tooltip, while a legacy ac_bonus keeps its own separately
-- named ac_equipment term - the two shares never blur.
local mixed = Library()
mixed.itm_9 = { id = "itm_9", name = "Ring of Protection", kind = "equipment",
    effects = { { type = "ac", value = 2 } } }
local ringed = ns.CharacterSheet.Compute(Char({
    { item_id = "itm_9", equipped = true },
    { item_id = "itm_3", equipped = true },     -- legacy ac_bonus = 1
}), system, mixed)
assert(ringed.derived.ac == 13, "10 base + 2 effect + 1 legacy, got " .. ringed.derived.ac)
assert(ringed.derived.ac_effects.total == 2
    and ringed.derived.ac_effects.sources[1] == "+2 Ring of Protection",
    "the ac effect must record its provenance")
assert(ringed.derived.ac_equipment.total == 1
    and ringed.derived.ac_equipment.sources[1] == "Chainmail",
    "the legacy share keeps its own term")
local unringed = ns.CharacterSheet.Compute(Char({
    { item_id = "itm_9", equipped = false },
}), system, mixed)
assert(unringed.derived.ac == 10 and unringed.derived.ac_effects == nil,
    "a stashed ac effect must not fold and leaves no provenance")

-- Wield states. The category decides the cycle: light may sit in either hand,
-- versatile in one hand or two, a two-hander only in both; no category means a
-- plain one-hander (the pre-wield behaviour).
T.load(ns, "Schema.lua")   -- damage below is gated on Schema.IsDieNotation
local WS = Items.WieldStates
assert(WS("light")[1] == "main" and WS("light")[2] == "off")
assert(WS("versatile")[1] == "main" and WS("versatile")[2] == "two")
assert(WS("two_hand")[1] == "two" and #WS("two_hand") == 1)
assert(WS("one_hand")[1] == "main" and #WS("one_hand") == 1)
assert(WS(nil)[1] == "main" and #WS(nil) == 1, "no category = plain one-hander")

-- CycleWield walks stashed -> each state -> stashed, and EffectiveWield never
-- trusts a stored wield the category does not allow.
local holder = { inventory = { { item_id = "x", equipped = false } } }
assert(Items.CycleWield(holder, 1, "light") == "main")
assert(Items.CycleWield(holder, 1, "light") == "off")
assert(Items.CycleWield(holder, 1, "light") == "stashed")
assert(holder.inventory[1].equipped == false and holder.inventory[1].wield == nil,
    "stashing clears the stored hand")
assert(Items.CycleWield(holder, 1, "two_hand") == "two")
assert(Items.CycleWield(holder, 1, "two_hand") == "stashed")
assert(Items.CycleWield(holder, 1, nil) == "main", "no category equips main hand")
assert(Items.EffectiveWield({ equipped = true, wield = "two" }, "light") == "main",
    "a stale wield falls back to the category's first state")
assert(Items.EffectiveWield({ equipped = false, wield = "main" }, "light") == nil,
    "a stashed entry has no wield")

-- Damage: die + governing attribute modifier, per wield state. A fresh mini
-- system with a nonzero modifier so the attribute share is visible - installed
-- as the active system too, since modifier/accomplishment lookups read it.
local dmgSystem = {
    system_name = "Damage Mini",
    attributes = { { id = "a", name = "Alpha" } },
    modifier_table = { 3 },                     -- score 1 -> modifier +3
    accomplishment_table = { 2 },
    hit_dice_bands = { { max_mod = 9, die = "d6" } },
    derived_stats = { ac_base = 10 },
    weapons = {
        { id = "club", name = "Club", attribute = "a", damage = "1d6" },
        { id = "knife", name = "Knife", attribute = "a", damage = "1d4",
          properties = { "Light", "Agile" } },
        { id = "staff", name = "Staff", attribute = "a", damage = "1d6",
          versatile = "1d8", properties = { "Versatile" } },
        { id = "maul", name = "Maul", attribute = "a", damage = "2d6",
          properties = { "Huge", "Two-Handed" } },
    },
}
ParchmentSystemDB = dmgSystem
local dmgLib = {
    club = { id = "club", name = "Old Club", kind = "weapon", weapon_id = "club" },
    knife = { id = "knife", name = "Skinning Knife", kind = "weapon", weapon_id = "knife" },
    staff = { id = "staff", name = "Walking Staff", kind = "weapon", weapon_id = "staff" },
    maul = { id = "maul", name = "Great Maul", kind = "weapon", weapon_id = "maul" },
    loose = { id = "loose", name = "Strange Shard", kind = "weapon", die = "2d6+1" },
    odd = { id = "odd", name = "Odd Relic", kind = "weapon", weapon_id = "club",
            die = "special" },
    magic = { id = "magic", name = "Runed Club", kind = "weapon", weapon_id = "club",
              die = "1d10", bonus = 2 },
}
local function DmgChar(inventory)
    return { name = "Swinger", level = 1, attributes = { a = 1 },
        accomplished_weapons = { "club", "knife", "staff", "maul" },
        inventory = inventory }
end
local function OneWeapon(entry)
    local sheet = ns.CharacterSheet.Compute(DmgChar({ entry }), dmgSystem, dmgLib)
    return sheet.inventory.weapons[1]
end

-- Main hand: die + modifier; the die and category inherit from the link.
local w = OneWeapon({ item_id = "club", equipped = true, wield = "main" })
assert(w.die == "1d6" and w.category == nil and w.wield == "main")
assert(w.damage and w.damage.notation == "1d6+3", "got " .. tostring(w.damage and w.damage.notation))

-- Off hand: the bare die - the light follow-up strike adds no damage modifier.
w = OneWeapon({ item_id = "knife", equipped = true, wield = "off" })
assert(w.category == "light" and w.wield == "off")
assert(w.damage.notation == "1d4" and w.damage.mod == 0, "off hand must drop the modifier")

-- Versatile two-handed: the parenthesized die, modifier kept.
w = OneWeapon({ item_id = "staff", equipped = true, wield = "two" })
assert(w.category == "versatile" and w.versatile_die == "1d8")
assert(w.damage.notation == "1d8+3", "two-handed swings the versatile die")
w = OneWeapon({ item_id = "staff", equipped = true, wield = "main" })
assert(w.damage.notation == "1d6+3", "one-handed keeps the base die")

-- A two-hander's only state is both hands; property strings decide it.
w = OneWeapon({ item_id = "maul", equipped = true })
assert(w.category == "two_hand" and w.wield == "two")
assert(w.damage.notation == "2d6+3")

-- Freestanding (no link): its own die, bare - nothing governs a modifier.
w = OneWeapon({ item_id = "loose", equipped = true, wield = "main" })
assert(w.damage.notation == "2d6+1" and w.damage.mod == 0)

-- A die the roller cannot parse renders as text, never as a roll.
w = OneWeapon({ item_id = "odd", equipped = true, wield = "main" })
assert(w.die == "special" and w.damage == nil, "garbage notation must not become a roll")

-- The item's own die overrides the linked weapon's, and the attack bonus
-- stays attack-only: damage is deliberately unaffected by it.
w = OneWeapon({ item_id = "magic", equipped = true, wield = "main" })
assert(w.damage.notation == "1d10+3", "the authored die wins over the inherited one")
assert(w.attack_total == 3 + 2 + 2, "modifier + accomplishment + item bonus")

-- A stale wield on a shared/edited sheet falls back cleanly in Compute too.
w = OneWeapon({ item_id = "knife", equipped = true, wield = "two" })
assert(w.wield == "main", "a light weapon cannot be two-handed")

print("test_items: wield states + damage OK")
