-- InitiativeTracker: turn-order mechanics, NPC hit-point bookkeeping
-- (AdjustHP), and the privacy guarantee that WireState/SetState never let
-- NPC HP cross the wire. The tail of the file adds the wire-facing limits the
-- comm layer cannot enforce - SetState's combatant-count cap, the UI's render
-- ceiling, and the sanitising of remote strings on their way to chat - by
-- driving UI/InitiativeUI.lua's sync handlers with stubbed frames.
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

-- Wire-sourced COUNTS need the same line as the lengths: the comm layer bounds
-- a payload's decompressed bytes, not its element count, and combatants
-- compress far enough that thousands of them fit under every wire cap. Each one
-- persists in the SavedVariables and becomes a frame the UI can never destroy,
-- so SetState truncates and reports what it dropped.
IT.Reset()
local FLOOD = {}
for i = 1, 5000 do FLOOD[i] = { name = "Mob" .. i, init = i } end
local dropped = IT.SetState({ combatants = FLOOD, current = 5000, round = 1 })
local CAP = #IT.GetState().combatants
assert(CAP > 0 and CAP < 5000, "SetState must cap the combatant count (kept " .. CAP .. ")")
assert(dropped == 5000 - CAP, "SetState must report how many combatants it dropped")
assert(IT.GetState().current == CAP, "the turn pointer must clamp to the truncated list")

