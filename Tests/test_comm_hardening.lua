-- Phase 2: the inbound edge hardened centrally in Comm.OnReceive - one shared
-- name normalizer, own-echo filtering, a fully pcall-guarded decode, per-sender
-- + per-type rate limiting, and roster-change pruning of per-sender state.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")

UnitName = function() return "Me" end
IsInRaid = function() return false end
IsInGroup = function() return true end
local NOW = 0
GetTime = function() return NOW end

local codec = {}
T.load(codec, "JSON.lua")
local JSON = codec.JSON
local function W(env) return "0" .. JSON.encode(env) end

-- Boots Comm with stubbed Ace plumbing; captures the receive callback and any
-- events registered, and a Deserialize that THROWS for the body "boom".
local function boot()
    GetAddOnMetadata = function() return "0.1.0" end
    C_AddOns = nil
    local ns = {}
    local printed = {}
    ns.Print = function(m) printed[#printed + 1] = m end
    local wire = { events = {} }
    ns.Addon = {
        db = { profile = {} },
        Serialize = function(_, t) return JSON.encode(t) end,
        Deserialize = function(_, d)
            if d == "boom" then error("deserialize blew up") end
            local ok, v = pcall(JSON.decode, d)
            if ok then return true, v end
            return false
        end,
        SendCommMessage = function() end,
        RegisterComm = function(_, _, cb) wire.receive = cb end,
        RegisterEvent = function(_, ev, cb) wire.events[ev] = cb end,
    }
    T.load(ns, "Modules/Comm.lua")
    ns.Comm.Init()
    assert(wire.receive, "OnReceive not registered")
    return ns, wire, printed
end

local ns, wire, printed = boot()

-- One shared normalizer, realm- and case-tolerant; nil for empty input.
assert(ns.Comm.NormalizeName("Bob-Realm") == "bob" and ns.Comm.NormalizeName("BOB") == "bob")
assert(ns.Comm.NormalizeName("") == nil and ns.Comm.NormalizeName(nil) == nil)
assert(ns.Comm.SameName("Bob", "bob-Realm") and not ns.Comm.SameName("Bob", "Alice"))

-- Central self-echo filter: our own GROUP broadcast is dropped before dispatch;
-- a self-WHISPER (which may legitimately target us, e.g. the self sheet view) is
-- still delivered.
local sys = 0
ns.Comm.On("SYSTEM", function() sys = sys + 1 end)
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "0.1.0" }), "PARTY", "Me")
assert(sys == 0, "our own group echo must be filtered centrally")
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "0.1.0" }), "WHISPER", "Me")
assert(sys == 1, "a self-whisper must still be delivered")

-- Per-sender + per-type rate limit: a second SYSTEM from a sender inside the
-- interval is dropped; after the interval it is accepted; a different sender is
-- tracked independently.
local cnt = 0
ns.Comm.On("SYSTEM", function() cnt = cnt + 1 end)
NOW = 0
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "0.1.0" }), "PARTY", "Alice")
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "0.1.0" }), "PARTY", "Alice")
assert(cnt == 1, "a second SYSTEM within the interval must be rate-limited")
NOW = 5
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "0.1.0" }), "PARTY", "Alice")
assert(cnt == 2, "after the interval the next SYSTEM is accepted")
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "0.1.0" }), "PARTY", "Carol")
assert(cnt == 3, "the rate limit must be keyed per sender")

-- The amplifier types are rate-limited too. A REQ is ~20 bytes in and up to a
-- ~100 KB serialized, compressed sheet out; a DMROLE prints, shows a popup and
-- (when we are the DM) whispers a counter-claim per claim - a flood the sender
-- would otherwise reflect off us at their own rate.
local reqs, claims = 0, 0
ns.Comm.On("REQ", function() reqs = reqs + 1 end)
ns.Comm.On("DMROLE", function() claims = claims + 1 end)
NOW = 100
wire.receive("Parchment", W({ t = "REQ", v = {}, ver = "0.1.0" }), "WHISPER", "Alice")
wire.receive("Parchment", W({ t = "REQ", v = {}, ver = "0.1.0" }), "WHISPER", "Alice")
assert(reqs == 1, "a second REQ within the interval must be rate-limited")
NOW = 110
wire.receive("Parchment", W({ t = "REQ", v = {}, ver = "0.1.0" }), "WHISPER", "Alice")
assert(reqs == 2, "after the interval the next REQ is accepted")
wire.receive("Parchment", W({ t = "DMROLE", v = {}, ver = "0.1.0" }), "PARTY", "Alice")
wire.receive("Parchment", W({ t = "DMROLE", v = {}, ver = "0.1.0" }), "PARTY", "Alice")
assert(claims == 1, "a second DMROLE within the interval must be rate-limited")
NOW = 130
wire.receive("Parchment", W({ t = "DMROLE", v = {}, ver = "0.1.0" }), "PARTY", "Alice")
assert(claims == 2, "after the interval the next DMROLE is accepted")

-- A type with no configured interval is never rate-limited.
local pings = 0
ns.Comm.On("PING", function() pings = pings + 1 end)
wire.receive("Parchment", W({ t = "PING", v = {}, ver = "0.1.0" }), "PARTY", "Alice")
wire.receive("Parchment", W({ t = "PING", v = {}, ver = "0.1.0" }), "PARTY", "Alice")
assert(pings == 2, "an unlisted type must not be rate-limited")

-- The decode chain is fully guarded: a body that makes the deserializer throw is
-- a quiet drop, never an error propagated out of AceComm's dispatch.
local ok = pcall(wire.receive, "Parchment", "0boom", "PARTY", "Alice")
assert(ok, "a throwing decode must be swallowed, not propagated")

-- Roster prune: a version-mismatch warning fires once per session, but a peer no
-- longer in the group is forgotten on a roster change so it can be warned again
-- (and the bookkeeping cannot grow unbounded).
GetNumGroupMembers = function() return 1 end
UnitExists = function(u) return u == "party1" end
UnitName = function(u)
    if u == "player" then return "Me" end
    if u == "party1" then return "Friend" end
    return nil
end
-- With a roster available, membership is checkable: Friend is in the party,
-- Ghost is not.
assert(ns.Comm.InGroup("Friend") and ns.Comm.InGroup("Me-Realm"), "group members must pass")
assert(not ns.Comm.InGroup("Ghost"), "a non-member must not pass the membership gate")

-- The party vitals cache is keyed by sender too, so the roster prune hands
-- Party the set of names still in the group (guarded - Party may not be loaded).
local pruned
ns.Party = { PruneDeparted = function(keep) pruned = keep end }

local base = #printed
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "9.9.9" }), "PARTY", "Ghost")
assert(#printed == base + 1, "a first version mismatch should warn")
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "9.9.9" }), "PARTY", "Ghost")
assert(#printed == base + 1, "a repeat mismatch is throttled within the session")
assert(wire.events.GROUP_ROSTER_UPDATE, "the roster prune was not registered")
wire.events.GROUP_ROSTER_UPDATE()
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "9.9.9" }), "PARTY", "Ghost")
assert(#printed == base + 2, "a departed peer can be warned again after pruning")
assert(pruned and pruned.friend and pruned.me, "the roster prune must reach Party's vitals cache")
assert(not pruned.ghost, "a departed sender must not be in the keep set")

-- Leave the roster APIs as the later test files expect to find them (absent):
-- every file installs the globals it needs itself.
GetNumGroupMembers, UnitExists = nil, nil
UnitName = function() return "Me" end
