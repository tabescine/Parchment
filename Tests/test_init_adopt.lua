-- InitiativeUI's INIT bootstrap gate: while no DM is recognized, Comm's central
-- authority check lets any group member through, so the handler itself must not
-- silently apply an INIT to the persisted order. It prompts instead; accepting
-- applies the state AND recognizes the sender as DM, declining ignores that
-- sender's pushes for the session. Once a DM is recognized, syncs apply
-- silently (Comm has already verified the sender).
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallWowStubs()
strtrim = function(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end
ACCEPT = "Accept"

-- Capture popups instead of showing them.
local shown
StaticPopup_Show = function(which, arg1, arg2, data)
    shown = { which = which, data = data }
end

local ns = { Addon = { db = { global = {}, profile = {} } } }
ns.Print = function() end
ns.RegisterModule = function() end
-- Sync is built at load time from UI.Debounce, so the stub must exist before
-- the module is loaded. Fires immediately here: the debounce is about
-- collapsing bursts on the wire, not about what a single change does.
ns.UI = { Debounce = function(_, fn) return fn end }

-- Core's remote-text sanitizer, mirrored here because this file loads the
-- module under test without Core.lua: combatant names arrive over the wire and
-- reach chat lines and the adopt prompt through it.
ns.SafeText = function(value, maxLen, fallback)
    local s = (type(value) == "string") and value or tostring(value or "")
    s = s:gsub("|", ""):gsub("%c", " ")
    local cap = maxLen or 64
    if #s > cap then s = s:sub(1, cap) .. "..." end
    if s == "" then return fallback or "?" end
    return s
end

-- Comm stub mirroring the recognized-DM session state the real module keeps.
local handlers, recognized = {}, nil
ns.Comm = {
    On = function(t, fn) handlers[t] = fn end,
    IsDM = function() return false end,
    RecognizedDM = function() return recognized end,
    SetRecognizedDM = function(n)
        recognized = (type(n) == "string" and n ~= "") and n or nil
        return recognized
    end,
    NormalizeName = function(n)
        if type(n) ~= "string" or n == "" then return nil end
        local key = n:match("^[^-]+")
        return key and key:lower() or nil
    end,
    IsSelf = function() return false end,
    Send = function() return true end,
}

T.load(ns, "Modules/InitiativeTracker.lua")
T.load(ns, "UI/InitiativeUI.lua")
local IT = ns.InitiativeTracker
assert(handlers.INIT, "INIT handler not registered")

local function wireState(name)
    return { combatants = { { name = name, init = 10 } }, current = 0, round = 0 }
end

-- Bootstrap window: an INIT before any DM is recognized must NOT apply
-- silently - it prompts, and the persisted order stays untouched.
handlers.INIT(wireState("Spoofed"), "Alice")
assert(#IT.GetState().combatants == 0, "a pre-recognition INIT must not apply silently")
assert(shown and shown.which == "PARCHMENT_ADOPT_INIT", "a pre-recognition INIT must prompt")

-- Accepting applies the carried state and locks recognition on the sender.
StaticPopupDialogs["PARCHMENT_ADOPT_INIT"].OnAccept(nil, shown.data)
assert(recognized == "Alice", "accepting must recognize the sender as DM")
assert(#IT.GetState().combatants == 1 and IT.GetState().combatants[1].name == "Spoofed",
    "accepting must apply the carried state")

-- With a DM recognized, their syncs apply silently (Comm gates the sender).
shown = nil
handlers.INIT(wireState("Round2"), "Alice")
assert(shown == nil, "a recognized DM's INIT must not prompt")
assert(IT.GetState().combatants[1].name == "Round2", "a recognized DM's INIT must apply")

-- Declining ignores that sender's pre-recognition pushes for the session.
recognized = nil
IT.Reset()
handlers.INIT(wireState("EvilOrder"), "Eve")
assert(shown and shown.which == "PARCHMENT_ADOPT_INIT")
StaticPopupDialogs["PARCHMENT_ADOPT_INIT"].OnCancel(nil, shown.data)
shown = nil
handlers.INIT(wireState("EvilOrder2"), "Eve")
assert(shown == nil, "a declined sender must not re-prompt")
assert(#IT.GetState().combatants == 0, "a declined sender's INIT must not apply")
-- A different sender still gets a fresh prompt.
handlers.INIT(wireState("Other"), "Frank")
assert(shown and shown.which == "PARCHMENT_ADOPT_INIT", "other senders still prompt")
