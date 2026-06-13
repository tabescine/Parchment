-- Comm.lua: envelope version stamping, the sync-compatibility gate, and the
-- wire codec (marker byte + optional compression), driven through the real
-- send/receive path with stubbed Ace plumbing. LibDeflate is absent here, so
-- Encode takes the uncompressed "0" path - the marker round-trip is still
-- exercised; the compression branch is covered by test_comm_compress below.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")

UnitName = function() return "Me" end
IsInRaid = function() return false end
IsInGroup = function() return true end

-- A real, reversible string codec for the Serialize/Deserialize stubs (the old
-- identity pass-through cannot survive the marker-prefixed wire format). The
-- addon's own JSON codec is dependency-free and round-trips these envelopes.
local codec = {}
T.load(codec, "JSON.lua")
local JSON = codec.JSON

-- Builds an inbound wire string the way a peer (without LibDeflate) would: the
-- "0" marker for "raw serialized", then the serialized envelope.
local function W(env) return "0" .. JSON.encode(env) end

-- Loads Comm as the given local version; returns ns plus the captured wire.
local function boot(version)
    GetAddOnMetadata = function() return version end
    C_AddOns = nil
    local ns = {}
    local printed = {}
    ns.Print = function(msg) printed[#printed + 1] = msg end
    local wire = {}
    ns.Addon = {
        db = { profile = {} },
        Serialize = function(_, t) return JSON.encode(t) end,
        Deserialize = function(_, d)
            local ok, v = pcall(JSON.decode, d)
            if ok then return true, v end
            return false
        end,
        SendCommMessage = function(_, _, data, channel, target)
            wire.sent, wire.channel, wire.target = data, channel, target
            wire.count = (wire.count or 0) + 1
        end,
        RegisterComm = function(_, _, cb) wire.receive = cb end,
    }
    T.load(ns, "Modules/Comm.lua")
    ns.Comm.Init()
    assert(wire.receive, "OnReceive not registered")
    -- Decodes the last outbound message back to its envelope (strips the marker).
    wire.env = function() return JSON.decode(wire.sent:sub(2)) end
    return ns, wire, printed
end

local ns, wire, printed = boot("0.1.0")
local got = {}
ns.Comm.On("SYSTEM", function(payload, sender) got[#got + 1] = { payload, sender } end)

-- Sends are stamped, ride the marker codec, and decode + dispatch on receipt.
assert(ns.Comm.Send("SYSTEM", { x = 1 }))
assert(wire.sent:sub(1, 1) == "0", "outbound message is not marker-tagged")
assert(wire.env().ver == "0.1.0", "Send did not stamp the version")
wire.receive("Parchment", wire.sent, "PARTY", "Alice")
assert(#got == 1 and got[1][1].x == 1)
assert(ns.Comm.Whisper("SYSTEM", {}, "Bob") and wire.env().ver == "0.1.0", "Whisper did not stamp")

-- Patch drift syncs; minor drift at major 0 does not.
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "0.1.9" }), "PARTY", "Bob")
assert(#got == 2, "patch difference wrongly blocked")
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "0.2.0" }), "PARTY", "Carol")
assert(#got == 2, "0.2 vs 0.1 not blocked")
assert(#printed == 1 and printed[1]:find("Carol") and printed[1]:find("Update your Parchment"),
    printed[1] or "no mismatch warning")

-- One warning per sender per session.
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "0.2.0" }), "PARTY", "Carol")
assert(#printed == 1, "mismatch warning not throttled")

-- An older sender is told to update instead.
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "0.0.9" }), "PARTY", "Dave")
assert(#printed == 2 and printed[2]:find("They need to update"), printed[2] or "no warning")

-- Versionless (pre-gating) and major-mismatched envelopes are dropped.
wire.receive("Parchment", W({ t = "SYSTEM", v = {} }), "PARTY", "Eve")
wire.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "1.0.0" }), "PARTY", "Frank")
assert(#got == 2)

-- Wrong prefix, a foreign marker, and a truncated body are ignored without
-- errors (Decode returns false for anything it cannot read).
wire.receive("OtherAddon", W({ t = "SYSTEM", v = {}, ver = "0.1.0" }), "PARTY", "Gail")
wire.receive("Parchment", "not-a-marked-message", "PARTY", "Gail")
wire.receive("Parchment", "0", "PARTY", "Gail")
assert(#got == 2)

-- IsSelf handles plain and realm-qualified names.
assert(ns.Comm.IsSelf("Me") and ns.Comm.IsSelf("Me-SomeRealm"))
assert(not ns.Comm.IsSelf("You") and not ns.Comm.IsSelf(nil))

-- DM role: claiming announces once; clashing DMs warn each other without
-- ping-ponging.
local prevCount = wire.count
ns.Comm.SetDM(true)
assert(wire.env().t == "DMROLE" and wire.count == prevCount + 1, "no DMROLE announce")
ns.Comm.SetDM(true)
assert(wire.count == prevCount + 1, "re-claiming the role must not re-announce")
ns.Comm.SetDM(false)
assert(wire.env().t == "RELEASE" and wire.count == prevCount + 2,
    "stepping down must broadcast a RELEASE so peers clear recognition")

-- As a non-DM: an announce prints info, no reply goes out.
prevCount = wire.count
local printedBefore = #printed
wire.receive("Parchment", W({ t = "DMROLE", v = {}, ver = "0.1.0" }), "PARTY", "Olga")
assert(#printed == printedBefore + 1 and printed[#printed]:find("Olga"), "no info line")
assert(wire.count == prevCount, "non-DM must not reply to DMROLE")

-- As an active DM: warn AND whisper our claim back to the newcomer.
ns.Addon.db.profile.dm = true
printedBefore = #printed
wire.receive("Parchment", W({ t = "DMROLE", v = {}, ver = "0.1.0" }), "PARTY", "Pete")
assert(#printed == printedBefore + 2 and printed[#printed]:find("also have DM mode"), "no clash warning")
assert(wire.count == prevCount + 1 and wire.env().t == "DMROLE"
    and wire.channel == "WHISPER" and wire.target == "Pete", "no whispered counter-claim")

-- A WHISPERED announce (the counter-claim) warns but is never answered.
prevCount = wire.count
wire.receive("Parchment", W({ t = "DMROLE", v = {}, ver = "0.1.0" }), "WHISPER", "Quin")
assert(printed[#printed]:find("also have DM mode"), "whispered claim must still warn")
assert(wire.count == prevCount, "whispered DMROLE must not be answered (ping-pong)")
ns.Addon.db.profile.dm = false

-- Post-1.0 policy: minor drift syncs, major mismatch does not.
local ns2, wire2 = boot("1.2.0")
local got2 = 0
ns2.Comm.On("SYSTEM", function() got2 = got2 + 1 end)
wire2.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "1.5.3" }), "PARTY", "Hank")
assert(got2 == 1, "1.x minor drift wrongly blocked")
wire2.receive("Parchment", W({ t = "SYSTEM", v = {}, ver = "2.0.0" }), "PARTY", "Iris")
assert(got2 == 1, "major mismatch not blocked")
