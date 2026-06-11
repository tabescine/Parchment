-- Parchment - Comm
--
-- Player-to-player sync over the addon channel (AceComm + AceSerializer). The
-- DM broadcasts the system definition and the initiative state to the group;
-- players receive them read-only and can submit their own initiative back.
--
-- A single role flag (db.profile.dm) decides whether this client is the DM.
-- Turning it on announces the role to the group (DMROLE) so clashing active
-- DMs warn each other; the flag also rides the party vitals as a "(DM)" tag.
-- Messages are typed envelopes { t = type, v = payload, ver = sender's addon
-- version }; consumers register a handler per type via Comm.On.
--
-- Version gating: a received message is only dispatched when the sender's
-- version is sync-compatible with ours (same major; while the major is 0 -
-- where a minor bump may change the wire format - the minor must match too).
-- Incompatible messages are dropped with a one-time notice per sender, so a
-- mixed-version group degrades to "no sync" instead of undefined behaviour.
--
-- Large payloads are DEFLATE-compressed on the wire (LibDeflate, optional - the
-- comm degrades to uncompressed when it is absent) and big bodies ride at BULK
-- priority so a system share cannot stall vitals/sheet traffic. See Encode.
--
-- Reads from: ns.Addon (the AceAddon object with Comm/Serializer mixins), its
--   db, ns.Print, ns.Party (guarded; vitals push on role change), and
--   LibDeflate via LibStub (optional).
-- Exposes on ns.Comm: IsDM, IsSelf, SetDM, Send, Whisper, On, Init.

local ADDON, ns = ...

ns.Comm = ns.Comm or {}
local Comm = ns.Comm

local PREFIX = "Parchment"
local handlers = {}

-- Our addon version, from the .toc (single source of truth).
local VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version"))
    or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "0.0.0"

-- Parses "MAJOR.MINOR[.PATCH...]" into numbers; nil, nil when unparsable.
local function MajorMinor(v)
    local maj, min = tostring(v or ""):match("^(%d+)%.(%d+)")
    return tonumber(maj), tonumber(min)
end

-- True when a sender's version can sync with ours: same major, and - while
-- the major is 0 - the same minor too.
local function Compatible(theirs)
    local tMaj, tMin = MajorMinor(theirs)
    local oMaj, oMin = MajorMinor(VERSION)
    if not tMaj or not oMaj or tMaj ~= oMaj then return false end
    return tMaj > 0 or tMin == oMin
end

