-- Parchment - Character Sheet (logic)
--
-- Resolves a raw character (base attributes + trait/perk selections) against a
-- system definition into a fully computed sheet: final attributes with their
-- bonus sources, modifiers, derived stats, skills and saving throws with
-- totals, weapons, traits and perks. Pure data in, pure data out - the UI layer
-- renders whatever this returns, so the same compute path can be unit-tested
-- without a running client.
--
-- Computation rules (from the the system ruleset, verified against the example sheet):
--   final attribute   = base + fixed trait bonuses (+/-)
--   modifier          = system modifier_table[final]
--   skill / save total= attribute modifier + (accomplished and accomplishment)
--   AC                = 10 + AC-attribute modifier + trait AC bonuses
--   mana (max)        = 2 x primary spell modifier (Int/Sen/Cha), else 2 x Vit
--   movement          = 12 + 0.5 per positive Agility modifier + trait bonuses
--   save DC (primary) = 10 + primary modifier + accomplishment bonus
--
-- Homebrew per-character perks (custom_perks) and conditional racial effects are
-- NOT folded into these totals - they are surfaced for the player to apply.
--
-- Reads from: ns.GetModifier, ns.GetHitDie, ns.GetAccomplishmentBonus, system.
-- Exposes on ns.CharacterSheet: .Compute

local ADDON, ns = ...

ns.CharacterSheet = ns.CharacterSheet or {}
local CharacterSheet = ns.CharacterSheet

