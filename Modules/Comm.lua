-- Parchment - Comm
--
-- Player-to-player sync over the addon channel (AceComm + AceSerializer). The
-- DM broadcasts the system definition and the initiative state to the group;
-- players receive them read-only and can submit their own initiative back.
--
-- A single role flag (db.profile.dm) decides whether this client BROADCASTS as
-- the DM. Separately, each client records the DM it RECOGNIZES (recognizedDM,
-- session memory): the first player to claim the role (DMROLE) locks it in, and
-- thereafter only that sender's DM-authoritative messages (INIT, SYSTEM) are
-- applied - spoofed broadcasts from any other group member are dropped centrally
-- in OnReceive. A later claim by a different player is a non-destructive
-- take-over offer; stepping down broadcasts a RELEASE so everyone clears
-- recognition. Messages are typed envelopes { t = type, v = payload, ver =
-- sender's addon version }; consumers register a handler per type via Comm.On.
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
-- The inbound edge is hardened centrally in OnReceive (not per handler): own
-- group echoes are filtered once, the decode chain is fully pcall-guarded, and
-- accepted messages are rate-limited per sender+type so one peer cannot flood
-- the main thread (SYSTEM decompress, VITALS churn). Per-sender bookkeeping is
-- pruned when the group roster changes.
--
-- Reads from: ns.Addon (the AceAddon object with Comm/Serializer mixins), its
--   db, ns.Print, ns.Party (guarded; vitals push on role change), and
--   LibDeflate via LibStub (optional).
-- Exposes on ns.Comm: IsDM, IsSelf, NormalizeName, SameName, SetDM, RecognizedDM,
--   SetRecognizedDM, ClearRecognizedDM, IsAuthoritative, Send, Whisper, On, Init.

local ADDON, ns = ...

ns.Comm = ns.Comm or {}
local Comm = ns.Comm

local PREFIX = "Parchment"
local handlers = {}

-- Message types whose authority belongs to the DM: applied only from the
-- recognized DM (see IsAuthoritative). Player-to-DM types (INITSUBMIT, TURNEND,
-- VITALS, ...) are not gated here; they are bound to the sender by their own
-- handlers.
local AUTHORITATIVE = { SYSTEM = true, INIT = true, FEATS = true, SPELLS = true }

-- This client's recognized DM (canonical name; session memory only). Distinct
-- from db.profile.dm. nil means "no DM recognized yet" - the bootstrap state in
-- which authoritative messages are accepted from anyone until the first claim
-- locks one in. Changed only by an explicit claim/take-over/accept, or cleared
-- by a RELEASE; a roster change never touches it.
local recognizedDM = nil

-- Group channels (AceComm loops our own broadcasts on these back to us).
local GROUP_DIST = { PARTY = true, RAID = true, INSTANCE_CHAT = true }

-- Inbound rate limit: the minimum seconds between two ACCEPTED messages of a
-- given type from one sender. Caps the cost a single peer can impose - SYSTEM
-- decompresses ~100 KB on the main thread, VITALS arrives at edit frequency.
-- Types absent here are unlimited (REQ/CHAR are self-throttled by `pending`).
local MIN_INTERVAL = { SYSTEM = 3, VITALS = 0.5, INIT = 0.25, CHAR = 2, FEATS = 3, SPELLS = 3,
    LINKQ = 0.3, LINKA = 0.3 }
-- [sender][type] = GetTime() of the last accepted message (pruned on roster
-- change). Nested by sender so a departing member's row drops in one step.
local recvAt = {}

-- Our addon version, from the .toc (single source of truth).
local VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version"))
    or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "0.0.0"

-- Parses "MAJOR.MINOR[.PATCH...]" into numbers; nil, nil when unparsable.
local function MajorMinor(v)
    local maj, min = tostring(v or ""):match("^(%d+)%.(%d+)")
    return tonumber(maj), tonumber(min)
end

-- True when a sender's version can sync with ours: same major, and - while
-- the major is 0 - the same minor too. NOTE: this is a compatibility gate, not
-- a resource guard - env.ver lives inside the (compressed) body, so it runs
-- only after full decode; the MAX_WIRE/MAX_DECOMPRESSED caps bound decode cost.
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

-- True when this client is broadcasting as the DM. Guarded so a half-built db
-- (no profile yet) cannot throw.
function Comm.IsDM()
    local db = ns.Addon and ns.Addon.db
    return (db and db.profile and db.profile.dm) or false
end

-- The single canonical identity key for a player name: the name part (before
-- any "-Realm"), lowercased. The one normalizer the whole addon shares, so name
-- comparisons can never diverge between modules. Returns nil for empty input.
-- (Realm-tolerant by design: within a party names are unique, and our peers send
-- bare and realm-qualified names interchangeably. A full Name-Realm canonical
-- via GetNormalizedRealmName is a possible future tightening.)
function Comm.NormalizeName(name)
    if type(name) ~= "string" or name == "" then return nil end
    local key = name:match("^[^-]+")
    return key and key:lower() or nil
end

-- This player's own name.
local function MyName()
    return (UnitName and UnitName("player")) or ""
end

-- True when two names refer to the same player (realm-suffix tolerant).
function Comm.SameName(a, b)
    local ka = Comm.NormalizeName(a)
    return ka ~= nil and ka == Comm.NormalizeName(b)
end

-- True when sender is this player. AceComm echoes our own group broadcasts
-- back to us; handlers that must not react to themselves check this.
function Comm.IsSelf(sender)
    if not sender then return false end
    return Comm.SameName(sender, MyName())
end

-- The DM this client currently recognizes (canonical name), or nil.
function Comm.RecognizedDM()
    return recognizedDM
end

-- Records (or clears, with nil/"") the recognized DM. Returns the new value.
-- Used by an explicit take-over/accept; receiving paths set it directly.
function Comm.SetRecognizedDM(name)
    recognizedDM = (type(name) == "string" and name ~= "") and name or nil
    return recognizedDM
end

-- Clears the recognized DM (an explicit release/step-down).
function Comm.ClearRecognizedDM()
    recognizedDM = nil
end

-- True when sender may apply DM-authoritative messages: the recognized DM, or
-- anyone while none is recognized yet (the first DMROLE claim locks it).
function Comm.IsAuthoritative(sender)
    if not recognizedDM then return true end
    return Comm.SameName(sender, recognizedDM)
end

function Comm.SetDM(on)
    on = on and true or false
    local was = Comm.IsDM()
    ns.Addon.db.profile.dm = on
    if on and not was then
        -- Claiming: recognize ourselves and announce to the group (Send no-ops
        -- when solo) so an already-active DM and this new one learn of the clash.
        recognizedDM = MyName()
        Comm.Send("DMROLE", {})
    elseif not on and was then
        -- Stepping down: a deliberate release (distinct from a disconnect) so
        -- everyone clears recognition and the next /pmt dm claims cleanly.
        if Comm.SameName(MyName(), recognizedDM) then recognizedDM = nil end
        Comm.Send("RELEASE", {})
    end
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
-- accepts as-is; a big system (a full ruleset can serialize to ~100 KB) then
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

-- Decompression-bomb guards. Decode necessarily runs before the version, trust,
-- and rate gates (the envelope's `ver`/`t` live inside the compressed body), so
-- those gates cannot bound decode cost - these size caps do. MAX_WIRE rejects an
-- oversized packed body before it is decompressed at all; MAX_DECOMPRESSED
-- rejects a body that expands past any legitimate payload before it is
-- deserialized into a table. The largest real message is a full system
-- (~100 KB raw, ~25 KB on the wire) or a 256 KB shared character; both sit far
-- under these ceilings, so a peer cannot make us expand a tiny body into
-- hundreds of MB on the main thread.
local MAX_WIRE = 128 * 1024
local MAX_DECOMPRESSED = 1024 * 1024

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
-- undecodable input, so the receiver drops it quietly). The whole chain runs
-- under pcall: a hostile or corrupt body that makes LibDeflate or the serializer
-- throw becomes a quiet drop, never an error surfaced from AceComm's dispatch.
local function DecodeUnprotected(text)
    if type(text) ~= "string" or #text < 1 or #text > MAX_WIRE then return false end
    local marker, body = text:sub(1, 1), text:sub(2)
    if marker == "1" then
        if not Deflate then return false end
        local packed = Deflate:DecodeForWoWAddonChannel(body)
        if not packed then return false end
        local raw = Deflate:DecompressDeflate(packed)
        if not raw or #raw > MAX_DECOMPRESSED then return false end
        return ns.Addon:Deserialize(raw)
    elseif marker == "0" then
        return ns.Addon:Deserialize(body)
    end
    return false
end

local function Decode(text)
    local ok, a, b = pcall(DecodeUnprotected, text)
    if not ok then return false end
    return a, b
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

-- True when accepting another `t` from `sender` now respects its rate limit;
-- records the acceptance time when it does. No clock (tests) means no limiting.
local function RateOK(sender, t)
    local interval = MIN_INTERVAL[t]
    if not interval or not GetTime then return true end
    local now = GetTime()
    local row = recvAt[sender or "?"]
    if row and row[t] and (now - row[t]) < interval then return false end
    row = row or {}
    row[t] = now
    recvAt[sender or "?"] = row
    return true
end

-- AceComm receive callback. The inbound edge is hardened here, in one place,
-- rather than per handler: drop our own looped-back group broadcasts, drop
-- malformed/foreign/incompatible bodies, gate DM authority, and rate-limit per
-- sender+type - so a handler only ever sees trusted, well-paced traffic.
local function OnReceive(prefix, text, distribution, sender)
    if prefix ~= PREFIX then return end
    -- Our own group broadcast echoes back to us; filter it once, centrally.
    -- (Whispers are never self-echoed and may legitimately target self - e.g.
    -- the self "View sheet" loopback - so only group channels are filtered.)
    if GROUP_DIST[distribution] and Comm.IsSelf(sender) then return end
    local ok, env = Decode(text)
    if not ok or type(env) ~= "table" then return end
    if not Compatible(env.ver) then
        if not Comm.IsSelf(sender) then WarnMismatch(sender, env.ver) end
        return
    end
    -- Trust gate: a DM-authoritative message is applied only from the recognized
    -- DM. This is the central fix for DM-broadcast spoofing - a non-DM group
    -- member can no longer push a fake system or initiative state.
    if AUTHORITATIVE[env.t] and not Comm.IsAuthoritative(sender) then return end
    -- Rate gate: cap how often one sender can make us do expensive work.
    if not RateOK(sender, env.t) then return end
    local fn = handlers[env.t]
    if fn then fn(env.v, sender, distribution) end
end

-- Drops per-sender bookkeeping for players no longer in the group, so a long
-- session cannot accumulate unbounded version-warning and rate-limit rows (and a
-- player who leaves and rejoins can be re-warned). The recognized DM is NOT
-- touched - a disconnect must not unseat the DM (see the trust model).
local function PruneDepartedSenders()
    local keep = { [Comm.NormalizeName(MyName()) or ""] = true }
    local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
    local prefix = (IsInRaid and IsInRaid()) and "raid" or "party"
    for i = 1, n do
        local unit = prefix .. i
        if UnitExists and UnitExists(unit) then
            local who = Comm.NormalizeName((UnitName and UnitName(unit)) or "")
            if who then keep[who] = true end
        end
    end
    for who in pairs(versionWarned) do
        if not keep[Comm.NormalizeName(who) or ""] then versionWarned[who] = nil end
    end
    for who in pairs(recvAt) do
        if not keep[Comm.NormalizeName(who) or ""] then recvAt[who] = nil end
    end
end

-- Registers the comm prefix and the roster-change prune. Called once the addon
-- is enabled. RegisterEvent is guarded so the out-of-client tests (a bare Addon
-- stub) can drive OnReceive without AceEvent.
function Comm.Init()
    ns.Addon:RegisterComm(PREFIX, OnReceive)
    if ns.Addon.RegisterEvent then
        ns.Addon:RegisterEvent("GROUP_ROSTER_UPDATE", PruneDepartedSenders)
    end
end

-- Role announcements drive DM recognition. The FIRST claim this client sees
-- locks in silently (no popup in the common case); a later claim by a DIFFERENT
-- player is a non-destructive take-over offer, surfaced as a switch-vs-keep
-- prompt (default: keep the current DM). When this client is ALSO an active DM,
-- warn about the clash and whisper our own claim back so the newcomer learns of
-- it - but never for a whispered announce, so two clients cannot ping-pong.
Comm.On("DMROLE", function(_, sender, distribution)
    if Comm.IsSelf(sender) then return end
    if not recognizedDM then
        recognizedDM = sender
        ns.Print((sender or "?") .. " is now your recognized DM.")
    elseif not Comm.SameName(sender, recognizedDM) then
        ns.Print((sender or "?") .. " is claiming DM; you currently recognize "
            .. recognizedDM .. ".")
        if ns.Dialogs and ns.Dialogs.ConfirmDMSwitch then
            ns.Dialogs.ConfirmDMSwitch(recognizedDM, sender)
        end
    end
    if Comm.IsDM() then
        ns.Print("|cffffcc00warning:|r you also have DM mode on - you would both broadcast"
            .. " system and initiative sync. One of you should toggle it off (/pmt dm).")
        if distribution ~= "WHISPER" then Comm.Whisper("DMROLE", {}, sender) end
    end
end)

-- A DM stepped down: clear recognition so the next claim locks cleanly. Honoured
-- only from the DM we actually recognize - a stray release cannot unseat someone
-- else's DM.
Comm.On("RELEASE", function(_, sender)
    if Comm.IsSelf(sender) then return end
    if Comm.SameName(sender, recognizedDM) then
        recognizedDM = nil
        ns.Print((sender or "?") .. " stepped down as DM.")
    end
end)
