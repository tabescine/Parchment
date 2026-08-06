-- The initiative submission round-trip. Two properties are pinned here:
--
-- 1. A player's AddSelf submits WITHOUT consulting the local order. The local
--    state is only a mirror of the DM's last sync and can be stale: the order
--    persists in db.global, so every player ends a session with their own
--    character in it, and any DM-side reset they miss (offline, not yet
--    grouped) leaves the mirror holding that entry. The old HasPlayer guard
--    then refused the roll call locally - no roll, no submit, and not a single
--    line on the DM's side. The DM-side SubmitFor guard is authoritative.
--
-- 2. The DM answers EVERY INITSUBMIT with an INITACK whisper - added, or
--    refused with the reason - including the name-trims-to-empty case that
--    used to fall through both branches with no output at all. The player-side
--    INITACK handler prints the verdict with remote strings sanitised.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallWowStubs()
strtrim = function(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
ACCEPT = "Accept"
IsInGroup = function() return true end

local ns = { Addon = { db = { global = {}, profile = {} } } }
local printed = {}
ns.Print = function(msg) printed[#printed + 1] = msg end
ns.RegisterModule = function() end
ns.UI = { Debounce = function(_, fn) return fn end }

-- Core's remote-text sanitizer, mirrored because Core.lua is not loaded here.
ns.SafeText = function(value, maxLen, fallback)
    local s = (type(value) == "string") and value or tostring(value or "")
    s = s:gsub("|", ""):gsub("%c", " ")
    local cap = maxLen or 64
    if #s > cap then s = s:sub(1, cap) .. "..." end
    if s == "" then return fallback or "?" end
    return s
end

-- Sheet plumbing for AddSelf: a loaded system and one active character.
ns.HasSystem = function() return true end
ns.GetSystem = function() return {} end
ns.GetItemLibrary = function() return {} end
ns.DerivedConfig = function() return {} end
ns.GetActiveCharacter = function() return { name = "Hero" } end
ns.CharacterSheet = { Compute = function(char)
    return { name = char.name, derived = { initiative = 3 }, attributes = {} }
end }

-- Deterministic roller: the d20 always lands 10.
ns.Dice = { Request = function(modifier, onComplete) onComplete(10 + (modifier or 0), 10) end }

-- Comm stub: the role is flippable, every outbound message is recorded.
local handlers, isDM = {}, false
local sends, whispers = {}, {}
ns.Comm = {
    On = function(t, fn) handlers[t] = fn end,
    IsDM = function() return isDM end,
    RecognizedDM = function() return "Dm" end,
    SetRecognizedDM = function() end,
    NormalizeName = function(n)
        if type(n) ~= "string" or n == "" then return nil end
        local key = n:match("^[^-]+")
        return key and key:lower() or nil
    end,
    IsSelf = function() return false end,
    Send = function(t, v) sends[#sends + 1] = { t = t, v = v } return true end,
    Whisper = function(t, v, target)
        whispers[#whispers + 1] = { t = t, v = v, target = target }
        return true
    end,
}

T.load(ns, "Modules/InitiativeTracker.lua")
T.load(ns, "UI/InitiativeUI.lua")
local IT = ns.InitiativeTracker
assert(handlers.INITSUBMIT and handlers.INITACK, "submit/ack handlers not registered")

-- Property 1: a stale mirror holding this player's own character must not
-- block the submit (the DM-side guard is the authoritative duplicate check).
IT.SetState({ combatants = { { name = "Hero", init = 12 } }, current = 0, round = 0 })
ns.InitiativeUI.AddSelf()
assert(#sends == 1 and sends[1].t == "INITSUBMIT",
    "the submit must go out despite the stale local mirror")
assert(sends[1].v.name == "Hero" and sends[1].v.init == 13,
    "the submit must carry the rolled total (d20 10 + modifier 3)")

-- Property 2, DM side: an accepted submission is added, synced, and acked.
isDM = true
IT.Reset()
printed, sends, whispers = {}, {}, {}
handlers.INITSUBMIT({ name = "Wren", init = 14 }, "Wren")
assert(#IT.GetState().combatants == 1, "the DM must accept the submission")
assert(#sends == 1 and sends[1].t == "INIT", "an accepted submission must rebroadcast the order")
assert(#whispers == 1 and whispers[1].t == "INITACK" and whispers[1].target == "Wren",
    "an accepted submission must be acked to its sender")
assert(whispers[1].v.ok == true and whispers[1].v.name == "Wren" and whispers[1].v.init == 14,
    "the ack must carry the accepted name and init")

-- A resubmit from the same sender is refused, and the refusal is acked too.
printed, sends, whispers = {}, {}, {}
handlers.INITSUBMIT({ name = "Wren2", init = 9 }, "Wren")
assert(#IT.GetState().combatants == 1, "a resubmit must not add a second entry")
assert(#whispers == 1 and whispers[1].v.ok == false and type(whispers[1].v.reason) == "string",
    "a refused submission must be acked with the reason")
assert(#printed == 1, "the refusal must also print on the DM's side")

-- A name that trims to empty used to be dropped with no output anywhere; it
-- must now be refused loudly on both ends.
printed, whispers = {}, {}
handlers.INITSUBMIT({ name = "   ", init = 5 }, "Moth")
assert(#IT.GetState().combatants == 1, "an empty name must not add an entry")
assert(#whispers == 1 and whispers[1].target == "Moth" and whispers[1].v.ok == false
    and type(whispers[1].v.reason) == "string", "an empty-name submission must still be acked")
assert(#printed == 1, "an empty-name submission must not be silent on the DM's side")

-- Property 2, player side: the ack prints the verdict; remote strings are
-- sanitised on the way (the notice's own colour codes are ours, so only the
-- remote escape sequences are asserted gone).
isDM = false
printed = {}
handlers.INITACK({ ok = true, name = "Hero", init = 13 })
assert(#printed == 1 and printed[1]:find("13", 1, true), "an ok ack must announce the add")
printed = {}
handlers.INITACK({ ok = false, reason = "|Hitem:6948:0|h[Hearthstone]|h squats the name" })
assert(#printed == 1 and printed[1]:find("Hearthstone", 1, true),
    "a refusal ack must print the reason")
assert(not printed[1]:find("|H", 1, true), "escape codes reached chat: " .. printed[1])

-- Malformed acks are ignored, not errors.
printed = {}
handlers.INITACK("nope")
handlers.INITACK(nil)
assert(#printed == 0, "a malformed ack must be ignored")
