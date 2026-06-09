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
--   Next, Prev, Start, Reset, RollD20.

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

-- Rolls a d20 and adds a modifier.
function IT.RollD20(modifier)
    return math.random(1, 20) + (modifier or 0)
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

-- Adds a combatant whose initiative is rolled as d20 + modifier. Returns the
-- rolled value.
function IT.AddRolled(name, modifier, isNPC)
    local roll = IT.RollD20(modifier)
    if IT.Add(name, roll, isNPC) then return roll end
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
