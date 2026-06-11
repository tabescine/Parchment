-- Party.lua: vitals snapshots, the share-vitals opt-out, the DM flag, and
-- received-field coercion.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")

IsInGroup = function() return true end
GetTime = function() return 100 end
C_Timer = { After = function(_, fn) fn() end }   -- throttle fires immediately

local ns = {}
local handlers, sent = {}, {}
local isDM = false
ns.Comm = {
    On = function(t, fn) handlers[t] = fn end,
    Send = function(t, payload) sent[#sent + 1] = { t = t, payload = payload }; return true end,
    IsSelf = function(sender) return sender == "Me" end,
    IsDM = function() return isDM end,
}
ns.Addon = { db = { profile = {} } }
ns.HasSystem = function() return true end
ns.GetSystem = function() return {} end
ns.GetActiveCharacter = function() return { name = "X" } end
ns.CharacterSheet = { Compute = function() return {
    name = "Hero", level = 3,
    derived = { hp = { current = 7, max = 12, temp = 1 }, mana = { current = 2, max = 4 }, ac = 13, initiative = 2 },
} end }
T.load(ns, "Modules/Party.lua")
assert(handlers.VITREQ and handlers.VITALS, "comm handlers not registered")

-- A VITREQ is answered with a full snapshot, including the DM flag.
isDM = true
handlers.VITREQ({}, "Asker")
assert(#sent == 1 and sent[1].t == "VITALS", "VITREQ not answered")
local snap = sent[1].payload
assert(snap.name == "Hero" and snap.level == 3 and snap.hp == 7 and snap.hpmax == 12)
assert(snap.temp == 1 and snap.mana == 2 and snap.manamax == 4 and snap.ac == 13 and snap.init == 2)
assert(snap.dm == true, "DM flag missing from snapshot")
isDM = false

-- Our own echoed VITREQ is ignored.
handlers.VITREQ({}, "Me")
assert(#sent == 1, "answered own VITREQ echo")

-- OnVitalsChanged pushes (throttle stubbed to immediate).
ns.Party.OnVitalsChanged()
assert(#sent == 2 and sent[2].t == "VITALS")

-- The opt-out silences pushes AND answers.
ns.Addon.db.profile.shareVitals = false
ns.Party.OnVitalsChanged()
handlers.VITREQ({}, "Asker")
assert(#sent == 2, "opt-out did not silence broadcasts")
ns.Addon.db.profile.shareVitals = true
handlers.VITREQ({}, "Asker")
assert(#sent == 3, "re-enabling sharing did not resume answers")

-- Received vitals: coerced, cached by sender, DM flag normalized; own echo
-- and malformed payloads ignored.
handlers.VITALS({ name = "Ally", level = "2", hp = 5.7, hpmax = 10, temp = 0,
    mana = 0, manamax = 0, ac = 11, init = -1, dm = 1 }, "Friend")
local roster = ns.Party.GetRoster()
assert(roster.Friend and roster.Friend.level == 2 and roster.Friend.hp == 5)
assert(roster.Friend.dm == true and roster.Friend.init == -1 and roster.Friend.time == 100)
handlers.VITALS({ name = "MeChar" }, "Me")
assert(roster.Me == nil, "cached own echo")
handlers.VITALS({ level = 2 }, "NoName")
assert(roster.NoName == nil, "cached a nameless payload")
handlers.VITALS({ name = "Quiet", dm = false }, "Other")
assert(roster.Other.dm == false)

ns.Party.Clear()
assert(next(ns.Party.GetRoster()) == nil)
