-- Luacheck configuration for Parchment.
--
-- The addon targets WoW's Lua 5.1. Almost all "undefined variable" noise is the
-- WoW client API (CreateFrame, GameTooltip, C_Timer, ...) and the handful of
-- globals WoW expects an addon to own (the SavedVariables tables, the
-- StaticPopupDialogs/UISpecialFrames tables addons append to). Declaring them
-- here lets luacheck flag real problems instead of drowning them.
--
-- Run: luacheck . --exclude-files 'Libs/*'   (std/excludes are set below).

std = "lua51"

-- Vendored libraries are never edited; do not lint them.
exclude_files = { "Libs" }

-- WoW client API and WoW-exposed Lua helpers, read-only from addon code.
local wow_api = {
    -- Frames, timers, tooltips
    "CreateFrame", "UIParent", "UISpecialFrames",
    "C_Timer", "GetTime", "GameTooltip", "GameTooltip_Hide", "ChatFontNormal",
    -- Static popups
    "StaticPopup_Show",
    -- Unit / group state
    "UnitName", "UnitExists", "UnitIsPlayer",
    "IsInGroup", "IsInRaid", "GetNumGroupMembers",
    -- Chat, rolls, reload
    "SendChatMessage", "DEFAULT_CHAT_FRAME", "RandomRoll", "RANDOM_ROLL_RESULT",
    "ChatFrameUtil", "ChatFrame_AddMessageEventFilter", "hooksecurefunc", "SetItemRef",
    "IsShiftKeyDown", "IsAltKeyDown",
    "ChatEdit_GetActiveWindow", "ChatFrame_OpenChat",
    "ReloadUI",
    -- Addon metadata + libraries
    "LibStub", "C_AddOns", "GetAddOnMetadata",
    -- Context menus (retail)
    "Menu", "MenuUtil",
    -- Localized button captions used in popups
    "ACCEPT", "CANCEL", "DELETE",
    -- WoW-provided Lua helpers
    "strtrim", "time", "tinsert",
}

read_globals = wow_api

-- Globals the addon legitimately owns or appends to. The four Parchment* tables
-- are the SavedVariables declared in Parchment.toc; StaticPopupDialogs and
-- UISpecialFrames are WoW tables addons add their own keys to.
globals = {
    "ParchmentSystemDB", "ParchmentCharDB", "ParchmentItemDB", "ParchmentPackDB", "ParchmentDB",
    "StaticPopupDialogs", "UISpecialFrames",
}

-- `local ADDON, ns = ...` is the namespace idiom in every file; ADDON is often
-- unused. WoW callbacks (OnClick, OnEnter, event handlers) have fixed
-- signatures, so unused arguments there are expected, not mistakes.
ignore = { "211/ADDON" }
unused_args = false

-- The test harness installs WoW API stubs by assigning these globals, and uses
-- TEST_ROOT to locate fixtures. Allow writing the API names there.
local test_globals = { "TEST_ROOT" }
for _, name in ipairs(wow_api) do test_globals[#test_globals + 1] = name end
files["Tests"] = {
    globals = test_globals,
}
