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

-- Removing a combatant BEFORE combat starts must not begin combat: the pre-combat
-- pointer (current == 0) has to stay 0, or the round counter never leaves 0.
IT.Reset()
IT.Add("One", 15)
IT.Add("Two", 10)
IT.Add("Three", 5)
assert(IT.GetState().current == 0 and IT.GetState().round == 0)
IT.Remove(2)                   -- DM fixes a mistyped entry before pressing Start
assert(IT.GetState().current == 0, "a pre-combat remove must not start a turn")
assert(IT.GetState().round == 0)
IT.Next()                      -- the real start
assert(IT.GetState().current == 1 and IT.GetState().round == 1, "first Next must begin round 1")
IT.Reset()
IT.Add("Slow", 5); IT.Add("Fast", 18, true); IT.Add("Mid", 10)
s = IT.GetState()

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
ok = IT.AdjustHP(99, "5")
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
IT.AddRolled("Wren", 0, false, nil, function(c, _, _, e) gotErr = (c == nil) and e end)
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

-- Player submissions are bound to their sender (the Phase 1 trust model).
IT.Reset()

-- SubmitFor records the submitter as the combatant's owner and returns the
-- clamped entry. Owner is realm-qualified as received.
local c1 = IT.SubmitFor("Bob-Realm", "Gandalf", 15)
assert(c1 and c1.owner == "Bob-Realm" and c1.init == 15, "submission not bound to its sender")

-- One live submission per player: a resubmit (realm-tolerant match) is refused,
-- so a player cannot flood the order with extra entries.
dup, dupErr = IT.SubmitFor("Bob", "Imposter", 20)
assert(dup == nil and dupErr, "a second submission from the same player must be refused")
assert(#IT.GetState().combatants == 1, "the refused resubmit must not add a combatant")

-- Wire-sourced init/tb are floored and bounded on the authoritative side.
local hi = IT.SubmitFor("Carol", "Big", 1e9, 1e9)
assert(hi.init == 999 and hi.tb == 999, "init/tb must be clamped to the sane maximum")
local lo = IT.SubmitFor("Dave", "Neg", -5000, 3.9)
assert(lo.init == -999 and lo.tb == 3, "init must clamp to the minimum and tb must floor")

-- Owner is DM-private: it never crosses the wire.
for _, c in ipairs(IT.WireState().combatants) do
    assert(c.owner == nil, "owner must be stripped from the broadcast state")
end

-- EndTurnFor advances only for the player who owns the ACTIVE combatant, and
-- only when the claimed name matches. Order is init-desc: Big, Gandalf, Neg.
local state = IT.GetState()
assert(state.combatants[2].name == "Gandalf")
IT.SetCurrent(2)
assert(IT.EndTurnFor("Mallory", "Gandalf") == nil, "a non-owner must not end the turn")
assert(IT.GetState().current == 2, "a refused end-turn must not advance")
assert(IT.EndTurnFor("Bob", "Wrongname") == nil, "a mismatched name must not end the turn")
assert(IT.GetState().current == 2)
local ended = IT.EndTurnFor("Bob-Other", "Gandalf")
assert(ended and ended.name == "Gandalf", "the owner must be able to end their own turn")
assert(IT.GetState().current == 3, "ending the turn must advance the order")

-- An NPC's turn is never player-endable (NPC HP/turns are the DM's alone).
IT.Reset()
IT.Add("Ogre", 12, true)
IT.Start()
assert(IT.EndTurnFor("Bob", "Ogre") == nil, "a player must not end an NPC's turn")

-- Wire-sourced names hold the same clamped line as the numeric fields: both
-- SetState (INIT) and Add (INITSUBMIT via SubmitFor) cap the length, so a peer
-- cannot persist a multi-KB name into the SavedVariables.
IT.Reset()
local LONG = string.rep("x", 500)
IT.SetState({ combatants = { { name = LONG, init = 1 } }, current = 0, round = 0 })
assert(#IT.GetState().combatants[1].name == 64, "SetState must cap combatant name length")
IT.Reset()
assert(IT.Add(LONG, 5, true))
assert(#IT.GetState().combatants[1].name == 64, "Add must cap combatant name length")
