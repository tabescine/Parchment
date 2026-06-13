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

-- A single bad character refuses the whole import (no partial write).
ns.Schema.ValidateCharacter = function(c) return c.name ~= "Bad", { "bad" } end
local before = roster.Zara
ok = IE.Import([[{"characters": {"Good": {"name":"Good"}, "Bad": {"name":"Bad"}}}]])
assert(not ok, "an invalid member must refuse the whole import")
assert(roster.Good == nil and roster.Zara == before, "a refused import must write nothing")
