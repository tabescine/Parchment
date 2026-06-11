-- Comm wire codec WITH LibDeflate present: a large payload must go out
-- compressed (marker "1", smaller than raw) and survive the full
-- encode -> chunk-safe -> decode round-trip; a small one stays raw (marker
-- "0"). Skips cleanly if the vendored LibDeflate cannot load in this Lua.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")

UnitName = function() return "Me" end
IsInRaid = function() return false end
IsInGroup = function() return true end

-- Real LibStub (matches the in-game one) so LibDeflate self-registers and
-- Comm's LibStub("LibDeflate", true) lookup finds it.
local LibStub = { libs = {}, minors = {} }
function LibStub:NewLibrary(major, minor)
    minor = tonumber(tostring(minor):match("%d+") or minor)
    local old = self.minors[major]
    if old and old >= minor then return nil end
    self.minors[major], self.libs[major] = minor, self.libs[major] or {}
    return self.libs[major], old
end
function LibStub:GetLibrary(major, silent)
    if not self.libs[major] and not silent then error("LibStub: " .. tostring(major) .. " not found", 2) end
    return self.libs[major], self.minors[major]
end
setmetatable(LibStub, { __call = function(self, major, silent) return self:GetLibrary(major, silent) end })
_G.LibStub = LibStub

local ok = pcall(dofile, (TEST_ROOT or "") .. "Libs/LibDeflate/LibDeflate.lua")
local Deflate = ok and LibStub("LibDeflate", true)
if not Deflate then
    print("  (skip) LibDeflate not loadable in this Lua - compression path untested")
    _G.LibStub = nil
    return
end

local codec = {}
T.load(codec, "JSON.lua")
local JSON = codec.JSON

GetAddOnMetadata = function() return "0.2.0" end
C_AddOns = nil
local ns = {}
ns.Print = function() end
local wire = {}
ns.Addon = {
    db = { profile = {} },
    Serialize = function(_, t) return JSON.encode(t) end,
    Deserialize = function(_, d)
        local dok, v = pcall(JSON.decode, d)
        if dok then return true, v end
        return false
    end,
    SendCommMessage = function(_, _, data, channel, target, prio)
        wire.sent, wire.channel, wire.prio = data, channel, prio
    end,
    RegisterComm = function(_, _, cb) wire.receive = cb end,
}
T.load(ns, "Modules/Comm.lua")
ns.Comm.Init()

local got = {}
ns.Comm.On("SYSTEM", function(payload) got[#got + 1] = payload end)

-- A small payload stays raw (compression would not pay for itself).
ns.Comm.Send("SYSTEM", { x = 1 })
assert(wire.sent:sub(1, 1) == "0", "small payload should not be compressed")

-- A large, repetitive payload (mimics a real system: lots of repeated keys and
-- descriptive text) must compress: marker "1", and meaningfully smaller.
local big = {}
for i = 1, 400 do
    big[i] = { id = "perk_" .. i, name = "Perk Number " .. i,
        description = "A lengthy and repetitive description of a perk that adds modifiers to skills and saves." }
end
local rawLen = #JSON.encode({ t = "SYSTEM", v = big, ver = "0.2.0" })
ns.Comm.Send("SYSTEM", big)
assert(wire.sent:sub(1, 1) == "1", "large payload should be compressed")
assert(#wire.sent < rawLen, "compressed body must be smaller than raw")
assert(wire.prio == "BULK", "a large body should ride at BULK priority")

-- The round-trip: deliver our own compressed wire back and confirm it decodes
-- to the exact payload (a different sender so it is not treated as self).
wire.receive("Parchment", wire.sent, "PARTY", "DungeonMaster-Realm")
assert(#got == 1, "compressed message did not dispatch")
assert(got[1][1].id == "perk_1" and got[1][400].name == "Perk Number 400", "payload corrupted in transit")

-- A corrupted compressed body is dropped, not errored.
wire.receive("Parchment", "1@@@not-valid-encoded-deflate@@@", "PARTY", "DungeonMaster-Realm")
assert(#got == 1, "corrupt compressed body must be ignored")

_G.LibStub = nil
