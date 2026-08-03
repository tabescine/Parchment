-- Parchment - Character Sheet (logic)
--
-- Resolves a raw character (base attributes + trait/feat/spell selections)
-- against a system definition into a fully computed sheet: final attributes
-- with their bonus sources, modifiers, derived stats, skills and saving
-- throws with totals, weapons and traits. Pure data in, pure data out - the UI layer
-- renders whatever this returns, so the same compute path can be unit-tested
-- without a running client.
--
-- Parchment's computation model. Imported systems supply the data (attributes,
-- modifier_table, skills, traits) and, via the optional `derived_stats`
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
-- Homebrew feats and spells (custom_feats/custom_spells) carry the same
-- machine-readable effects as traits, but they are level-gated: a record
-- folds into these totals only once the character has reached the level it
-- is gained at (see .HomebrewActive). One written ahead of time renders as
-- pending and contributes nothing until then. Owned pack feat ranks and
-- known pack spells fold their effects too. Conditional racial effects are
-- never folded - they are surfaced for the player to apply.
--
-- Items are references, not copies: each char.inventory entry names a library
-- item, resolved on every Compute (ns.Items.Resolve), so an edit to the library
-- shows up everywhere at once. The library is passed IN, like the system, to
-- keep this file pure. A weapon item never touches the weapon rows - those are
-- proficiency rows, one per weapon skill, and stay the bare skill. Instead each
-- inventory weapon carries its OWN attack total (the linked weapon's
-- proficiency total + the item's bonus), so a character holding two blades
-- rolls the one actually swung. Equipment ac_bonus values sum into derived.ac
-- through their own `ac_equipment` term, kept separate so the AC tooltip can
-- name the equipment share. Equipment may also cap the AC attribute's
-- contribution while worn (ac_mod_cap - heavy armor is cap 0, medium cap 2/3,
-- absent means the full modifier applies); the lowest worn cap binds and is
-- surfaced as derived.ac_mod_cap.
--
-- Reads from: ns.GetModifier, ns.GetHitDie, ns.GetAccomplishmentBonus,
--   ns.Items.Resolve, system.
-- Exposes on ns.CharacterSheet: .Compute, .HomebrewActive (the one
--   active/pending test for homebrew records, shared with Picks.Spent and
--   the UIs),
--   .EFFECT_TYPES and .EffectType (the effect vocabulary - see the table
--   for the per-entry fields).

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
        accomplishSkill = {},
    }
end