-- Returns a list of the trait records a character has selected (racial first,
-- then origins), skipping any that do not resolve in the system.
local function SelectedTraits(char, system)
    local out = {}
    local function find(list, id)
        for _, t in ipairs(list or {}) do if t.id == id then return t end end
    end
    if char.racial_trait then
        local t = find(system.racial_traits, char.racial_trait)
        if t then out[#out + 1] = t end
    end
    for _, id in ipairs(char.origin_traits or {}) do
        local t = find(system.origin_traits, id)
        if t then out[#out + 1] = t end
    end
    return out
end

-- Effect vocabulary, shared by trait bonuses/penalties and custom-perk effects.
-- Each effect is { type = ..., value = N, ... }:
--   attribute(id)          all_attributes
--   skill(skill|id)        skill(skill|id, add_modifier = attrId)   all_skills
--   save(id)               save(id, add_modifier = attrId)
--   ac  attack_rolls  initiative  movement  actions  save_dc  max_hp  max_mana
-- add_modifier adds a copy of an attribute's modifier to that skill/save, which
-- is how "twice your X modifier on skill Y" is expressed. Any other type
-- (attribute_points, damage_reduction, ...) is informational and ignored here.

-- Creates an empty effect accumulator.
local function NewAccumulator()
    return {
        attr = {}, attrSources = {}, allAttr = 0,
        ac = 0, attack = 0, initiative = 0, movement = 0, actions = 0,
        saveDC = 0, maxHP = 0, maxMana = 0,
        skill = {}, allSkill = 0, skillAddMod = {}, skillSources = {},
        save = {}, saveAddMod = {}, saveSources = {},
    }
end

-- Appends value to list only if not already present (preserves order).
local function AddUnique(list, value)
    for _, existing in ipairs(list) do
        if existing == value then return end
    end
    list[#list + 1] = value
end

-- Folds a single effect entry into the accumulator. source is the trait/perk
-- name, recorded for attribute bonus provenance.
local function ApplyEffect(acc, e, source)
    local t = e.type
    local v = e.value or 0
    if t == "attribute" then
        acc.attr[e.id] = (acc.attr[e.id] or 0) + v
        acc.attrSources[e.id] = acc.attrSources[e.id] or {}
        table.insert(acc.attrSources[e.id], (v >= 0 and "+" or "") .. v .. " " .. source)
    elseif t == "all_attributes" then acc.allAttr = acc.allAttr + v
    elseif t == "ac" then acc.ac = acc.ac + v
    elseif t == "attack_rolls" then acc.attack = acc.attack + v
    elseif t == "initiative" then acc.initiative = acc.initiative + v
    elseif t == "movement" then acc.movement = acc.movement + v
    elseif t == "actions" then acc.actions = acc.actions + v
    elseif t == "save_dc" then acc.saveDC = acc.saveDC + v
    elseif t == "max_hp" then acc.maxHP = acc.maxHP + v
    elseif t == "max_mana" then acc.maxMana = acc.maxMana + v
    elseif t == "all_skills" then acc.allSkill = acc.allSkill + v
    elseif t == "skill" then
        local id = e.skill or e.id
        if id then
            if v ~= 0 then acc.skill[id] = (acc.skill[id] or 0) + v end
            if e.add_modifier then
                acc.skillAddMod[id] = acc.skillAddMod[id] or {}
                table.insert(acc.skillAddMod[id], e.add_modifier)
            end
            acc.skillSources[id] = acc.skillSources[id] or {}
            AddUnique(acc.skillSources[id], source)
        end
    elseif t == "save" then
        if e.id then
            if v ~= 0 then acc.save[e.id] = (acc.save[e.id] or 0) + v end
            if e.add_modifier then
                acc.saveAddMod[e.id] = acc.saveAddMod[e.id] or {}
                table.insert(acc.saveAddMod[e.id], e.add_modifier)
            end
            acc.saveSources[e.id] = acc.saveSources[e.id] or {}
            AddUnique(acc.saveSources[e.id], source)
        end
    end
end

-- Accumulates every effect from the selected traits and the character's custom
-- perks into one structure the rest of compute reads from.
local function AccumulateEffects(traits, perks)
    local acc = NewAccumulator()
    for _, trait in ipairs(traits) do
        for _, b in ipairs(trait.bonuses or {}) do ApplyEffect(acc, b, trait.name) end
        for _, p in ipairs(trait.penalties or {}) do ApplyEffect(acc, p, trait.name) end
    end
    for _, perk in ipairs(perks or {}) do
        for _, e in ipairs(perk.effects or {}) do ApplyEffect(acc, e, perk.name) end
    end
    return acc
end

-- Sums the modifiers of each attribute id in a list (for add_modifier effects).
local function SumAddModifiers(list, modifier)
    local total = 0
    for _, attrId in ipairs(list or {}) do total = total + (modifier[attrId] or 0) end
    return total
end

-- Builds a set { id = true } from a list of ids.
local function ListToSet(list)
    local set = {}
    for _, id in ipairs(list or {}) do set[id] = true end
    return set
end

-- Finds a perk by id across the system's trees. Returns the perk record and
-- its sphere name, or nil.
local function FindPerkInSystem(system, id)
    for _, tree in ipairs(system.perk_trees or {}) do
        for _, perk in ipairs(tree.perks or {}) do
            if perk.id == id then return perk, tree.name end
        end
    end
end

-- Computes the full sheet for a character against a system definition.
--
-- Returns a single table (see the field comments inline). Returns nil when
-- either argument is missing.
function CharacterSheet.Compute(char, system)
    if type(char) ~= "table" or type(system) ~= "table" then return nil end

    local traits = SelectedTraits(char, system)

    -- Resolve selected standard-sphere perks: a display list (unique, with rank
    -- and sphere) and a flat per-occurrence list for effect folding.
    local spherePerks, spherePerkSeen, takenForEffects = {}, {}, {}
    for _, pid in ipairs(char.perks or {}) do
        local perk, sphereName = FindPerkInSystem(system, pid)
        if perk then
            takenForEffects[#takenForEffects + 1] = perk
            local entry = spherePerkSeen[pid]
            if not entry then
                entry = { name = perk.name, description = perk.description, sphere = sphereName, rank = 0 }
                spherePerkSeen[pid] = entry
                spherePerks[#spherePerks + 1] = entry
            end
            entry.rank = entry.rank + 1
        end
    end

    -- Effects come from traits, homebrew perks, and any selected sphere perks
    -- that carry machine-readable effects.
    local effectPerks = {}
    for _, p in ipairs(char.custom_perks or {}) do effectPerks[#effectPerks + 1] = p end
    for _, p in ipairs(takenForEffects) do effectPerks[#effectPerks + 1] = p end
    local fx = AccumulateEffects(traits, effectPerks)

    local level = char.level or 1
    local accomplishment = ns.GetAccomplishmentBonus(level)

    -- Attributes: base + trait bonus + global all-attribute adjustment.
    local final, modifier = {}, {}
    local attributes = {}
    for _, attr in ipairs(system.attributes or {}) do
        local base = (char.attributes or {})[attr.id] or 0
        local bonus = (fx.attr[attr.id] or 0) + fx.allAttr
        local value = base + bonus
        final[attr.id] = value
        modifier[attr.id] = ns.GetModifier(value)
        attributes[#attributes + 1] = {
            id = attr.id, name = attr.name,
            base = base, bonus = bonus, final = value, modifier = modifier[attr.id],
            sources = fx.attrSources[attr.id] or {},
        }
    end

    -- Skills grouped under their governing attribute.
    local accomplishedSkills = ListToSet(char.accomplished_skills)
    local skills = {}
    for _, skill in ipairs(system.skills or {}) do
        local mod = modifier[skill.attribute] or 0
        local isAccomplished = accomplishedSkills[skill.id] or false
        local perkAdd = (fx.skill[skill.id] or 0) + SumAddModifiers(fx.skillAddMod[skill.id], modifier)
        local total = mod + (isAccomplished and accomplishment or 0) + perkAdd + fx.allSkill
        skills[#skills + 1] = {
            id = skill.id, name = skill.name, attribute = skill.attribute,
            total = total, accomplished = isAccomplished,
            sources = fx.skillSources[skill.id],
        }
    end

    -- Saving throws: one per attribute.
    local accomplishedSaves = ListToSet(char.accomplished_saves)
    local saves = {}
    for _, attr in ipairs(system.attributes or {}) do
        local isAccomplished = accomplishedSaves[attr.id] or false
        local perkAdd = (fx.save[attr.id] or 0) + SumAddModifiers(fx.saveAddMod[attr.id], modifier)
        saves[#saves + 1] = {
            id = attr.id, name = attr.name,
            total = (modifier[attr.id] or 0) + (isAccomplished and accomplishment or 0) + perkAdd,
            accomplished = isAccomplished,
            sources = fx.saveSources[attr.id],
        }
    end

    -- Weapon proficiencies (display + accomplished flag).
    local accomplishedWeapons = ListToSet(char.accomplished_weapons)
    local weapons = {}
    for _, weapon in ipairs(system.weapons or {}) do
        if accomplishedWeapons[weapon.id] then
            weapons[#weapons + 1] = {
                id = weapon.id, name = weapon.name, damage = weapon.damage,
                versatile = weapon.versatile, properties = weapon.properties or {},
            }
        end
    end

    -- Derived stats.
    local primary = char.primary_attribute
    local spellMod = (primary == "int" or primary == "sen" or primary == "cha")
        and modifier[primary] or modifier["vit"] or 0
    local acMod = modifier[char.ac_attribute] or 0
    local agiMod = modifier["agi"] or 0
    local initMod = modifier[char.init_attribute or "agi"] or 0

    local derived = {
        accomplishment = accomplishment,
        primary_attribute = primary,
        hit_dice = level .. ns.GetHitDie(modifier["vit"] or 0),
        hp = { current = char.current_hp, max = (char.max_hp or 0) + fx.maxHP },
        mana = { current = char.current_mana, max = (char.max_mana or math.max(0, 2 * spellMod)) + fx.maxMana },
        ac = 10 + acMod + fx.ac,
        ac_attribute = char.ac_attribute,
        initiative = initMod + fx.initiative,
        init_attribute = char.init_attribute or "agi",
        movement = 12 + math.max(0, agiMod) * 0.5 + fx.movement,
        actions = 2 + fx.actions,
        save_dc = 10 + (modifier[primary] or 0) + accomplishment + fx.saveDC,
        attack_modifier = fx.attack,
    }
    -- Level-granted extra actions (and any other level_bonuses.actions).
    for lvl, bonus in pairs(system.level_bonuses or {}) do
        if lvl <= level and bonus.actions then derived.actions = derived.actions + bonus.actions end
    end

    return {
        name = char.name, player = char.player, race = char.race,
        level = level, quote = char.quote, notes = char.notes,
        attributes = attributes,
        skills = skills,
        saves = saves,
        weapons = weapons,
        derived = derived,
        traits = traits,
        sphere_perks = spherePerks,
        custom_perks = char.custom_perks or {},
        attack_lines = char.attack_lines or {},
    }
end
