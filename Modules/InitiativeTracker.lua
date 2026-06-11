-- Parchment - Initiative Tracker (logic)
--
-- Owns the combat turn order: a list of combatants (name + initiative value),
-- the current turn index, and the round counter. NPC combatants may also
-- carry DM-tracked hit points (hp/hpmax) - the DM's private bookkeeping.
-- State is persisted in the addon DB so it survives a /reload mid-session.
-- Pure state manipulation here; the UI reads GetState and calls the mutators.
--
-- Sync is handled by the UI layer: the DM broadcasts state (INIT, via
-- WireState so NPC hit points never cross the wire) and players submit their
-- own rolls back (INITSUBMIT); SetState applies a received state and accepts
-- only name/init/isNPC, so remote data cannot smuggle fields in either.
--
-- Reads from: ns.Addon.db.global.initiative, ns.Dice (shared d20 roller).
-- Exposes on ns.InitiativeTracker: GetState, SetState, WireState, Add,
--   AddRolled, Remove, SetCurrent, Next, Prev, Start, Reset, AdjustHP,
--   RollD20, RequestRoll.

local ADDON, ns = ...

ns.InitiativeTracker = ns.InitiativeTracker or {}
local IT = ns.InitiativeTracker

-- Returns the persisted initiative state, creating the default on first use.
local function State()
    local db = ns.Addon.db
    db.global.initiative = db.global.initiative or { combatants = {}, current = 0, round = 0 }
    return db.global.initiative
end

-- Sorts combatants by initiative descending, breaking ties by name. Coerces
-- init defensively so a corrupt entry (e.g. persisted before sanitizing was
-- added) cannot make the comparator throw.
local function SortDescending(state)
    table.sort(state.combatants, function(a, b)
        local ai, bi = tonumber(a.init) or 0, tonumber(b.init) or 0
        if ai ~= bi then return ai > bi end
        return tostring(a.name or "") < tostring(b.name or "")
    end)
end

function IT.GetState()
    return State()
end

-- Replaces the whole turn order (used by players receiving the DM's sync).
-- The incoming table crossed the wire, so it is rebuilt field by field: only
-- well-formed combatants survive and the pointers are coerced into range,
-- ensuring bad remote data can never poison the persisted state.
function IT.SetState(incoming)
    local state = State()
    local combatants = {}
    for _, c in ipairs(type(incoming.combatants) == "table" and incoming.combatants or {}) do
        if type(c) == "table" and type(c.name) == "string" and c.name ~= "" then
            combatants[#combatants + 1] = {
                name = c.name,
                init = tonumber(c.init) or 0,
                isNPC = c.isNPC and true or false,
            }
        end
    end
    state.combatants = combatants
    local current = math.floor(tonumber(incoming.current) or 0)
    state.current = math.max(0, math.min(current, #combatants))
    state.round = math.max(0, math.floor(tonumber(incoming.round) or 0))
end

-- The state as broadcast to players: combatants reduced to name/init/isNPC.
-- NPC hit points are the DM's private bookkeeping and are stripped here, so
-- players never receive them at all.
function IT.WireState()
    local state = State()
    local out = { current = state.current, round = state.round, combatants = {} }
    for i, c in ipairs(state.combatants) do
        out.combatants[i] = { name = c.name, init = c.init, isNPC = c.isNPC and true or false }
    end
    return out
end

-- Sets or adjusts an NPC combatant's hit points from a user-typed string:
--   "12"      sets current HP (and max HP too, while max is unset)
--   "12/40"   sets current and max
--   "+5"/"-7" adjusts current HP (clamped at 0; may exceed max - DM's call)
-- Player rows are refused: their HP comes from their own live vitals.
-- Returns ok, err.
function IT.AdjustHP(index, text)
    local c = State().combatants[index]
    if not c then return false, "no combatant at that position." end
    if not c.isNPC then return false, "player HP comes from their own sheet (live vitals)." end
    text = strtrim(tostring(text or ""))
    local cur, max = text:match("^(%d+)%s*/%s*(%d+)$")
    if cur then
        c.hp, c.hpmax = tonumber(cur), tonumber(max)
        return true
    end
    local sign, n = text:match("^([+%-])(%d+)$")
    if sign then
        local delta = tonumber(n) * (sign == "-" and -1 or 1)
        c.hp = math.max(0, (c.hp or 0) + delta)
        return true
    end
    n = text:match("^(%d+)$")
    if n then
        c.hp = tonumber(n)
        c.hpmax = c.hpmax or c.hp
        return true
    end
    return false, "use a number, +N / -N, or current/max."
end

-- Rolls a d20 locally and adds a modifier (hidden from the group).
function IT.RollD20(modifier)
    return math.random(1, 20) + (modifier or 0)
end

-- Requests a d20 roll via the shared roller (public-roll aware), calling
-- onComplete(total, raw) when it resolves. See Modules/Dice.lua.
function IT.RequestRoll(modifier, onComplete)
    return ns.Dice.Request(modifier, onComplete)
end

-- Adds a combatant with an explicit initiative total, then re-sorts. Returns
-- the combatant table. Ignores blank or non-string names; init is coerced to a
-- number (it may arrive over the wire via INITSUBMIT).
function IT.Add(name, init, isNPC)
    if type(name) ~= "string" then return nil end
    name = strtrim(name)
    if name == "" then return nil end
    local state = State()
    local combatant = { name = name, init = tonumber(init) or 0, isNPC = isNPC and true or false }

    -- The sort can shift indices; keep the active turn on the same combatant.
    local active = state.combatants[state.current]
    table.insert(state.combatants, combatant)
    SortDescending(state)
    if active then
        for i, c in ipairs(state.combatants) do
            if c == active then state.current = i break end
        end
    elseif state.current == 0 then
        state.current = 1
    end
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

-- Removes the combatant at index, keeping the current pointer valid. Entries
-- above the removed slot shift down one, so the pointer follows them.
function IT.Remove(index)
    local state = State()
    if not state.combatants[index] then return end
    table.remove(state.combatants, index)
    if index < state.current then state.current = state.current - 1 end
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
