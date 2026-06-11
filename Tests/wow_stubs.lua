-- Shared helpers for Parchment's out-of-client tests (see Tests/run.lua).
--
-- The pure modules (Schema, JSON, TOML, CharacterSheet, PerkTree, the data
-- API in Core, ...) run under plain lua5.1; these helpers install the few
-- WoW/Ace globals their file scopes touch. Tests that exercise behaviour
-- behind a WoW API (UnitName, comm plumbing, AceDB) override the relevant
-- global with a purpose-built stub BEFORE loading the module under test.
local T = {}

T.root = TEST_ROOT or ""

-- Loads an addon file the way WoW does: as a chunk called with (name, ns).
function T.load(ns, path)
    assert(loadfile(T.root .. path))("Parchment", ns)
    return ns
end

-- Installs the minimal globals addon files reference at load time. LibStub
-- resolves every library to an "absorber" whose every method returns the
-- absorber - enough to survive file scope. Tests that drive the AceAddon
-- lifecycle (OnInitialize) install their own LibStub with a real db table.
function T.InstallWowStubs()
    DEFAULT_CHAT_FRAME = { AddMessage = function() end }
    StaticPopupDialogs = {}
    StaticPopup_Show = function() end
    CANCEL, DELETE = "Cancel", "Delete"
    LibStub = setmetatable({}, { __call = function()
        local absorber
        absorber = setmetatable({}, { __index = function() return function() return absorber end end })
        return absorber
    end })
end

-- LibStub variant for tests that call OnInitialize: AceDB:New returns a real
-- table ({ global = ..., profile = {} }) so Core's db logic actually runs.
function T.InstallLifecycleStubs(dbGlobal)
    T.InstallWowStubs()
    local db = { global = dbGlobal or {}, profile = {} }
    LibStub = setmetatable({}, { __call = function(_, name)
        if name == "AceAddon-3.0" then
            return { NewAddon = function() return { RegisterChatCommand = function() end } end }
        end
        return { New = function() return db end }
    end })
    return db
end

function T.readfile(path)
    local f = assert(io.open(T.root .. path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

-- Structural equality; returns ok, path-of-first-difference.
function T.deepeq(a, b, path)
    path = path or "value"
    if type(a) ~= type(b) then return false, path .. ": " .. type(a) .. " vs " .. type(b) end
    if type(a) ~= "table" then
        if a ~= b then return false, path .. ": " .. tostring(a) .. " ~= " .. tostring(b) end
        return true
    end
    for k, v in pairs(a) do
        local ok, p = T.deepeq(v, b[k], path .. "." .. tostring(k))
        if not ok then return false, p end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, path .. "." .. tostring(k) .. ": only on right side" end
    end
    return true
end

-- assert(deepeq) with the diff path in the failure message.
function T.assert_deepeq(a, b, label)
    local ok, p = T.deepeq(a, b, label or "value")
    assert(ok, p)
end

return T
