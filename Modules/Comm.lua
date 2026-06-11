-- Parchment - Comm
--
-- Player-to-player sync over the addon channel (AceComm + AceSerializer). The
-- DM broadcasts the system definition and the initiative state to the group;
-- players receive them read-only and can submit their own initiative back.
--
-- A single role flag (db.profile.dm) decides whether this client is the DM.
-- Messages are typed envelopes { t = type, v = payload }; consumers register a
-- handler per type via Comm.On.
--
-- Reads from: ns.Addon (the AceAddon object with Comm/Serializer mixins), its db.
-- Exposes on ns.Comm: IsDM, IsSelf, SetDM, Send, Whisper, On, Init.

local ADDON, ns = ...

ns.Comm = ns.Comm or {}
local Comm = ns.Comm

local PREFIX = "Parchment"
local handlers = {}

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
    ns.Addon.db.profile.dm = on and true or false
end

-- The group channel to broadcast on, or nil when solo.
local function GroupChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- Broadcasts a typed message to the group. Returns ok, reason.
function Comm.Send(msgType, payload)
    local channel = GroupChannel()
    if not channel then return false, "you are not in a party or raid." end
    local data = ns.Addon:Serialize({ t = msgType, v = payload })
    ns.Addon:SendCommMessage(PREFIX, data, channel)
    return true
end

-- Sends a typed message directly to one player (addon whisper).
function Comm.Whisper(msgType, payload, target)
    if not target or target == "" then return false, "no target." end
    local data = ns.Addon:Serialize({ t = msgType, v = payload })
    ns.Addon:SendCommMessage(PREFIX, data, "WHISPER", target)
    return true
end

-- Registers a handler fn(payload, sender, distribution) for a message type.
function Comm.On(msgType, fn)
    handlers[msgType] = fn
end

-- AceComm receive callback: deserialize and dispatch by type.
local function OnReceive(prefix, text, distribution, sender)
    if prefix ~= PREFIX then return end
    local ok, env = ns.Addon:Deserialize(text)
    if not ok or type(env) ~= "table" then return end
    local fn = handlers[env.t]
    if fn then fn(env.v, sender, distribution) end
end

-- Registers the comm prefix. Called once the addon is enabled.
function Comm.Init()
    ns.Addon:RegisterComm(PREFIX, OnReceive)
end
