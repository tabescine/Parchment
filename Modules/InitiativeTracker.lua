-- Parchment - Initiative Tracker (logic)
--
-- Owns the combat turn order: a list of combatants (name + initiative value),
-- the current turn index, and the round counter. State is persisted in the
-- addon DB so it survives a /reload mid-session. Pure state manipulation here;
-- the UI reads GetState and calls these mutators.
--
-- DM/player roles and AceComm sync are a later work item; for now this is a
-- single local turn order the DM drives.
--
-- Reads from: ns.Addon.db.global.initiative.
-- Exposes on ns.InitiativeTracker: GetState, Add, AddRolled, Remove, SetCurrent,
--   Next, Prev, Start, Reset, RollD20, RequestRoll.

local ADDON, ns = ...

ns.InitiativeTracker = ns.InitiativeTracker or {}
local IT = ns.InitiativeTracker

-- Seed the RNG once so d20 rolls are not identical every session.
if math.randomseed then
    local seed = (time and time() or 0) + math.floor((GetTime and GetTime() or 0) * 1000)
    math.randomseed(seed)
    math.random()
end

-- Returns the persisted initiative state, creating the default on first use.
local function State()
    local db = ns.Addon.db
    db.global.initiative = db.global.initiative or { combatants = {}, current = 0, round = 0 }
    return db.global.initiative
end

-- Sorts combatants by initiative descending, breaking ties by name.
local function SortDescending(state)
    table.sort(state.combatants, function(a, b)
        if a.init ~= b.init then return a.init > b.init end
        return (a.name or "") < (b.name or "")
    end)
end

function IT.GetState()
    return State()
end

-- Replaces the whole turn order (used by players receiving the DM's sync).
function IT.SetState(incoming)
    local state = State()
    state.combatants = incoming.combatants or {}
    state.current = incoming.current or 0
    state.round = incoming.round or 0
end

-- Rolls a d20 locally and adds a modifier (hidden from the group).
function IT.RollD20(modifier)
    return math.random(1, 20) + (modifier or 0)
end

-- Public-roll capture --------------------------------------------------------
--
-- When db.profile.publicRolls is set, rolls go through the in-game dice roller
-- (RandomRoll) so the whole party sees them, and we read the result back off the
-- system chat message. Requests queue FIFO and are matched to results in order.

local rollQueue = {}

-- Turns a format string like "%s rolls %d (%d-%d)" into a capture pattern.
local function ToPattern(fmt)
    local p = fmt:gsub("[%-%.%(%)%[%]%+%*%?%^%$%%]", "%%%0")
    p = p:gsub("%%%%s", "(.+)")
    p = p:gsub("%%%%d", "(%%d+)")
    return p
end
local ROLL_PATTERN = ToPattern(RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)")

-- True when public rolling is enabled and the in-game roller is available.
local function PublicEnabled()
    return ns.Addon and ns.Addon.db and ns.Addon.db.profile.publicRolls
        and type(RandomRoll) == "function"
end

-- Requests a d20 roll, calling onComplete(total, raw) when it resolves. With
-- public rolls off it resolves immediately and locally; with them on it fires a
-- RandomRoll and resolves when the system message arrives (3s local fallback).
function IT.RequestRoll(modifier, onComplete)
    modifier = modifier or 0
    if not PublicEnabled() then
        local raw = math.random(1, 20)
        onComplete(raw + modifier, raw)
        return
    end
    local req = { modifier = modifier, onComplete = onComplete }
    rollQueue[#rollQueue + 1] = req
    if C_Timer and C_Timer.NewTimer then
        req.timer = C_Timer.NewTimer(3, function()
            for i, r in ipairs(rollQueue) do
                if r == req then
                    table.remove(rollQueue, i)
                    local raw = math.random(1, 20)
                    req.onComplete(raw + req.modifier, raw)
                    return
                end
            end
        end)
    end
    RandomRoll(1, 20)
end

-- Listens for our own 1-20 system rolls and resolves the oldest pending request.
local listener = CreateFrame and CreateFrame("Frame")
if listener then
    listener:RegisterEvent("CHAT_MSG_SYSTEM")
    listener:SetScript("OnEvent", function(_, _, message)
        if #rollQueue == 0 then return end
        local who, raw, low, high = message:match(ROLL_PATTERN)
        if not who then return end
        raw, low, high = tonumber(raw), tonumber(low), tonumber(high)
        if low ~= 1 or high ~= 20 then return end
        local me = UnitName and UnitName("player")
        if me and who ~= me then return end
        local req = table.remove(rollQueue, 1)
        if req.timer then req.timer:Cancel() end
        req.onComplete(raw + (req.modifier or 0), raw)
    end)
end

-- Adds a combatant with an explicit initiative total, then re-sorts. Returns
-- the combatant table. Ignores blank names.
function IT.Add(name, init, isNPC)
    name = name and strtrim(name) or ""
    if name == "" then return nil end
    local state = State()
    local combatant = { name = name, init = init or 0, isNPC = isNPC and true or false }
    table.insert(state.combatants, combatant)
    SortDescending(state)
    if state.current == 0 then state.current = 1 end
    return combatant
end

-- Adds a combatant whose initiative is rolled as d20 + modifier. The roll may be
-- asynchronous (public rolls), so the combatant is delivered via onAdded(combatant,
-- total, raw) rather than returned.
function IT.AddRolled(name, modifier, isNPC, onAdded)
    name = name and strtrim(name) or ""
    if name == "" then if onAdded then onAdded(nil) end return end
    IT.RequestRoll(modifier, function(total, raw)
        local combatant = IT.Add(name, total, isNPC)
        if onAdded then onAdded(combatant, total, raw) end
    end)
end

-- Removes the combatant at index, keeping the current pointer valid.
function IT.Remove(index)
    local state = State()
    if not state.combatants[index] then return end
    table.remove(state.combatants, index)
    local n = #state.combatants
    if state.current > n then state.current = n end
    if state.current < 1 and n > 0 then state.current = 1 end
end

-- Sets the current turn to a specific index.
function IT.SetCurrent(index)
    local state = State()
    if state.combatants[index] then state.current = index end
end

-- Advances to the next turn, wrapping and incrementing the round.
function IT.Next()
    local state = State()
    local n = #state.combatants
    if n == 0 then return end
    if state.current == 0 then
        state.current = 1
        if state.round == 0 then state.round = 1 end
        return
    end
    state.current = state.current + 1
    if state.current > n then
        state.current = 1
        state.round = state.round + 1
    end
end

-- Steps back one turn, wrapping and decrementing the round when it wraps.
function IT.Prev()
    local state = State()
    local n = #state.combatants
    if n == 0 then return end
    state.current = state.current - 1
    if state.current < 1 then
        state.current = n
        if state.round > 1 then state.round = state.round - 1 end
    end
end

-- Starts combat at the top of the order, round 1.
function IT.Start()
    local state = State()
    if #state.combatants > 0 then
        state.current = 1
        state.round = 1
    end
end

-- Clears all combatants and resets the round.
function IT.Reset()
    local state = State()
    state.combatants = {}
    state.current = 0
    state.round = 0
end
