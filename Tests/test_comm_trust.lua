-- Phase 0 (test-first): the comm trust model. These cases are EXPECTED TO FAIL
-- until Phase 1 ("Trust model") lands - today OnReceive dispatches every typed
-- message regardless of who sent it, so any group member can spoof the DM's
-- authoritative broadcasts (audit Networking CRITICAL: Comm.lua:182-192 +
-- InitiativeUI.lua:669-676).
--
-- The contract pinned here: a client recognizes the FIRST claimant as DM, and
-- thereafter applies DM-authoritative messages (INIT, SYSTEM) only from that
-- recognized sender. Messages of those types from anyone else are dropped
-- before they reach a handler. The gate is expected to live centrally in
-- OnReceive (or a Comm.IsAuthoritative(sender) the dispatch consults).
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")

UnitName = function() return "Me" end
IsInRaid = function() return false end
IsInGroup = function() return true end

-- A real, reversible codec for the Serialize/Deserialize stubs (mirrors
-- test_comm.lua): the addon's own JSON round-trips the envelopes.
local codec = {}
T.load(codec, "JSON.lua")
local JSON = codec.JSON

-- Builds an inbound wire string the way a peer without LibDeflate would: the
-- "0" raw marker, then the serialized envelope.
local function W(env) return "0" .. JSON.encode(env) end

-- Boots Comm at the given version with stubbed Ace plumbing; returns ns plus the
-- captured receive callback.
local function boot(version)
    GetAddOnMetadata = function() return version end
    C_AddOns = nil
    local ns = {}
    ns.Print = function() end
    local wire = {}
    ns.Addon = {
        db = { profile = {} },
        Serialize = function(_, t) return JSON.encode(t) end,
        Deserialize = function(_, d)
            local ok, v = pcall(JSON.decode, d)
            if ok then return true, v end
            return false
        end,
        SendCommMessage = function() end,
        RegisterComm = function(_, _, cb) wire.receive = cb end,
    }
    T.load(ns, "Modules/Comm.lua")
    ns.Comm.Init()
    assert(wire.receive, "OnReceive not registered")
    return ns, wire
end

local ns, wire = boot("0.1.0")

-- Count dispatches per authoritative type through real registered handlers.
local sys, init = 0, 0
ns.Comm.On("SYSTEM", function() sys = sys + 1 end)
ns.Comm.On("INIT", function() init = init + 1 end)

-- First claim wins: receiving Alice's DMROLE while recognizing nobody makes her
-- this client's recognized DM. (No popup in the common case.)
wire.receive("Parchment", W({ t = "DMROLE", v = {}, ver = "0.1.0" }), "PARTY", "Alice")

-- The recognized DM's authoritative messages are applied.
wire.receive("Parchment", W({ t = "SYSTEM", v = { system_name = "S" }, ver = "0.1.0" }),
    "PARTY", "Alice")
wire.receive("Parchment", W({ t = "INIT", v = { combatants = {} }, ver = "0.1.0" }),
    "PARTY", "Alice")
assert(sys == 1, "the recognized DM's SYSTEM was not applied")
assert(init == 1, "the recognized DM's INIT was not applied")

-- The core fix: the SAME messages from a different sender (who is NOT the
-- recognized DM) must be dropped before reaching the handler. A non-DM player
-- cannot push a fake system or initiative state onto the group.
wire.receive("Parchment", W({ t = "SYSTEM", v = { system_name = "EVIL" }, ver = "0.1.0" }),
    "PARTY", "Mallory")
wire.receive("Parchment", W({ t = "INIT", v = { combatants = {} }, ver = "0.1.0" }),
    "PARTY", "Mallory")
assert(sys == 1, "a non-DM sender's SYSTEM was applied (DM-broadcast spoofing)")
assert(init == 1, "a non-DM sender's INIT was applied (initiative spoofing)")

-- A second claimant does NOT silently steal recognition: Mallory broadcasting
-- DMROLE while Alice is recognized must not make Mallory authoritative. (Switch
-- is an explicit user choice; the non-destructive default keeps the current DM.)
wire.receive("Parchment", W({ t = "DMROLE", v = {}, ver = "0.1.0" }), "PARTY", "Mallory")
wire.receive("Parchment", W({ t = "SYSTEM", v = { system_name = "EVIL2" }, ver = "0.1.0" }),
    "PARTY", "Mallory")
assert(sys == 1, "a rival DMROLE claim silently transferred authority to the claimant")
