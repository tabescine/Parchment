-- Phase 2: the shared-sheet cache is bounded before it reaches SavedVariables -
-- an unsolicited or malformed sheet is dropped, an oversized sheet is refused,
-- and the cache caps its entry count, evicting the oldest by time. Inbound CHAR
-- validation runs through the REAL Schema (not a stub), so the wire path proves
-- it holds the same validation line as the local import path.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")

Menu = nil                                  -- skip the right-click menu registration
StaticPopupDialogs = {}                       -- Sharing registers a remove-cached confirm
StaticPopup_Show = function() end
CANCEL, DELETE = "Cancel", "Delete"
UnitName = function() return "Me" end
IsInGroup = function() return false end      -- so requests whisper (no group scan)
IsInRaid = function() return false end
GetTime = function() return 1 end
local CLOCK = 0
time = function() return CLOCK end           -- entry timestamps (eviction key)
C_Timer = { After = function() end }         -- request-timeout no-op

local ns = {}
ns.Print = function() end
T.load(ns, "Schema.lua")   -- the real validator: the comm path must hold the import path's line
T.load(ns, "JSON.lua")
local handlers = {}
ns.Comm = {
    On = function(t, fn) handlers[t] = fn end,
    NormalizeName = function(n) return n and (tostring(n):match("^[^-]+") or n):lower() or nil end,
    SameName = function(a, b)
        if not a or not b then return false end
        return (tostring(a):match("^[^-]+") or a):lower() == (tostring(b):match("^[^-]+") or b):lower()
    end,
    IsSelf = function(s) return ns.Comm.SameName(s, "Me") end,
    Send = function() return true end,
    Whisper = function() return true end,
}
ns.Addon = { db = { global = {} } }
ns.GetActiveCharacter = function() return { name = "Me" } end
T.load(ns, "Modules/Sharing.lua")
local S = ns.Sharing
assert(handlers.CHAR and handlers.REQ, "comm handlers not registered")

-- Records the panel re-rendered when a sheet arrives (so its "cached N ago" line
-- reflects a refetch, not the stale copy).
local hubRefreshed
ns.HubUI = { RefreshIfShown = function(panel) hubRefreshed = panel end }

-- A schema-valid character shape (CHAR_REQUIRED: name, level, attributes).
local function validChar(name, extra)
    local c = { name = name, level = 1, attributes = {} }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

-- Seeds a pending request for `sender`, then delivers their CHAR reply.
local function deliver(sender, char)
    CLOCK = CLOCK + 1
    S.Request(sender)
    handlers.CHAR({ char = char, to = "Me" }, sender)
end

-- An UNSOLICITED sheet (no pending request to that sender) is dropped: the
-- pendingKey guard is what stops any peer from pushing sheets into the
-- persistent cache at will.
handlers.CHAR({ char = validChar("Intruder"), to = "Me" }, "Intruder")
assert(S.GetCache()["Intruder"] == nil, "an unsolicited sheet must be dropped")

-- A normal sheet is cached, and receiving it re-renders the Cached Sheets panel.
deliver("Bob", validChar("Bob"))
assert(S.GetCache()["Bob"], "a valid sheet should be cached")
assert(hubRefreshed == "cached", "receiving a sheet must refresh the cached panel")

-- A malformed sheet (fails the real shape validation - no level/attributes)
-- is refused even though it was requested.
deliver("Eve", { name = "Eve" })
assert(S.GetCache()["Eve"] == nil, "a schema-invalid sheet must be refused")

-- A non-finite numeric field is a shape error too (Schema finiteness check).
deliver("Nan", validChar("Nan", { level = 1 / 0 }))
assert(S.GetCache()["Nan"] == nil, "a non-finite level must be refused")

-- An oversized sheet is refused before it touches the saved cache.
deliver("Hugo", validChar("Hugo", { blob = string.rep("x", 300 * 1024) }))
assert(S.GetCache()["Hugo"] == nil, "an oversized sheet must be refused")

-- The cache caps its entry count, evicting the oldest by time. Bob is the oldest
-- entry, so filling past the cap must drop it while keeping the newest.
for i = 1, 51 do deliver("P" .. i, validChar("P" .. i)) end
local n = 0
for _ in pairs(S.GetCache()) do n = n + 1 end
assert(n == 50, "the cache must cap at MAX_ENTRIES, got " .. n)
assert(S.GetCache()["Bob"] == nil, "the oldest entry must be evicted")
assert(S.GetCache()["P51"], "the newest entry must remain")

-- Per-entry removal drops exactly one entry by its exact key.
assert(S.RemoveCached("P51") == true, "removing a present key should report success")
assert(S.GetCache()["P51"] == nil, "the removed entry must be gone")
assert(S.GetCache()["P50"], "removal must not touch other entries")
assert(S.RemoveCached("P51") == false, "removing an absent key should report no-op")
local m = 0
for _ in pairs(S.GetCache()) do m = m + 1 end
assert(m == 49, "exactly one entry should have been removed, have " .. m)
