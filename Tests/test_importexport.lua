-- Phase 4: a full-roster (character_db) import MERGES into the existing roster
-- instead of replacing it, so a paste can never silently wipe characters not
-- present in the import; the active-character pointer stays valid afterward.
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
