-- Parchment - Import / Export (logic)
--
-- Turns the live data into copyable text and turns pasted text back into data.
-- Import accepts JSON (via ns.JSON) or a Lua table literal (sandboxed loadstring
-- with an empty environment), auto-detects whether it is a system or character,
-- validates against the schema, and only commits to SavedVariables on success.
-- Export produces pretty JSON matching the converter's format.
--
-- Reads from: ns.JSON, ns.Schema, ns.GetSystem, ns.GetCharacter(s),
--   ns.SetActiveCharacter.
-- Exposes on ns.ImportExport: ExportSystem, ExportCharacter, Import.

local ADDON, ns = ...

ns.ImportExport = ns.ImportExport or {}
local IE = ns.ImportExport

-- Recursively copies a table, converting integer-looking string keys to numbers
-- so JSON objects keyed "3"/"9" (level_bonuses) restore as Lua numeric keys.
local function NormalizeKeys(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do
        local key = k
        if type(k) == "string" and k:match("^%-?%d+$") then key = tonumber(k) end
        out[key] = NormalizeKeys(v)
    end
    return out
end

-- Returns a shallow copy of a table without keys beginning with '_' (metadata
-- such as _key, which is converter/import-only and never stored).
local function StripMeta(t)
    local out = {}
    for k, v in pairs(t) do
        if not (type(k) == "string" and k:sub(1, 1) == "_") then out[k] = v end
    end
    return out
end

-- Classifies a decoded table as a system, a single character, a full character
-- DB, or nil when it matches none.
local function DetectKind(data)
    if type(data) ~= "table" then return nil end
    if data.characters then return "character_db" end
    if data.system_name or data.perk_trees or data.modifier_table then return "system" end
    if data.name and (data.attributes or data.level) then return "character" end
    return nil
end

-- Parses a Lua table literal in a sandbox (empty environment, no global access).
-- Returns the table, or nil plus an error message.
local function ParseLua(text)
    local fn, compileErr = loadstring("return " .. text)
    if not fn then return nil, compileErr end
    setfenv(fn, {})
    local ok, value = pcall(fn)
    if not ok then return nil, value end
    if type(value) ~= "table" then return nil, "expected a table" end
    return value
end

-- Joins up to the first few schema issues into a single message line.
local function SummarizeIssues(issues)
    local shown = {}
    for i = 1, math.min(#issues, 4) do shown[i] = issues[i] end
    local msg = table.concat(shown, "; ")
    if #issues > 4 then msg = msg .. " (+" .. (#issues - 4) .. " more)" end
    return msg
end

-- Encodes a table as JSON or TOML. format defaults to "json".
local function Encode(tbl, format)
    if format == "toml" then return ns.TOML.encode(tbl) end
    return ns.JSON.encode(tbl, true)
end

-- Exports the active system definition. format is "json" (default) or "toml".
function IE.ExportSystem(format)
    return Encode(ns.GetSystem(), format)
end

-- Exports a character (by key, or the active one), tagged with its _key so it
-- round-trips on import. format is "json" (default) or "toml". Returns the
-- string, or nil plus an error.
function IE.ExportCharacter(key, format)
    local char, resolvedKey
    if key then
        char, resolvedKey = ns.GetCharacter(key), key
    else
        char, resolvedKey = ns.GetActiveCharacter()
    end
    if not char then return nil, "no character to export." end
    local copy = StripMeta(char)
    copy._key = resolvedKey
    return Encode(copy, format)
end

-- Imports pasted text. Returns ok, message.
--
-- On success the data is written to SavedVariables and, for a single character,
-- that character is made active. On failure nothing is written and the message
-- explains why (parse error or the schema issues found).
function IE.Import(text)
    text = strtrim(text or "")
    if text == "" then return false, "nothing to import." end

    -- Auto-detect the format: try JSON, then TOML, then a Lua table literal.
    -- The three syntaxes are distinct enough that the wrong parser fails cleanly
    -- rather than mis-parsing, so the first that succeeds is the right one.
    local data, jsonErr = ns.JSON.decode(text)
    if not data then
        local tomlErr, luaErr
        data, tomlErr = ns.TOML.decode(text)
        if not data then
            data, luaErr = ParseLua(text)
            if not data then
                return false, "could not parse (JSON: " .. tostring(jsonErr)
                    .. "; TOML: " .. tostring(tomlErr)
                    .. "; Lua: " .. tostring(luaErr) .. ")"
            end
        end
    end

    data = NormalizeKeys(data)
    local kind = DetectKind(data)
    if not kind then
        return false, "could not tell if this is a system or a character."
    end

    if kind == "system" then
        local clean = StripMeta(data)
        local ok, issues = ns.Schema.ValidateSystem(clean)
        if not ok then return false, "system invalid: " .. SummarizeIssues(issues) end
        ParchmentSystemDB = clean
        -- Mark the system DM-owned so version migration won't overwrite it.
        if ns.Addon and ns.Addon.db then ns.Addon.db.global.systemSource = "imported" end
        return true, "imported system '" .. (clean.system_name or "?") .. "'."
    end

    if kind == "character_db" then
        local count = 0
        for charKey, char in pairs(data.characters or {}) do
            local ok, issues = ns.Schema.ValidateCharacter(char, ns.GetSystem())
            if not ok then
                return false, "character '" .. tostring(charKey) .. "' invalid: " .. SummarizeIssues(issues)
            end
            count = count + 1
        end
        ParchmentCharDB = StripMeta(data)
        return true, "imported " .. count .. " character(s)."
    end

    -- Single character.
    local key = data._key
    if not key then return false, "character has no key; add a \"_key\" field." end
    local clean = StripMeta(data)
    local ok, issues = ns.Schema.ValidateCharacter(clean, ns.GetSystem())
    if not ok then return false, "character invalid: " .. SummarizeIssues(issues) end

    ParchmentCharDB.characters = ParchmentCharDB.characters or {}
    ParchmentCharDB.characters[key] = clean
    ns.SetActiveCharacter(key)
    return true, "imported character '" .. (clean.name or key) .. "'."
end
