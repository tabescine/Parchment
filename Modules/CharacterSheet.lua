-- Parchment - Character Sheet (logic)
--
-- Resolves a raw character (base attributes + trait/perk selections) against a
-- system definition into a fully computed sheet: final attributes with their
-- bonus sources, modifiers, derived stats, skills and saving throws with
-- totals, weapons, traits and perks. Pure data in, pure data out - the UI layer
-- renders whatever this returns, so the same compute path can be unit-tested
-- without a running client.
--
-- Parchment's computation model. Imported systems supply the data (attributes,
-- modifier_table, skills, perks, traits) and, via the optional `derived_stats`
-- block, declare which attributes drive the derived stats. The fixed formulas:
--   final attribute   = base + fixed trait bonuses (+/-)
--   modifier          = system modifier_table[final]
--   skill / save total= attribute modifier + (accomplished and accomplishment)
--   AC                = ac_base + AC-attribute modifier + trait AC bonuses
--                       (AC/init attribute: the character's pick, constrained
--                       to derived_stats.ac_attributes/init_attributes when
--                       declared; no/invalid pick = best candidate)
--   hit die           = band for the hit_die_attribute's modifier
--   mana (max)        = mana_multiplier x spell-source modifier
--   movement          = movement_base + per_step per positive movement modifier
--   save DC (primary) = save_dc_base + primary modifier + accomplishment bonus
--                       (casters only; non-casters carry no save DC)
--   spell attack      = primary modifier + accomplishment (casters; per-school
--                       rows fold school-targeted effects)
-- Which attribute fills each role is configured per system (see ns.DerivedConfig);
-- an unset role contributes 0, so no specific attribute id is ever assumed.
--
-- Homebrew per-character perks (custom_perks, written in game by the perk
-- wizard) carry the same machine-readable effects as traits, but they are
-- level-gated: a perk folds into these totals only once the character has
-- reached the level it is gained at (see .PerkActive). A perk written ahead of
-- time stays on the sheet as pending and contributes nothing until then.
-- Conditional racial effects are never folded - they are surfaced for the
-- player to apply.
--
-- Reads from: ns.GetModifier, ns.GetHitDie, ns.GetAccomplishmentBonus, system.
-- Exposes on ns.CharacterSheet: .Compute, .PerkActive (the one active/pending
--   test for homebrew perks, shared with PerkTree.Points and the UIs),
--   .EFFECT_TYPES and .EffectType (the effect vocabulary, which the perk wizard
--   generates its pickers, labels and validation from - see the table for the
--   per-entry fields).

local ADDON, ns = ...

ns.CharacterSheet = ns.CharacterSheet or {}
local CharacterSheet = ns.CharacterSheet

