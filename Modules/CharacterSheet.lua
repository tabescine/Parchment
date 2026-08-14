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
-- rolls the one actually swung. Each also carries its damage: a die (the
-- item's own, or inherited from the linked weapon), a wield state cycled on
-- the sheet (main / off hand / two-handed, constrained by the item's
-- category), and the governing attribute's modifier - dropped in the off hand,
-- with the versatile die swapped in when held two-handed. An item's +AC arrives as an "ac" effect (the
-- wizard authors it that way), folded with per-source provenance into
-- derived.ac_effects; the legacy ac_bonus field (pre-effects items, wire
-- snapshots) still sums into derived.ac through its own `ac_equipment` term,
-- kept separate so the AC tooltip can name the equipment share. Equipment may
-- also cap the AC attribute's
-- contribution while worn (ac_mod_cap - heavy armor is cap 0, medium cap 2/3,
-- absent means the full modifier applies); the lowest worn cap binds and is
-- surfaced as derived.ac_mod_cap. Weapon and equipment items may additionally
-- carry an `effects` list from the shared vocabulary below (saving throws,
-- skills, attributes, ...), folded into the totals only while the item is
-- equipped - before the attribute pass, so an item's attribute bonus reaches
-- everything a trait's would.
--
-- Compute never throws on a character that passed schema validation, and does
-- not assume much more of one that did not: a shared sheet is validated for
-- shape only (there is no sender system to cross-reference), fields like `name`
-- are optional, and the sheet is cached before it is ever rendered - so a value
-- that throws here would keep throwing on every later view. Every character-side
-- read is therefore coerced (AsList / FiniteNumber / DisplayName) and every
-- effect value clamped to +/- MAX_EFFECT, scaled by a level bounded to
-- MAX_LEVEL, so no wire payload can produce a non-finite or absurd total.
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

