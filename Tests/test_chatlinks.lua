-- Chat links: the plain-text token registry, the display-time rewrite, href
-- parsing, payload builders, answer sanitizing, and the LINKQ/LINKA comm
-- handlers (via a Comm stub).
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
local ns = T.load({}, "Core.lua")
T.load(ns, "Modules/Spells.lua")
-- Item payloads summarize effects via ns.Widgets.EffectSummary, which reads
-- the effect vocabulary and the UI's sign formatter.
T.load(ns, "UI/Window.lua")
T.load(ns, "UI/Widgets.lua")
T.load(ns, "Modules/CharacterSheet.lua")

-- Comm stub capturing whispers and letting us fire handlers.
local handlers, whispers = {}, {}
ns.Comm = {
    On = function(t, fn) handlers[t] = fn end,
    Whisper = function(t, payload, target)
        whispers[#whispers + 1] = { t = t, payload = payload, target = target }
        return true
    end,
}
-- Chat-input stubs: an "active" edit box capturing Insert, and the
-- open-a-fresh-input fallback.
local inserted, opened = {}, {}
local activeBox = { Insert = function(_, text) inserted[#inserted + 1] = text end }
ChatEdit_GetActiveWindow = function() return activeBox end
ChatFrame_OpenChat = function(text) opened[#opened + 1] = text end

T.load(ns, "Modules/ChatLinks.lua")
local CL = ns.ChatLinks
assert(handlers.LINKQ and handlers.LINKA, "comm handlers not registered")

-- Store/MakeToken: identifiers are unique, name delimiters are stripped.
local id1 = CL.Store({ title = "Rime Sheath", lines = {} })
local id2 = CL.Store({ title = "Rime Sheath", lines = {} })
assert(id1 == "Rime Sheath:1" and id2 == "Rime Sheath:2", id1 .. " / " .. id2)
assert(CL.Get(id1) and CL.Get("nope:9") == nil)
local weird = CL.Store({ title = "A|B[C]D:E", lines = {} })
assert(weird == "ABCDE:1", weird)
local token = CL.MakeToken({ title = "Lancet", lines = {} })
assert(token == "[PMT:Lancet:1]", token)

-- Rewrite: the token becomes a colored addon: link carrying the author; the
-- id is stripped from the display text; non-token text is untouched.
local rewritten = CL.Rewrite("look: [PMT:Lancet:1] !", "Tab-Realm")
assert(rewritten:find("|Haddon:parchment:Tab%-Realm:Lancet:1|h%[Lancet%]|h"), rewritten)
assert(rewritten:sub(1, 6) == "look: " and rewritten:sub(-2) == " !")
assert(CL.Rewrite("no links here", "X") == "no links here")

-- ParseHref: round-trips what Rewrite emits; foreign links are nil.
local player, id = CL.ParseHref("addon:parchment:Tab-Realm:Lancet:1")
assert(player == "Tab-Realm" and id == "Lancet:1")
assert(CL.ParseHref("addon:totalrp3:X:Y") == nil)
assert(CL.ParseHref("item:12345") == nil)

-- PostLink inserts the bare token into the open chat input; with none open
-- it pre-fills a fresh input instead. Nothing is sent by the addon itself.
assert(CL.PostLink({ title = "Ward", lines = {} }))
assert(inserted[1] == "[PMT:Ward:1]", tostring(inserted[1]))
ChatEdit_GetActiveWindow = function() return nil end
assert(CL.PostLink({ title = "Ward", lines = {} }))
assert(opened[1] == "[PMT:Ward:2]", tostring(opened[1]))
ChatEdit_GetActiveWindow = function() return activeBox end

-- Builders produce title + symbolic-colored lines.
ParchmentSystemDB = { system_name = "Mini", attributes = { { id = "vit", name = "Vitality" } } }
local payload = CL.FeatRank({ id = "grip", name = "Iron Grip" },
    { name = "Hold", type = "active", cost = { ap = 1 }, range = "melee",
        save = "vit", description = "Grab." }, 1)
assert(payload.title == "Hold")
assert(payload.lines[1].text == "Iron Grip I" and payload.lines[1].color == "blue")
assert(payload.lines[2].text:find("active") and payload.lines[2].text:find("1 AP")
    and payload.lines[2].text:find("Vitality save"), payload.lines[2].text)
assert(payload.lines[3].text == "Grab." and payload.lines[3].wrap)

local pack = { schools = { { id = "d", name = "Death" } } }
payload = CL.Spell(pack, { id = "coil", name = "Coil", school = "d", rank = 1,
    cost = { mana = 1 }, damage = "1d8 shadow", concentration = true })
assert(payload.lines[1].text == "Death - Rank 1")
assert(payload.lines[2].text:find("Concentration") and payload.lines[2].text:find("1d8 shadow"))

payload = CL.Homebrew("feat", { name = "Field Alchemy", type = "utility", description = "Brew." })
assert(payload.lines[1].text == "Homebrew feat")

payload = CL.Item({ name = "Dagger +1", kind = "weapon", weapon_name = "Dagger",
    bonus = 1, description = "Sharp." })
assert(payload.title == "Dagger +1")
assert(payload.lines[1].text:find("Weapon") and payload.lines[1].text:find("+1 attack")
    and payload.lines[1].text:find("for Dagger"), payload.lines[1].text)
assert(payload.icon == nil, "an iconless item must not invent one")

-- An item's icon rides as its own payload field, and each effect becomes a
-- line under a "While equipped:" header, before the description.
payload = CL.Item({ name = "Sentry Ring", kind = "equipment", icon = "inv_jewelry_ring_03",
    effects = { { type = "save", id = "vit", value = 1 }, { type = "initiative", value = 2 } },
    description = "Watchful." })
assert(payload.icon == "inv_jewelry_ring_03")
assert(payload.lines[1].text == "Equipment")
assert(payload.lines[2].text == "While equipped:" and payload.lines[2].color == "blue")
assert(payload.lines[3].text == "- Saving throw: Vitality  +1", payload.lines[3].text)
assert(payload.lines[4].text == "- Initiative  +2", payload.lines[4].text)
assert(payload.lines[5].text == "Watchful.")

-- SanitizeAnswer: caps sizes, strips escapes, normalizes colors, keeps
-- `unknown`; garbage shapes are nil.
local answer = CL.SanitizeAnswer({
    id = "X:1", title = "T|cffff0000red|r",
    lines = {
        { text = "ok", color = "gold" },
        { text = string.rep("y", 2000), color = "evil" },
        "not a line",
        { text = 5 },
    },
})
assert(answer.title == "Tcffff0000redr", answer.title)
assert(#answer.lines == 2)
assert(#answer.lines[2].text == 600 and answer.lines[2].color == "text")
assert(CL.SanitizeAnswer({ id = "X:1", unknown = true }).unknown == true)
assert(CL.SanitizeAnswer("nope") == nil)
assert(CL.SanitizeAnswer({ id = 5 }) == nil)
assert(CL.SanitizeAnswer({ id = "X:1", title = nil }) == nil)

-- A received icon is bounded like the item schema's: plain texture names
-- pass, anything path-shaped, escaped, overlong or non-string is dropped
-- (the answer survives, iconless).
assert(CL.SanitizeAnswer({ id = "X:1", title = "T", icon = "inv_sword_04" }).icon
    == "inv_sword_04")
for _, evil in ipairs({ "..\\..\\Interface\\evil", "Interface/Icons/x", "a|cff00ff00b",
    string.rep("i", 65), 5, true }) do
    assert(CL.SanitizeAnswer({ id = "X:1", title = "T", icon = evil }).icon == nil,
        "a hostile icon survived sanitizing: " .. tostring(evil))
end

-- LINKQ answers from the registry; unknown ids get an expiry answer.
whispers = {}
handlers.LINKQ({ id = id1 }, "Asker")
assert(whispers[1].t == "LINKA" and whispers[1].target == "Asker")
assert(whispers[1].payload.title == "Rime Sheath" and whispers[1].payload.id == id1)
handlers.LINKQ({ id = "gone:9" }, "Asker")
assert(whispers[2].payload.unknown == true)
handlers.LINKQ("garbage", "Asker")
assert(#whispers == 2, "garbage question must be dropped silently")

-- A stored payload's icon travels in the answer.
local iconId = CL.Store({ title = "Ring", icon = "inv_jewelry_ring_03", lines = {} })
handlers.LINKQ({ id = iconId }, "Asker")
assert(whispers[3].payload.icon == "inv_jewelry_ring_03", "the answer must carry the icon")

-- LINKA renders only through the UI seam, sanitized.
local shown
ns.ChatLinkUI = { OnAnswer = function(answer2, sender) shown = { answer = answer2, sender = sender } end }
handlers.LINKA({ id = "X:1", title = "Hi", lines = {} }, "Someone")
assert(shown and shown.answer.title == "Hi" and shown.sender == "Someone")
shown = nil
handlers.LINKA({ id = 5 }, "Someone")
assert(shown == nil, "an unparseable answer must never reach the UI")
