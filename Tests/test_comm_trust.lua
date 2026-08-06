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

-- INITACK claims to be the DM's verdict on a submitted roll, so it holds the
-- same line: only the recognized DM may put that notice in a player's chat.
local ack = 0
ns.Comm.On("INITACK", function() ack = ack + 1 end)
wire.receive("Parchment", W({ t = "INITACK", v = { ok = true }, ver = "0.1.0" }),
    "WHISPER", "Mallory")
assert(ack == 0, "a non-DM sender's INITACK was dispatched (verdict spoofing)")
wire.receive("Parchment", W({ t = "INITACK", v = { ok = true }, ver = "0.1.0" }),
    "WHISPER", "Alice")
assert(ack == 1, "the recognized DM's INITACK was blocked")

-- Group membership. DMROLE is not authoritative (it is what ESTABLISHES the
-- DM), so on a client that recognizes nobody the first claim wins - which means
-- a stranger whispering one would take the seat. A fresh client with a real
-- roster: only Alice is in the group, Mallory is any other player on the realm.
GetNumGroupMembers = function() return 2 end
UnitExists = function(u) return u == "party1" end
UnitName = function(u)
    if u == "party1" then return "Alice-OtherRealm" end
    return "Me"
end

local ns2, wire2 = boot("0.1.0")
local init2 = 0
ns2.Comm.On("INIT", function() init2 = init2 + 1 end)
assert(ns2.Comm.InGroup("Alice") and ns2.Comm.InGroup("Me"), "group members must pass InGroup")
assert(not ns2.Comm.InGroup("Mallory"), "a player outside the group must fail InGroup")

-- A whispered DMROLE from outside the group must not claim the empty DM seat.
wire2.receive("Parchment", W({ t = "DMROLE", v = {}, ver = "0.1.0" }), "WHISPER", "Mallory")
assert(ns2.Comm.RecognizedDM() == nil, "a stranger's whispered DMROLE became the recognized DM")

-- Nor may a stranger whisper group state directly (the trust gate is wide open
-- while no DM is recognized - membership is what closes it).
wire2.receive("Parchment", W({ t = "INIT", v = { combatants = {} }, ver = "0.1.0" }),
    "WHISPER", "Mallory")
assert(init2 == 0, "a stranger's whispered INIT was dispatched")

-- A real group member still claims the role normally, and is then authoritative.
wire2.receive("Parchment", W({ t = "DMROLE", v = {}, ver = "0.1.0" }), "PARTY", "Alice")
assert(ns2.Comm.SameName(ns2.Comm.RecognizedDM(), "Alice"), "a group member's DMROLE was blocked")
wire2.receive("Parchment", W({ t = "INIT", v = { combatants = {} }, ver = "0.1.0" }),
    "PARTY", "Alice")
assert(init2 == 1, "the recognized DM's INIT was blocked by the membership gate")

-- Without the roster APIs the gate cannot decide and stays lenient (documented
-- test-only leniency). Clearing them also keeps them out of the files that run
-- after this one, which boot Comm without a roster of their own.
GetNumGroupMembers, UnitExists = nil, nil
UnitName = function() return "Me" end
assert(ns2.Comm.InGroup("Mallory"), "an unknown roster must not block anyone")
