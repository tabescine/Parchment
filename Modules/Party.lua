-- Parchment - Party (logic)
--
-- Data behind the party overview: group members broadcast a small VITALS
-- snapshot (character name, level, hp/temp/mana, ac, initiative, DM flag)
-- when their resources change and whenever someone asks (VITREQ). Everyone
-- caches what they receive, keyed by sender, session-only (vitals are too
-- volatile to be worth persisting). Pushes are throttled - resource edits
-- can fire per keystroke. Every received field is coerced per the comm hard
-- rule. Broadcasting honours the "Share vitals" opt-out
-- (db.profile.shareVitals): when off, nothing is sent or answered - the
-- player still sees members who do share.
--
-- Reads from: ns.Comm, ns.Addon.db.profile.shareVitals, ns.GetActiveCharacter,
--   ns.CharacterSheet.Compute, ns.GetSystem, ns.HasSystem, ns.PartyUI
--   (refresh notification).
-- Exposes on ns.Party: GetRoster, RequestAll, OnVitalsChanged, Clear.

local ADDON, ns = ...

ns.Party = ns.Party or {}
local Party = ns.Party

local THROTTLE = 2 -- seconds between pushed vitals broadcasts

-- [sender] = { name, level, hp, hpmax, temp, mana, manamax, ac, init, time }
local vitals = {}
local sendQueued = false

-- Builds this client's vitals snapshot from the active character, or nil.
local function Snapshot()
    if not ns.HasSystem() then return nil end
    local char = ns.GetActiveCharacter()
    if not char then return nil end
    local sheet = ns.CharacterSheet.Compute(char, ns.GetSystem())
    if not sheet then return nil end
    local d = sheet.derived
    return {
        name = sheet.name, level = sheet.level,
        hp = d.hp.current or d.hp.max or 0, hpmax = d.hp.max or 0, temp = d.hp.temp or 0,
        mana = d.mana.current or d.mana.max or 0, manamax = d.mana.max or 0,
        ac = d.ac or 0, init = d.initiative or 0,
        dm = (ns.Comm.IsDM() and true) or false,
    }
end

-- True unless the player opted out of broadcasting vitals (/pmt config).
-- ~= false so the default (unset on old profiles) counts as sharing.
local function SharingEnabled()
    return ns.Addon.db.profile.shareVitals ~= false
end

-- Sends our snapshot to the group (silently does nothing when solo, empty,
-- or opted out of sharing).
local function Broadcast()
    if not (ns.Comm and IsInGroup() and SharingEnabled()) then return end
    local snap = Snapshot()
    if snap then ns.Comm.Send("VITALS", snap) end
end

-- Pushes a vitals update to the group, throttled.
function Party.OnVitalsChanged()
    if not (IsInGroup and IsInGroup()) then return end
    if sendQueued then return end
    sendQueued = true
    C_Timer.After(THROTTLE, function()
        sendQueued = false
        Broadcast()
    end)
end

-- Asks the whole group to re-send vitals, and sends our own along.
-- Returns ok, err (err when not in a group).
function Party.RequestAll()
    if not ns.Comm then return false, "comm is not available." end
    local ok, err = ns.Comm.Send("VITREQ", {})
    if ok then Broadcast() end
    return ok, err
end

-- The received vitals keyed by sender. Treat as read-only.
function Party.GetRoster()
    return vitals
end

-- Drops all received vitals.
function Party.Clear()
    for k in pairs(vitals) do vitals[k] = nil end
end

-- Comm handlers. Own echoes are ignored (AceComm loops group broadcasts back).
if ns.Comm then
    ns.Comm.On("VITREQ", function(_, sender)
        if ns.Comm.IsSelf(sender) then return end
        Broadcast()
    end)
    ns.Comm.On("VITALS", function(payload, sender)
        if ns.Comm.IsSelf(sender) then return end
        if type(payload) ~= "table" or not sender then return end
        if type(payload.name) ~= "string" or payload.name == "" then return end
        vitals[sender] = {
            name = payload.name,
            level = math.floor(tonumber(payload.level) or 0),
            hp = math.floor(tonumber(payload.hp) or 0),
            hpmax = math.floor(tonumber(payload.hpmax) or 0),
            temp = math.floor(tonumber(payload.temp) or 0),
            mana = math.floor(tonumber(payload.mana) or 0),
            manamax = math.floor(tonumber(payload.manamax) or 0),
            ac = math.floor(tonumber(payload.ac) or 0),
            init = math.floor(tonumber(payload.init) or 0),
            dm = (payload.dm and true) or false,
            time = GetTime and GetTime() or 0,
        }
        if ns.PartyUI then ns.PartyUI.RefreshIfShown() end
    end)
end
