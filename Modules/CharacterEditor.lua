-- Parchment - Character Editor (logic)
--
-- Pure, testable logic behind the in-game character creator/editor: a blank
-- skeleton, the point-buy and accomplishment budgets, guided level-up, and a
-- list of soft validation warnings. The UI layers (editor panel and wizard)
-- mutate the live character and call these for budgets and warnings.
--
-- Validation is soft: Warnings reports problems but nothing here blocks an edit.
--
-- Reads from: ns.CharacterSheet.Compute, ns.Schema, ns.Picks, ns.GetModifier,
--   ns.GetHitDie, ns.GetItemLibrary, ns.GetFeatPack, ns.GetSpellPack, and the
--   character data API (Get/SetCharacter(s), SetActiveCharacter).
-- Exposes on ns.CharacterEditor: NewBlank, HitDieSize, InitResources, Races,
--   AttributePoints, AccomplishTargets, AccomplishTargetDesc, LevelUp,
--   LevelDown, Warnings, SaveNew, Delete.

local ADDON, ns = ...

ns.CharacterEditor = ns.CharacterEditor or {}
local CE = ns.CharacterEditor

-- Finds a trait record by id in a system list ("racial_traits"/"origin_traits").
local function FindTrait(system, listKey, id)
    return ns.FindById(system[listKey], id)
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
    -- Default the primary attribute to the first one (the player changes it
    -- in the wizard/editor). AC/initiative stay UNSET when the system
    -- declares candidate lists - the sheet then uses the best candidate
    -- automatically until the player explicitly picks one.
    local ds = system.derived_stats or {}
    local first = system.attributes and system.attributes[1] and system.attributes[1].id or nil
    local acDefault = (ds.ac_attributes and #ds.ac_attributes > 0) and nil or first
    local initDefault = (ds.init_attributes and #ds.init_attributes > 0) and nil or first

    return {
        name = "New Character", player = "", race = "", quote = "", level = 1,
        attributes = attributes,
        racial_trait = nil, origin_traits = {},
        primary_attribute = first, ac_attribute = acDefault, init_attribute = initDefault,
        accomplished_skills = {}, accomplished_weapons = {}, accomplished_saves = {},
        -- HP/Mana are left unset until the build is finished (InitResources),
        -- so they derive from the final stats rather than a fixed 0.
        hit_dice = nil, notes = "",
    }
end

-- The die size of a hit-dice string ("3d8" -> 8), defaulting to 6 when it does
-- not parse. The one shared parse - the editor UI's per-level HP math uses it
-- too, so the two can never drift.
function CE.HitDieSize(hitDice)
    return tonumber(tostring(hitDice):match("d(%d+)")) or 6
end

-- Sets the level-1 starting HP and Mana from the character's stats: HP is the
-- maximum of the hit die + 5; Mana is the computed maximum from the system's
-- derived_stats config. Called when a new character is finished.
function CE.InitResources(char, system)
    char.max_hp, char.max_mana = nil, nil
    local sheet = ns.CharacterSheet.Compute(char, system, ns.GetItemLibrary())
    if not sheet then return end
    char.hit_dice = sheet.derived.hit_dice
    local die = CE.HitDieSize(sheet.derived.hit_dice)
    char.max_hp = die + 5
    char.current_hp = char.max_hp
    -- Store the fx-free base, not the effect-inclusive max: Compute re-adds trait
    -- and homebrew mana effects on every call, so persisting the max would double-count
    -- them (a creation-time +5 mana trait would grant +10 forever).
    char.max_mana = sheet.derived.mana.base or 0
    char.current_mana = char.max_mana
end

-- Returns the race list for the race picker: system.races verbatim when the
-- system declares it, otherwise (sorted) every race named by a racial trait's
-- allowed_races / disallowed_races. No race is ever assumed; an empty result
-- means the system defines none.
function CE.Races(system)
    if type(system.races) == "table" and #system.races > 0 then
        local list = {}
        for _, r in ipairs(system.races) do list[#list + 1] = r end
        return list
    end
    local set = {}
    for _, t in ipairs(system.racial_traits or {}) do
        for _, r in ipairs(t.allowed_races or {}) do set[r] = true end
        for _, r in ipairs(t.disallowed_races or {}) do set[r] = true end
    end
    local list = {}
    for r in pairs(set) do list[#list + 1] = r end
    table.sort(list)
    return list
end

-- Returns used, available attribute points. used = points spent above the
-- system's point-buy base per attribute (matching NewBlank's seeding);
-- available = point-buy total + trait attribute_points + level milestone
-- attribute points up to the current level.
function CE.AttributePoints(char, system)
    local base = (system.point_buy and (system.point_buy.base or system.point_buy.min)) or 1
    local used = 0
    for _, attr in ipairs(system.attributes or {}) do
        used = used + (((char.attributes or {})[attr.id] or base) - base)
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
-- Defaults when a system declares no accomplish_targets.
local TARGET_DEFAULTS = { skills = 3, weapons = 5, saves = 2 }

-- Resolves one target spec to a number. A spec may be a plain number, or a table
-- { base, attribute } (base + that attribute's modifier, min 0) or
-- { base, attribute_max = {ids} } (base + the highest of those modifiers, min 0).
local function ResolveTarget(spec, dflt, modById)
    if type(spec) == "number" then return spec end
    if type(spec) ~= "table" then return dflt end
    local n = spec.base or dflt
    if spec.attribute then
        n = n + math.max(0, modById[spec.attribute] or 0)
    elseif spec.attribute_max then
        local hi = 0
        for _, id in ipairs(spec.attribute_max) do hi = math.max(hi, modById[id] or 0) end
        n = n + math.max(0, hi)
    end
    return n
end

function CE.AccomplishTargets(sheet)
    local t = ns.GetSystem().accomplish_targets or {}
    local mod = {}
    for _, a in ipairs(sheet.attributes or {}) do mod[a.id] = a.modifier end
    return {
        skills = ResolveTarget(t.skills, TARGET_DEFAULTS.skills, mod),
        weapons = ResolveTarget(t.weapons, TARGET_DEFAULTS.weapons, mod),
        saves = ResolveTarget(t.saves, TARGET_DEFAULTS.saves, mod),
    }
end

-- A human-readable description of how a target is computed (for tooltips), e.g.
-- "3 + Intellect modifier" or "5 + highest of Power/Agility modifier".
function CE.AccomplishTargetDesc(which)
    local system = ns.GetSystem()
    local spec = (system.accomplish_targets or {})[which]
    local dflt = TARGET_DEFAULTS[which] or 0
    if type(spec) == "number" then return tostring(spec) end
    if type(spec) ~= "table" then return tostring(dflt) end
    local base = spec.base or dflt
    if spec.attribute then
        return base .. " + " .. ns.AttrName(spec.attribute) .. " modifier (min 0)"
    elseif spec.attribute_max and #spec.attribute_max > 0 then
        local names = {}
        for _, id in ipairs(spec.attribute_max) do names[#names + 1] = ns.AttrName(id) end
        return base .. " + highest of " .. table.concat(names, "/") .. " modifier (min 0)"
    end
    return tostring(base)
end

-- The mana the system's formula grants between two levels: the per-level
-- share is the only level-dependent term (base and the casting modifier do
-- not move with level), so the delta is the rounded-up share's step. Applied
-- to the STORED max on level change - InitResources persisted the level-1
-- base, and Compute prefers a stored max, so without this mana never scales.
local function ManaDelta(fromLevel, toLevel)
    local per = ns.DerivedConfig().mana_per_level
    return math.ceil(toLevel * per) - math.ceil(fromLevel * per)
end

-- Raises the character's level by one, adding hpGain to max/current HP,
-- applying the system's per-level mana gain and refreshing the hit-dice
-- string. Returns ok, notes (list of milestone gains).
function CE.LevelUp(char, hpGain, system)
    local maxLevel = system.max_level or 30
    if (char.level or 1) >= maxLevel then return false, { "Already at maximum level." } end

    local manaGain = ManaDelta(char.level or 1, (char.level or 1) + 1)
    char.level = (char.level or 1) + 1
    hpGain = hpGain or 0
    char.max_hp = (char.max_hp or 0) + hpGain
    char.current_hp = (char.current_hp or 0) + hpGain
    -- Only a STORED max is adjusted. A character imported without one runs on
    -- Compute's live formula, which scales with level by itself - materializing
    -- 0 + delta here would both be wrong and freeze that scaling.
    if manaGain ~= 0 and char.max_mana then
        char.max_mana = math.max(0, char.max_mana + manaGain)
        char.current_mana = math.max(0, (char.current_mana or 0) + manaGain)
    end

    local sheet = ns.CharacterSheet.Compute(char, system, ns.GetItemLibrary())
    char.hit_dice = sheet.derived.hit_dice

    -- The pick gain is the ledger's per-level delta (system.progression may
    -- reshape it; the classic default is one per level).
    local gained = ns.Picks.Budget(char) - ns.Picks.Budget({ level = char.level - 1 })
    local notes = {}
    if gained > 0 then
        notes[#notes + 1] = "+" .. gained .. " pick" .. (gained == 1 and "" or "s")
            .. " (feat or spell)"
    end
    local b = system.level_bonuses and system.level_bonuses[char.level]
    if b then
        if b.attribute_points then notes[#notes + 1] = "+" .. b.attribute_points .. " attribute point" end
        if b.actions then notes[#notes + 1] = "+" .. b.actions .. " action" end
        if b.weapon_dice then notes[#notes + 1] = "+" .. b.weapon_dice .. " weapon die" end
    end
    if manaGain > 0 then notes[#notes + 1] = "+" .. manaGain .. " mana" end
    return true, notes
end

-- Lowers the character's level by one (e.g. to undo an accidental level-up) and
-- refreshes the hit-dice string. Does not touch HP, which is managed manually
-- (the gain was a user-chosen roll) - but the mana delta is deterministic, so
-- it IS taken back, keeping down a true undo of up. Returns ok, note.
function CE.LevelDown(char, system)
    if (char.level or 1) <= 1 then return false, "Already at level 1." end
    local manaLoss = ManaDelta(char.level - 1, char.level)
    char.level = char.level - 1
    if manaLoss ~= 0 and char.max_mana then
        char.max_mana = math.max(0, char.max_mana - manaLoss)
        char.current_mana = math.min(char.max_mana,
            math.max(0, (char.current_mana or 0) - manaLoss))
    end
    char.hit_dice = ns.CharacterSheet.Compute(char, system, ns.GetItemLibrary()).derived.hit_dice
    return true, "now level " .. char.level
end

-- Returns a list of soft build warnings (never blocking). Combines structural
-- schema issues with build-rule checks (point-buy, accomplished counts, origin
-- count, pick budget).
function CE.Warnings(char, system)
    local w = {}
    local sheet = ns.CharacterSheet.Compute(char, system, ns.GetItemLibrary())

    local _, issues = ns.Schema.ValidateCharacter(char, system,
        { feats = ns.GetFeatPack(), spells = ns.GetSpellPack() })
    for _, i in ipairs(issues) do w[#w + 1] = i end

    local used, avail = CE.AttributePoints(char, system)
    if used > avail then
        w[#w + 1] = string.format("Too many attribute points: %d of %d allocated (%d over).", used, avail, used - avail)
    elseif used < avail then
        w[#w + 1] = string.format("%d of %d attribute points spent (%d unspent).", used, avail, avail - used)
    end
    -- The creation cap applies only at creation; afterwards level points and
    -- traits can push base attributes higher (toward late feat requirements).
    -- Only flag values outside the system's floor / modifier-table range.
    local floor = (system.point_buy and system.point_buy.min) or 1
    local cap = #(system.modifier_table or {})
    for _, attr in ipairs(system.attributes or {}) do
        local v = (char.attributes or {})[attr.id] or floor
        if v < floor then
            w[#w + 1] = attr.name .. " is below the minimum of " .. floor .. "."
        elseif cap > 0 and v > cap then
            w[#w + 1] = attr.name .. " is above the maximum of " .. cap .. "."
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

    local invested, available = ns.Picks.Points(char)
    if invested > available then
        w[#w + 1] = string.format("Picks (feats and spells): %d used of %d available",
            invested, available)
    end
    return w
end

-- Saves a character under a key and makes it active.
function CE.SaveNew(key, char)
    ns.SetCharacter(key, char)
    ns.SetActiveCharacter(key)
end

-- Deletes a character by key (Core re-points the active character if needed).
function CE.Delete(key)
    ns.DeleteCharacter(key)
end
