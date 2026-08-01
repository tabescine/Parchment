-- Parchment - Homebrew (logic)
--
-- The data seams for per-character homebrew feats and spells: custom entries
-- authored in game (UI/HomebrewUI.lua) or imported, living in
-- char.custom_feats / char.custom_spells. Each record is self-contained -
-- name, the level it is gained at, picker metadata (type, cost, range, save;
-- spells add school, rank, damage, concentration), rules text, and optional
-- machine-readable effects in the shared vocabulary. A record gained at a
-- level above the character's is pending: it renders dimmed, folds nothing
-- into the sheet, and costs no pick until the level is reached (the same
-- active/pending test, ns.CharacterSheet.HomebrewActive).
--
-- Commit/Delete are the single seams through which homebrew reaches a
-- character, mirroring the retired perk-wizard seams.
--
-- Reads from: ns.CharacterSheet.HomebrewActive.
-- Exposes on ns.Homebrew: List, Field, NextId, Commit, Delete, Active.

local ADDON, ns = ...

ns.Homebrew = ns.Homebrew or {}
local Homebrew = ns.Homebrew

local FIELD = { feat = "custom_feats", spell = "custom_spells" }
local ID_PREFIX = { feat = "hf-", spell = "hs-" }

-- The character field a homebrew kind lives in ("custom_feats"/"custom_spells").
function Homebrew.Field(kind)
    return FIELD[kind]
end

-- The character's homebrew list for a kind (never nil; not created on read).
function Homebrew.List(char, kind)
    local field = FIELD[kind]
    local list = field and type(char) == "table" and char[field]
    return type(list) == "table" and list or {}
end

-- The first free "hf-N"/"hs-N" id for a character's homebrew of a kind. The id
-- is not read by the engine (effects fold by record name), but it keeps the
-- record self-contained, like imported entries.
function Homebrew.NextId(char, kind)
    local used = {}
    for _, r in ipairs(Homebrew.List(char, kind)) do
        if type(r) == "table" then used[r.id] = true end
    end
    local n = 0
    repeat
        n = n + 1
    until not used[ID_PREFIX[kind] .. n]
    return ID_PREFIX[kind] .. n
end

-- True when a homebrew record is gained at the character's current level
-- (pending records fold nothing and cost no pick).
function Homebrew.Active(char, record)
    return ns.CharacterSheet.HomebrewActive(char, record)
end

-- Commits a homebrew record onto a character: appended when index is nil,
-- replacing that entry when index names an existing one. The record is stored
-- as given (it is self-contained). Returns the index the record landed at,
-- or nil when the arguments are unusable.
function Homebrew.Commit(char, kind, record, index)
    local field = FIELD[kind]
    if not field or type(char) ~= "table" or type(record) ~= "table" then return nil end
    char[field] = type(char[field]) == "table" and char[field] or {}
    local list = char[field]
    if index and list[index] then
        list[index] = record
        return index
    end
    list[#list + 1] = record
    return #list
end

-- Removes the homebrew record at index (later entries shift down). Returns
-- true when one was removed, false when the index holds nothing.
function Homebrew.Delete(char, kind, index)
    local field = FIELD[kind]
    local list = field and type(char) == "table" and char[field]
    if type(list) ~= "table" or index == nil or list[index] == nil then return false end
    table.remove(list, index)
    return true
end
