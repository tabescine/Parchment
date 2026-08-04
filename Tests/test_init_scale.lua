-- Initiative sync at a full table: N independent clients on one comm bus.
--
-- The addon has only ever been played at two clients. This file boots N client
-- namespaces - each with its own InitiativeTracker, its own Comm (so the
-- recognized DM, the per-sender rate-limit rows and the persisted order are per
-- client, as in game) - against a shared in-process bus, and asserts the group
-- converges. It is the only test that drives the RAID roster path in
-- Comm.InGroup, the rate gate under real contention, and one DM broadcast
-- fanning out to eleven receivers at once.
--
-- The failure it locks down: every INIT carries the FULL turn order, and a
-- receiver rate-limits INIT to one per MIN_INTERVAL.INIT (0.25 s) per sender,
-- DROPPING whatever arrives inside the window. UI/InitiativeUI.lua's Sync used
-- to fire per state change, so a roll call answered by eleven players made the
-- DM re-broadcast eleven times milliseconds apart - and when the LAST broadcast
-- was the one the window ate, every player silently held a short turn order
-- forever. Sync is now UI.Debounce(SYNC_DELAY, SyncNow): one trailing send per
-- burst, which can never collide with the gate.
--
-- The debounce and the pull coalescing live in UI/InitiativeUI.lua, which needs
-- frame stubs to load; both are modelled here instead (a pending flag plus an
-- explicit flush). What is asserted is therefore the wire-level property - how
-- many messages a burst produces and what the group ends up holding - not the
-- UI internals, which Tests/test_widgets_debounce.lua covers.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")

-- Table size: client 1 is the DM, the other N-1 are players. Raise to re-measure
-- at a bigger table.
local N = 12
-- The version every client reports. They must agree - Comm's 0.x gate drops
-- everything between mismatched minors.
local VERSION = "0.4.0"
-- UI/InitiativeUI.lua's debounce window, mirrored here.
local SYNC_DELAY = 0.35
-- Gap between two submissions in the roll-call burst: 40 ms, i.e. players
-- answering the same popup "at the same time". Deliberately NOT a divisor of
-- Comm's 0.25 s INIT window - on an even divisor a burst's broadcasts land
-- exactly on the boundary, where float rounding rather than the debounce would
-- decide whether the negative control below still fails.
local SUBMIT_GAP = 0.04
-- Quiet time between phases, so a phase never starts inside the previous
-- phase's INIT rate window.
local QUIET = 5

-- Client names; the raid roster resolves raid1..raidN to these.
local NAMES = { "DM" }
for i = 1, N - 1 do NAMES[i + 1] = string.format("Player%02d", i) end

-- What each player submits: distinct and jumbled, so the DM's ordered insert
-- produces an order that is NOT submission order and the convergence check
-- really compares order, not just membership.
local INITS = {}
for i = 2, N do INITS[i] = ((i * 7) % 19) + 1 end

-- The world clock (driven by hand, so the real rate limiter runs
-- deterministically) and the client whose "player" unit is currently resolving:
-- all N clients share one Lua state, so UnitName has to be told which one is
-- acting before its code runs.
local CLOCK, acting = 0, NAMES[1]