-- True when their version is newer than ours (decides who the mismatch
-- notice tells to update). Compares numeric segments left to right.
local function IsNewer(theirs)
    local t = {}; for n in tostring(theirs or ""):gmatch("%d+") do t[#t + 1] = tonumber(n) end
    local o = {}; for n in tostring(VERSION):gmatch("%d+") do o[#o + 1] = tonumber(n) end
    for i = 1, math.max(#t, #o) do
        local a, b = t[i] or 0, o[i] or 0
        if a ~= b then return a > b end
    end
    return false
end

-- Prints one notice per sender per session about a version mismatch.
local versionWarned = {}
local function WarnMismatch(sender, theirs)
    local who = sender or "?"
    if versionWarned[who] then return end
    versionWarned[who] = true
    local hint = IsNewer(theirs) and "Update your Parchment to sync with them."
        or "They need to update their Parchment to sync with you."
    ns.Print(string.format("%s runs Parchment %s, you run %s - sync between you is disabled. %s",
        who, tostring(theirs or "(unknown)"), VERSION, hint))
end

-- True when this client is acting as the DM.
function Comm.IsDM()
    return ns.Addon.db and ns.Addon.db.profile.dm or false
end

-- True when sender is this player. AceComm echoes our own group broadcasts
-- back to us; handlers that must not react to themselves check this.
function Comm.IsSelf(sender)
    local me = (UnitName and UnitName("player")) or ""
    if not sender then return false end
    return sender == me or sender:match("^[^-]+") == me
end

function Comm.SetDM(on)
    on = on and true or false
    local was = Comm.IsDM()
    ns.Addon.db.profile.dm = on
    -- Claiming the role announces it to the group (Send no-ops when solo) so
    -- an already-active DM and this new one both learn of the clash.
    if on and not was then Comm.Send("DMROLE", {}) end
    -- The DM tag rides the vitals snapshot; push an update on any change.
    if ns.Party then ns.Party.OnVitalsChanged() end
end

-- The group channel to broadcast on, or nil when solo.
local function GroupChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- Wire encoding. AceSerializer produces a printable string the addon channel
-- accepts as-is; a big system (the aias ruleset serializes to ~100 KB) then
-- chunks into hundreds of throttled packets and takes minutes to arrive,
-- stalling every other message behind it. So we DEFLATE-compress the payload
-- (LibDeflate, ~5x on this data) when it is large enough to pay for itself.
--
-- A one-byte marker tags the body so the receiver knows how to read it:
--   "0" = raw serialized       (already addon-channel safe)
--   "1" = deflated, then EncodeForWoWAddonChannel (binary made channel-safe)
-- Compression is skipped (marker "0") when LibDeflate is absent or the packed
-- form is not actually smaller, so small/odd messages never pay for it.
local Deflate = LibStub and LibStub("LibDeflate", true)
local COMPRESS_MIN = 600   -- below this, deflate + encode rarely nets a saving
local BULK_MIN = 2000      -- encoded bodies larger than this go out at BULK prio

-- Serializes and (when worthwhile) compresses an envelope. Returns the wire
-- string and the AceComm priority to send it at: a large body uses "BULK" so
-- it cannot starve the small, latency-sensitive traffic (vitals, sheet
-- requests) that shares ChatThrottleLib's single outbound queue.
local function Encode(env)
    local raw = ns.Addon:Serialize(env)
    if Deflate and type(raw) == "string" and #raw >= COMPRESS_MIN then
        local packed = Deflate:EncodeForWoWAddonChannel(Deflate:CompressDeflate(raw))
        if packed and #packed < #raw then
            return "1" .. packed, (#packed >= BULK_MIN) and "BULK" or "NORMAL"
        end
    end
    local body = "0" .. tostring(raw)
    return body, (#body >= BULK_MIN) and "BULK" or "NORMAL"
end

-- Reverses Encode. Returns ok, envelope (ok=false on any malformed/foreign or
-- undecodable input, so the receiver drops it quietly).
local function Decode(text)
    if type(text) ~= "string" or #text < 1 then return false end
    local marker, body = text:sub(1, 1), text:sub(2)
    if marker == "1" then
        if not Deflate then return false end
        local packed = Deflate:DecodeForWoWAddonChannel(body)
        if not packed then return false end
        local raw = Deflate:DecompressDeflate(packed)
        if not raw then return false end
        return ns.Addon:Deserialize(raw)
    elseif marker == "0" then
        return ns.Addon:Deserialize(body)
    end
    return false
end

-- Broadcasts a typed message to the group. Returns ok, reason.
function Comm.Send(msgType, payload)
    local channel = GroupChannel()
    if not channel then return false, "you are not in a party or raid." end
    local data, prio = Encode({ t = msgType, v = payload, ver = VERSION })
    ns.Addon:SendCommMessage(PREFIX, data, channel, nil, prio)
    return true
end

-- Sends a typed message directly to one player (addon whisper).
function Comm.Whisper(msgType, payload, target)
    if not target or target == "" then return false, "no target." end
    local data, prio = Encode({ t = msgType, v = payload, ver = VERSION })
    ns.Addon:SendCommMessage(PREFIX, data, "WHISPER", target, prio)
    return true
end

-- Registers a handler fn(payload, sender, distribution) for a message type.
function Comm.On(msgType, fn)
    handlers[msgType] = fn
end

-- AceComm receive callback: decode, gate on version, dispatch by type.
local function OnReceive(prefix, text, distribution, sender)
    if prefix ~= PREFIX then return end
    local ok, env = Decode(text)
    if not ok or type(env) ~= "table" then return end
    if not Compatible(env.ver) then
        if not Comm.IsSelf(sender) then WarnMismatch(sender, env.ver) end
        return
    end
    local fn = handlers[env.t]
    if fn then fn(env.v, sender, distribution) end
end

-- Registers the comm prefix. Called once the addon is enabled.
function Comm.Init()
    ns.Addon:RegisterComm(PREFIX, OnReceive)
end

-- Role announcements: prints who took the DM role; when this client is ALSO
-- an active DM, warn - two DMs would both broadcast system/initiative sync -
-- and whisper our own claim back so the newcomer is warned too. The reply is
-- only sent for group announces (never for a whispered one), so two clients
-- cannot ping-pong.
Comm.On("DMROLE", function(_, sender, distribution)
    if Comm.IsSelf(sender) then return end
    ns.Print((sender or "?") .. " enabled DM mode.")
    if Comm.IsDM() then
        ns.Print("|cffffcc00warning:|r you also have DM mode on - you would both broadcast"
            .. " system and initiative sync. One of you should toggle it off (/pmt dm).")
        if distribution ~= "WHISPER" then Comm.Whisper("DMROLE", {}, sender) end
    end
end)
