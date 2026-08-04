-- Party.lua: vitals snapshots, the share-vitals opt-out, the DM flag, and
-- received-field coercion. The tail of the file drives UI/PartyUI.lua's render
-- path against stubbed widgets: the own row the roster can never contain, the
-- sort that keeps it first, the sanitising of wire-sourced names, row pooling,
-- stale dimming and the empty state.
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
    NormalizeName = function(n) return n and n:match("^[^-]+"):lower() or nil end,
}
ns.Addon = { db = { profile = {} } }
ns.HasSystem = function() return true end
ns.GetSystem = function() return {} end
ns.GetItemLibrary = function() return {} end
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

-- Roster prune: Comm hands us the canonical names still in the group on a roster
-- change, and everyone else's cached vitals go - otherwise a member who left (or
-- a stranger who whispered) stays on the overview for the rest of the session.
handlers.VITALS({ name = "Ally" }, "Friend-OtherRealm")
handlers.VITALS({ name = "Ghost" }, "Departed")
ns.Party.PruneDeparted({ me = true, friend = true })
assert(roster["Friend-OtherRealm"], "a member still in the group was pruned")
assert(roster.Departed == nil, "a departed sender's vitals were not pruned")

-- An unknown roster (Comm could not determine one) drops nothing.
ns.Party.PruneDeparted(nil)
ns.Party.PruneDeparted({})
assert(roster["Friend-OtherRealm"], "an unknown roster must not drop cached vitals")

-- The party overview in UI/PartyUI.lua. Widget stand-in: WoW methods are
-- CapitalCase, while the UI's own fields are lowercase and must read as nil
-- until it sets them (the code branches on them). The handful of methods the
-- asserts read back record onto the widget instead of doing nothing.
local frames = 0
local function fakeFrame()
    return setmetatable({}, { __index = function(_, key)
        if not key:match("^%u") then return nil end
        if key == "Show" then return function(self) rawset(self, "_shown", true) end end
        if key == "Hide" then return function(self) rawset(self, "_shown", false) end end
        if key == "IsShown" then return function(self) return rawget(self, "_shown") ~= false end end
        if key == "SetText" then return function(self, text) rawset(self, "_text", text) end end
        if key == "SetTextColor" then
            return function(self, r, g, b) rawset(self, "_color", { r, g, b }) end
        end
        if key == "SetScript" then
            return function(self, which, fn)
                local s = rawget(self, "_scripts") or {}
                rawset(self, "_scripts", s)
                s[which] = fn
            end
        end
        if key:match("^Get") then return function() return 0 end end
        return function() return fakeFrame() end
    end })
end
CreateFrame = function() frames = frames + 1; return fakeFrame() end
UnitName = function() return "Me" end
GameTooltip_Hide = function() end

