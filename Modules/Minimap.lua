-- Parchment - Minimap
--
-- A LibDataBroker launcher shown on the minimap via LibDBIcon. Left-click opens
-- the character sheet; right-click opens a menu of all Parchment windows and
-- actions. The button's shown/hidden state persists in db.profile.minimap.
--
-- Reads from: ns.OpenModule, ns.Sharing, ns.SaveToDisk, ns.Comm, ns.Addon.db.
-- Exposes on ns.Minimap: Init, SetShown, Toggle.

local ADDON, ns = ...

ns.Minimap = ns.Minimap or {}
local M = ns.Minimap

local ICON = "Interface\\Icons\\inv_scroll_05"

-- Builds the right-click menu (modern Menu API).
local function BuildMenu(owner)
    if not MenuUtil then
        ns.OpenModule("sheet")
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Parchment")
        root:CreateButton("Character Sheet", function() ns.OpenModule("sheet") end)
        root:CreateButton("Initiative", function() ns.OpenModule("initiative") end)
        root:CreateButton("Perks", function() ns.OpenModule("perks") end)
        root:CreateButton("Character Editor", function() ns.OpenModule("edit") end)
        root:CreateButton("New Character", function() ns.OpenModule("new") end)
        root:CreateButton("Import / Export", function() ns.OpenModule("import") end)
        root:CreateButton("Party Overview", function() ns.OpenModule("party") end)
        root:CreateButton("Cached Sheets", function() ns.Sharing.OpenCache() end)
        root:CreateDivider()
        root:CreateButton((ns.Comm.IsDM() and "DM mode: on" or "DM mode: off"), function()
            ns.Comm.SetDM(not ns.Comm.IsDM())
            if ns.InitiativeUI and ns.InitiativeUI.RefreshIfShown then ns.InitiativeUI.RefreshIfShown() end
            if ns.ConfigUI then ns.ConfigUI.RefreshIfShown() end
        end)
        root:CreateButton("Settings", function() ns.OpenModule("config") end)
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
