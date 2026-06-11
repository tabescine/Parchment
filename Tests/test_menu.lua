-- Sharing.lua's context-menu integration: deferred registration and the
-- "Parchment" section emitted on every covered menu.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")

UnitName = function() return "Me" end
UnitExists = function() return true end
UnitIsPlayer = function() return true end
IsInGroup = function() return false end
IsInRaid = function() return false end
GetNumGroupMembers = function() return 0 end
GetTime = function() return 0 end
C_Timer = { After = function() end }

local modifyCallbacks = {}
Menu = { ModifyMenu = function(tag, cb)
    assert(modifyCallbacks[tag] == nil, "duplicate registration for " .. tag)
    modifyCallbacks[tag] = cb
end }

local ns = {}
ns.Print = function() end
ns.Schema = { ValidateCharacter = function() return true end }
ns.Comm = { On = function() end, Send = function() return true end, Whisper = function() return true end }
local eventHandlers = {}
ns.Addon = {
    RegisterEvent = function(_, ev, fn) eventHandlers[ev] = fn end,
    UnregisterEvent = function(_, ev) eventHandlers[ev] = nil end,
    db = { global = {} },
}
T.load(ns, "Modules/Sharing.lua")

-- Registration is deferred to PLAYER_ENTERING_WORLD, then unhooked.
assert(next(modifyCallbacks) == nil, "registered before PLAYER_ENTERING_WORLD")
assert(eventHandlers.PLAYER_ENTERING_WORLD, "no PLAYER_ENTERING_WORLD handler")
eventHandlers.PLAYER_ENTERING_WORLD()
assert(eventHandlers.PLAYER_ENTERING_WORLD == nil, "event not unregistered after firing")
local count = 0
for _ in pairs(modifyCallbacks) do count = count + 1 end
assert(count == 12, "expected 12 menu tags, got " .. count)
assert(modifyCallbacks.MENU_UNIT_PLAYER ~= modifyCallbacks.MENU_UNIT_TARGET,
    "closures must be unique per tag (ModifyMenu registry requirement)")

local function NewRoot()
    local r = { log = {} }
    function r:CreateDivider() self.log[#self.log + 1] = "divider" end
    function r:CreateTitle(text) self.log[#self.log + 1] = "title:" .. text end
    function r:CreateButton(text, cb) self.log[#self.log + 1] = "button:" .. text; self.cb = cb end
    return r
end

-- Every menu gets the own section: divider, "Parchment" title, the button.
for tag, cb in pairs(modifyCallbacks) do
    local root = NewRoot()
    cb(nil, root, { name = "Bob", server = "Realm" })
    assert(table.concat(root.log, "|") == "divider|title:Parchment|button:View sheet",
        tag .. ": " .. table.concat(root.log, "|"))
end

-- Clicking requests the full Name-Realm.
local sentTo
ns.Comm.Whisper = function(_, payload, target) sentTo = target; return true end
local root = NewRoot()
modifyCallbacks.MENU_UNIT_PLAYER(nil, root, { name = "Bob", server = "Realm" })
root.cb()
assert(sentTo == "Bob-Realm", tostring(sentTo))

-- Non-player units get nothing - not even an empty section.
UnitIsPlayer = function() return false end
root = NewRoot()
modifyCallbacks.MENU_UNIT_TARGET(nil, root, { unit = "target" })
assert(#root.log == 0, "section added for a non-player unit")