-- Appends value to list only if not already present (preserves order).
local function AddUnique(list, value)
    for _, existing in ipairs(list) do
        if existing == value then return end
    end
    list[#list + 1] = value
end

-- Effect vocabulary, shared by trait bonuses/penalties, pack feat/spell
-- effects, and homebrew records.
-- Each effect is a record { type = <id>, value = N, ... }; this table is the
-- one place that says what a type means.
--
-- Per entry:
--   id          the effect `type` string stored in the data
--   label       display name (shown wherever effects are summarized)
--   target      what the effect points at: "none", "attribute", "skill", or
--               "school" (school is OPTIONAL - no school means every school)
--   target_key  the effect field holding that target (absent for "none")
--   add_modifier  true when the type also accepts add_modifier = <attribute id>,
--               which adds a copy of that attribute's modifier to the skill/save
--               ("twice your X modifier on skill Y")
--   apply(acc, e, v, source)  folds the effect into the accumulator; v is the
--               effect's numeric value and source the granting record's name
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
    -- Grants accomplishment in one skill outright ("You gain Accomplishment
    -- in Perception"), the way many rank-I feats read. The value is ignored:
    -- accomplishment is on/off, and its size comes from the level table.
    { id = "accomplish_skill", label = "Accomplished skill", target = "skill", target_key = "skill",
      apply = function(acc, e)
          local id = e.skill or e.id
          if id then acc.accomplishSkill[id] = true end
      end },
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

-- True when a homebrew record (custom feat or spell) has already been
-- gained: its level (absent or non-numeric means 1, so an unlevelled record
-- the character's. The single place the active/pending line is drawn - Compute,
-- Picks.Spent and the UIs all ask here.
function CharacterSheet.HomebrewActive(char, record)
    local gainedAt = tonumber(type(record) == "table" and record.level) or 1
    return gainedAt <= ((type(char) == "table" and char.level) or 1)
end

-- Folds a single effect entry into the accumulator. source is the record
-- name, recorded for attribute bonus provenance.
local function ApplyEffect(acc, e, source)
    local spec = EFFECT_BY_ID[e.type]
    if not spec then return end
    spec.apply(acc, e, e.value or 0, source)
end

-- Accumulates every effect from the selected traits and the gained
-- feat/spell records into one structure the rest of compute reads from.
local function AccumulateEffects(traits, records)
    local acc = NewAccumulator()
    for _, trait in ipairs(traits) do
        for _, b in ipairs(trait.bonuses or {}) do ApplyEffect(acc, b, trait.name) end
        for _, p in ipairs(trait.penalties or {}) do ApplyEffect(acc, p, trait.name) end
    end
    for _, rec in ipairs(records or {}) do
        for _, e in ipairs(rec.effects or {}) do ApplyEffect(acc, e, rec.name) end
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

-- Returns x when it is a table, else an empty table. Used for char.inventory
-- and its entries, which (unlike the rest of a character) can arrive straight
-- off the wire and may be any shape at all.
local function AsList(x)
    return type(x) == "table" and x or {}
end

-- The usable value of an item bonus: a finite number, or 0. Item data is
-- hand-editable and, as a wire snapshot, hostile - a NaN or infinity here would
-- poison every total it reaches.
local function BonusValue(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return 0 end
    return n
end

-- Coerces an item's ac_mod_cap into a usable cap: a whole number in [0, 99],
-- or nil when the field is absent or unusable. Reads the same hand-editable
-- and wire data as BonusValue, so garbage must coerce, never throw. A negative
-- cap reads as 0 - a cap limits the modifier's benefit, a penalty belongs in
-- ac_bonus.
local function CapValue(value)
    if value == nil then return nil end
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return math.max(0, math.min(99, math.floor(n)))
end

-- The bare attack total for one system weapon: the best of its governing
-- attribute(s) modifiers + accomplishment + global attack-roll effects. The one
-- place that number is computed, so a weapon proficiency row and the inventory
-- items linking that weapon cannot drift apart.
--
-- Returns the governing attribute id and the total, or nil when the weapon
-- names no attribute (or none the character has a modifier for) - such a weapon
-- carries no attack number at all.
local function WeaponAttack(weapon, modifier, accomplishment, attackFx)
    if not weapon.attribute then return nil end
    -- attribute may be a list (finesse-style "use either"): the best modifier
    -- wins and is reported as the governing one.
    local attrs = type(weapon.attribute) == "table" and weapon.attribute or { weapon.attribute }
    local bestId, bestMod
    for _, id in ipairs(attrs) do
        local m = modifier[id]
        if m and (not bestMod or m > bestMod) then bestId, bestMod = id, m end
    end
    if not bestId then return nil end
    return bestId, bestMod + accomplishment + attackFx
end

-- Resolves a character's inventory into display entries plus the AC total
-- equipped equipment contributes.
--
-- `weaponAttack` is weapon id -> bare proficiency attack total (see
-- WeaponAttack), which each weapon entry adds its own bonus to.
--
-- Returns two values:
--   inventory   - { weapons = {...}, equipment = {...}, gear = {...} }, display
--                 entries only (never library or character tables), each
--                 carrying its `index` into char.inventory so the UI can toggle
--                 and count without knowing how resolution worked
--   acEquipment - { total, sources } from equipped equipment, or nil when no
--                 equipped piece carries an ac_bonus
--   acCap       - { value, source } for the lowest ac_mod_cap among equipped
--                 equipment (the binding cap), or nil when nothing worn caps
--                 the AC attribute modifier
local function ResolveInventory(char, system, itemLib, weaponAttack)
    local inventory = { weapons = {}, equipment = {}, gear = {} }
    local acTotal, acSources = 0, {}
    local acCap

    for index, raw in ipairs(AsList(char.inventory)) do
        local state = AsList(raw)                  -- the per-character half
        local item, source = ns.Items.Resolve(raw, itemLib)
        local kind = item.kind
        local entry = {
            index = index, name = item.name, icon = item.icon,
            description = item.description, kind = kind,
            source = source, missing = (source == "missing") or nil,
        }

        if kind == "weapon" then
            entry.equipped = state.equipped and true or false
            entry.bonus = BonusValue(item.bonus)
            entry.weapon_id = item.weapon_id
            -- The linked weapon's display name, nil when the link dangles in
            -- this system: the item still shows, it just has nothing to boost.
            if item.weapon_id then
                local weapon = ns.FindById(system.weapons, item.weapon_id)
                entry.weapon_name = weapon and weapon.name or nil
            end
            -- This item's own attack total: the linked weapon's proficiency
            -- total plus this item's bonus. Every linked item gets one, stashed
            -- included - the UI decides that only a held weapon shows a number.
            local base = entry.weapon_id and weaponAttack[entry.weapon_id]
            if base then
                entry.attack_total = base + entry.bonus
                entry.attack_parts = { base = base, bonus = entry.bonus }
            end
            inventory.weapons[#inventory.weapons + 1] = entry
        elseif kind == "equipment" then
            entry.equipped = state.equipped and true or false
            entry.ac_bonus = BonusValue(item.ac_bonus)
            entry.ac_mod_cap = CapValue(item.ac_mod_cap)
            if entry.equipped and entry.ac_bonus ~= 0 then
                acTotal = acTotal + entry.ac_bonus
                acSources[#acSources + 1] = entry.name
            end
            -- The most restrictive worn cap binds; ties keep the first piece,
            -- so the tooltip names one garment, deterministically.
            if entry.equipped and entry.ac_mod_cap
                and (not acCap or entry.ac_mod_cap < acCap.value) then
                acCap = { value = entry.ac_mod_cap, source = entry.name }
            end
            inventory.equipment[#inventory.equipment + 1] = entry
        else
            -- Gear, and anything whose kind we cannot know: a missing item
            -- (nothing left to say what it was) or a wire snapshot from a newer
            -- Parchment. Both are shown as countable, never-equipped rows.
            entry.kind = "gear"
            entry.count = ns.Items.ClampCount(state.count)
                or ns.Items.ClampCount(item.default_count) or 1
            inventory.gear[#inventory.gear + 1] = entry
        end
    end

    local acEquipment = #acSources > 0 and { total = acTotal, sources = acSources } or nil
    return inventory, acEquipment, acCap
end

-- Computes the full sheet for a character against a system definition.
--
-- `itemLib` is the item library ({ [id] = item }) the character's inventory
-- resolves against - ns.GetItemLibrary() in the client, a fixture in tests.
-- It is a parameter rather than a lookup so this stays pure; omitting it
-- resolves every entry as missing, and a character without an inventory
-- computes exactly as it did before items existed.
--
-- Returns a single table (see the field comments inline). Returns nil when
-- either the character or the system is missing.
function CharacterSheet.Compute(char, system, itemLib)
    if type(char) ~= "table" or type(system) ~= "table" then return nil end

    local traits = SelectedTraits(char, system)
    local level = char.level or 1
    local accomplishment = ns.GetAccomplishmentBonus(level)

    -- Homebrew feats and spells (authored in the pickers) fold their effects
    -- once gained; a record written for a higher level is pending and
    -- contributes nothing yet. Their display lives in the pickers and the
    -- sheet's quick-reference sections, which read the character directly.
    -- (Field names, not the lists - a nil list would truncate the array
    -- constructor and silently skip the rest.)
    local activeCustom = {}
    for _, field in ipairs({ "custom_feats", "custom_spells" }) do
        for _, p in ipairs(type(char[field]) == "table" and char[field] or {}) do
            if CharacterSheet.HomebrewActive(char, p) then
                activeCustom[#activeCustom + 1] = p
            end
        end
    end

    -- Owned PACK feats (every rank up to the owned one) and known pack spells
    -- fold their machine-readable effects the same way - e.g. a rank-I feat
    -- granting skill accomplishment. Packs come through the ns accessors,
    -- like the modifier table and hit dice already do.
    local featPack = ns.GetFeatPack and ns.GetFeatPack()
    if featPack and type(char.feats) == "table" then
        for _, line in ipairs(type(featPack.lines) == "table" and featPack.lines or {}) do
            local owned = type(line) == "table" and tonumber(char.feats[line.id]) or 0
            local ranks = type(line.ranks) == "table" and line.ranks or {}
            for i = 1, math.min(owned, #ranks) do
                local rank = ranks[i]
                if type(rank) == "table" and type(rank.effects) == "table" then
                    activeCustom[#activeCustom + 1] = rank
                end
            end
        end
    end
    local spellPack = ns.GetSpellPack and ns.GetSpellPack()
    if spellPack and type(char.spells) == "table" then
        local byId = {}
        for _, s in ipairs(type(spellPack.spells) == "table" and spellPack.spells or {}) do
            if type(s) == "table" and s.id then byId[s.id] = s end
        end
        for _, id in ipairs(char.spells) do
            local spell = byId[id]
            if spell and type(spell.effects) == "table" then
                activeCustom[#activeCustom + 1] = spell
            end
        end
    end

    -- Effects come from traits and everything collected above (homebrew and
    -- pack feats/spells alike).
    local fx = AccumulateEffects(traits, activeCustom)

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
    for id in pairs(fx.accomplishSkill) do accomplishedSkills[id] = true end
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

    -- Weapon proficiencies (display + accomplished flag): one row per weapon
    -- skill, never per item. When a weapon names its governing attribute
    -- (weapon.attribute, like skills), an attack-roll total is computed:
    -- attribute modifier + accomplishment (every listed weapon is accomplished)
    -- + global attack-roll effects. `weaponAttack` carries those totals to the
    -- inventory below, where each linked item adds its own bonus on top.
    local accomplishedWeapons = ListToSet(char.accomplished_weapons)
    local weapons, weaponAttack = {}, {}
    for _, weapon in ipairs(system.weapons or {}) do
        if accomplishedWeapons[weapon.id] then
            local entry = {
                id = weapon.id, name = weapon.name, damage = weapon.damage,
                versatile = weapon.versatile, properties = weapon.properties or {},
            }
            local attrId, total = WeaponAttack(weapon, modifier, accomplishment, fx.attack)
            if attrId then
                entry.attack_attribute = attrId
                entry.attack_total = total
                weaponAttack[weapon.id] = total
            end
            weapons[#weapons + 1] = entry
        end
    end

    -- Inventory, resolved against the library and the weapon totals above:
    -- each weapon item ends up with its own attack total, and equipped
    -- equipment adds to AC in `derived`.
    local inventory, acEquipment, acModCap = ResolveInventory(char, system, itemLib, weaponAttack)

    -- Derived stats. Which attributes drive hit die, mana, movement etc. comes
    -- from the system's derived_stats config; an unset coupling contributes 0,
    -- so nothing assumes a particular attribute exists.
    local cfg = ns.DerivedConfig()
    local primary = char.primary_attribute

    -- Casting source. An explicit cast_attribute (the spells-pack model) wins;
    -- else the primary attribute when it is one of the system's spell
    -- attributes (the classic model); else the configured mana fallback.
    -- Either of the first two makes the character a caster (save DC, spell
    -- attack rows); the fallback only feeds mana.
    local castAttr = (char.cast_attribute and modifier[char.cast_attribute] ~= nil)
        and char.cast_attribute or nil
    local isCaster = castAttr ~= nil
    for _, id in ipairs(cfg.spell_attributes) do if id == primary then isCaster = true end end
    local castingMod = castAttr and modifier[castAttr] or (modifier[primary] or 0)
    local spellMod = castAttr and modifier[castAttr]
        or (isCaster and (modifier[primary] or 0))
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
    -- Worn armor may cap the AC attribute's contribution (heavy armor caps at
    -- 0, medium at +2/+3). The cap only limits the benefit: a modifier already
    -- below it - negative included - passes through untouched.
    local acModWorn = acModCap and math.min(acMod, acModCap.value) or acMod
    local initMod = modifier[initAttr] or 0
    local moveMod = cfg.movement_attribute and (modifier[cfg.movement_attribute] or 0) or 0
    local hitDieMod = cfg.hit_die_attribute and (modifier[cfg.hit_die_attribute] or 0) or 0

    -- Stored max mana wins when set; otherwise the system's mana formula:
    -- mana_base + a per-level share (rounded up) + multiplier x casting-source
    -- modifier. The defaults (base 0, per-level 0, multiplier 2) reproduce the
    -- classic "2 x modifier"; an AIAS-style "3 + half level + cast modifier"
    -- is mana_base 3, mana_per_level 0.5, mana_multiplier 1. This is the
    -- fx-free base (trait/homebrew effects are added as `mana.max` in derived).
    local manaBase = char.max_mana or math.max(0,
        cfg.mana_base + math.ceil(level * cfg.mana_per_level) + cfg.mana_multiplier * spellMod)

    local derived = {
        accomplishment = accomplishment,
        primary_attribute = primary,
        hit_dice = level .. ns.GetHitDie(hitDieMod),
        hp = { current = char.current_hp, max = (char.max_hp or 0) + fx.maxHP, temp = char.temp_hp },
        -- `base` is the stored (fx-free) maximum; `max` adds the live trait/homebrew
        -- effect on top. Creation persists `base`, never `max`, so an effect is
        -- not baked into the stored value and then re-added on every Compute.
        mana = {
            current = char.current_mana,
            base = manaBase,
            max = manaBase + fx.maxMana,
        },
        ac = cfg.ac_base + acModWorn + fx.ac + (acEquipment and acEquipment.total or 0),
        -- The equipped-equipment share of AC, named so the tooltip can break it
        -- out ("+1 equipment (Chainmail)"). Absent when no equipped piece
        -- carries an ac_bonus - a character without equipment reads as before.
        ac_equipment = acEquipment,
        ac_attribute = acAttr,       -- the EFFECTIVE attribute (pick or best candidate)
        -- The modifier term the total actually used (post-cap), plus the
        -- binding cap itself ({ value, source }) when one is worn - so the
        -- tooltip can show the capped number and name the garment that did it.
        ac_attribute_mod = acModWorn,
        ac_mod_cap = acModCap,
        initiative = initMod + fx.initiative,
        init_attribute = initAttr,   -- ditto
        movement = cfg.movement_base + math.max(0, moveMod) * cfg.movement_per_step + fx.movement,
        actions = cfg.actions_base + fx.actions,
        -- The save DC is a spellcasting number: non-casters carry none (the
        -- sheet hides the row), so a martial's primary cannot fake one.
        save_dc = isCaster and (cfg.save_dc_base + castingMod + accomplishment + fx.saveDC) or nil,
        cast_attribute = castAttr,   -- explicit pick only; nil for classic casters
        attack_modifier = fx.attack,
    }
    -- Level-granted extra actions (and any other level_bonuses.actions).
    for lvl, bonus in pairs(system.level_bonuses or {}) do
        if lvl <= level and bonus.actions then derived.actions = derived.actions + bonus.actions end
    end

    -- Spellcasting (casters only): spell attack = casting-source modifier +
    -- accomplishment + spell_attack effects. When the system declares
    -- spell_schools (records or plain strings), one row per school folds in
    -- the school-targeted spell_attack / save_dc effects.
    if isCaster then
        local spell = {
            attack = castingMod + accomplishment + fx.spellAttack,
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
        -- Display entries grouped by kind (see ResolveInventory), or nil when
        -- the character carries nothing - the sheet then renders exactly what
        -- it rendered before inventories existed.
        inventory = next(AsList(char.inventory)) and inventory or nil,
    }
end