-- An order that fits still applies whole, and leaves no truncated rows behind.
assert(IT.SetState({ combatants = { { name = "Solo", init = 1 } }, current = 1, round = 1 }) == 0)
assert(#IT.GetState().combatants == 1, "a later state must replace the truncated one")

-- The sync handlers in UI/InitiativeUI.lua. That file only registers handlers
-- and popups at load time, so stubbed globals are enough to drive it here.
T.InstallWowStubs()
ACCEPT = "Accept"

-- Core's ns.SafeText, mirrored: this file never loads Core.lua.
ns.SafeText = function(value, maxLen, fallback)
    local str = (type(value) == "string") and value or tostring(value or "")
    str = str:gsub("|", ""):gsub("%c", " ")
    local cap = maxLen or 64
    if #str > cap then str = str:sub(1, cap) .. "..." end
    if str == "" then return fallback or "?" end
    return str
end

local printed = {}
ns.Print = function(msg) printed[#printed + 1] = msg end
ns.RegisterModule = function() end
ns.Addon.db.profile = {}
-- Debounce must be present before the module loads: Sync is built from it at
-- load time. It fires straight through here, so the existing assertions about
-- what a single change broadcasts still read as written; the burst-collapsing
-- behaviour it exists for is measured in test_init_scale.lua.
ns.UI = { HILITE = { 0, 0, 0, 0 }, DIM = { 0, 0, 0 }, GOLD = { 1, 1, 1 },
    TEXT = { 1, 1, 1 }, RED = { 1, 0, 0 },
    Debounce = function(_, fn) return fn end }

-- Comm stub: the role and the recognized DM are flippable (both decide whether
-- the window pulls on open), and every outbound message is recorded so the
-- push/pull distinction - group Send vs. targeted Whisper - can be asserted.
local handlers, isDM, recognizedDM = {}, true, "Dm"
local sends, whispers = {}, {}
ns.Comm = {
    On = function(msgType, fn) handlers[msgType] = fn end,
    IsDM = function() return isDM end,
    RecognizedDM = function() return recognizedDM end,
    SetRecognizedDM = function() end,
    NormalizeName = function(n) return type(n) == "string" and n:lower() or nil end,
    IsSelf = function() return false end,
    Send = function(t, v) sends[#sends + 1] = { t = t, v = v } return true end,
    Whisper = function(t, v, target)
        whispers[#whispers + 1] = { t = t, v = v, target = target }
        return true
    end,
}
T.load(ns, "UI/InitiativeUI.lua")
assert(handlers.INIT and handlers.INITSUBMIT and handlers.TURNEND, "sync handlers not registered")
assert(handlers.INITREQ and handlers.INITCALL, "the pull/roll-call handlers were not registered")

-- Everything printed since the last checkpoint, as one string.
local function chat() return table.concat(printed, "\n") end

-- Remote strings must never reach chat with their escape codes intact: a
-- "|H...|h[...]|h" name renders as a CLICKABLE forged link in the victim's chat
-- frame and "|T...|t" injects an arbitrary texture.
local EVIL = "|Hitem:6948:0|h[Hearthstone]|h"
IT.Reset()
printed = {}
handlers.INITSUBMIT({ name = EVIL, init = 12 }, "Mallory")
assert(#IT.GetState().combatants == 1, "the DM must accept the submission")
assert(#printed == 1 and chat():find("Hearthstone", 1, true), chat())
assert(not chat():find("|", 1, true), "escape codes reached chat: " .. chat())

-- The end-of-turn notice prints the combatant's name, so it holds the same line.
IT.SetCurrent(1)
printed = {}
handlers.TURNEND({ name = IT.GetState().combatants[1].name }, "Mallory")
assert(#printed == 1 and chat():find("ended", 1, true), chat())
assert(not chat():find("|", 1, true), "escape codes reached chat: " .. chat())

-- A truncated INIT is announced rather than applied quietly, and the sender's
-- name is sanitised on the way (the notice's own colour codes are ours, so only
-- the remote escapes are asserted gone).
isDM = false
IT.Reset()
printed = {}
handlers.INIT({ combatants = FLOOD, current = 0, round = 1 }, "|Hplayer:Eve|hEve|h")
assert(#IT.GetState().combatants == CAP, "the INIT handler must apply the capped order")
assert(chat():find("dropped", 1, true), "a truncated order must be announced: " .. chat())
assert(not chat():find("|H", 1, true), "the sender name reached chat as a link: " .. chat())

-- The render ceiling. State also reaches the window from the persisted DB - a
-- hand-edited SavedVariables file never passes through SetState - and WoW
-- cannot destroy a frame, so the list must refuse to build rows without bound.
local frames = 0
-- Widget stand-in: WoW methods are CapitalCase, while the UI's own fields are
-- lowercase and must read as nil until it sets them (the code branches on them).
-- SetScript records into the widget's own `scripts` table, so a test can invoke
-- a button's handler the way a click would.
local function fakeFrame()
    local f
    f = setmetatable({ scripts = {} }, { __index = function(_, key)
        if not key:match("^%u") then return nil end
        if key == "IsShown" then return function() return true end end
        if key == "SetScript" then return function(_, event, fn) f.scripts[event] = fn end end
        if key:match("^Get") then return function() return 0 end end
        return function() return fakeFrame() end
    end })
    return f
end
CreateFrame = function() frames = frames + 1 return fakeFrame() end
GetTime = function() return 0 end
IsInGroup = function() return false end

local frame = fakeFrame()
for _, key in ipairs({ "titleFS", "addBtn", "rollBtn", "npcCheck", "startBtn", "nextBtn",
    "resetBtn", "meBtn", "callBtn", "publicCheck", "timerBtn", "timerText", "scroll", "content" }) do
    frame[key] = fakeFrame()
end
frame.content.rows = {}
ns.InitiativeUI.frame = frame

local hacked = IT.GetState()
hacked.combatants = {}
for i = 1, 5000 do hacked.combatants[i] = { name = "Mob" .. i, init = i } end
hacked.current, hacked.round = 1, 1
ns.InitiativeUI.RefreshIfShown()
local rows = #frame.content.rows
assert(rows > 0 and rows < 5000, "the UI must cap the rows it builds (built " .. rows .. ")")
assert(frame.content.overflow, "the rows past the ceiling must be announced in the list")

-- Rows stay pooled: re-rendering the same order creates no further frames.
local built = frames
ns.InitiativeUI.RefreshIfShown()
assert(#frame.content.rows == rows and frames == built, "rows must be reused, not re-created")

-- The on-demand halves of the sync: the pull a player's window performs when it
-- opens, and the roll call the DM broadcasts. Sync itself is push-only, so
-- without the pull a player who reloaded or joined mid-combat sees nothing
-- until the DM next changes something.
IT.Reset()

-- Opens the window in a given role/group/recognition state and returns what it
-- put on the wire.
local function opened(dm, grouped, recognized)
    isDM, recognizedDM = dm, recognized
    IsInGroup = function() return grouped end
    sends, whispers = {}, {}
    ns.InitiativeUI.Open()
    return sends
end

assert(#opened(false, true, "Dm") == 1 and sends[1].t == "INITREQ",
    "a player opening the window must pull the order from the DM")

-- Nobody to ask (or asking ourselves): all three cases must stay silent, or
-- every solo /pmt combat would spam the channel.
assert(#opened(true, true, "Dm") == 0, "the DM must not pull their own state")
assert(#opened(false, false, "Dm") == 0, "solo play must not send anything")
assert(#opened(false, true, nil) == 0, "with no recognized DM there is nobody to ask")

-- The DM answers a pull by WHISPERING the order back to that one asker: a
-- single window opening must not push a full state at the whole group.
isDM = true
IT.Add("Wolf", 8, true)
sends, whispers = {}, {}
handlers.INITREQ({}, "Wren")
assert(#whispers == 1 and whispers[1].t == "INIT" and whispers[1].target == "Wren",
    "the DM must whisper INIT back to the asker")
assert(whispers[1].v and #whispers[1].v.combatants == 1, "the answer must carry the wire state")
assert(#sends == 0, "answering a pull must not broadcast to the group")

-- Only the DM answers - a player receiving a stray pull does nothing at all.
isDM = false
sends, whispers = {}, {}
handlers.INITREQ({}, "Wren")
assert(#whispers == 0 and #sends == 0, "a non-DM must not answer a pull")

-- The roll call button. Building the REAL window (rather than the stand-in
-- above) is what puts its OnClick within reach.
ns.UI.CreateWindow = function()
    local w = fakeFrame()
    w.titleFS = fakeFrame()
    return w
end
ns.UI.SetPlaceholder = function() end
ns.UI.Debounce = function(_, fn) return fn end

IT.Reset()
isDM = true
IsInGroup = function() return true end
ns.InitiativeUI.frame = nil
sends = {}
ns.InitiativeUI.Open()
local window = ns.InitiativeUI.frame
assert(window and window.callBtn, "the action row must carry a roll call button")
assert(#sends == 0, "the DM's own window must not pull")
window.callBtn.scripts.OnClick()
assert(#sends == 1 and sends[1].t == "INITCALL", "the button must call the group to roll")

-- The call as it lands on a player: a prompt naming the caller (sanitised - the
-- name is remote) and the character it would roll, whose accept path is AddSelf
-- itself, which owns the no-system / no-character / already-entered checks.
local shown
StaticPopup_Show = function(which, a, b, data)
    shown = { which = which, a = a, b = b, data = data }
end
isDM = false
ns.GetActiveCharacter = function() return { name = "Wren" } end
handlers.INITCALL({}, "|Hplayer:Eve|hEve|h")
assert(shown and shown.which == "PARCHMENT_INIT_CALL", "the roll call must prompt the player")
assert(not shown.a:find("|", 1, true), "the caller's name reached the popup unsanitised")
assert(shown.b:find("Wren", 1, true), "the prompt must name the character it would roll")

local rolled = false
local realAddSelf = ns.InitiativeUI.AddSelf
ns.InitiativeUI.AddSelf = function() rolled = true end
StaticPopupDialogs["PARCHMENT_INIT_CALL"].OnAccept(nil, shown.data)
ns.InitiativeUI.AddSelf = realAddSelf
assert(rolled, "accepting the roll call must go through AddSelf")

-- No active character: still a usable prompt, just without the name line.
shown = nil
ns.GetActiveCharacter = function() return nil end
handlers.INITCALL({}, "Dm")
assert(shown and shown.b == "", "a character-less client must still get the prompt")