-- Bounds on the numbers that fold into a sheet. A character can arrive straight
-- off the wire, where only its shape was validated, so every effect value is
-- clamped to +/- MAX_EFFECT (the schema's item-bonus limit) and the level a
-- per_level effect multiplies by to MAX_LEVEL: neither a huge value nor a huge
-- level, nor the two multiplied together, may reach a total.
local MAX_EFFECT = 99
local MAX_LEVEL = 1000

-- Stands in for a missing item/record name. `name` is optional in the schema
-- (and on a wire snapshot), but it is what an effect's provenance line
-- concatenates and what an inventory row is labelled with, so the sheet
-- substitutes a string rather than carrying a nil into either.
local UNNAMED = "Unnamed"

-- Returns x when it is a table, else an empty table. Used at every optional-list
-- read on a character: unlike a system (imported and validated locally), a
-- character can be a wire snapshot and may be any shape at all.
local function AsList(x)
    return type(x) == "table" and x or {}
end

-- Returns value as a finite number, or nil when it is not usable as one (a
-- table, an unparseable string, NaN, an infinity). Every number the sheet reads
-- off a character or an item passes through here or one of the coercions built
-- on it - a NaN or infinity would poison every total it reaches.
local function FiniteNumber(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

-- The usable value of an item bonus: a finite number, or 0.
local function BonusValue(value)
    return FiniteNumber(value) or 0
end

-- The usable value of an effect: finite and clamped to +/- MAX_EFFECT. Trait,
-- homebrew, pack feat/spell and item effects all fold through here, so one
-- discipline covers every source an effect can come from.
local function EffectValue(value)
    return math.max(-MAX_EFFECT, math.min(MAX_EFFECT, BonusValue(value)))
end

-- The level the sheet computes with: a finite number in [1, MAX_LEVEL]. Level
-- multiplies into per_level effects, mana and the hit-die line, so a shared
-- character's (attacker-influenced) level is bounded once, here.
local function SheetLevel(value)
    return math.max(1, math.min(MAX_LEVEL, FiniteNumber(value) or 1))
end

-- The display name of an item or record, always a string (see UNNAMED).
local function DisplayName(name)
    return type(name) == "string" and name or UNNAMED
end

-- Optional free text passed through to the sheet, or nil. The UI concatenates
-- these (the sheet subtitle does '"' .. quote .. '"'), so a non-string from a
-- shared sheet must not survive Compute even when validation let it past.
local function DisplayText(value)
    return type(value) == "string" and value or nil
end

-- Coerces an item's ac_mod_cap into a usable cap: a whole number in [0, 99],
-- or nil when the field is absent or unusable. Reads the same hand-editable
-- and wire data as BonusValue, so garbage must coerce, never throw. A negative
-- cap reads as 0 - a cap limits the modifier's benefit, a penalty belongs in
-- ac_bonus.
local function CapValue(value)
    if value == nil then return nil end
    local n = FiniteNumber(value)
    if not n then return nil end
    return math.max(0, math.min(99, math.floor(n)))
end

-- Returns a list of the trait records a character has selected (racial first,
-- then origins), skipping any that do not resolve in the system.
local function SelectedTraits(char, system)
    local out = {}
    if char.racial_trait then
        local t = ns.FindById(system.racial_traits, char.racial_trait)
        if t then out[#out + 1] = t end
    end
    for _, id in ipairs(AsList(char.origin_traits)) do
        local t = ns.FindById(system.origin_traits, id)
        if t then out[#out + 1] = t end
    end
    return out
end

-- Creates an empty effect accumulator.
local function NewAccumulator()
    return {
        attr = {}, attrSources = {}, allAttr = 0,
        ac = 0, acSources = {}, attack = 0, initiative = 0, movement = 0, actions = 0,
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
-- one place that says what a type means. Any effect may add per_level = true
-- to scale its value by character level ("+1 maximum HP per character level"),
-- applied before the type folds it in.
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
    -- AC provenance mirrors the attribute sources: the tooltip names what
    -- granted each point ("+2 Ring of Protection"), trait or worn item alike.
    { id = "ac", label = "Armor Class", target = "none",
      apply = function(acc, _, v, source)
          acc.ac = acc.ac + v
          acc.acSources[#acc.acSources + 1] = (v >= 0 and "+" or "") .. v .. " " .. source
      end },
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
    return gainedAt <= (tonumber(type(char) == "table" and char.level) or 1)
end

-- Folds a single effect entry into the accumulator. source is the record
-- name, recorded for attribute bonus provenance; level scales per_level
-- effects. Everything read here is coerced: an effect can come from a shared
-- character's homebrew or an equipped item's wire snapshot, where a value may
-- be any shape and a name may simply be absent.
local function ApplyEffect(acc, e, source, level)
    if type(e) ~= "table" then return end
    local spec = EFFECT_BY_ID[e.type]
    if not spec then return end
    local v = EffectValue(e.value)
    if e.per_level then v = v * SheetLevel(level) end
    spec.apply(acc, e, v, DisplayName(source))
end

-- Accumulates every effect from the selected traits and the gained
-- feat/spell records into one structure the rest of compute reads from.
local function AccumulateEffects(traits, records, level)
    local acc = NewAccumulator()
    for _, trait in ipairs(AsList(traits)) do
        for _, b in ipairs(AsList(trait.bonuses)) do ApplyEffect(acc, b, trait.name, level) end
        for _, p in ipairs(AsList(trait.penalties)) do ApplyEffect(acc, p, trait.name, level) end
    end
    for _, rec in ipairs(AsList(records)) do
        if type(rec) == "table" then
            for _, e in ipairs(AsList(rec.effects)) do ApplyEffect(acc, e, rec.name, level) end
        end
    end
    return acc
end

-- Sums the modifiers of each attribute id in a list (for add_modifier effects).
local function SumAddModifiers(list, modifier)
    local total = 0
    for _, attrId in ipairs(AsList(list)) do total = total + (modifier[attrId] or 0) end
    return total
end

-- Death saves. The rules are the system's (ns.DerivedConfig().death_saves
-- declares them; no config = no death saves anywhere): at 0 HP a d20 at or
-- above `threshold` marks a success, below marks a failure, a natural 1 marks
-- two, and a natural 20 puts the character back up at 1 HP. `successes` full =
-- stable (still down, no more rolls); `failures` full = dead. State lives in
-- char.death_saves ({ successes, failures, stable }) so it survives a /reload
-- mid-fight; healing clears it (the sheet's HP commit does).

-- Ensures and returns a sane pip state on the character.
local function DeathState(char)
    local state = type(char.death_saves) == "table" and char.death_saves or {}
    char.death_saves = state
    state.successes = tonumber(state.successes) or 0
    state.failures = tonumber(state.failures) or 0
    return state
end

-- Applies one rolled death save (the raw d20). Mutates char; returns the
-- outcome: "success", "failure", "stable", "dead" or "revive".
function CharacterSheet.ApplyDeathSave(char, raw, cfg)
    local state = DeathState(char)
    if raw == 20 then
        char.current_hp = 1
        char.death_saves = nil
        return "revive"
    end
    if raw == 1 then
        state.failures = state.failures + 2
    elseif raw >= (cfg.threshold or 10) then
        state.successes = state.successes + 1
    else
        state.failures = state.failures + 1
    end
    if state.failures >= (cfg.failures or 3) then
        state.failures = cfg.failures or 3
        return "dead"
    end
    if state.successes >= (cfg.successes or 3) then
        state.successes = cfg.successes or 3
        state.stable = true
        return "stable"
    end
    return raw >= (cfg.threshold or 10) and "success" or "failure"
end

-- One manual failure pip - taking damage while at 0 HP (a critical hit is two
-- clicks, per the rule). Damage also breaks stabilization. Returns "dead" when
-- the pips fill, else "failure".
function CharacterSheet.AddDeathFailure(char, cfg)
    local state = DeathState(char)
    state.stable = nil
    state.failures = math.min((cfg.failures or 3), state.failures + 1)
    return state.failures >= (cfg.failures or 3) and "dead" or "failure"
end

-- Removes one pip - the misclick eraser. `which` is "success" or "failure".
-- Removing a success un-stabilizes (the full row no longer stands), and the
-- block drops entirely once nothing is marked, so a corrected character
-- carries no empty scaffolding.
function CharacterSheet.UndoDeathPip(char, which)
    if type(char.death_saves) ~= "table" then return end
    local state = DeathState(char)
    local field = which == "success" and "successes" or "failures"
    state[field] = math.max(0, state[field] - 1)
    if which == "success" then state.stable = nil end
    if state.successes == 0 and state.failures == 0 and not state.stable then
        char.death_saves = nil
    end
end

-- Builds a set { id = true } from a list of ids.
local function ListToSet(list)
    local set = {}
    for _, id in ipairs(AsList(list)) do set[id] = true end
    return set
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
    -- wins and is reported as the governing one. Taking the best once and
    -- using it for attack AND damage is the agile rule's "same modifier for
    -- both rolls" satisfied by the optimal pick.
    local attrs = type(weapon.attribute) == "table" and weapon.attribute or { weapon.attribute }
    local bestId, bestMod
    for _, id in ipairs(attrs) do
        local m = modifier[id]
        if m and (not bestMod or m > bestMod) then bestId, bestMod = id, m end
    end
    if not bestId then return nil end
    return bestId, bestMod + accomplishment + attackFx, bestMod
end

-- The wield category of a weapon item that declares none: versatile when a
-- two-handed die exists (its own or the linked weapon's), else read from the
-- linked weapon's property strings - display data, so matched loosely and
-- worth nothing more than a default. nil means a plain one-hander to the
-- wield logic (ns.Items.WieldStates).
local function DeriveCategory(linked, versatileDie)
    if versatileDie then return "versatile" end
    local props = (linked and linked.properties) or {}
    for _, p in ipairs(props) do
        local s = tostring(p):lower()
        if s:find("two", 1, true) and s:find("hand", 1, true) then return "two_hand" end
    end
    for _, p in ipairs(props) do
        if tostring(p):lower() == "light" then return "light" end
    end
    return nil
end

-- Resolves a character's inventory into display entries plus the AC total
-- equipped equipment contributes.
--
-- `weaponAttack` is weapon id -> { total, mod, attr } (see WeaponAttack):
-- the bare proficiency attack total each weapon entry adds its own bonus to,
-- plus the governing attribute's bare modifier, which is the damage modifier.
--
-- Returns two values:
--   inventory   - { weapons = {...}, equipment = {...}, gear = {...} }, display
--                 entries only (never library or character tables), each
--                 carrying its `index` into char.inventory so the UI can toggle
--                 and count without knowing how resolution worked, plus the
--                 entry's `item_id` so link/share actions can reach the
--                 library record behind the row
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
            index = index, name = DisplayName(item.name), icon = item.icon,
            description = item.description, kind = kind,
            source = source, missing = (source == "missing") or nil,
            item_id = type(state.item_id) == "string" and state.item_id or nil,
        }

        -- The item's effect list rides along on equippable kinds for display
        -- (the sheet's tooltips list what a worn piece changes); the folding
        -- into totals happened in Compute, before the attribute pass.
        if kind == "weapon" or kind == "equipment" then
            entry.effects = type(item.effects) == "table" and #item.effects > 0
                and item.effects or nil
        end

        if kind == "weapon" then
            entry.equipped = state.equipped and true or false
            entry.bonus = BonusValue(item.bonus)
            entry.weapon_id = item.weapon_id
            -- The linked weapon's record, nil when the link dangles in this
            -- system: the item still shows, it just has nothing to boost or
            -- inherit.
            local linked
            if item.weapon_id then
                linked = ns.FindById(system.weapons, item.weapon_id)
                entry.weapon_name = linked and linked.name or nil
            end

            -- Die, versatile die and category: the item's own fields when
            -- authored (created / freestanding weapons and overrides), else
            -- inherited from the linked system weapon's damage / versatile /
            -- properties.
            entry.die = item.die or (linked and linked.damage) or nil
            entry.versatile_die = item.versatile_die or (linked and linked.versatile) or nil
            entry.category = item.category or DeriveCategory(linked, entry.versatile_die)

            -- How the weapon is held right now (nil when stashed), validated
            -- against the category - a stale stored wield falls back.
            entry.wield = ns.Items.EffectiveWield(state, entry.category)

            -- This item's own attack total: the linked weapon's proficiency
            -- total plus this item's bonus. Every linked item gets one, stashed
            -- included - the UI decides that only a held weapon shows a number.
            local base = entry.weapon_id and weaponAttack[entry.weapon_id]
            if base then
                entry.attack_total = base.total + entry.bonus
                entry.attack_parts = { base = base.total, bonus = entry.bonus }
            end

            -- The damage this weapon rolls in its current state: the
            -- two-handed die when a versatile weapon is held in both hands, no
            -- attribute modifier in the off hand (the light follow-up strike
            -- rule), bare die when no link provides a governing attribute.
            -- Only parseable notation becomes a roll - a foreign damage string
            -- stays display text. Item `bonus` is attack-roll only; damage is
            -- deliberately unaffected.
            local die = (entry.wield == "two" and entry.versatile_die) or entry.die
            if die and ns.Schema and ns.Schema.IsDieNotation and ns.Schema.IsDieNotation(die) then
                local mod = 0
                if entry.wield ~= "off" and base and base.mod then mod = base.mod end
                entry.damage = {
                    die = die, mod = mod, attr = base and base.attr or nil,
                    notation = die:lower() .. (mod ~= 0 and string.format("%+d", mod) or ""),
                }
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
    local level = SheetLevel(char.level)
    local accomplishment = ns.GetAccomplishmentBonus(level)

    -- Homebrew feats and spells (authored in the pickers) fold their effects
    -- once gained; a record written for a higher level is pending and
    -- contributes nothing yet. Their display lives in the pickers and the
    -- sheet's quick-reference sections, which read the character directly.
    -- (Field names, not the lists - a nil list would truncate the array
    -- constructor and silently skip the rest.)
    local activeCustom = {}
    for _, field in ipairs({ "custom_feats", "custom_spells" }) do
        for _, p in ipairs(AsList(char[field])) do
            -- A shared character's homebrew is validated for shape only (there
            -- is no sender system to check it against), so an entry may be a
            -- scalar - it carries no effects and simply does not fold.
            if type(p) == "table" and CharacterSheet.HomebrewActive(char, p) then
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

    -- Equipped weapon and equipment items fold their effects too - a ring's
    -- "+1 Alpha saving throws" counts only while worn. This runs before the
    -- attribute pass so an item's attribute effect reaches the modifiers (and
    -- through them skills, saves and weapon attacks). Resolution mirrors
    -- ResolveInventory below; values are coerced and clamped like the other
    -- item bonuses because the wire `resolved` snapshot is hostile.
    for _, raw in ipairs(AsList(char.inventory)) do
        local state = AsList(raw)
        if state.equipped then
            local item = ns.Items.Resolve(raw, itemLib)
            if (item.kind == "weapon" or item.kind == "equipment")
                and type(item.effects) == "table" then
                -- `name` is optional on a wire snapshot, and it is what an
                -- attribute effect's provenance line concatenates: a nameless
                -- item folds under the placeholder rather than throwing.
                local rec = { name = DisplayName(item.name), effects = {} }
                for _, e in ipairs(item.effects) do
                    if type(e) == "table" then
                        local copy = {}
                        for k, v in pairs(e) do copy[k] = v end
                        copy.value = EffectValue(e.value)
                        rec.effects[#rec.effects + 1] = copy
                    end
                end
                if #rec.effects > 0 then activeCustom[#activeCustom + 1] = rec end
            end
        end
    end

    -- Effects come from traits and everything collected above (homebrew, pack
    -- feats/spells, and equipped items alike).
    local fx = AccumulateEffects(traits, activeCustom, level)

    -- Attributes: base + trait bonus + global all-attribute adjustment. A base
    -- score is coerced: the wire path validates that `attributes` is a table,
    -- not what its values are, and a table (or a NaN) there would break the
    -- arithmetic every other total is built on.
    local baseScores = AsList(char.attributes)
    local modifier = {}
    local attributes = {}
    for _, attr in ipairs(system.attributes or {}) do
        local base = FiniteNumber(baseScores[attr.id]) or 0
        local bonus = (fx.attr[attr.id] or 0) + fx.allAttr
        local value = base + bonus
        modifier[attr.id] = ns.GetModifier(value)
        attributes[#attributes + 1] = {
            id = attr.id, name = attr.name,
            base = base, bonus = bonus, final = value, modifier = modifier[attr.id],
            sources = fx.attrSources[attr.id] or {},
        }
    end

    -- Fatigue: a system-declared leveled condition (derived_stats.fatigue; no
    -- config = no fatigue anywhere). Each level subtracts the configured
    -- penalty from every skill check, saving throw and attack roll - folded
    -- into the totals right here, so the displayed numbers and click-to-roll
    -- agree. Movement halves at the configured level (applied in `derived`
    -- below). Attribute-check rolls apply the penalty at roll time instead:
    -- the raw modifiers feed every other total, so dimming them here would
    -- double-count.
    local ftgCfg = ns.DerivedConfig().fatigue
    local fatigueLevel = 0
    if ftgCfg then
        fatigueLevel = math.max(0, math.min(ftgCfg.max,
            math.floor(FiniteNumber(char.fatigue) or 0)))
    end
    local fatiguePenalty = ftgCfg and fatigueLevel * ftgCfg.penalty or 0   -- subtracted

    -- Skills grouped under their governing attribute.
    local accomplishedSkills = ListToSet(char.accomplished_skills)
    for id in pairs(fx.accomplishSkill) do accomplishedSkills[id] = true end
    local skills = {}
    for _, skill in ipairs(system.skills or {}) do
        local mod = modifier[skill.attribute] or 0
        local isAccomplished = accomplishedSkills[skill.id] or false
        local perkAdd = (fx.skill[skill.id] or 0) + SumAddModifiers(fx.skillAddMod[skill.id], modifier)
        local total = mod + (isAccomplished and accomplishment or 0) + perkAdd + fx.allSkill
            - fatiguePenalty
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
            total = (modifier[attr.id] or 0) + (isAccomplished and accomplishment or 0) + perkAdd
                - fatiguePenalty,
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
            -- Fatigue rides the attack-effects term: it dims the attack roll
            -- but never the damage modifier (mod stays the bare attribute).
            local attrId, total, mod = WeaponAttack(weapon, modifier, accomplishment,
                fx.attack - fatiguePenalty)
            if attrId then
                entry.attack_attribute = attrId
                entry.attack_total = total
                weaponAttack[weapon.id] = { total = total, mod = mod, attr = attrId }
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
    -- The stored maxima and the current/temp pools are coerced for the same
    -- reason the base scores are: they are numbers on a character the wire
    -- checked only the shape of.
    local manaBase = FiniteNumber(char.max_mana) or math.max(0,
        cfg.mana_base + math.ceil(level * cfg.mana_per_level) + cfg.mana_multiplier * spellMod)

    local derived = {
        accomplishment = accomplishment,
        primary_attribute = primary,
        hit_dice = level .. ns.GetHitDie(hitDieMod),
        hp = {
            current = FiniteNumber(char.current_hp),
            max = (FiniteNumber(char.max_hp) or 0) + fx.maxHP,
            temp = FiniteNumber(char.temp_hp),
        },
        -- `base` is the stored (fx-free) maximum; `max` adds the live trait/homebrew
        -- effect on top. Creation persists `base`, never `max`, so an effect is
        -- not baked into the stored value and then re-added on every Compute.
        mana = {
            current = FiniteNumber(char.current_mana),
            base = manaBase,
            max = manaBase + fx.maxMana,
        },
        ac = cfg.ac_base + acModWorn + fx.ac + (acEquipment and acEquipment.total or 0),
        -- The equipped-equipment share of AC, named so the tooltip can break it
        -- out ("+1 equipment (Chainmail)"). Absent when no equipped piece
        -- carries an ac_bonus - a character without equipment reads as before.
        ac_equipment = acEquipment,
        -- The effect share of AC with its provenance ({ total, sources }, e.g.
        -- "+2 Ring of Protection"), absent when no ac effect folded. This is
        -- where an item's +AC lands since the wizard authors it as an effect;
        -- ac_equipment above only carries the legacy ac_bonus field.
        ac_effects = #fx.acSources > 0 and { total = fx.ac, sources = fx.acSources } or nil,
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

    -- Fatigue's derived share: halved movement at the configured level, and
    -- the state block the sheet's counter row renders from. The check/save/
    -- attack penalty was folded into those totals above.
    if ftgCfg then
        local halved = ftgCfg.speed_half_at and fatigueLevel >= ftgCfg.speed_half_at or false
        if halved then derived.movement = derived.movement / 2 end
        derived.fatigue = {
            level = fatigueLevel, penalty = fatiguePenalty, max = ftgCfg.max,
            speed_halved = halved,
        }
    end

    -- Spellcasting (casters only): spell attack = casting-source modifier +
    -- accomplishment + spell_attack effects. When the system declares
    -- spell_schools (records or plain strings), one row per school folds in
    -- the school-targeted spell_attack / save_dc effects.
    if isCaster then
        local spell = {
            -- Spell attacks are attack rolls: fatigue dims them too.
            attack = castingMod + accomplishment + fx.spellAttack - fatiguePenalty,
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
        name = DisplayName(char.name), player = DisplayText(char.player),
        race = DisplayText(char.race),
        level = level, quote = DisplayText(char.quote), notes = DisplayText(char.notes),
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