-- Tooltip stand-in: every line the UI writes, in order.
local tip = {}
GameTooltip = {
    SetOwner = function() end,
    SetText = function(_, text) tip = { text } end,
    AddLine = function(_, text) tip[#tip + 1] = text end,
    Show = function() end,
}
local function tipText() return table.concat(tip, "\n") end

-- Core's ns.SafeText, mirrored: this file never loads Core.lua.
ns.SafeText = function(value, maxLen, fallback)
    local s = (type(value) == "string") and value or tostring(value or "")
    s = s:gsub("|", ""):gsub("%c", " ")
    local cap = maxLen or 64
    if #s > cap then s = s:sub(1, cap) .. "..." end
    if s == "" then return fallback or "?" end
    return s
end

local printed = {}
ns.Print = function(msg) printed[#printed + 1] = msg end
local modules = {}
ns.RegisterModule = function(name, fn) modules[name] = fn end
local opened, requested = 0
ns.CharacterSheetUI = { Open = function() opened = opened + 1 end }
ns.Sharing = { Request = function(sender) requested = sender end }

local empty
ns.UI = {
    HILITE = { 1, 1, 1, 0.1 }, GOLD = { 1, 0.82, 0 }, DIM = { 0.4, 0.4, 0.4 },
    TEXT = { 0.9, 0.9, 0.9 }, RED = { 1, 0.3, 0.3 }, HEAD = { 0.7, 0.7, 0.7 },
    CreateWindow = function() return fakeFrame() end,
    Empty = function(_, message, _, onClick) empty = { message = message, onClick = onClick } end,
    HideEmpty = function() empty = nil end,
}
T.load(ns, "UI/PartyUI.lua")
assert(modules.party, "the party module opener was not registered")

local content
local function rowNamed(text)
    for _, r in ipairs(content.rows) do
        if r.name._text and r.name._text:find(text, 1, true) then return r end
    end
end
local function colored(fs, c)
    return fs._color and fs._color[1] == c[1] and fs._color[2] == c[2] and fs._color[3] == c[3]
end

ns.Party.Clear()
handlers.VITALS({ name = "Aaa", level = 5, hp = 20, hpmax = 20, mana = 3, manamax = 6,
    ac = 15, init = 4, dm = true }, "Ally")
ns.PartyUI.Open()
content = ns.PartyUI.frame.content

-- The roster holds only RECEIVED vitals and never us, so the window prepends
-- our own snapshot - and it sorts first even though "Aaa" beats "Hero".
assert(#content.rows == 2, "expected our own row plus one member, got " .. #content.rows)
local mine = content.rows[1]
assert(mine.isSelf == true and mine.charName == "Hero", "our own row must come first")
assert(mine.sender == "Me", "the own row must carry a sender (the tooltip needs one)")
assert(mine.name._text:find("(you)", 1, true), mine.name._text)
assert(mine.age == nil, "the own row is rebuilt each render, so it can have no age")
assert(mine.level._text == "3" and mine.ac._text == "13" and mine.init._text == "+2")
assert(mine.hp._text:find("7 / 12", 1, true) and mine.hp._text:find("+1", 1, true), mine.hp._text)
assert(mine.mana._text == "2 / 4", mine.mana._text)

-- Received members follow, by character name, with the gold DM tag.
local ally = content.rows[2]
assert(ally.sender == "Ally" and ally.charName == "Aaa" and ally.isSelf == nil)
assert(ally.name._text:find("|cffc8a868(DM)|r", 1, true), ally.name._text)
assert(ally.level._text == "5" and ally.hp._text == "20 / 20" and ally.mana._text == "3 / 6")
assert(ally.ac._text == "15" and ally.init._text == "+4")
assert(ally.age == 0, "a received row's age comes from its snapshot time")

-- Clicking: our own row opens our sheet, a member's asks them for theirs.
mine._scripts.OnClick(mine)
assert(opened == 1 and requested == nil, "the own row must open our sheet, not request it")
ally._scripts.OnClick(ally)
assert(requested == "Ally" and opened == 1, "a member row must request their full sheet")

mine._scripts.OnEnter(mine)
assert(tipText():find("Your character", 1, true), tipText())
assert(not tipText():find("Updated", 1, true), "the own row must show no age line: " .. tipText())
ally._scripts.OnEnter(ally)
assert(tipText():find("Played by Ally", 1, true), tipText())
assert(tipText():find("Updated 0s ago", 1, true), "a received row's tooltip must age it: " .. tipText())

-- A wire-sourced name reaches both the row and the tooltip: a "|H...|h" name
-- would otherwise render as a forged, clickable link inside the window.
local EVIL = "|Hitem:6948:0|h[Hearthstone]|h"
handlers.VITALS({ name = EVIL, hp = 1, hpmax = 10 }, "Mallory")   -- re-renders (debounce immediate)
local evil = rowNamed("Hearthstone")
assert(evil and evil.sender == "Mallory", "the member with an escaped name did not render")
assert(not evil.name._text:find("|", 1, true), "escape codes reached the row: " .. evil.name._text)
assert(not evil.charName:find("|", 1, true), "escape codes reached the tooltip name")
evil._scripts.OnEnter(evil)
assert(tipText():find("Hearthstone", 1, true), tipText())
assert(not tipText():find("|", 1, true), "escape codes reached the tooltip: " .. tipText())
assert(colored(evil.hp, ns.UI.RED), "a badly hurt member must render red HP")

-- Rows stay pooled: WoW cannot destroy a frame, so a re-render must reuse them.
local built, count = frames, #content.rows
ns.PartyUI.RefreshIfShown()
assert(frames == built, "re-rendering must reuse rows, not create frames")
assert(#content.rows == count and content.rows[1] == mine, "the pooled rows must be the same frames")

-- Stale dimming: a snapshot older than the threshold greys out, ours never can.
GetTime = function() return 400 end        -- 300s after the cached snapshots
ns.PartyUI.RefreshIfShown()
local stale = rowNamed("Aaa")
assert(stale.age == 300, "the row age must be measured from the snapshot time")
assert(colored(stale.name, ns.UI.DIM) and colored(stale.hp, ns.UI.DIM), "a stale row must dim")
assert(colored(stale.init, ns.UI.DIM) and colored(stale.mana, ns.UI.DIM))
assert(colored(content.rows[1].name, ns.UI.GOLD), "our own row can never go stale")

-- Empty state: no roster and no own snapshot (no active character) must render
-- the empty state, not throw - and every pooled row hides behind it.
ns.Party.Clear()
ns.GetActiveCharacter = function() return nil end
assert(ns.Party.OwnSnapshot() == nil, "no active character means no own snapshot")
empty = nil
ns.PartyUI.RefreshIfShown()
assert(empty and empty.message:find("No party data yet", 1, true), "the empty state must show")
for _, r in ipairs(content.rows) do
    assert(rawget(r, "_shown") == false, "rows left over from the last render must hide")
end

-- The other way to have no snapshot: no system imported at all.
ns.GetActiveCharacter = function() return { name = "X" } end
ns.HasSystem = function() return false end
assert(ns.Party.OwnSnapshot() == nil, "no system means no own snapshot")
empty = nil
ns.PartyUI.RefreshIfShown()
assert(empty, "a system-less client must still get the empty state")

-- Its "Request vitals" button reports a failed request instead of erroring.
local realSend = ns.Comm.Send
ns.Comm.Send = function() return false, "you are not in a group." end
empty.onClick()
assert(printed[#printed] == "you are not in a group.", table.concat(printed, "\n"))
ns.Comm.Send = realSend

-- And the window recovers: the own row comes back, still from the pool.
ns.HasSystem = function() return true end
local pooled = frames
ns.PartyUI.RefreshIfShown()
assert(empty == nil and #content.rows == count, "the empty state must clear when a row returns")
assert(rawget(content.rows[1], "_shown") == true and content.rows[1].isSelf == true)
assert(frames == pooled, "recovering from the empty state must not create frames")
