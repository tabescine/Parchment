-- Parchment - Party (logic)
--
-- Data behind the party overview: group members broadcast a small VITALS
-- snapshot (character name, level, hp/temp/mana, ac, initiative, DM flag)
-- when their resources change and whenever someone asks (VITREQ). Everyone
-- caches what they receive, keyed by sender, session-only (vitals are too
-- volatile to be worth persisting, and dropped again when their sender leaves
-- the group - Comm's roster-change prune calls PruneDeparted, so the overview
-- never lingers on a departed member). Pushes are leading-edge throttled (resource
-- edits can fire per keystroke); VITREQ answers are jittered and coalesced to
-- avoid a group-wide reply storm; and incoming-vitals UI refreshes are
-- debounced. Every received field is coerced per the comm hard
-- rule. Broadcasting honours the "Share vitals" opt-out
-- (db.profile.shareVitals): when off, nothing is sent or answered - the
-- player still sees members who do share.
--
-- Reads from: ns.Comm, ns.Addon.db.profile.shareVitals, ns.GetActiveCharacter,
--   ns.CharacterSheet.Compute, ns.GetSystem, ns.GetItemLibrary, ns.HasSystem,
--   ns.PartyUI and
--   ns.InitiativeUI (refresh notifications; the tracker renders vitals inline).
-- Exposes on ns.Party: GetRoster, OwnSnapshot, RequestAll, OnVitalsChanged,
--   PruneDeparted, Clear.

local ADDON, ns = ...

ns.Party = ns.Party or {}
local Party = ns.Party

local THROTTLE = 2          -- min seconds between our pushed vitals broadcasts
local VITREQ_JITTER = 3     -- max random delay before answering a VITREQ
local REFRESH_DEBOUNCE = 0.2 -- coalesce incoming-vitals UI refreshes

-- [sender] = { name, level, hp, hpmax, temp, mana, manamax, ac, init, time }
local vitals = {}
local cooling = false       -- inside a post-send cooldown (leading-edge send)
local pendingChange = false -- a change arrived during the cooldown
local answerQueued = false  -- a jittered VITREQ answer is scheduled
local refreshQueued = false -- a debounced UI refresh is scheduled

-- Builds this client's vitals snapshot from the active character, or nil.
local function Snapshot()
    if not ns.HasSystem() then return nil end
    local char = ns.GetActiveCharacter()
    if not char then return nil end
    local sheet = ns.CharacterSheet.Compute(char, ns.GetSystem(), ns.GetItemLibrary())
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

-- Pushes a vitals update to the group on change, leading-edge throttled: the
-- first change broadcasts immediately, then a cooldown collapses any further
-- changes into a single trailing send when it ends - so a burst of edits is
-- responsive at the start and capped in rate, instead of always lagging by
-- THROTTLE. The local windows that render own vitals refresh immediately.
function Party.OnVitalsChanged()
    if ns.InitiativeUI and ns.InitiativeUI.RefreshIfShown then ns.InitiativeUI.RefreshIfShown() end
    if not (IsInGroup and IsInGroup()) then return end
    if cooling then pendingChange = true; return end
    Broadcast()
    if not C_Timer then return end
    cooling = true
    C_Timer.After(THROTTLE, function()
        cooling = false
        if pendingChange then
            pendingChange = false
            Party.OnVitalsChanged()
        end
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

-- This client's own live snapshot (own broadcasts echo back but are ignored,
-- so the roster never contains us; the initiative tracker shows it inline).
function Party.OwnSnapshot()
    return Snapshot()
end

-- Drops all received vitals.
function Party.Clear()
    for k in pairs(vitals) do vitals[k] = nil end
end

-- Answers a VITREQ after a small random delay, coalescing a burst of requests
-- into a single reply: in a 40-player group, everyone asking at once would
-- otherwise trigger 40 simultaneous broadcasts from us. The jitter spreads the
-- answers across the group; the queue flag drops duplicate requests in-window.
local function AnswerRequest()
    if answerQueued then return end
    answerQueued = true
    local delay = (math.random and math.random() or 0) * VITREQ_JITTER
    local function fire() answerQueued = false; Broadcast() end
    if C_Timer then C_Timer.After(delay, fire) else fire() end
end

-- Coalesces incoming-vitals UI refreshes: many VITALS can land in one frame
-- (a VITREQ answered by the whole group), so re-render once, debounced.
local function ScheduleRefresh()
    if refreshQueued then return end
    refreshQueued = true
    local function fire()
        refreshQueued = false
        if ns.PartyUI then ns.PartyUI.RefreshIfShown() end
        if ns.InitiativeUI and ns.InitiativeUI.RefreshIfShown then ns.InitiativeUI.RefreshIfShown() end
    end
    if C_Timer then C_Timer.After(REFRESH_DEBOUNCE, fire) else fire() end
end

-- Drops cached vitals for senders who are no longer in the group, so a departed
-- member's (or a stranger's) row cannot linger in the overview for the session.
-- keepSet is the canonical-name set Comm builds on a roster change
-- (Comm.NormalizeName keys); an absent or empty set means "roster unknown" and
-- nothing is dropped. Refreshes the UI only when a row actually went away.
function Party.PruneDeparted(keepSet)
    if type(keepSet) ~= "table" or next(keepSet) == nil then return end
    local dropped = false
    for sender in pairs(vitals) do
        local who = ns.Comm and ns.Comm.NormalizeName(sender)
        if not who or not keepSet[who] then
            vitals[sender] = nil
            dropped = true
        end
    end
    if dropped then ScheduleRefresh() end
end

-- Comm handlers. Own echoes are dropped centrally in Comm.OnReceive; the
-- IsSelf guards here are cheap belt-and-braces for any direct dispatch.
if ns.Comm then
    ns.Comm.On("VITREQ", function(_, sender)
        if ns.Comm.IsSelf(sender) then return end
        AnswerRequest()
    end)
    ns.Comm.On("VITALS", function(payload, sender)
        if ns.Comm.IsSelf(sender) then return end
        if type(payload) ~= "table" or not sender then return end
        if type(payload.name) ~= "string" or payload.name == "" then return end
        vitals[sender] = {
            -- Numeric fields are clamped below; the name gets the same line - a
            -- length cap - so a peer cannot fill the roster/UI with multi-KB
            -- strings (cosmetic/memory nuisance, but free to prevent).
            name = string.sub(payload.name, 1, 64),
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
        -- The party overview and the initiative tracker both render these inline;
        -- debounce so a group-wide answer re-renders once, not per message.
        ScheduleRefresh()
    end)
end
