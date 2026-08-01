-- Parchment - Minimap
--
-- A LibDataBroker launcher shown on the minimap via LibDBIcon. Left-click
-- toggles the character sheet (the window in use during play); right-click
-- opens the full menu: every play window, the hub and settings, the DM and
-- public-rolls toggles, and Save to Disk. The button's shown/hidden state
-- persists in db.profile.minimap.
--
-- Reads from: ns.OpenModule, ns.RequestDMRole, ns.SaveToDisk, ns.Comm,
--   ns.Addon.db.
-- Exposes on ns.Minimap: Init, SetShown, Toggle.

local ADDON, ns = ...

ns.Minimap = ns.Minimap or {}
local M = ns.Minimap

local ICON = "Interface\\Icons\\inv_scroll_05"

-- Builds the right-click menu (modern Menu API).
local function BuildMenu(owner)
    if not MenuUtil then
        ns.OpenModule("hub")
        return
    end
    -- Play windows first, then the management screens; everything deeper
    -- (characters, systems, import/export, cached sheets) lives in the hub.
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Parchment")
        root:CreateButton("Character Sheet", function() ns.OpenModule("sheet") end)
        root:CreateButton("Combat", function() ns.OpenModule("initiative") end)
        root:CreateButton("Feats", function() ns.OpenModule("feats") end)
        root:CreateButton("Spellbook", function() ns.OpenModule("spellbook") end)
        root:CreateButton("Items", function() ns.OpenModule("items") end)
        root:CreateButton("Party Overview", function() ns.OpenModule("party") end)
        root:CreateDivider()
        root:CreateButton("Menu (characters, systems, ...)", function() ns.OpenModule("hub") end)
        root:CreateButton("Settings", function() ns.OpenModule("config") end)
        root:CreateDivider()
        -- The toggles show their state as real checkboxes. DM mode routes
        -- through the shared claim/step-down path, so the take-over confirm
        -- holds here exactly as it does for /pmt dm.
        if root.CreateCheckbox then
            root:CreateCheckbox("DM mode",
                function() return ns.Comm.IsDM() end,
                function() ns.RequestDMRole(not ns.Comm.IsDM()) end)
            root:CreateCheckbox("Public rolls",
                function() return ns.Addon.db.profile.publicRolls and true or false end,
                function()
                    ns.Addon.db.profile.publicRolls = not ns.Addon.db.profile.publicRolls
                    if ns.ConfigUI then ns.ConfigUI.RefreshIfShown() end
                end)
        else
            root:CreateButton((ns.Comm.IsDM() and "DM mode: on" or "DM mode: off"),
                function() ns.RequestDMRole(not ns.Comm.IsDM()) end)
        end
        root:CreateButton("Save to Disk", function() ns.SaveToDisk() end)
    end)
end

local dataObject = {
    type = "launcher",
    text = "Parchment",
    icon = ICON,
    OnClick = function(self, button)
        if button == "RightButton" then
            BuildMenu(self)
        else
            ns.OpenModule("sheet")
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("Parchment")
        tooltip:AddLine("|cffeeeeeeLeft-click|r  character sheet", 0.9, 0.9, 0.9)
        tooltip:AddLine("|cffeeeeeeRight-click|r  menu", 0.9, 0.9, 0.9)
    end,
}

-- Registers the minimap button. Called once the addon is enabled (db ready).
function M.Init()
    local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (ldb and icon) then return end
    ldb:NewDataObject("Parchment", dataObject)
    ns.Addon.db.profile.minimap = ns.Addon.db.profile.minimap or { hide = false }
    if not icon:IsRegistered("Parchment") then
        icon:Register("Parchment", dataObject, ns.Addon.db.profile.minimap)
    end
end

-- Shows or hides the minimap button explicitly (persisted). Returns whether
-- the button is now shown, or nil when LibDBIcon is unavailable.
function M.SetShown(shown)
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not icon then return end
    local mm = ns.Addon.db.profile.minimap
    mm.hide = not shown
    if mm.hide then icon:Hide("Parchment") else icon:Show("Parchment") end
    return not mm.hide
end

-- Flips the minimap button's visibility (persisted).
function M.Toggle()
    return M.SetShown(ns.Addon.db.profile.minimap.hide)
end
