-- CharacterSheet.Compute: the sheet math against a handcrafted mini system
-- with known-by-construction expected totals.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
local ns = T.load({}, "Core.lua")
T.load(ns, "Modules/Items.lua")
T.load(ns, "Modules/CharacterSheet.lua")

ParchmentSystemDB = {
    system_name = "Mini",
    attributes = { { id = "a", name = "Alpha" }, { id = "b", name = "Bravo" }, { id = "c", name = "Charlie" } },
    modifier_table = { -1, 0, 1, 2 },           -- score 1..4 -> mod -1..2
    accomplishment_table = { 2, 3 },            -- level 1 -> +2, level 2+ -> +3
    hit_dice_bands = { { max_mod = 0, die = "d6" }, { max_mod = 9, die = "d10" } },
    level_bonuses = { [2] = { actions = 1 } },
    derived_stats = {
        hit_die_attribute = "a",
        spell_attributes = { "c" }, mana_attribute = "c", mana_multiplier = 3,
        movement_attribute = "b", movement_base = 10, movement_per_step = 1,
        ac_base = 12, save_dc_base = 8, actions_base = 2,
        ac_attributes = { "a", "b" },        -- candidates: pick honored, else best
        init_attributes = { "b", "c" },
    },
    skills = {
        { id = "s1", name = "Skill One", attribute = "a" },
        { id = "s2", name = "Skill Two", attribute = "b" },
    },
    weapons = {
        { id = "w1", name = "Club", attribute = "a", damage = "1d6", properties = {} },
        { id = "w2", name = "Knife", attribute = { "a", "b" }, damage = "1d4", properties = {} },
        { id = "w3", name = "Unused", attribute = "a", damage = "1d8", properties = {} },
    },
    spell_schools = { { id = "ev", name = "Evocation" }, { id = "wd", name = "Warding" } },
    racial_traits = {
        { id = "r1", name = "Race One",
          bonuses = { { type = "attribute", id = "a", value = 1 } },
          penalties = { { type = "skill", skill = "s2", value = -1 } } },
    },
}
local system = ParchmentSystemDB

local char = {
    name = "Unit", level = 2,
    attributes = { a = 1, b = 3, c = 4 },        -- a: 1+1(race)=2 mod 0; b: mod 1; c: mod 2
    racial_trait = "r1",
    primary_attribute = "c",                     -- in spell_attributes -> caster
    ac_attribute = "b", init_attribute = "b",
    max_hp = 10, current_hp = 7, temp_hp = 1,
    accomplished_skills = { "s1" },
    accomplished_saves = { "a" },
    accomplished_weapons = { "w1", "w2" },
    custom_feats = { {
        id = "hb", name = "Homebrew", level = 1,
        effects = {
            { type = "skill", skill = "s1", add_modifier = "c" },  -- +copy of c's mod (2)
            { type = "save", id = "b", value = 1 },
            { type = "spell_attack", value = 1 },                  -- all schools
            { type = "spell_attack", school = "ev", value = 2 },   -- one school
            { type = "save_dc", school = "ev", value = 1 },        -- one school's DC
            { type = "made_up_informational", value = 5 },          -- must be ignored
        },
    } },
}

local sheet = ns.CharacterSheet.Compute(char, system)
assert(sheet, "Compute returned nil")
assert(ns.CharacterSheet.Compute(nil, system) == nil and ns.CharacterSheet.Compute(char, nil) == nil)

-- Attributes: base + trait bonus, modifier via the table, provenance recorded.
local byId = {}
for _, a in ipairs(sheet.attributes) do byId[a.id] = a end
assert(byId.a.base == 1 and byId.a.bonus == 1 and byId.a.final == 2 and byId.a.modifier == 0)
assert(byId.a.sources[1] == "+1 Race One")
assert(byId.b.final == 3 and byId.b.modifier == 1)
assert(byId.c.final == 4 and byId.c.modifier == 2)

