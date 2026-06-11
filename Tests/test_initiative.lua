-- InitiativeTracker: turn-order mechanics, NPC hit-point bookkeeping
-- (AdjustHP), and the privacy guarantee that WireState/SetState never let
-- NPC HP cross the wire.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
strtrim = function(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

local ns = { Addon = { db = { global = {} } } }
T.load(ns, "Modules/InitiativeTracker.lua")
local IT = ns.InitiativeTracker

-- Adding inserts at the ordered position (initiative descending) and keeps
-- the active turn on the same combatant when indices shift.
assert(IT.Add("Slow", 5))
assert(IT.Add("Fast", 18, true))
assert(IT.Add("Mid", 10))
local s = IT.GetState()
assert(s.combatants[1].name == "Fast" and s.combatants[2].name == "Mid" and s.combatants[3].name == "Slow")
assert(s.combatants[1].isNPC and not s.combatants[2].isNPC)
assert(IT.Add("  ") == nil and IT.Add(nil) == nil, "blank names must be refused")

-- Adding must NOT start combat: no current turn, no round (so the timers
-- stay off and the round count starts at 1 only when the DM starts).
assert(s.current == 0 and s.round == 0, "adding combatants must not start combat")

-- A first Next acts as a start too.
IT.Next()
assert(s.current == 1 and s.round == 1, "first Next must begin round 1")

IT.Start()
assert(s.current == 1 and s.round == 1)
IT.SetCurrent(3)
IT.Add("Faster", 20)          -- shifts every index down by one
assert(s.combatants[s.current].name == "Slow", "active turn must follow the combatant")

-- Next/Prev wrap and track the round.
IT.Next()                      -- Slow (4) -> wrap to Faster (1), round 2
assert(s.current == 1 and s.round == 2)
IT.Prev()                      -- back to Slow, round 1
assert(s.current == 4 and s.round == 1)

-- Remove keeps the pointer on the same combatant where possible.
IT.SetCurrent(4)               -- Slow
IT.Remove(1)                   -- Faster gone; everything shifts down
assert(s.combatants[s.current].name == "Slow")
assert(#s.combatants == 3)

-- AdjustHP: only NPC rows; number / +N / -N / cur-max syntaxes.
local npcIndex, pcIndex
for i, c in ipairs(s.combatants) do
    if c.isNPC then npcIndex = i else pcIndex = pcIndex or i end
end
local ok, err = IT.AdjustHP(pcIndex, "10")
assert(not ok and err:find("their own sheet"), "PC rows must refuse DM HP")
ok = IT.AdjustHP(npcIndex, "30")
assert(ok and s.combatants[npcIndex].hp == 30 and s.combatants[npcIndex].hpmax == 30,
    "plain number must set current and (unset) max")
assert(IT.AdjustHP(npcIndex, "-7"))
assert(s.combatants[npcIndex].hp == 23)
assert(IT.AdjustHP(npcIndex, "+2"))
assert(s.combatants[npcIndex].hp == 25)
assert(IT.AdjustHP(npcIndex, "-99"))
assert(s.combatants[npcIndex].hp == 0, "current HP clamps at 0")
assert(IT.AdjustHP(npcIndex, "12/40"))
assert(s.combatants[npcIndex].hp == 12 and s.combatants[npcIndex].hpmax == 40)
ok, err = IT.AdjustHP(npcIndex, "potato")
assert(not ok and err ~= nil)
ok, err = IT.AdjustHP(99, "5")
assert(not ok, "out-of-range index must fail")

-- WireState: same order/pointers, but NO hp fields - the privacy guarantee.
local wire = IT.WireState()
assert(#wire.combatants == #s.combatants and wire.current == s.current and wire.round == s.round)
for _, c in ipairs(wire.combatants) do
    assert(c.hp == nil and c.hpmax == nil, "NPC HP leaked onto the wire")
    assert(c.name and c.init ~= nil and c.isNPC ~= nil)
end

-- SetState: rebuilt field by field - smuggled hp fields are dropped, bad
-- entries skipped, pointers clamped.
IT.SetState({
    combatants = {
        { name = "Remote", init = "12", isNPC = true, hp = 99, hpmax = 99 },
        { name = "", init = 3 },          -- invalid: skipped
        "garbage",                         -- invalid: skipped
    },
    current = 42, round = -3,
})
s = IT.GetState()
assert(#s.combatants == 1 and s.combatants[1].name == "Remote" and s.combatants[1].init == 12)
assert(s.combatants[1].hp == nil and s.combatants[1].hpmax == nil, "SetState accepted smuggled HP")
assert(s.current == 1 and s.round == 0, "pointers not clamped")

IT.Reset()
assert(#IT.GetState().combatants == 0 and IT.GetState().current == 0)

-- Duplicate guard: a player may appear only once (case-insensitive); NPC
-- names may repeat freely.
assert(IT.Add("Wren", 12))
assert(IT.HasPlayer("Wren") and IT.HasPlayer("wREN"))
assert(not IT.HasPlayer("Other") and not IT.HasPlayer(nil))
local dup, dupErr = IT.Add("wren", 15)
assert(dup == nil and dupErr:find("already in the turn order"), tostring(dupErr))
assert(IT.Add("Wolf", 8, true) and IT.Add("Wolf", 11, true), "NPC duplicates must be allowed")
assert(not IT.HasPlayer("Wolf"), "NPCs must not count as player entries")
assert(IT.Add("Wolf", 9), "a player may share a name with NPCs")
assert(#IT.GetState().combatants == 4)
-- AddRolled refuses a duplicate player BEFORE rolling, via the callback.
local gotErr
IT.AddRolled("Wren", 0, false, nil, function(c, _, _, err) gotErr = (c == nil) and err end)
assert(gotErr and gotErr:find("already in the turn order"), tostring(gotErr))
IT.Reset()

-- Tie-breaking: equal initiative orders by the tb value (the system's
-- initiative_tiebreaker stat, captured on add); absent tb sorts last; equal
-- on both keeps insertion order (stable - the DM resolves by hand).
IT.Add("A", 10, false, 2)
IT.Add("B", 10, false, 5)            -- same roll, higher tiebreak: goes first
IT.Add("C", 10, false)               -- no tiebreak value: goes last
IT.Add("D", 10, false, 2)            -- equal to A on both: after A (stable)
s = IT.GetState()
local order = {}
for _, c in ipairs(s.combatants) do order[#order + 1] = c.name end
assert(table.concat(order, ",") == "B,A,D,C", table.concat(order, ","))

-- Move: adjacent swap, pointer follows the combatant, bounds respected.
IT.SetCurrent(3)                     -- D
assert(IT.Move(3, -1))               -- D above A
s = IT.GetState()
assert(s.combatants[2].name == "D" and s.combatants[3].name == "A")
assert(s.current == 2, "active turn must follow the moved combatant")
assert(IT.Move(1, 1))                -- B down past D
assert(IT.GetState().combatants[1].name == "D")
assert(not IT.Move(1, -1), "moving the top row up must fail")
assert(not IT.Move(#s.combatants, 1), "moving the bottom row down must fail")

-- A later add must NOT undo the manual ordering of existing rows.
IT.Add("E", 10, false, 99)           -- outranks all current init-10 rows
s = IT.GetState()
order = {}
for _, c in ipairs(s.combatants) do order[#order + 1] = c.name end
assert(table.concat(order, ",") == "E,D,B,A,C", table.concat(order, ","))