-- Returns a list of the trait records a character has selected (racial first,
-- then origins), skipping any that do not resolve in the system.
local function SelectedTraits(char, system)
    local out = {}
    if char.racial_trait then
        local t = ns.FindById(system.racial_traits, char.racial_trait)
        if t then out[#out + 1] = t end
    end
    for _, id in ipairs(char.origin_traits or {}) do
        local t = ns.FindById(system.origin_traits, id)
        if t then out[#out + 1] = t end
    end
    return out
end

-- Creates an empty effect accumulator.
local function NewAccumulator()
    return {
        attr = {}, attrSources = {}, allAttr = 0,
        ac = 0, attack = 0, initiative = 0, movement = 0, actions = 0,
        saveDC = 0, saveDCSchool = {}, spellAttack = 0, spellAttackSchool = {},
        maxHP = 0, maxMana = 0,
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

-- Effect vocabulary, shared by trait bonuses/penalties and custom-perk effects.
-- Each effect is a record { type = <id>, value = N, ... }; this table is the one
-- place that says what a type means, so the perk wizard's pickers, labels and
-- validation are generated from it instead of a hand-kept copy.
--
-- Per entry:
--   id          the effect `type` string stored in the data
--   label       display name (wizard pickers, review summary)
--   target      what the effect points at: "none", "attribute", "skill", or
--               "school" (school is OPTIONAL - no school means every school)
--   target_key  the effect field holding that target (absent for "none")
--   add_modifier  true when the type also accepts add_modifier = <attribute id>,
--               which adds a copy of that attribute's modifier to the skill/save
--               ("twice your X modifier on skill Y")
--   apply(acc, e, v, source)  folds the effect into the accumulator; v is the
--               effect's numeric value and source the trait/perk name
--
-- Any type outside this table (attribute_points, damage_reduction, ...) is
-- informational: it is surfaced to the player but never folded into totals.
local EFFECT_TYPES = {
    { id = "attribute", label = "Attribute", target = "attribute", target_key = "id",
      apply = function(acc, e, v, source)
          acc.attr[e.id] = (acc.attr[e.id] or 0) + v
          acc.attrSources[e.id] = acc.attrSources[e.id] or {}
          table.insert(acc.attrSources[e.id], (v >= 0 and "+" or "") .. v .. " " .. source)
      end },
    { id = "all_attributes", label = "All attributes", target = "none",
      apply = function(acc, _, v) acc.allAttr = acc.allAttr + v end },
    { id = "ac", label = "Armor Class", target = "none",
      apply = function(acc, _, v) acc.ac = acc.ac + v end },
    { id = "attack_rolls", label = "Attack rolls", target = "none",
      apply = function(acc, _, v) acc.attack = acc.attack + v end },
    { id = "initiative", label = "Initiative", target = "none",
      apply = function(acc, _, v) acc.initiative = acc.initiative + v end },
    { id = "movement", label = "Movement", target = "none",
      apply = function(acc, _, v) acc.movement = acc.movement + v end },
    { id = "actions", label = "Actions", target = "none",
      apply = function(acc, _, v) acc.actions = acc.actions + v end },
    { id = "save_dc", label = "Save DC", target = "school", target_key = "school",
      apply = function(acc, e, v)
          if e.school then
              acc.saveDCSchool[e.school] = (acc.saveDCSchool[e.school] or 0) + v
          else
              acc.saveDC = acc.saveDC + v
          end
      end },
    { id = "spell_attack", label = "Spell attack", target = "school", target_key = "school",
      apply = function(acc, e, v)
          if e.school then
              acc.spellAttackSchool[e.school] = (acc.spellAttackSchool[e.school] or 0) + v
          else
              acc.spellAttack = acc.spellAttack + v
          end
      end },
    { id = "max_hp", label = "Maximum HP", target = "none",
      apply = function(acc, _, v) acc.maxHP = acc.maxHP + v end },
    { id = "max_mana", label = "Maximum Mana", target = "none",
      apply = function(acc, _, v) acc.maxMana = acc.maxMana + v end },
    { id = "all_skills", label = "All skills", target = "none",
      apply = function(acc, _, v) acc.allSkill = acc.allSkill + v end },
    { id = "skill", label = "Skill", target = "skill", target_key = "skill", add_modifier = true,
      apply = function(acc, e, v, source)
          -- Authored data uses either `skill` or the generic `id` for the target.
          local id = e.skill or e.id
          if not id then return end
          if v ~= 0 then acc.skill[id] = (acc.skill[id] or 0) + v end
          if e.add_modifier then
              acc.skillAddMod[id] = acc.skillAddMod[id] or {}
              table.insert(acc.skillAddMod[id], e.add_modifier)
          end
          acc.skillSources[id] = acc.skillSources[id] or {}
          AddUnique(acc.skillSources[id], source)
      end },
    { id = "save", label = "Saving throw", target = "attribute", target_key = "id", add_modifier = true,
      apply = function(acc, e, v, source)
          if not e.id then return end
          if v ~= 0 then acc.save[e.id] = (acc.save[e.id] or 0) + v end
          if e.add_modifier then
              acc.saveAddMod[e.id] = acc.saveAddMod[e.id] or {}
              table.insert(acc.saveAddMod[e.id], e.add_modifier)
          end
          acc.saveSources[e.id] = acc.saveSources[e.id] or {}
          AddUnique(acc.saveSources[e.id], source)
      end },
}
CharacterSheet.EFFECT_TYPES = EFFECT_TYPES

-- id -> entry, for dispatch and for the wizard's lookups.
local EFFECT_BY_ID = {}
for _, spec in ipairs(EFFECT_TYPES) do EFFECT_BY_ID[spec.id] = spec end

-- Returns the vocabulary entry for an effect type id, or nil when the type is
-- informational (outside the vocabulary).
function CharacterSheet.EffectType(id)
    return EFFECT_BY_ID[id]
end

-- True when a homebrew perk has already been gained: its level (absent or
-- non-numeric means 1, so an unlevelled perk is always active) is at or below
-- the character's. The single place the active/pending line is drawn - Compute,
-- PerkTree.Points and the UIs all ask here.
function CharacterSheet.PerkActive(char, perk)
    local gainedAt = tonumber(type(perk) == "table" and perk.level) or 1
    return gainedAt <= ((type(char) == "table" and char.level) or 1)
end

-- Folds a single effect entry into the accumulator. source is the trait/perk
-- name, recorded for attribute bonus provenance.
local function ApplyEffect(acc, e, source)
    local spec = EFFECT_BY_ID[e.type]
    if not spec then return end
    spec.apply(acc, e, e.value or 0, source)
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

-- Counts occurrences of id in a list.
local function CountIn(list, id)
    local c = 0
    for _, v in ipairs(list or {}) do
        if v == id then c = c + 1 end
    end
    return c
end

-- Resolves a record id to its display name within a system list (skills/weapons).
local function NameInList(list, id)
    local rec = ns.FindById(list, id)
    return rec and rec.name or id
end

-- Computes the full sheet for a character against a system definition.
--
-- Returns a single table (see the field comments inline). Returns nil when
-- either argument is missing.
function CharacterSheet.Compute(char, system)
    if type(char) ~= "table" or type(system) ~= "table" then return nil end

    local traits = SelectedTraits(char, system)
    local level = char.level or 1
    local accomplishment = ns.GetAccomplishmentBonus(level)

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

    -- Perk-driven choices: build
    -- the extra effects/accomplishments they grant and tag the chosen values onto
    -- the display entry for that perk.
    local choiceEffects, extraSkills, extraWeapons = {}, {}, {}
    for pid, chosen in pairs(char.perk_choices or {}) do
        local perk = FindPerkInSystem(system, pid)
        local choice = perk and perk.choice
        if choice and CountIn(char.perks, pid) > 0 then
            local names = {}
            for _, cid in ipairs(chosen) do
                if choice.kind == "skill" then
                    names[#names + 1] = NameInList(system.skills, cid)
                    if choice.apply == "accomplished" then
                        extraSkills[cid] = true
                    elseif choice.apply == "double_accomplishment" then
                        choiceEffects[#choiceEffects + 1] =
                            { { type = "skill", skill = cid, value = accomplishment }, perk.name }
                    else
                        local n = tonumber(tostring(choice.apply):match("skill_bonus:(%d+)"))
                        if n then
                            choiceEffects[#choiceEffects + 1] =
                                { { type = "skill", skill = cid, value = n }, perk.name }
                        end
                    end
                elseif choice.kind == "weapon" then
                    names[#names + 1] = NameInList(system.weapons, cid)
                    if choice.apply == "accomplished" then extraWeapons[cid] = true end
                else
                    names[#names + 1] = cid
                end
            end
            if spherePerkSeen[pid] then spherePerkSeen[pid].choices = names end
        end
    end

    -- Homebrew perks: a display entry each (in authored order), but only the
    -- ones already gained at this level contribute effects - the rest are
    -- flagged pending, so a whole ability path can be written up front.
    local customPerks, activeCustom = {}, {}
    for _, p in ipairs(char.custom_perks or {}) do
        local entry = { name = p.name, description = p.description, level = p.level }
        if CharacterSheet.PerkActive(char, p) then
            activeCustom[#activeCustom + 1] = p
        else
            entry.pending = true
        end
        customPerks[#customPerks + 1] = entry
    end

    -- Effects come from traits, gained homebrew perks, selected sphere perks
    -- that carry machine-readable effects, and the choice-derived effects above.
    local effectPerks = {}
    for _, p in ipairs(activeCustom) do effectPerks[#effectPerks + 1] = p end
    for _, p in ipairs(takenForEffects) do effectPerks[#effectPerks + 1] = p end
    local fx = AccumulateEffects(traits, effectPerks)
    for _, ce in ipairs(choiceEffects) do ApplyEffect(fx, ce[1], ce[2]) end

    -- Attributes: base + trait bonus + global all-attribute adjustment.
    local modifier = {}
    local attributes = {}
    for _, attr in ipairs(system.attributes or {}) do
        local base = (char.attributes or {})[attr.id] or 0
        local bonus = (fx.attr[attr.id] or 0) + fx.allAttr
        local value = base + bonus
        modifier[attr.id] = ns.GetModifier(value)
        attributes[#attributes + 1] = {
            id = attr.id, name = attr.name,
            base = base, bonus = bonus, final = value, modifier = modifier[attr.id],
            sources = fx.attrSources[attr.id] or {},
        }
    end

    -- Skills grouped under their governing attribute.
    local accomplishedSkills = ListToSet(char.accomplished_skills)
    for id in pairs(extraSkills) do accomplishedSkills[id] = true end
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

    -- Weapon proficiencies (display + accomplished flag). When a weapon names
    -- its governing attribute (weapon.attribute, like skills), an attack-roll
    -- total is computed: attribute modifier + accomplishment (every listed
    -- weapon is accomplished) + global attack-roll effects.
    local accomplishedWeapons = ListToSet(char.accomplished_weapons)
    for id in pairs(extraWeapons) do accomplishedWeapons[id] = true end
    local weapons = {}
    for _, weapon in ipairs(system.weapons or {}) do
        if accomplishedWeapons[weapon.id] then
            local entry = {
                id = weapon.id, name = weapon.name, damage = weapon.damage,
                versatile = weapon.versatile, properties = weapon.properties or {},
            }
            if weapon.attribute then
                -- attribute may be a list (finesse-style "use either"): the
                -- best modifier wins and is reported as the governing one.
                local attrs = type(weapon.attribute) == "table" and weapon.attribute or { weapon.attribute }
                local bestId, bestMod
                for _, id in ipairs(attrs) do
                    local m = modifier[id]
                    if m and (not bestMod or m > bestMod) then bestId, bestMod = id, m end
                end
                if bestId then
                    entry.attack_attribute = bestId
                    entry.attack_total = bestMod + accomplishment + fx.attack
                end
            end
            weapons[#weapons + 1] = entry
        end
    end

    -- Derived stats. Which attributes drive hit die, mana, movement etc. comes
    -- from the system's derived_stats config; an unset coupling contributes 0,
    -- so nothing assumes a particular attribute exists.
    local cfg = ns.DerivedConfig()
    local primary = char.primary_attribute

    -- Mana source: the primary attribute if it is one of the system's spell
    -- attributes, otherwise the configured fallback attribute (else none).
    local isCaster = false
    for _, id in ipairs(cfg.spell_attributes) do if id == primary then isCaster = true end end
    local spellMod = isCaster and (modifier[primary] or 0)
        or (cfg.mana_attribute and (modifier[cfg.mana_attribute] or 0)) or 0

    -- AC / initiative attributes. A system may constrain them to candidate
    -- lists (derived_stats.ac_attributes / init_attributes, e.g. "Agility,
    -- Sense or Luck"): an explicit character pick is honored when it is one
    -- of the candidates, anything else (including no pick at all) falls to
    -- the best candidate modifier - a fresh character is correct without
    -- choosing. Without a list, the character's pick alone rules.
    local function EffectiveAttr(pick, candidates)
        if not candidates or #candidates == 0 then return pick end
        local bestId, bestMod
        for _, id in ipairs(candidates) do
            if id == pick then return pick end
            local m = modifier[id]
            if m and (not bestMod or m > bestMod) then bestId, bestMod = id, m end
        end
        return bestId
    end
    local acAttr = EffectiveAttr(char.ac_attribute, cfg.ac_attributes)
    local initAttr = EffectiveAttr(char.init_attribute, cfg.init_attributes)
    local acMod = modifier[acAttr] or 0
    local initMod = modifier[initAttr] or 0
    local moveMod = cfg.movement_attribute and (modifier[cfg.movement_attribute] or 0) or 0
    local hitDieMod = cfg.hit_die_attribute and (modifier[cfg.hit_die_attribute] or 0) or 0

    -- Stored max mana wins when set; otherwise the system's mana formula. This is
    -- the fx-free base (trait/perk effects are added as `mana.max` in derived).
    local manaBase = char.max_mana or math.max(0, cfg.mana_multiplier * spellMod)

    local derived = {
        accomplishment = accomplishment,
        primary_attribute = primary,
        hit_dice = level .. ns.GetHitDie(hitDieMod),
        hp = { current = char.current_hp, max = (char.max_hp or 0) + fx.maxHP, temp = char.temp_hp },
        -- `base` is the stored (fx-free) maximum; `max` adds the live trait/perk
        -- effect on top. Creation persists `base`, never `max`, so an effect is
        -- not baked into the stored value and then re-added on every Compute.
        mana = {
            current = char.current_mana,
            base = manaBase,
            max = manaBase + fx.maxMana,
        },
        ac = cfg.ac_base + acMod + fx.ac,
        ac_attribute = acAttr,       -- the EFFECTIVE attribute (pick or best candidate)
        initiative = initMod + fx.initiative,
        init_attribute = initAttr,   -- ditto
        movement = cfg.movement_base + math.max(0, moveMod) * cfg.movement_per_step + fx.movement,
        actions = cfg.actions_base + fx.actions,
        -- The save DC is a spellcasting number: non-casters carry none (the
        -- sheet hides the row), so a martial's primary cannot fake one.
        save_dc = isCaster and (cfg.save_dc_base + (modifier[primary] or 0) + accomplishment + fx.saveDC) or nil,
        attack_modifier = fx.attack,
    }
    -- Level-granted extra actions (and any other level_bonuses.actions).
    for lvl, bonus in pairs(system.level_bonuses or {}) do
        if lvl <= level and bonus.actions then derived.actions = derived.actions + bonus.actions end
    end

    -- Spellcasting (casters only): spell attack = primary modifier +
    -- accomplishment + spell_attack effects. When the system declares
    -- spell_schools (records or plain strings), one row per school folds in
    -- the school-targeted spell_attack / save_dc effects.
    if isCaster then
        local spell = {
            attack = (modifier[primary] or 0) + accomplishment + fx.spellAttack,
            dc = derived.save_dc,
            schools = {},
        }
        for _, s in ipairs(system.spell_schools or {}) do
            local id = type(s) == "table" and s.id or s
            local name = (type(s) == "table" and s.name) or tostring(s)
            if id then
                spell.schools[#spell.schools + 1] = {
                    id = id, name = name,
                    attack = spell.attack + (fx.spellAttackSchool[id] or 0),
                    dc = spell.dc + (fx.saveDCSchool[id] or 0),
                }
            end
        end
        derived.spell = spell
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
        custom_perks = customPerks,   -- display entries, pending ones flagged
    }
end