-- Skills. s1 = mod a (0) + accomplishment (3) + homebrew add_modifier copy
-- of c (2) = 5. s2 = mod b (1) + race penalty -1 = 0.
local skills = {}
for _, s in ipairs(sheet.skills) do skills[s.id] = s end
assert(skills.s1.total == 5, "s1 expected 5, got " .. skills.s1.total)
assert(skills.s1.accomplished and not skills.s2.accomplished)
assert(skills.s2.total == 0, "s2 expected 0, got " .. skills.s2.total)

-- Saves: a accomplished (0+3); b has the homebrew +1 (1+1); c plain (2).
local saves = {}
for _, s in ipairs(sheet.saves) do saves[s.id] = s end
assert(saves.a.total == 3 and saves.b.total == 2 and saves.c.total == 2)

-- Weapons: only accomplished ones appear; list-attribute uses the best mod.
local weapons = {}
for _, w in ipairs(sheet.weapons) do weapons[w.id] = w end
assert(weapons.w3 == nil, "unaccomplished weapon leaked onto the sheet")
assert(weapons.w1.attack_total == 3)                        -- 0 + 3
assert(weapons.w2.attack_total == 4 and weapons.w2.attack_attribute == "b")  -- best(0,1)=1 + 3

-- Derived stats.
local d = sheet.derived
assert(d.accomplishment == 3)
assert(d.hit_dice == "2d6")                                 -- a's mod 0 -> d6, level 2
assert(d.hp.max == 10 and d.hp.current == 7 and d.hp.temp == 1)
assert(d.mana.max == 6)                                     -- caster: 3 x c's mod 2
assert(d.ac == 13)                                          -- 12 + b's mod 1
-- The explicit init pick "b" is in the candidate list, so it is honored even
-- though candidate "c" has the better modifier (a choice, not auto-best).
assert(d.initiative == 1 and d.init_attribute == "b")
assert(d.movement == 11)                                    -- 10 + max(0,1) x 1
assert(d.actions == 3)                                      -- 2 + level-2 bonus
assert(d.save_dc == 13)                                     -- 8 + c's mod 2 + 3

