-- Parchment - Character Editor (logic)
--
-- Pure, testable logic behind the in-game character creator/editor: a blank
-- skeleton, the point-buy and accomplishment budgets, guided level-up, and a
-- list of soft validation warnings. The UI layers (editor panel and wizard)
-- mutate the live character and call these for budgets and warnings.
--
-- Validation is soft: Warnings reports problems but nothing here blocks an edit.
--
-- Reads from: ns.CharacterSheet.Compute, ns.Schema, ns.PerkTree, ns.GetModifier,
--   ns.GetHitDie, ns.SetActiveCharacter, ParchmentCharDB.
-- Exposes on ns.CharacterEditor: NewBlank, AttributePoints, AccomplishTargets,
--   LevelUp, Warnings, Races, SaveNew, Delete.

local ADDON, ns = ...

ns.CharacterEditor = ns.CharacterEditor or {}
local CE = ns.CharacterEditor

-- Finds a trait record by id in a system list ("racial_traits"/"origin_traits").
local function FindTrait(system, listKey, id)
    for _, t in ipairs(system[listKey] or {}) do
        if t.id == id then return t end
    end
end

-- The trait records a character has selected (racial first, then origins).
local function SelectedTraits(char, system)
    local out = {}
    if char.racial_trait then
        local t = FindTrait(system, "racial_traits", char.racial_trait)
        if t then out[#out + 1] = t end
    end
    for _, id in ipairs(char.origin_traits or {}) do
        local t = FindTrait(system, "origin_traits", id)
        if t then out[#out + 1] = t end
    end
    return out
end

-- Returns a fresh level-1 character skeleton, with attributes and default
-- governing-attribute choices drawn from the loaded system (so it works for any
-- imported ruleset, not a fixed set of attributes).
function CE.NewBlank()
    local system = ns.GetSystem()
    local base = (system.point_buy and (system.point_buy.base or system.point_buy.min)) or 1

    -- One entry per system attribute, each starting at the point-buy baseline.
    local attributes = {}
    for _, attr in ipairs(system.attributes or {}) do attributes[attr.id] = base end
    -- Default the primary/AC/initiative attributes to the first one; the player
    -- changes them in the wizard/editor.
    local first = system.attributes and system.attributes[1] and system.attributes[1].id or nil

    return {
        name = "New Character", player = "", race = "", quote = "", level = 1,
        attributes = attributes,
        racial_trait = nil, origin_traits = {},
        primary_attribute = first, ac_attribute = first, init_attribute = first,
        accomplished_skills = {}, accomplished_weapons = {}, accomplished_saves = {},
        perks = {}, custom_perks = {}, perk_choices = {},
        -- HP/Mana are left unset until the build is finished (InitResources),
        -- so they derive from the final stats rather than a fixed 0.
        hit_dice = nil, notes = "",
    }
end

-- Sets the level-1 starting HP and Mana from the character's stats: HP is the
-- maximum of the hit die + 5; Mana is the computed maximum from the system's
-- derived_stats config. Called when a new character is finished.
function CE.InitResources(char, system)
    char.max_hp, char.max_mana = nil, nil
    local sheet = ns.CharacterSheet.Compute(char, system)
    if not sheet then return end
    char.hit_dice = sheet.derived.hit_dice
    local die = tonumber(tostring(sheet.derived.hit_dice):match("d(%d+)")) or 6
    char.max_hp = die + 5
    char.current_hp = char.max_hp
    char.max_mana = sheet.derived.mana.max or 0
    char.current_mana = char.max_mana
end

-- Returns the list of races a character may be (union of racial-trait
-- allowed_races, plus human), excluding the "all_but_human" wildcard token.
function CE.Races(system)
    local set = { human = true }
    for _, t in ipairs(system.racial_traits or {}) do
        for _, r in ipairs(t.allowed_races or {}) do
            if r ~= "all_but_human" then set[r] = true end
        end
    end
    local list = {}
    for r in pairs(set) do list[#list + 1] = r end
    table.sort(list)
    return list
end

-- Returns used, available attribute points. used = points spent above the base
-- of 1 per attribute; available = point-buy total + trait attribute_points +
-- level milestone attribute points up to the current level.
function CE.AttributePoints(char, system)
    local used = 0
    for _, attr in ipairs(system.attributes or {}) do
        used = used + (((char.attributes or {})[attr.id] or 1) - 1)
    end
    local available = (system.point_buy and system.point_buy.total) or 33
    for _, t in ipairs(SelectedTraits(char, system)) do
        for _, b in ipairs(t.bonuses or {}) do
            if b.type == "attribute_points" then available = available + (b.value or 0) end
        end
    end
    for lvl, bonus in pairs(system.level_bonuses or {}) do
        if lvl <= (char.level or 1) and bonus.attribute_points then
            available = available + bonus.attribute_points
        end
    end
    return used, available
end

-- Returns suggested target counts for accomplished skills/weapons/saves. These
-- are soft guidance only. A system may override the defaults by declaring an
-- `accomplish_targets = { skills, weapons, saves }` table; otherwise sensible
-- generic constants are used (no assumptions about which attributes exist).
function CE.AccomplishTargets(sheet)
    local t = ns.GetSystem().accomplish_targets or {}
    return {
        skills = t.skills or 3,
        weapons = t.weapons or 5,
        saves = t.saves or 2,
    }
end

-- Raises the character's level by one, adding hpGain to max/current HP and
-- refreshing the hit-dice string. Returns ok, notes (list of milestone gains).
function CE.LevelUp(char, hpGain, system)
    local maxLevel = system.max_level or 30
    if (char.level or 1) >= maxLevel then return false, { "Already at maximum level." } end

    char.level = (char.level or 1) + 1
    hpGain = hpGain or 0
    char.max_hp = (char.max_hp or 0) + hpGain
    char.current_hp = (char.current_hp or 0) + hpGain

    local sheet = ns.CharacterSheet.Compute(char, system)
    char.hit_dice = sheet.derived.hit_dice

    local notes = { "+1 perk point" }
    local b = system.level_bonuses and system.level_bonuses[char.level]
    if b then
        if b.attribute_points then notes[#notes + 1] = "+" .. b.attribute_points .. " attribute point" end
        if b.actions then notes[#notes + 1] = "+" .. b.actions .. " action" end
        if b.weapon_dice then notes[#notes + 1] = "+" .. b.weapon_dice .. " weapon die" end
    end
    return true, notes
end

-- Lowers the character's level by one (e.g. to undo an accidental level-up) and
-- refreshes the hit-dice string. Does not touch HP, which is managed manually.
-- Returns ok, note.
function CE.LevelDown(char, system)
    if (char.level or 1) <= 1 then return false, "Already at level 1." end
    char.level = char.level - 1
    char.hit_dice = ns.CharacterSheet.Compute(char, system).derived.hit_dice
    return true, "now level " .. char.level
end

-- Returns a list of soft build warnings (never blocking). Combines structural
-- schema issues with build-rule checks (point-buy, accomplished counts, origin
-- count, perk budget).
function CE.Warnings(char, system)
    local w = {}
    local sheet = ns.CharacterSheet.Compute(char, system)

    local _, issues = ns.Schema.ValidateCharacter(char, system)
    for _, i in ipairs(issues) do w[#w + 1] = i end

    local used, avail = CE.AttributePoints(char, system)
    if used > avail then
        w[#w + 1] = string.format("Too many attribute points: %d of %d allocated (%d over).", used, avail, used - avail)
    elseif used < avail then
        w[#w + 1] = string.format("%d of %d attribute points spent (%d unspent).", used, avail, avail - used)
    end
    -- The 1-10 cap applies only at creation; afterwards level points and traits
    -- can push base attributes higher (toward 11/12 perk requirements). Only
    -- flag values outside the modifier table's range.
    local cap = #(system.modifier_table or {})
    for _, attr in ipairs(system.attributes or {}) do
        local v = (char.attributes or {})[attr.id] or 1
        if v < 1 or (cap > 0 and v > cap) then
            w[#w + 1] = attr.name .. " is out of the 1-" .. cap .. " range."
        end
    end

    local tg = CE.AccomplishTargets(sheet)
    local function countWarn(label, list, target)
        local n = #(list or {})
        if n ~= target then w[#w + 1] = string.format("Accomplished %s: %d of %d", label, n, target) end
    end
    countWarn("skills", char.accomplished_skills, tg.skills)
    countWarn("weapons", char.accomplished_weapons, tg.weapons)
    countWarn("saves", char.accomplished_saves, tg.saves)

    -- The primary attribute's save is automatically accomplished by the rules.
    if char.primary_attribute then
        local hasPrimary = false
        for _, id in ipairs(char.accomplished_saves or {}) do
            if id == char.primary_attribute then hasPrimary = true end
        end
        if not hasPrimary then
            local name = char.primary_attribute
            for _, a in ipairs(system.attributes or {}) do if a.id == char.primary_attribute then name = a.name end end
            w[#w + 1] = "Primary save (" .. name .. ") should be accomplished."
        end
    end

    if #(char.origin_traits or {}) > 2 then w[#w + 1] = "More than 2 origin traits selected." end

    local invested, available = ns.PerkTree.Points(char)
    if invested > available then
        w[#w + 1] = string.format("Perk points: %d used of %d available", invested, available)
    end
    return w
end

-- Saves a character under a key and makes it active.
function CE.SaveNew(key, char)
    ParchmentCharDB.characters = ParchmentCharDB.characters or {}
    ParchmentCharDB.characters[key] = char
    ns.SetActiveCharacter(key)
end

-- Deletes a character by key, re-pointing the active character if needed.
function CE.Delete(key)
    local chars = ParchmentCharDB.characters or {}
    chars[key] = nil
    if ns.Addon.db.global.activeCharacter == key then
        ns.Addon.db.global.activeCharacter = next(chars)
    end
end
