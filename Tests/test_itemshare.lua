-- Item sharing: the direct ITEM offer and its ITEMACK verdicts, the
-- ITEMQ/ITEMA fetch behind importable chat links, and the shared receive
-- seam - size cap, validation through the REAL Schema (the comm path holds
-- the local import path's line), field narrowing, escape scrubbing and fresh
-- local ids. Comm is a stub capturing whispers; popups and timers are
-- captured and driven by hand.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
local ns = T.load({}, "Core.lua")
T.load(ns, "Schema.lua")
T.load(ns, "JSON.lua")
T.load(ns, "Modules/Items.lua")

local prints = {}
ns.Print = function(msg) prints[#prints + 1] = tostring(msg) end
local function lastPrint() return prints[#prints] or "" end

UnitName = function() return "Me" end

-- Timers are collected and fired by hand; each firing drains the current
-- batch so a test can interleave "time passes" with new registrations.
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function FireTimers()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do fn() end
end

-- Popup capture; popupResult simulates StaticPopup_Show refusing to stack.
local popups = {}
local popupResult = true
StaticPopup_Show = function(which, a1, a2, data)
    popups[#popups + 1] = { which = which, a1 = a1, a2 = a2, data = data }
    return popupResult
end

local handlers, whispers = {}, {}
ns.Comm = {
    On = function(t, fn) handlers[t] = fn end,
    Whisper = function(t, payload, target)
        whispers[#whispers + 1] = { t = t, payload = payload, target = target }
        return true
    end,
    NormalizeName = function(n)
        if type(n) ~= "string" or n == "" then return nil end
        local key = n:match("^[^-]+")
        return key and key:lower() or nil
    end,
    SameName = function(a, b)
        local ka = ns.Comm.NormalizeName(a)
        return ka ~= nil and ka == ns.Comm.NormalizeName(b)
    end,
    IsSelf = function(s) return ns.Comm.SameName(s, "Me") end,
    Version = function() return "0.4.1" end,
}

-- Chat-input stub for the link half (PostItemLink inserts tokens).
local inserted = {}
ChatEdit_GetActiveWindow = function()
    return { Insert = function(_, text) inserted[#inserted + 1] = text end }
end

T.load(ns, "Modules/ChatLinks.lua")
T.load(ns, "Modules/ItemShare.lua")
local CL = ns.ChatLinks
local IS = ns.ItemShare
assert(handlers.ITEM and handlers.ITEMACK and handlers.ITEMQ and handlers.ITEMA,
    "comm handlers not registered")

ParchmentItemDB = nil   -- a fresh library (globals persist across test files)

-- Offer: whispers the record, prints, and tracks the pending ack.
local sword = { id = "itm_1", name = "Rime Blade", kind = "weapon", bonus = 1 }
IS.Offer("Friend-Realm", sword)
assert(whispers[1].t == "ITEM" and whispers[1].target == "Friend-Realm")
assert(whispers[1].payload.item.name == "Rime Blade")
assert(lastPrint():find("offered"), lastPrint())

-- The delivery ack quiets the timeout; the decision ack closes the offer,
-- after which further acks from that sender are unsolicited and silent.
handlers.ITEMACK({ status = "offered" }, "Friend")
assert(lastPrint():find("received the offer"), lastPrint())
FireTimers()
assert(not lastPrint():find("no response"), "an acked offer must not time out")
handlers.ITEMACK({ status = "accepted" }, "Friend")
assert(lastPrint():find("added"), lastPrint())
local nPrints = #prints
handlers.ITEMACK({ status = "accepted" }, "Friend")
handlers.ITEMACK({ status = "declined" }, "Stranger")
assert(#prints == nPrints, "an unsolicited ack must not print")

-- A never-acked offer times out with the version hint (an older client
-- drops the unknown message type silently - the timeout is the diagnostic).
IS.Offer("Ghost", sword)
FireTimers()
assert(lastPrint():find("no response from Ghost"), lastPrint())
assert(lastPrint():find("0.4.1", 1, true), "the timeout must name the version")

-- Declines and validation refusals resolve their pending offers too.
IS.Offer("Wary", sword)
handlers.ITEMACK({ status = "declined" }, "Wary")
assert(lastPrint():find("declined"), lastPrint())
IS.Offer("Strict", sword)
handlers.ITEMACK({ status = "invalid" }, "Strict")
assert(lastPrint():find("rejected"), lastPrint())

-- Offering to yourself or to nobody never reaches the wire.
local nWhispers = #whispers
IS.Offer("Me", sword)
IS.Offer("   ", sword)
assert(#whispers == nWhispers)

-- Receiving an offer: a valid record prompts and acks "offered"; accepting
-- stores under a FRESH id (the sender's "itm_1" must not overwrite ours),
-- stamps version 1, migrates the retired ac_bonus, narrows to known fields
-- and scrubs escape pipes.
ns.SetItem("itm_1", { name = "My Own Sword", kind = "weapon" })
whispers = {}
handlers.ITEM({ item = { id = "itm_1", name = "Loot|ed Ring", kind = "equipment",
    ac_bonus = 2, junk = "smuggled" } }, "Peer")
local offer = popups[#popups]
assert(offer and offer.which == "PARCHMENT_ITEM_OFFER")
assert(whispers[1].t == "ITEMACK" and whispers[1].payload.status == "offered")
StaticPopupDialogs["PARCHMENT_ITEM_OFFER"].OnAccept(nil, offer.data)
local lib = ns.GetItemLibrary()
assert(lib.itm_1.name == "My Own Sword", "the local item must survive")
local stored = lib.itm_2
assert(stored and stored.id == "itm_2" and stored.version == 1)
assert(stored.name == "Looted Ring", tostring(stored.name))
assert(stored.junk == nil, "unknown fields must not be stored")
assert(stored.ac_bonus == nil and stored.effects and stored.effects[1].type == "ac"
    and stored.effects[1].value == 2, "ac_bonus must migrate to an effect")
assert(whispers[2].payload.status == "accepted")

-- Declining acks "declined" and stores nothing.
handlers.ITEM({ item = sword }, "Peer")
whispers = {}
StaticPopupDialogs["PARCHMENT_ITEM_OFFER"].OnCancel(nil, popups[#popups].data, "clicked")
assert(whispers[1].payload.status == "declined")
assert(lib.itm_3 == nil, "a declined offer must not store")

-- An override by another popup lapses without an ack.
handlers.ITEM({ item = sword }, "Peer")
whispers = {}
StaticPopupDialogs["PARCHMENT_ITEM_OFFER"].OnCancel(nil, popups[#popups].data, "override")
assert(#whispers == 0, "an overridden prompt must not ack a decision")

-- A record failing the schema (or outgrowing the size cap) is refused with
-- an "invalid" ack and no prompt; a busy popup refuses with "busy".
local nPopups = #popups
whispers = {}
handlers.ITEM({ item = { id = "x", name = "Potion", kind = "potion" } }, "Peer")
assert(whispers[1].payload.status == "invalid")
handlers.ITEM({ item = { id = "x", name = "Big", kind = "gear",
    junk = string.rep("x", 20000) } }, "Peer")
assert(whispers[2].payload.status == "invalid")
assert(#popups == nPopups, "a refused offer must not prompt")
popupResult = nil
handlers.ITEM({ item = sword }, "Peer")
assert(whispers[3].payload.status == "busy")
popupResult = true

-- Our own looped-back offer and garbage payloads are dropped outright.
whispers = {}
handlers.ITEM({ item = sword }, "Me")
handlers.ITEM("garbage", "Peer")
assert(#whispers == 0)

-- An importable link's record answers an ITEMQ; view-only or expired ids
-- answer unknown (the record never rides in a LINKA - see test_chatlinks).
CL.PostItemLink(ns.GetItem("itm_1"))
local choice = popups[#popups]
assert(choice.which == "PARCHMENT_LINK_IMPORTABLE")
StaticPopupDialogs["PARCHMENT_LINK_IMPORTABLE"].OnAccept(nil, choice.data)
local linkId = inserted[#inserted]:match("^%[PMT:(.-)%]$")
assert(linkId and CL.Get(linkId) and CL.Get(linkId).item.name == "My Own Sword")
whispers = {}
handlers.ITEMQ({ id = linkId }, "Asker")
assert(whispers[1].t == "ITEMA" and whispers[1].target == "Asker")
assert(whispers[1].payload.item.name == "My Own Sword")
handlers.ITEMQ({ id = "gone:9" }, "Asker")
assert(whispers[2].payload.unknown == true)
handlers.ITEMQ("garbage", "Asker")
assert(#whispers == 2, "a garbage question must be dropped silently")

-- RequestImport: asks, then stores only the matching pending answer - the
-- wrong sender is ignored (and the request stays pending for the right one),
-- and a second answer after resolution is unsolicited.
local results = {}
ns.ChatLinkUI = { OnImportResult = function(id, ok) results[#results + 1] = { id = id, ok = ok } end }
whispers = {}
IS.RequestImport("Peer", "Blade:1")
assert(whispers[1].t == "ITEMQ" and whispers[1].payload.id == "Blade:1")
handlers.ITEMA({ id = "Blade:1",
    item = { id = "itm_9", name = "Fetched Blade", kind = "weapon" } }, "Impostor")
assert(lib.itm_3 == nil, "a wrong-sender answer must not store")
handlers.ITEMA({ id = "Blade:1",
    item = { id = "itm_9", name = "Fetched Blade", kind = "weapon" } }, "Peer-Realm")
assert(lib.itm_3 and lib.itm_3.name == "Fetched Blade" and lib.itm_3.id == "itm_3")
assert(results[1] and results[1].id == "Blade:1" and results[1].ok == true)
handlers.ITEMA({ id = "Blade:1",
    item = { id = "itm_9", name = "Again", kind = "weapon" } }, "Peer")
assert(lib.itm_4 == nil, "a resolved request must not accept a second answer")

-- An expired link and a malformed record both report failure to the window.
IS.RequestImport("Peer", "Old:1")
handlers.ITEMA({ id = "Old:1", unknown = true }, "Peer")
assert(lastPrint():find("no longer has"), lastPrint())
assert(results[#results].ok == false)
IS.RequestImport("Peer", "Bad:1")
handlers.ITEMA({ id = "Bad:1", item = { id = "x", name = "Bad", kind = "nope" } }, "Peer")
assert(lastPrint():find("malformed"), lastPrint())
assert(results[#results].ok == false)

-- An unanswered request times out (stale timers from resolved requests and
-- closed offers stay silent - the serial guards recognize themselves).
IS.RequestImport("Peer", "Slow:1")
local before = #prints
FireTimers()
assert(lastPrint():find("could not be fetched"), lastPrint())
assert(#prints == before + 1, "only the live request may time out")

-- The suite runs in one process: leave no library behind for later files.
ParchmentItemDB = nil