-- Spellcasting (the char's primary c IS a spell attribute): spell attack =
-- c's mod (2) + accomplishment (3) + global effect (1) = 6; the targeted
-- effects raise only Evocation's row (+2 atk, +1 DC).
local spell = sheet.derived.spell
assert(spell, "caster must get a spell block")
assert(spell.attack == 6 and spell.dc == 13)
assert(#spell.schools == 2)
assert(spell.schools[1].id == "ev" and spell.schools[1].attack == 8 and spell.schools[1].dc == 14)
assert(spell.schools[2].id == "wd" and spell.schools[2].attack == 6 and spell.schools[2].dc == 13)

-- Mana base vs max: a max_mana effect adds to `max` but not to the stored-facing
-- `base`. Persisting `base` (as CE.InitResources does) and recomputing must NOT
-- re-add the effect - the fix for creation-time mana being double-counted forever.
local charM = {
    name = "M", level = 1, attributes = { a = 1, b = 3, c = 4 }, primary_attribute = "c",
    custom_feats = { { id = "hb", name = "HB", level = 1, effects = { { type = "max_mana", value = 5 } } } },
}
local sm = ns.CharacterSheet.Compute(charM, system).derived.mana
assert(sm.base == 6, "base must be the fx-free mana (3 x c's mod 2), got " .. tostring(sm.base))
assert(sm.max == 11, "max must add the +5 max_mana effect once, got " .. tostring(sm.max))
charM.max_mana = sm.base                    -- what InitResources persists
local sm2 = ns.CharacterSheet.Compute(charM, system).derived.mana
assert(sm2.max == 11, "recompute must not double-count the effect, got " .. tostring(sm2.max))

-- Non-caster fallback: primary outside spell_attributes uses mana_attribute,
-- and there is no spell block and NO save DC (it is a spellcasting number).
local char2 = { name = "N", level = 1, attributes = { a = 1, b = 3, c = 4 }, primary_attribute = "b" }
local sheet2 = ns.CharacterSheet.Compute(char2, system)
assert(sheet2.derived.mana.max == 6, "fallback mana attribute (c) should drive mana")
assert(sheet2.derived.save_dc == nil, "non-casters must not carry a save DC")
assert(sheet2.derived.spell == nil, "non-casters must not get a spell block")

-- No AC/init picks at all: the best candidate decides automatically.
assert(sheet2.derived.ac == 13 and sheet2.derived.ac_attribute == "b")     -- best of a(0)/b(1)
assert(sheet2.derived.initiative == 2 and sheet2.derived.init_attribute == "c")  -- best of b(1)/c(2)

-- Items regression guard: a character without an inventory computes exactly as
-- it did before items existed, whatever library is passed (or none at all). The
-- inventory and equipment-AC keys stay absent, so nothing downstream has to
-- learn a new empty shape.
local lib = { itm_1 = { id = "itm_1", name = "Unheld", kind = "equipment", ac_bonus = 5 } }
T.assert_deepeq(sheet, ns.CharacterSheet.Compute(char, system, lib), "library-only difference")
T.assert_deepeq(sheet, ns.CharacterSheet.Compute(char, system, nil), "nil library")
assert(sheet.inventory == nil and sheet.derived.ac_equipment == nil)
-- An empty inventory list is the same story.
char.inventory = {}
T.assert_deepeq(sheet, ns.CharacterSheet.Compute(char, system, lib), "empty inventory")
char.inventory = nil

-- An equipped item's effects fold BEFORE the attribute pass, so an item's
-- attribute bonus reaches the modifier and everything riding it - skills,
-- saves, weapon attacks, the hit die - exactly as a trait's would.
local ringLib = { ring = { id = "ring", name = "Ring of Alpha", kind = "equipment",
    effects = { { type = "attribute", id = "a", value = 1 } } } }
char.inventory = { { item_id = "ring", equipped = true } }
local ringed = ns.CharacterSheet.Compute(char, system, ringLib)
local rBy = {}
for _, a in ipairs(ringed.attributes) do rBy[a.id] = a end
assert(rBy.a.final == 3 and rBy.a.modifier == 1, "the ring must shift a's modifier")
assert(rBy.a.sources[2] == "+1 Ring of Alpha", "the attribute bonus names the item")
for _, s in ipairs(ringed.skills) do
    if s.id == "s1" then
        assert(s.total == 6, "the shifted modifier must reach skills, got " .. s.total)
    end
end
for _, s in ipairs(ringed.saves) do
    if s.id == "a" then assert(s.total == 4, "the shifted modifier must reach saves") end
end
for _, w in ipairs(ringed.weapons) do
    if w.id == "w1" then
        assert(w.attack_total == 4, "the shifted modifier must reach weapon attacks")
    end
end
assert(ringed.derived.hit_dice == "2d10", "the shifted modifier must reach the hit die")
char.inventory = nil

-- Hostile-but-schema-valid characters. A shared sheet is validated for shape
-- only (no sender system to cross-reference), several fields are optional, and
-- the receiver caches it before rendering it - so a payload that throws in
-- Compute would throw on every later view. Compute must stay total: a sane
-- sheet with finite numbers, never an error.
local function Finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end
local function Hostile(fields)
    local c = { name = "Hostile", level = 1, attributes = { a = 1, b = 3, c = 4 } }
    for k, v in pairs(fields) do c[k] = v end
    return c
end
-- Computes a hostile character, asserting it neither throws nor produces a
-- non-finite derived number. Returns the sheet for further assertions.
local function Computes(label, fields)
    local ok, result = pcall(ns.CharacterSheet.Compute, Hostile(fields), system, {})
    assert(ok, label .. " must not throw: " .. tostring(result))
    assert(type(result) == "table", label .. " must still return a sheet")
    local der = result.derived
    assert(Finite(der.ac) and Finite(der.initiative) and Finite(der.movement)
        and Finite(der.actions), label .. " left a non-finite derived stat")
    assert(Finite(der.hp.max) and Finite(der.mana.max) and Finite(der.mana.base),
        label .. " left a non-finite resource maximum")
    for _, a in ipairs(result.attributes) do
        assert(Finite(a.final) and Finite(a.modifier), label .. " left a non-finite attribute")
    end
    for _, s in ipairs(result.skills) do assert(Finite(s.total), label .. " left a non-finite skill") end
    for _, s in ipairs(result.saves) do assert(Finite(s.total), label .. " left a non-finite save") end
    return result
end

-- List fields that are not lists: ipairs would throw on every one of them.
Computes("a scalar origin_traits", { origin_traits = 5 })
Computes("scalar accomplishment lists", {
    accomplished_skills = 5, accomplished_saves = "s1", accomplished_weapons = true,
})
Computes("a scalar custom list", { custom_feats = 7, custom_spells = "none" })

-- Attribute scores that are not numbers: everything on the sheet is built on
-- this arithmetic.
Computes("non-numeric attributes", { attributes = { a = {}, b = "many", c = 1 / 0 } })
Computes("a scalar attributes block", { attributes = 5 })

-- Homebrew records that are not tables, whose effects are not a list, and whose
-- effect values are not numbers.
local junkHb = Computes("junk homebrew", { custom_feats = {
    5, "feat", true,
    { name = "No effects", effects = 9 },
    { name = "Junk effects", effects = { 5, "e", { type = "max_hp", value = {} },
        { type = "max_hp", value = "lots" }, { type = "max_hp", value = 0 / 0 } } },
} })
assert(junkHb.derived.hp.max == 0, "unusable effect values must contribute nothing")

-- An absurd homebrew value is clamped like an item's (+/- 99), so wire homebrew
-- cannot poison a total the way an item bonus cannot.
local huge = Computes("an absurd homebrew value", { custom_feats = {
    { name = "Greedy", effects = { { type = "max_hp", value = 1e12 },
        { type = "ac", value = -1e308 } } },
} })
assert(huge.derived.hp.max == 99, "an absurd effect value must clamp to 99, got " .. huge.derived.hp.max)
assert(huge.derived.ac == 12 + 1 - 99, "an absurd negative value must clamp to -99, got "
    .. huge.derived.ac)                             -- 12 base + best candidate b's mod 1 - 99

-- Stored maxima that are not numbers.
local maxima = Computes("non-numeric maxima", { max_hp = {}, max_mana = "plenty",
    current_hp = {}, temp_hp = 0 / 0, current_mana = "x" })
assert(maxima.derived.hp.max == 0 and maxima.derived.hp.current == nil)
assert(maxima.derived.mana.base == 6, "an unusable max_mana falls to the formula (3 x c's mod 2)")

-- Level: attacker-influenced, and per_level effects multiply by it. Both the
-- level and the product stay finite (level is bounded to MAX_LEVEL = 1000).
local scaled = Computes("an enormous level", { level = 1e308, custom_feats = {
    { name = "Per level", effects = { { type = "max_hp", value = 5, per_level = true } } },
} })
assert(scaled.derived.hp.max == 5000, "per_level must scale by a bounded level, got "
    .. scaled.derived.hp.max)
assert(scaled.level == 1000, "the sheet's level is bounded too, got " .. tostring(scaled.level))
Computes("a non-numeric level", { level = {}, custom_feats = {
    { name = "Per level", effects = { { type = "max_hp", value = 5, per_level = true } } },
} })
Computes("a negative level", { level = -1e12 })

-- An equipped item with effects but no name: `name` is optional in the schema,
-- and it is what an attribute effect's provenance line concatenates.
local nameless = Computes("a nameless equipped item", { inventory = { {
    item_id = "x", equipped = true,
    resolved = { kind = "equipment", effects = { { type = "attribute", id = "a", value = 1 } } },
} } })
local nBy = {}
for _, a in ipairs(nameless.attributes) do nBy[a.id] = a end
assert(nBy.a.bonus == 1, "a nameless item's effect must still fold")
assert(type(nBy.a.sources[1]) == "string", "the provenance line needs a name to concatenate")

-- An out-of-list pick is ignored in favour of the best candidate.
local char3 = { name = "O", level = 1, attributes = { a = 1, b = 3, c = 4 },
    primary_attribute = "b", ac_attribute = "c", init_attribute = "a" }
local sheet3 = ns.CharacterSheet.Compute(char3, system)
assert(sheet3.derived.ac_attribute == "b", "out-of-list AC pick must fall to the best candidate")
assert(sheet3.derived.init_attribute == "c", "out-of-list init pick must fall to the best candidate")
