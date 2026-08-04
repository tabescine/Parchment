-- Phase 4: a full-roster (character_db) import MERGES into the existing roster
-- instead of replacing it, so a paste can never silently wipe characters not
-- present in the import; the active-character pointer stays valid afterward.
-- The tail of the file covers the item library travelling the same paste flow:
-- detection, merge-by-id, refuse-on-any-issue, and the export round-trip.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
strtrim = function(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

local ns = {}
T.load(ns, "JSON.lua")
T.load(ns, "TOML.lua")
ns.Schema = {
    ValidateCharacter = function() return true end,
    ValidateSystem = function() return true end,
}

-- An in-memory roster + active pointer behind the ns data API.
local roster, active, dbReplaced = {}, nil, false
ns.GetCharacters = function() return roster end
ns.GetCharacter = function(k) return roster[k] end
ns.SetCharacter = function(k, c) roster[k] = c end
ns.SetCharacterDB = function() dbReplaced = true end   -- merge must NOT call this
ns.GetActiveCharacter = function()
    if active and roster[active] then return roster[active], active end
    local k = next(roster)
    return roster[k], k
end
ns.SetActiveCharacter = function(k)
    if roster[k] then active = k; return true end
    return false
end
ns.NextCharacterKey = function()
    local n = 0
    repeat n = n + 1 until not roster["Character-" .. n]
    return "Character-" .. n
end
ns.HasSystem = function() return false end
ns.GetSystem = function() return {} end
ns.Systems = { SetActive = function() end }
ns.GetFeatPack = function() return nil end
ns.GetSpellPack = function() return nil end
ns.Packs = {
    Label = function(kind) return kind .. " pack" end,
    PairedSystem = function() return nil end,
    Import = function() return true end,
}

-- An in-memory item library behind the ns data API, with Core's SetItem
-- semantics (stamp the key onto `id`, bump `version` past the stored copy's).
local library = {}
ns.GetItemLibrary = function() return library end
ns.SetItem = function(id, item)
    if type(id) ~= "string" or type(item) ~= "table" then return nil end
    local previous = library[id]
    item.id = id
    item.version = (tonumber(type(previous) == "table" and previous.version) or 0) + 1
    library[id] = item
    return item
end

-- Items are validated for real (the stubs above only stand in for the
-- character/system validators, which have their own test file).
do
    local schemaNs = {}
    T.load(schemaNs, "Schema.lua")
    ns.Schema.ValidateItemLibrary = schemaNs.Schema.ValidateItemLibrary
end

T.load(ns, "Modules/ImportExport.lua")
local IE = ns.ImportExport

-- Seed an existing roster; Bob is active.
roster.Bob = { name = "Bob", level = 1 }
roster.Alice = { name = "Alice", level = 2 }
active = "Bob"

-- Import a DB that updates Alice and adds Carol. Bob (absent from the import)
-- must survive, Alice is overwritten by key, Carol is added, and the merge must
-- not replace the whole database.
local ok, msg = IE.Import(
    [[{"characters": {"Alice": {"name":"Alice2","level":3}, "Carol": {"name":"Carol","level":1}}}]])
assert(ok, tostring(msg))
assert(not dbReplaced, "character_db import must merge, not replace the whole DB")
assert(roster.Bob, "merge must not wipe characters absent from the import")
assert(roster.Carol, "merge must add new characters")
assert(roster.Alice.name == "Alice2", "merge must overwrite an existing key")
assert(active == "Bob", "the active pointer must be preserved through a merge")

-- Importing into an empty install gains an active character (the self-healing
-- pointer lands on a present key).
for k in pairs(roster) do roster[k] = nil end
active = nil
ok, msg = IE.Import([[{"characters": {"Zara": {"name":"Zara","level":1}}}]])
assert(ok, tostring(msg))
assert(active == "Zara", "import into an empty install should set an active character")

-- StripMeta is recursive: '_'-prefixed metadata is removed at every depth, not
-- just the top level, before a character reaches storage.
ok = IE.Import([[
  {"characters": {"Meta": {"name":"Meta", "_key":"ignored",
    "nested": {"keep": 1, "_hidden": 2, "deep": {"_x": 9, "ok": 3}}}}}
]])
assert(ok, tostring(msg))
local m = roster.Meta
assert(m and m._key == nil, "top-level _meta must be stripped")
assert(m.nested.keep == 1 and m.nested._hidden == nil, "nested _meta must be stripped")
assert(m.nested.deep._x == nil and m.nested.deep.ok == 3, "deeply nested _meta must be stripped")

-- A single bad character refuses the whole import (no partial write).
ns.Schema.ValidateCharacter = function(c) return c.name ~= "Bad", { "bad" } end
local before = roster.Zara
ok = IE.Import([[{"characters": {"Good": {"name":"Good"}, "Bad": {"name":"Bad"}}}]])
assert(not ok, "an invalid member must refuse the whole import")
assert(roster.Good == nil and roster.Zara == before, "a refused import must write nothing")

ns.Schema.ValidateCharacter = function() return true end

-- A `characters` field that is not a table must fail cleanly, not throw from
-- pairs() on a scalar (empty-states-never-errors on the import path).
ok, msg = IE.Import([[{"characters": 5}]])
assert(not ok and msg and msg:find("could not tell"), "a scalar characters field must refuse cleanly")

-- A character_db with a non-string roster key (only reachable via the Lua-literal
-- path) is refused rather than persisting a boolean/number-keyed entry.
ok, msg = IE.Import("{ characters = { [true] = { name = 'X', level = 1 } } }")
assert(not ok and msg and msg:find("not a string"), "a non-string roster key must be refused")

-- Single-character import must not clobber an unrelated existing character on a
-- key collision: auto-generated "Character-N" keys collide across installs.
for k in pairs(roster) do roster[k] = nil end
active = nil
roster["Character-1"] = { name = "Mine", level = 5 }
ok, msg = IE.Import([[{"_key":"Character-1", "name":"Yours", "level":1, "attributes":{}}]])
assert(ok, tostring(msg))
assert(roster["Character-1"].name == "Mine", "an unrelated character must not be overwritten")
local imported
for k, c in pairs(roster) do if c.name == "Yours" then imported = k end end
assert(imported and imported ~= "Character-1", "the colliding import must land on a fresh key")
assert(msg:find("avoid overwriting"), "the remap should be reported to the user")

-- Re-importing the SAME character (same key, same name) is an idempotent update,
-- not a collision - it overwrites in place rather than spawning a duplicate.
local n0 = 0; for _ in pairs(roster) do n0 = n0 + 1 end
ok, msg = IE.Import([[{"_key":"Character-1", "name":"Mine", "level":9, "attributes":{}}]])
assert(ok, tostring(msg))
local n1 = 0; for _ in pairs(roster) do n1 = n1 + 1 end
assert(n1 == n0, "an idempotent re-import must not add a row")
assert(roster["Character-1"].level == 9, "an idempotent re-import must update in place")

-- A non-string single-character _key is refused.
ok, msg = IE.Import("{ _key = true, name = 'X', level = 1, attributes = {} }")
assert(not ok and msg and msg:find("must be a string"), "a non-string _key must be refused")

-- Item library.

-- Copies every record so a library can be compared before and after an import.
-- Recursive: an equippable item's `effects` list is a table of tables, and a
-- snapshot that aliased it could not show an import writing through it.
local function copyItem(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copyItem(v) end
    return out
end

local function copyLib(lib)
    local out = {}
    for id, item in pairs(lib) do out[id] = copyItem(item) end
    return out
end

-- copyLib without `version`: every save bumps it, so a round-trip comparison
-- ignores it and the bump is asserted on its own.
local function copyLibBare(lib)
    local out = copyLib(lib)
    for _, item in pairs(out) do item.version = nil end
    return out
end

-- An empty library exports as a clean error, not an empty document.
local str, err = IE.ExportItems("json")
assert(str == nil and err and err:find("no items"), "an empty library must refuse to export")

-- Seed one item of each kind, exercising every optional field. Both equippable
-- kinds carry effects (gear may not), so the round-trip below covers a nested
-- list of records, its optional target keys, and a per_level boolean - the only
-- boolean an item record has.
library.itm_1 = { id = "itm_1", name = "Hunter's Bow", kind = "weapon",
    description = "Ash and sinew.", icon = "inv_weapon_bow_08",
    weapon_id = "bow", bonus = 1, version = 3,
    effects = { { type = "skill", skill = "survival", value = 1, add_modifier = "sen" } } }
library.itm_2 = { id = "itm_2", name = "Traveller's Leathers", kind = "equipment",
    description = "Oiled against the weather.", icon = "inv_chest_leather_09",
    ac_bonus = 1, version = 1,
    effects = {
        { type = "attribute", id = "agi", value = 1 },
        { type = "max_hp", value = 1, per_level = true },
    } }
library.itm_3 = { id = "itm_3", name = "Arrows", kind = "gear",
    icon = "inv_misc_ammo_arrow_01", default_count = 20, version = 1 }

-- Export -> wipe -> import restores every field, in both formats.
for _, format in ipairs({ "json", "toml" }) do
    local roundBefore = copyLibBare(library)
    local text = assert(IE.ExportItems(format))
    for id in pairs(library) do library[id] = nil end
    ok, msg = IE.Import(text)
    assert(ok, tostring(msg))
    assert(msg:find("3 item"), "the import should report how many items landed: " .. msg)
    T.assert_deepeq(roundBefore, copyLibBare(library), format .. " item round-trip")
    -- Spelled out as well as deep-compared: a boolean silently arriving as the
    -- string "true" would still make the record "an item with effects".
    local perLevel = library.itm_2.effects[2].per_level
    assert(perLevel == true, format .. " must round-trip per_level as a boolean, got "
        .. type(perLevel) .. " " .. tostring(perLevel))
    for id, item in pairs(library) do
        assert(item.id == id, "every stored item must carry its own key as `id`")
        assert(item.version == 1, "an import into an empty library starts the version at 1")
    end
end

-- MERGE by id: the incoming item overwrites its own entry and leaves the others
-- untouched, and the save bumps its version past the local copy's.
ok, msg = IE.Import(
    [[{"items": {"itm_2": {"id":"itm_2", "name":"Scale Mail", "kind":"equipment", "ac_bonus":3}}}]])
assert(ok, tostring(msg))
assert(library.itm_2.name == "Scale Mail" and library.itm_2.ac_bonus == 3,
    "an item import must overwrite by id")
assert(library.itm_2.description == nil, "overwriting replaces the record, it does not patch it")
assert(library.itm_2.version == 2, "an import is a local save: the version must move forward")
assert(library.itm_1 and library.itm_3 and library.itm_3.name == "Arrows",
    "an item import must never wipe items the paste does not mention")

-- Malformed payloads are refused WHOLESALE (the character-DB house rule): a
-- partially imported library would be worse than a refusal, so the valid
-- sibling in each paste must not land either.
local libBefore = copyLib(library)
local malformed = {
    { [[{"items": {"itm_9": {"id":"itm_9", "name":"Potion", "kind":"potion"}}}]], "unknown kind" },
    { [[{"items": {"itm_9": {"id":"itm_9", "name":"]] .. string.rep("x", 65)
        .. [[", "kind":"gear"}}}]], "longer than" },
    { [[{"items": {"itm_9": {"id":"itm_8", "name":"Wrong key", "kind":"gear"}}}]],
      "does not match its key" },
    { [[{"items": {"itm_9": {"id":"itm_9", "name":"Good", "kind":"gear"},
         "itm_10": {"id":"itm_10", "kind":"gear"}}}]], "should be string" },
}
for _, case in ipairs(malformed) do
    ok, msg = IE.Import(case[1])
    assert(not ok, "a malformed item library must be refused: " .. case[1])
    assert(msg:find(case[2], 1, true), "expected '" .. case[2] .. "', got: " .. msg)
    T.assert_deepeq(libBefore, copyLib(library), "a refused item import must write nothing")
end

-- Detection: `items` marks a library only on a payload that is nothing else, so
-- a system or roster carrying a field of that name is still what it says it is.
local itemsField = [[, "items": {"itm_9": {"id":"itm_9", "name":"Sneak", "kind":"gear"}}}]]
ok, msg = IE.Import([[{"system_name": "S"]] .. itemsField)
assert(ok and msg:find("system"), "a system with an items field must import as a system: " .. msg)
ok, msg = IE.Import([[{"characters": {"Ivy": {"name":"Ivy", "level":1}}]] .. itemsField)
assert(ok and msg:find("character"), "a roster with an items field must import as a roster")
ok, msg = IE.Import([[{"_key":"ivy", "name":"Ivy", "level":1, "attributes":{}]] .. itemsField)
assert(ok and msg:find("character"), "a character with an items field must import as a character")
T.assert_deepeq(libBefore, copyLib(library), "only an item-library paste may touch the library")

-- StripMeta applies to items too: converter/export metadata never reaches the
-- library, and a `_note` alone does not stop the payload being a library.
ok, msg = IE.Import([[{"_note": "hi",
    "items": {"itm_9": {"id":"itm_9", "name":"Rope", "kind":"gear", "_src":"paste"}}}]])
assert(ok, tostring(msg))
assert(library.itm_9 and library.itm_9._src == nil, "item metadata must be stripped on import")
