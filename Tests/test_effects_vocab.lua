-- The effect vocabulary (CharacterSheet.EFFECT_TYPES) behind homebrew perks
-- and trait bonuses.
--
-- Every vocabulary entry is driven end to end: a homebrew perk carrying that
-- one effect must move the computed sheet exactly where the entry claims it
-- points. The expectation table is keyed by effect id and checked for
-- completeness, so a new effect type without a test fails this file.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
local ns = T.load({}, "Core.lua")
T.load(ns, "Modules/CharacterSheet.lua")
local CS = ns.CharacterSheet

ParchmentSystemDB = {
    system_name = "Mini",
    attributes = { { id = "a", name = "Alpha" }, { id = "b", name = "Bravo" } },
    modifier_table = { -1, 0, 1, 2 },
    accomplishment_table = { 2 },
    hit_dice_bands = { { max_mod = 9, die = "d8" } },
    derived_stats = {
        hit_die_attribute = "a",
        spell_attributes = { "b" }, mana_attribute = "b", mana_multiplier = 2,
        movement_attribute = "a", movement_base = 10, movement_per_step = 1,
        ac_base = 10, save_dc_base = 10, actions_base = 2,
    },
    skills = { { id = "s1", name = "Skill One", attribute = "a" },
               { id = "s2", name = "Skill Two", attribute = "b" } },
    weapons = { { id = "w1", name = "Club", attribute = "a", damage = "1d6" } },
    spell_schools = { { id = "ev", name = "Evocation" }, { id = "wd", name = "Warding" } },
}
local system = ParchmentSystemDB

-- Base character: primary "b" is a spell attribute, so the spell block exists.
local function BaseChar()
    return {
        name = "Vocab", level = 1,
        attributes = { a = 3, b = 4 },          -- a mod +1, b mod +2
        primary_attribute = "b",
        accomplished_skills = { "s1" }, accomplished_weapons = { "w1" },
        max_hp = 10,
        perks = {}, custom_perks = {},
    }
end

-- The sheet for a character carrying one wizard-shaped homebrew perk.
local function SheetWith(effect)
    local char = BaseChar()
    char.custom_perks = { { id = "hb-1", name = "Draft", level = 1,
        description = "From the wizard.", effects = { effect } } }
    return ns.CharacterSheet.Compute(char, system)
end

local base = ns.CharacterSheet.Compute(BaseChar(), system)

-- Field pickers used by the expectations below.
local function skill(sheet, id)
    for _, s in ipairs(sheet.skills) do if s.id == id then return s.total end end
end
local function save(sheet, id)
    for _, s in ipairs(sheet.saves) do if s.id == id then return s.total end end
end
local function attr(sheet, id)
    for _, a in ipairs(sheet.attributes) do if a.id == id then return a.final end end
end
local function school(sheet, id)
    for _, s in ipairs(sheet.derived.spell.schools) do if s.id == id then return s end end
end

