-- Phase 2: the shared-sheet cache is bounded before it reaches SavedVariables -
-- an oversized sheet is refused, and the cache caps its entry count, evicting
-- the oldest by time.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")

Menu = nil                                  -- skip the right-click menu registration
UnitName = function() return "Me" end
IsInGroup = function() return false end      -- so requests whisper (no group scan)
IsInRaid = function() return false end
GetTime = function() return 1 end
local CLOCK = 0
time = function() return CLOCK end           -- entry timestamps (eviction key)
C_Timer = { After = function() end }         -- request-timeout no-op

local ns = {}
ns.Print = function() end
ns.Schema = { ValidateCharacter = function() return true end }
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

-- Seeds a pending request for `sender`, then delivers their CHAR reply.
local function deliver(sender, char)
    CLOCK = CLOCK + 1
    S.Request(sender)
    handlers.CHAR({ char = char, to = "Me" }, sender)
end

-- A normal sheet is cached.
deliver("Bob", { name = "Bob", level = 1 })
assert(S.GetCache()["Bob"], "a valid sheet should be cached")

-- An oversized sheet is refused before it touches the saved cache.
deliver("Hugo", { name = "Hugo", blob = string.rep("x", 300 * 1024) })
assert(S.GetCache()["Hugo"] == nil, "an oversized sheet must be refused")

-- The cache caps its entry count, evicting the oldest by time. Bob is the oldest
-- entry, so filling past the cap must drop it while keeping the newest.
for i = 1, 51 do deliver("P" .. i, { name = "P" .. i }) end
local n = 0
for _ in pairs(S.GetCache()) do n = n + 1 end
assert(n == 50, "the cache must cap at MAX_ENTRIES, got " .. n)
assert(S.GetCache()["Bob"] == nil, "the oldest entry must be evicted")
assert(S.GetCache()["P51"], "the newest entry must remain")
