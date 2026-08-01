-- Parchment - Picks (logic)
--
-- The shared pick ledger. Feat ranks, known spells and homebrew records all
-- spend from ONE per-level pool, so the budget and the spend count live here
-- rather than in any single picker. The budget comes from the
-- system's optional `progression` block:
--   budget = picks_level_1 + picks_per_level x (level - 1)
-- with both knobs defaulting to 1 - the classic one pick per level.
--
-- Reads from: ns.GetSystem, ns.GetFeatPack, ns.GetSpellPack, ns.FindById,
--   ns.CharacterSheet.HomebrewActive (the shared active/pending test).
-- Exposes on ns.Picks: Budget, Spent, Points.

local ADDON, ns = ...

ns.Picks = ns.Picks or {}
local Picks = ns.Picks

-- Total pick budget for a character's level.
function Picks.Budget(char)
    local p = ns.GetSystem().progression
    p = type(p) == "table" and p or {}
    local first = tonumber(p.picks_level_1) or 1
    local per = tonumber(p.picks_per_level) or 1
    local level = math.max(1, tonumber(type(char) == "table" and char.level) or 1)
    return first + per * (level - 1)
end

-- How many picks a character has spent. Only entries that resolve in the
-- ACTIVE packs count: after a pack switch, char.feats/spells can hold stale
-- ids the player can neither see nor deselect in any picker, and counting
-- those would warn about an overspend the player cannot fix (the sheet
-- already skips them for effects and display).
function Picks.Spent(char)
    if type(char) ~= "table" then return 0 end
    local spent = 0

    -- Homebrew (feats and spells), once gained: one planned for a higher
    -- level has not been paid for yet, so it must not read as an overspend
    -- today. (Field names, not the lists themselves - a nil list would
    -- truncate an array constructor and silently skip the rest.)
    for _, field in ipairs({ "custom_feats", "custom_spells" }) do
        for _, rec in ipairs(type(char[field]) == "table" and char[field] or {}) do
            if ns.CharacterSheet.HomebrewActive(char, rec) then spent = spent + 1 end
        end
    end

    -- Feat ranks: rank N of a line = N picks, clamped to the ladder's length
    -- so an over-recorded rank cannot inflate the count past what the picker
    -- could ever have sold.
    local featPack = ns.GetFeatPack()
    if featPack then
        for lineId, rank in pairs(type(char.feats) == "table" and char.feats or {}) do
            local line = ns.FindById(featPack.lines, lineId)
            if line and type(rank) == "number" and rank >= 1 then
                local cap = type(line.ranks) == "table" and #line.ranks or 0
                spent = spent + math.min(rank, cap)
            end
        end
    end

    -- Known spells resolving in the active spell pack: one pick each.
    local spellPack = ns.GetSpellPack()
    if spellPack then
        local spellIds = {}
        for _, s in ipairs(spellPack.spells or {}) do
            if type(s) == "table" and s.id then spellIds[s.id] = true end
        end
        for _, id in ipairs(char.spells or {}) do
            if spellIds[id] then spent = spent + 1 end
        end
    end

    return spent
end

-- Returns spent, budget - the pair every picker and the editor display.
function Picks.Points(char)
    return Picks.Spent(char), Picks.Budget(char)
end