GetTime = function() return CLOCK end
-- InitiativeTracker.Add and AdjustHP need it; wow_stubs does not provide it.
strtrim = function(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
IsInRaid = function() return true end
IsInGroup = function() return true end
GetNumGroupMembers = function() return N end
UnitExists = function(unit)
    local i = tonumber(tostring(unit):match("^raid(%d+)$") or "")
    return i ~= nil and i >= 1 and i <= N
end
UnitName = function(unit)
    if unit == "player" then return acting end
    local i = tonumber(tostring(unit):match("^raid(%d+)$") or "")
    return i and NAMES[i] or nil
end
GetAddOnMetadata = function() return VERSION end
C_AddOns = nil
-- No LibDeflate: the bus then carries exactly what Encode produced, and a
-- LibStub absorber leaked in by an earlier test file cannot pose as a codec.
LibStub = nil

-- JSON stands in for AceSerializer.
local codec = {}
T.load(codec, "JSON.lua")
local JSON = codec.JSON

-- Canonical player key, mirroring Comm.NormalizeName.
local function Key(name)
    return tostring(name or ""):match("^[^-]*"):lower()
end

-- "name@init" per row, in order: one comparable string covering count, names
-- and order at once.
local function Signature(combatants)
    local parts = {}
    for i, c in ipairs(combatants) do
        parts[i] = tostring(c.name) .. "@" .. tostring(c.init)
    end
    return table.concat(parts, "|")
end

-- The index of the named combatant, or nil.
local function IndexOf(combatants, name)
    for i, c in ipairs(combatants) do
        if c.name == name then return i end
    end
    return nil
end

-- Boots N clients around one bus and returns the world: .clients (1 = the DM),
-- .dm, the bus helpers, and the harness models of the DM's debounced Sync and
-- of the pull coalescing.
local function NewWorld()
    local world = { clients = {}, debounced = true }

    -- The bus. A group distribution reaches every client including the sender
    -- (AceComm echoes our own broadcasts back, and Comm filters that centrally);
    -- a WHISPER reaches the named one.
    function world.Deliver(dist, target, sender, text)
        for _, c in ipairs(world.clients) do
            if dist ~= "WHISPER" or Key(c.name) == Key(target) then
                local was = acting
                acting = c.name
                c.receive("Parchment", text, dist, sender)
                acting = was
            end
        end
    end

    -- Puts a hand-built envelope on the bus from a sender that is not one of our
    -- clients (the outsider in the group-gating phase).
    function world.Inject(dist, target, sender, msgType, payload)
        world.Deliver(dist, target, sender,
            "0" .. JSON.encode({ t = msgType, v = payload, ver = VERSION }))
    end

    -- The DM's Sync, modelled: UI/InitiativeUI.lua sets a debounce timer per
    -- state change and only the last one survives, so a burst produces exactly
    -- one trailing broadcast. world.debounced = false reproduces the pre-fix
    -- behaviour (a broadcast per change).
    local syncPending = false
    function world.Sync()
        if not world.debounced then
            world.dm.ns.Comm.Send("INIT", world.dm.IT.WireState())
            return
        end
        syncPending = true
    end
    function world.Flush()
        if not syncPending then return end
        syncPending = false
        acting = world.dm.name
        world.dm.ns.Comm.Send("INIT", world.dm.IT.WireState())
    end

    -- The DM's pull answer, modelled: the first asker is answered by whisper,
    -- but a second asker inside the same window upgrades the reply to a single
    -- group broadcast that the whole burst rides along on.
    local pullTo, pullPending = nil, false
    function world.Pull(sender)
        if pullPending then
            if pullTo and not world.dm.ns.Comm.SameName(pullTo, sender) then pullTo = nil end
            return
        end
        pullPending, pullTo = true, sender
    end
    function world.FlushPull()
        if not pullPending then return end
        pullPending = false
        acting = world.dm.name
        local state = world.dm.IT.WireState()
        if pullTo then
            world.dm.ns.Comm.Whisper("INIT", state, pullTo)
        else
            world.dm.ns.Comm.Send("INIT", state)
        end
        pullTo = nil
    end

    -- One client: a stubbed AceAddon whose SendCommMessage goes straight onto
    -- the bus, the two real modules, and the handlers UI/InitiativeUI.lua would
    -- register (applying through the REAL SetState/SubmitFor).
    local function NewClient(name, isDM)
        local client = { name = name, broadcasts = 0, whispers = 0, applied = 0, calls = 0 }
        local ns = { Print = function() end }
        acting = name
        ns.Addon = {
            db = { global = {}, profile = { dm = isDM and true or false } },
            Serialize = function(_, env) return JSON.encode(env) end,
            Deserialize = function(_, body)
                local value = JSON.decode(body)
                if type(value) ~= "table" then return false end
                return true, value
            end,
            SendCommMessage = function(_, _, text, dist, target)
                if dist == "WHISPER" then
                    client.whispers = client.whispers + 1
                else
                    client.broadcasts = client.broadcasts + 1
                end
                world.Deliver(dist, target, name, text)
            end,
            RegisterComm = function(_, _, cb) client.receive = cb end,
            RegisterEvent = function() end,
        }
        T.load(ns, "Modules/InitiativeTracker.lua")
        T.load(ns, "Modules/Comm.lua")
        ns.Comm.Init()
        ns.Comm.SetRecognizedDM(NAMES[1])
        client.ns, client.IT = ns, ns.InitiativeTracker
        assert(client.receive, name .. ": OnReceive not registered")

        -- A player adopts the DM's order. The raw wire table is kept too: it is
        -- what proves WireState stripped the DM's private fields, since SetState
        -- would drop them either way.
        ns.Comm.On("INIT", function(state)
            if ns.Comm.IsDM() then return end
            if type(state) ~= "table" then return end
            client.wire = state
            client.applied = client.applied + 1
            ns.InitiativeTracker.SetState(state)
        end)
        -- The DM accepts a submission and re-syncs.
        ns.Comm.On("INITSUBMIT", function(payload, sender)
            if not ns.Comm.IsDM() then return end
            if type(payload) ~= "table" or type(payload.name) ~= "string" then return end
            if ns.InitiativeTracker.SubmitFor(sender, payload.name, payload.init) then
                world.Sync()
            end
        end)
        ns.Comm.On("INITREQ", function(_, sender)
            if not ns.Comm.IsDM() then return end
            world.Pull(sender)
        end)
        ns.Comm.On("INITCALL", function() client.calls = client.calls + 1 end)
        return client
    end

    for i = 1, N do world.clients[i] = NewClient(NAMES[i], i == 1) end
    world.dm = world.clients[1]
    return world
end

-- The roll call: every player answers with their own initiative, SUBMIT_GAP
-- apart, the way a full table answers one popup.
local function RollCall(world)
    for i = 2, N do
        CLOCK = CLOCK + SUBMIT_GAP
        local c = world.clients[i]
        acting = c.name
        c.ns.Comm.Send("INITSUBMIT", { name = "Hero" .. i, init = INITS[i] })
    end
end

-- Asserts every player holds exactly the DM's order (count, names, order).
local function AssertConverged(world, label)
    local want = Signature(world.dm.IT.GetState().combatants)
    for i = 2, N do
        local c = world.clients[i]
        local got = Signature(c.IT.GetState().combatants)
        assert(got == want, label .. ": " .. c.name .. " diverged\n  DM:  " .. want
            .. "\n  got: " .. got)
    end
end

-- 1. Convergence under a tight burst. Eleven submissions land inside half a
-- second; the debounced Sync collapses them into ONE trailing broadcast, and
-- every client ends on the DM's settled order.
local world = NewWorld()
RollCall(world)
assert(world.dm.broadcasts == 0, "a debounced Sync must not broadcast during the burst")
CLOCK = CLOCK + SYNC_DELAY
world.Flush()
assert(world.dm.broadcasts == 1, "a burst must collapse into exactly one INIT broadcast")
assert(#world.dm.IT.GetState().combatants == N - 1, "the DM should hold every submission")
AssertConverged(world, "roll call")
for i = 2, N do
    assert(world.clients[i].applied == 1, "each client applies the one broadcast exactly once")
end

-- 2. Negative control - an INTENTIONAL failure, not an aspiration. The same
-- burst with the debounce removed must still break: a broadcast per submission,
-- and every one that lands inside a receiver's 0.25 s INIT window is dropped, so
-- the group is left holding an order the DM has long since moved past. This is
-- what makes assertion 1 mean anything; if this ever starts converging the
-- harness has stopped reproducing the failure and assertion 1 proves nothing -
-- fix the harness, do not delete this.
local shadow = NewWorld()
shadow.debounced = false
CLOCK = CLOCK + QUIET
RollCall(shadow)
assert(shadow.dm.broadcasts == N - 1, "undebounced, the DM broadcasts once per submission")
local dmSig = Signature(shadow.dm.IT.GetState().combatants)
local diverged = 0
for i = 2, N do
    local c = shadow.clients[i]
    if Signature(c.IT.GetState().combatants) ~= dmSig then
        diverged = diverged + 1
        assert(#c.IT.GetState().combatants < N - 1, "the drop must leave a SHORT order")
    end
end
assert(diverged == N - 1, "negative control: the rate gate must still eat the last broadcast")

-- 3. A late change after the burst settles: the DM adds an NPC and syncs again,
-- and the group follows. (QUIET first - a real late change is seconds later, and
-- the receivers' INIT window from phase 1 has to be open.)
CLOCK = CLOCK + QUIET
acting = world.dm.name
assert(world.dm.IT.Add("Bandit", 8, true), "the DM should be able to add an NPC")
world.Sync()
CLOCK = CLOCK + SYNC_DELAY
world.Flush()
assert(world.dm.broadcasts == 2, "the late change is one more broadcast")
AssertConverged(world, "late change")

-- 4. Group gating at scale: a sender outside the raid roster is ignored by every
-- client. INIT and INITCALL are DM-authoritative on top of this, but INITREQ is
-- not - it isolates the membership gate, and its being dropped is what keeps a
-- stranger from making the DM serialize the whole order on demand.
CLOCK = CLOCK + QUIET
local before = { sig = Signature(world.clients[2].IT.GetState().combatants),
    broadcasts = world.dm.broadcasts, whispers = world.dm.whispers }
assert(not world.dm.ns.Comm.InGroup("Interloper"), "the outsider must fail the roster check")
world.Inject("RAID", nil, "Interloper", "INIT",
    { combatants = { { name = "Spoofed", init = 99 } }, current = 0, round = 0 })
world.Inject("RAID", nil, "Interloper", "INITCALL", {})
for i = 1, N do
    world.Inject("WHISPER", NAMES[i], "Interloper", "INITREQ", {})
end
for i = 2, N do
    local c = world.clients[i]
    assert(Signature(c.IT.GetState().combatants) == before.sig,
        c.name .. " applied an outsider's INIT")
    assert(c.calls == 0, c.name .. " raised a roll call for an outsider")
end
world.FlushPull()
assert(world.dm.broadcasts == before.broadcasts and world.dm.whispers == before.whispers,
    "an outsider's pull must not make the DM answer")

-- 5. Pull coalescing: at a full table everyone opens their combat window within
-- the same few seconds. Answering each asker by whisper would put the same state
-- on the wire once per player, so a second asker inside the window upgrades the
-- reply to a single group broadcast. Assert the message-count property: one
-- message for the whole burst, and not one whisper per asker.
CLOCK = CLOCK + QUIET
before = { broadcasts = world.dm.broadcasts, whispers = world.dm.whispers }
local askers = 0
for i = 2, 6 do
    CLOCK = CLOCK + SUBMIT_GAP
    local c = world.clients[i]
    acting = c.name
    c.ns.Comm.Send("INITREQ", {})
    askers = askers + 1
end
world.FlushPull()
assert(world.dm.whispers == before.whispers, "a multi-asker burst must not whisper per asker")
assert(world.dm.broadcasts == before.broadcasts + 1,
    "a multi-asker burst is answered by ONE group broadcast")
assert(askers > 1, "the coalescing check needs more than one asker to mean anything")
AssertConverged(world, "pull")

-- 6. NPC hit points never leave the DM: they are the DM's private bookkeeping,
-- and IT.WireState strips them (along with the `owner` a submission is bound
-- to) before the state is broadcast.
CLOCK = CLOCK + QUIET
acting = world.dm.name
local dmCombatants = world.dm.IT.GetState().combatants
local ogre = IndexOf(dmCombatants, "Bandit")
assert(ogre and world.dm.IT.AdjustHP(ogre, "30/44"), "the DM should be able to track NPC HP")
assert(dmCombatants[ogre].hp == 30 and dmCombatants[ogre].hpmax == 44)
local owned = 0
for _, c in ipairs(dmCombatants) do
    if c.owner then owned = owned + 1 end
end
assert(owned == N - 1, "every submission should be bound to its sender on the DM's side")
world.Sync()
CLOCK = CLOCK + SYNC_DELAY
world.Flush()
for i = 2, N do
    local c = world.clients[i]
    assert(c.wire, c.name .. " never received a state")
    for _, row in ipairs(c.wire.combatants) do
        assert(row.hp == nil and row.hpmax == nil, c.name .. " received NPC hit points")
        assert(row.owner == nil, c.name .. " received a combatant's owner")
    end
end
AssertConverged(world, "npc hp")

-- Leave the roster APIs as the later test files expect to find them (absent):
-- every file installs the globals it needs itself.
GetTime, GetNumGroupMembers, UnitExists = nil, nil, nil
UnitName = function() return "Me" end
IsInRaid = function() return false end