-- One check per vocabulary entry: the effect a wizard would write, and what it
-- must do to the computed sheet.
local EXPECT = {
    attribute = function()
        local s = SheetWith({ type = "attribute", id = "a", value = 2 })
        assert(attr(s, "a") == attr(base, "a") + 2, "attribute effect missed its target")
        assert(attr(s, "b") == attr(base, "b"), "attribute effect leaked onto another attribute")
    end,
    all_attributes = function()
        local s = SheetWith({ type = "all_attributes", value = 1 })
        assert(attr(s, "a") == attr(base, "a") + 1 and attr(s, "b") == attr(base, "b") + 1)
    end,
    ac = function()
        assert(SheetWith({ type = "ac", value = 3 }).derived.ac == base.derived.ac + 3)
    end,
    attack_rolls = function()
        local s = SheetWith({ type = "attack_rolls", value = 2 })
        assert(s.derived.attack_modifier == base.derived.attack_modifier + 2)
        assert(s.weapons[1].attack_total == base.weapons[1].attack_total + 2,
            "attack_rolls must reach the weapon rows")
    end,
    initiative = function()
        assert(SheetWith({ type = "initiative", value = 2 }).derived.initiative
            == base.derived.initiative + 2)
    end,
    movement = function()
        assert(SheetWith({ type = "movement", value = 2 }).derived.movement
            == base.derived.movement + 2)
    end,
    actions = function()
        assert(SheetWith({ type = "actions", value = 1 }).derived.actions == base.derived.actions + 1)
    end,
    save_dc = function()
        local s = SheetWith({ type = "save_dc", value = 2 })
        assert(s.derived.save_dc == base.derived.save_dc + 2, "untargeted save_dc must raise the DC")
        -- School-targeted: only that school's row moves.
        local t = SheetWith({ type = "save_dc", school = "ev", value = 1 })
        assert(t.derived.save_dc == base.derived.save_dc, "school save_dc must not raise the global DC")
        assert(school(t, "ev").dc == school(base, "ev").dc + 1)
        assert(school(t, "wd").dc == school(base, "wd").dc, "school save_dc leaked to another school")
    end,
    spell_attack = function()
        local s = SheetWith({ type = "spell_attack", value = 2 })
        assert(s.derived.spell.attack == base.derived.spell.attack + 2)
        local t = SheetWith({ type = "spell_attack", school = "wd", value = 3 })
        assert(t.derived.spell.attack == base.derived.spell.attack)
        assert(school(t, "wd").attack == school(base, "wd").attack + 3)
        assert(school(t, "ev").attack == school(base, "ev").attack)
    end,
    max_hp = function()
        assert(SheetWith({ type = "max_hp", value = 4 }).derived.hp.max == base.derived.hp.max + 4)
    end,
    max_mana = function()
        local s = SheetWith({ type = "max_mana", value = 5 })
        assert(s.derived.mana.max == base.derived.mana.max + 5)
        assert(s.derived.mana.base == base.derived.mana.base, "max_mana must not move the stored base")
    end,
    all_skills = function()
        local s = SheetWith({ type = "all_skills", value = 1 })
        assert(skill(s, "s1") == skill(base, "s1") + 1 and skill(s, "s2") == skill(base, "s2") + 1)
    end,
    accomplish_skill = function()
        -- Grants accomplishment (the level table's bonus, here 2), not a flat
        -- value; s2 is the base character's unaccomplished skill.
        local s = SheetWith({ type = "accomplish_skill", skill = "s2" })
        assert(skill(s, "s2") == skill(base, "s2") + 2, "accomplish_skill must add the accomplishment bonus")
        assert(skill(s, "s1") == skill(base, "s1"), "accomplish_skill leaked onto another skill")
        -- s1 is already accomplished by hand: the grant must not stack.
        local twice = SheetWith({ type = "accomplish_skill", skill = "s1" })
        assert(skill(twice, "s1") == skill(base, "s1"),
            "accomplishment must not stack with an existing accomplished pick")
    end,
    skill = function()
        local s = SheetWith({ type = "skill", skill = "s1", value = 2 })
        assert(skill(s, "s1") == skill(base, "s1") + 2, "skill effect missed its target")
        assert(skill(s, "s2") == skill(base, "s2"), "skill effect leaked onto another skill")
        -- add_modifier adds a copy of an attribute's modifier (b: +2).
        local t = SheetWith({ type = "skill", skill = "s1", add_modifier = "b" })
        assert(skill(t, "s1") == skill(base, "s1") + 2, "skill add_modifier not applied")
    end,
    save = function()
        local s = SheetWith({ type = "save", id = "a", value = 2 })
        assert(save(s, "a") == save(base, "a") + 2, "save effect missed its target")
        assert(save(s, "b") == save(base, "b"), "save effect leaked onto another save")
        local t = SheetWith({ type = "save", id = "a", add_modifier = "b" })
        assert(save(t, "a") == save(base, "a") + 2, "save add_modifier not applied")
    end,
}

-- Vocabulary shape: unique ids, a label, a known target kind, an apply function,
-- and a target_key exactly when the entry takes a target.
local TARGETS = { none = true, attribute = true, skill = true, school = true }
local seen = {}
for _, spec in ipairs(CS.EFFECT_TYPES) do
    assert(type(spec.id) == "string" and not seen[spec.id], "duplicate/invalid effect id")
    seen[spec.id] = true
    assert(type(spec.label) == "string" and spec.label ~= "", spec.id .. ": missing label")
    assert(TARGETS[spec.target], spec.id .. ": unknown target kind " .. tostring(spec.target))
    assert(type(spec.apply) == "function", spec.id .. ": missing apply")
    if spec.target == "none" then
        assert(spec.target_key == nil, spec.id .. ": targetless entry must not name a target key")
    else
        assert(type(spec.target_key) == "string", spec.id .. ": missing target_key")
    end
    assert(CS.EffectType(spec.id) == spec, spec.id .. ": not reachable via EffectType")
    assert(EXPECT[spec.id], "no round-trip test for effect type '" .. spec.id .. "'")
end
assert(CS.EffectType("made_up_informational") == nil, "unknown types must not resolve")
for id in pairs(EXPECT) do assert(seen[id], "test for a type the vocabulary no longer has: " .. id) end

-- Run every round-trip.
for _, spec in ipairs(CS.EFFECT_TYPES) do EXPECT[spec.id]() end

-- An informational (out-of-vocabulary) effect changes nothing at all.
T.assert_deepeq(SheetWith({ type = "made_up_informational", value = 9 }).derived,
    base.derived, "informational effect changed the sheet")

-- Level gating: a homebrew perk only folds into the totals once the character
-- has reached the level it is gained at. Until then it stays on the sheet,
-- flagged pending, and moves nothing.
local function GatedChar(perkLevel, charLevel)
    local c = BaseChar()
    c.level = charLevel or 1
    c.custom_perks = { { id = "hb-1", name = "Later", level = perkLevel,
        description = "Planned.", effects = { { type = "ac", value = 3 } } } }
    return c
end
local function GatedSheet(perkLevel, charLevel)
    return ns.CharacterSheet.Compute(GatedChar(perkLevel, charLevel), system)
end

local pending = GatedSheet(3, 1)
assert(pending.derived.ac == base.derived.ac, "a pending perk must not move the totals")
assert(#pending.custom_perks == 1, "a pending perk must still be listed")
local pendingEntry = pending.custom_perks[1]
assert(pendingEntry.pending == true, "a perk gained later must be flagged pending")
assert(pendingEntry.name == "Later" and pendingEntry.level == 3
    and pendingEntry.description == "Planned.",
    "the display entry must carry name/level/description")

local gained = GatedSheet(1, 1)
assert(gained.derived.ac == base.derived.ac + 3, "a gained perk must fold into the totals")
assert(gained.custom_perks[1].pending == nil, "a gained perk must not be flagged pending")

-- Absent or unparseable levels mean level 1 (active); a numeric string still gates.
assert(GatedSheet(nil, 1).derived.ac == base.derived.ac + 3, "no level must count as level 1")
assert(GatedSheet("garbage", 1).derived.ac == base.derived.ac + 3,
    "a non-numeric level must count as level 1")
assert(GatedSheet("3", 1).derived.ac == base.derived.ac, "a numeric string level must still gate")

-- Levelling up activates the perk, and nothing else about it changes.
local growing = GatedChar(3, 1)
local before = ns.CharacterSheet.Compute(growing, system)
growing.level = 3
local after = ns.CharacterSheet.Compute(growing, system)
assert(after.derived.ac == before.derived.ac + 3, "reaching the level must apply the effect")
assert(after.custom_perks[1].pending == nil and after.custom_perks[1].name == "Later",
    "reaching the level must clear pending without touching the entry")

-- The sheet's list is built, never the character's own table handed out.
assert(after.custom_perks ~= growing.custom_perks, "Compute must not expose the raw perk table")
assert(after.custom_perks[1] ~= growing.custom_perks[1], "display entries must be copies")

-- (The perk-commit seam these effects used to travel through died with the
-- perk wizard; homebrew perks are import-authored data now.)
