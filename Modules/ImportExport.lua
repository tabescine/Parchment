-- Parchment - Import / Export (logic)
--
-- Turns the live data into copyable text and turns pasted text back into data.
-- Import accepts JSON, TOML, or a Lua table literal (sandboxed loadstring with
-- an empty environment), auto-detects whether it is a system, a character, an
-- item library or a feats/spells pack, validates against the schema, and only
-- commits on success - via ns.Systems.SetActive for systems, the character
-- data API for characters, ns.SetItem for items and ns.Packs.Import for
-- packs, never by touching the SavedVariables globals directly.
-- Export produces pretty JSON (or TOML) matching the converter's format.
--
-- Reads from: ns.JSON, ns.TOML, ns.Schema, ns.Systems, ns.Packs, ns.GetSystem,
--   ns.GetCharacter(s), ns.SetCharacter, ns.NextCharacterKey, ns.SetActiveCharacter,
--   ns.GetItemLibrary, ns.SetItem, ns.Items.MigrateAC, ns.GetFeatPack,
--   ns.GetSpellPack.
-- Exposes on ns.ImportExport: ExportSystem, ExportCharacter, ExportItems,
--   ExportFeatPack, ExportSpellPack, Import, StripMeta.

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

-- The deepest table nesting StripMeta will walk, matching ns.DeepCopy's
-- MAX_COPY_DEPTH in Core.lua. This runs on remote payloads BEFORE validation
-- (the comm handlers in Modules/Systems.lua and Modules/Packs.lua strip first),
-- and AceSerializer happily deserializes thousands of levels, so an unbounded
-- recursion is a stack overflow reachable from the wire. No legitimate
-- Parchment record nests anywhere near this deep.
local MAX_STRIP_DEPTH = 32

-- Returns a deep copy of a table with every key beginning with '_' removed at
-- all depths (metadata such as _key, which is converter/import-only and never
-- stored). Recursive so a nested record cannot smuggle a _-field into storage.
-- Nesting past MAX_STRIP_DEPTH is dropped rather than copied (see above): the
-- branch becomes nil, so a hostile payload loses its abusive depth instead of
-- overflowing the stack. `depth` is internal - callers pass the table only.
local function StripMeta(t, depth)
    depth = (depth or 0) + 1
    if depth > MAX_STRIP_DEPTH then return nil end
    local out = {}
    for k, v in pairs(t) do
        if not (type(k) == "string" and k:sub(1, 1) == "_") then
            -- Never `and StripMeta(v, depth) or v`: a dropped over-deep branch
            -- returns nil, which that idiom would turn back into the original
            -- table - re-attaching the very nesting the cap just refused.
            if type(v) == "table" then
                out[k] = StripMeta(v, depth)
            else
                out[k] = v
            end
        end
    end
    return out
end
-- Exposed for the comm path (Modules/Systems.lua): a DM-shared system must be
-- stripped exactly like a locally imported one, or remote metadata persists
-- into the library and round-trips into local exports.
IE.StripMeta = StripMeta

-- Classifies a decoded table as a system, a single character, a full character
-- DB, an item library, a feats/spells pack, or nil when it matches none.
local function DetectKind(data)
    if type(data) ~= "table" then return nil end
    -- The explicit pack discriminator wins outright: packs also carry sniffable
    -- fields other kinds use (a spells pack has `spells`, like a character; a
    -- pack pairing field must never be `system_name` or the system branch
    -- would swallow it - which is why packs use `for_system`).
    if data.kind == "feats" or data.kind == "spells" then return data.kind end
    -- A `characters` field must be a table to be a roster; a scalar there (e.g.
    -- `{"characters": 5}`) is malformed, not a DB - falling through to a clean
    -- "could not tell" refusal instead of later throwing from pairs(5).
    if type(data.characters) == "table" then return "character_db" end
    if data.system_name or data.modifier_table then return "system" end
    -- Pack sniffs for hand-authored files that omit `kind`: pack_name plus the
    -- kind's payload list. Characters have no pack_name, so `spells` is safe.
    if data.pack_name and type(data.lines) == "table" then return "feats" end
    if data.pack_name and type(data.spells) == "table" then return "spells" end
    if data.name and (data.attributes or data.level) then return "character" end
    -- Item libraries are checked last: `items` is only a library marker on a
    -- payload that is nothing else, so a system or character that happens to
    -- carry a field of that name is still recognised as what it is.
    if type(data.items) == "table" then return "item_db" end
    return nil
