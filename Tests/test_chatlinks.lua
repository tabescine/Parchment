-- Chat links: the plain-text token registry, the display-time rewrite, href
-- parsing, payload builders, answer sanitizing, and the LINKQ/LINKA comm
-- handlers (via a Comm stub).
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
local ns = T.load({}, "Core.lua")
T.load(ns, "Modules/Spells.lua")

-- Comm stub capturing whispers and letting us fire handlers.
local handlers, whispers = {}, {}
ns.Comm = {
    On = function(t, fn) handlers[t] = fn end,
    Whisper = function(t, payload, target)
        whispers[#whispers + 1] = { t = t, payload = payload, target = target }
        return true
    end,
}
IsInGroup = function() return true end
IsInRaid = function() return false end
local said = {}
SendChatMessage = function(msg, channel) said[#said + 1] = { msg = msg, channel = channel } end

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

-- PostLink: parenthesized token to the group channel.
assert(CL.PostLink({ title = "Ward", lines = {} }))
assert(said[1].channel == "PARTY" and said[1].msg == "([PMT:Ward:1])", said[1].msg)
IsInGroup = function() return false end
assert(CL.PostLink({ title = "Ward", lines = {} }) == false, "no group, no post")
IsInGroup = function() return true end

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

-- LINKQ answers from the registry; unknown ids get an expiry answer.
whispers = {}
handlers.LINKQ({ id = id1 }, "Asker")
assert(whispers[1].t == "LINKA" and whispers[1].target == "Asker")
assert(whispers[1].payload.title == "Rime Sheath" and whispers[1].payload.id == id1)
handlers.LINKQ({ id = "gone:9" }, "Asker")
assert(whispers[2].payload.unknown == true)
handlers.LINKQ("garbage", "Asker")
assert(#whispers == 2, "garbage question must be dropped silently")

-- LINKA renders only through the UI seam, sanitized.
local shown
ns.ChatLinkUI = { OnAnswer = function(answer2, sender) shown = { answer = answer2, sender = sender } end }
handlers.LINKA({ id = "X:1", title = "Hi", lines = {} }, "Someone")
assert(shown and shown.answer.title == "Hi" and shown.sender == "Someone")
shown = nil
handlers.LINKA({ id = 5 }, "Someone")
assert(shown == nil, "an unparseable answer must never reach the UI")