end

-- True when two character records look like the same character (same name,
-- case-insensitive). Used to decide whether importing onto an existing key is an
-- idempotent update of that character or a collision with an unrelated one.
local function SameCharacter(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local an, bn = tostring(a.name or ""):lower(), tostring(b.name or ""):lower()
    return an ~= "" and an == bn
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

-- Encodes a table as JSON or TOML. format defaults to "json". Returns the
-- string, or nil plus an error - the codecs throw on unencodable input
-- (non-finite numbers), which must surface as a status line, not a Lua error.
local function Encode(tbl, format)
    local ok, out
    if format == "toml" then
        ok, out = pcall(ns.TOML.encode, tbl)
    else
        ok, out = pcall(ns.JSON.encode, tbl, true)
    end
    if not ok then return nil, "export failed: " .. tostring(out) end
    return out
end

-- Exports the active system definition. format is "json" (default) or "toml".
-- Returns the string, or nil plus an error.
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

-- Exports the whole item library, wrapped in an `items` key so the import path
-- can tell a library apart from a system or a roster. format is "json"
-- (default) or "toml". Returns the string, or nil plus an error.
function IE.ExportItems(format)
    local lib = ns.GetItemLibrary()
    if type(lib) ~= "table" or not next(lib) then return nil, "no items to export." end
    return Encode({ items = StripMeta(lib) }, format)
end

-- Exports the active feats pack. format is "json" (default) or "toml".
-- Returns the string, or nil plus an error.
function IE.ExportFeatPack(format)
    local pack = ns.GetFeatPack()
    if not pack then return nil, "no feats pack active to export." end
    return Encode(pack, format)
end

-- Exports the active spells pack. format is "json" (default) or "toml".
-- Returns the string, or nil plus an error.
function IE.ExportSpellPack(format)
    local pack = ns.GetSpellPack()
    if not pack then return nil, "no spells pack active to export." end
    return Encode(pack, format)
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
                -- '""' directly followed by text is the signature of escape
                -- backslashes lost in transit (Discord and most markdown eat
                -- lone backslashes outside code blocks), turning \" into ".
                local hint = text:find('""%a') and
                    ' HINT: a text field contains "" - were escape backslashes (\\") lost'
                    .. ' when the export was shared (e.g. pasted into Discord outside a code block)?'
                    or ""
                return false, "could not parse (JSON: " .. tostring(jsonErr)
                    .. "; TOML: " .. tostring(tomlErr)
                    .. "; Lua: " .. tostring(luaErr) .. ")" .. hint
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
        -- Systems owns all ParchmentSystemDB swaps: SetActive makes the import
        -- active, caches it in the system library, and refreshes open windows.
        ns.Systems.SetActive(clean, "import")
        return true, "imported system '" .. (clean.system_name or "?") .. "'."
    end

    if kind == "feats" or kind == "spells" then
        local clean = StripMeta(data)
        local validate = (kind == "feats") and ns.Schema.ValidateFeatPack
            or ns.Schema.ValidateSpellPack
        -- Cross-references resolve against the active system only when the
        -- pack claims it by name (Packs.PairedSystem) - a pack for another
        -- system must not fail against whatever happens to be loaded.
        local ok, issues = validate(clean, ns.Packs.PairedSystem(clean))
        if not ok then
            return false, ns.Packs.Label(kind) .. " invalid: " .. SummarizeIssues(issues)
        end
        -- A pack library refuses an oversized pack, and a full one refuses new
        -- names (Modules/Packs.lua); Store printed the reason, so report the
        -- import as failed rather than claiming it was stored.
        local activated, stored = ns.Packs.Import(kind, clean, "import")
        if not stored then
            return false, ns.Packs.Label(kind) .. " '" .. clean.pack_name
                .. "' could not be stored - see the chat notice."
        end
        return true, "imported " .. ns.Packs.Label(kind) .. " '" .. clean.pack_name .. "'"
            .. (activated and " (now active)."
                or (" (stored; it pairs with system '" .. tostring(clean.for_system) .. "')."))
    end

    if kind == "item_db" then
        local incoming = StripMeta(data.items)   -- DetectKind proved it is a table
        -- Validate the whole payload BEFORE writing anything, like the roster
        -- path: a half-written library would be worse than refusing outright.
        -- ValidateItemLibrary covers each record's shape AND the id-vs-key
        -- agreement inventories rely on (they resolve references by key).
        local ok, issues = ns.Schema.ValidateItemLibrary(incoming)
        if not ok then return false, "item library invalid: " .. SummarizeIssues(issues) end
        -- MERGE into the existing library (add or overwrite by id) rather than
        -- replacing it, so a paste can never silently drop items the import does
        -- not mention. SetItem bumps each stored item's `version` past the local
        -- copy's: an import IS a local save, and the future item transfer over
        -- comm compares versions to decide whose copy is newer.
        -- Old exports carry equipment +AC as an ac_bonus field; fold it into
        -- the effects list on the way in, the shape the library stores since
        -- the field was retired (mirrors Core's load-time migration).
        local count = 0
        for id, item in pairs(incoming) do
            ns.SetItem(id, ns.Items.MigrateAC(item))
            count = count + 1
        end
        return true, "imported " .. count .. " item(s) into the library."
    end

    -- Validate characters against the active system, or shape-only when none is
    -- loaded yet (so a character can be imported before its system). The active
    -- packs join in the same spirit: absent packs mean shape-only feats/spells.
    local validateSystem = ns.HasSystem() and ns.GetSystem() or nil
    local validatePacks = { feats = ns.GetFeatPack(), spells = ns.GetSpellPack() }

    if kind == "character_db" then
        local incoming = data.characters or {}
        -- Validate every character BEFORE writing anything: a partial import that
        -- committed some and failed others would be worse than refusing outright.
        local count = 0
        for charKey, char in pairs(incoming) do
            if type(charKey) ~= "string" then
                return false, "character key '" .. tostring(charKey) .. "' is not a string."
            end
            local ok, issues = ns.Schema.ValidateCharacter(char, validateSystem, validatePacks)
            if not ok then
                return false, "character '" .. tostring(charKey) .. "' invalid: " .. SummarizeIssues(issues)
            end
            count = count + 1
        end
        -- MERGE into the existing roster (add or overwrite by key) rather than
        -- replacing the whole database: a paste can no longer silently wipe
        -- characters that are not present in the import. Written through
        -- SetCharacter, like every other write, so wire-only inventory fields
        -- are stripped before anything is persisted.
        for charKey, char in pairs(incoming) do
            ns.SetCharacter(charKey, StripMeta(char))
        end
        -- Re-stamp the active pointer onto a key that still exists (GetActiveCharacter
        -- self-heals to the first present character), so it never dangles and an
        -- import into an empty install gains an active character.
        local _, activeKey = ns.GetActiveCharacter()
        if activeKey then ns.SetActiveCharacter(activeKey) end
        return true, "imported " .. count .. " character(s) (merged into your roster)."
    end

    -- Single character.
    local key = data._key
    if not key then return false, "character has no key; add a \"_key\" field." end
    if type(key) ~= "string" then return false, "the \"_key\" field must be a string." end
    local clean = StripMeta(data)
    local ok, issues = ns.Schema.ValidateCharacter(clean, validateSystem, validatePacks)
    if not ok then return false, "character invalid: " .. SummarizeIssues(issues) end

    -- Keys are auto-generated "Character-N", so an export from another install
    -- almost always collides with one of ours. Overwrite only when the existing
    -- entry is the same character (an idempotent re-import); otherwise import
    -- under a fresh key so a shared character can never clobber an unrelated one.
    local existing = ns.GetCharacter(key)
    local remapped = false
    if existing and not SameCharacter(existing, clean) then
        key = ns.NextCharacterKey()
        remapped = true
    end

    ns.SetCharacter(key, clean)
    ns.SetActiveCharacter(key)
    local msg = "imported character '" .. (clean.name or key) .. "'."
    if remapped then msg = msg .. " (added as '" .. key .. "' to avoid overwriting an existing character.)" end
    return true, msg
end
