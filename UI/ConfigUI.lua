-- Parchment - Config (UI)
--
-- The settings window (/pmt config): checkboxes for the profile toggles that
-- previously lived only behind slash commands (DM mode, public initiative
-- rolls, minimap button), plus shortcuts to the system library and saving.
-- Pure UI over db.profile - it owns no state of its own, so the slash
-- commands and the minimap menu stay equally valid ways to flip the same
-- settings (they refresh this window when it is open, and vice versa).
--
-- Reads from: ns.Addon.db.profile, ns.Comm, ns.Minimap, ns.Systems, ns.UI.
-- Exposes on ns.ConfigUI: Open, Toggle, RefreshIfShown.
-- Registers the "config" module opener with Core.

local ADDON, ns = ...

local UI = ns.UI
local PAD = 16

local ConfigUI = {}
ns.ConfigUI = ConfigUI

local Refresh

-- Other windows whose display depends on these settings.
local function RefreshDependents()
    if ns.InitiativeUI and ns.InitiativeUI.RefreshIfShown then ns.InitiativeUI.RefreshIfShown() end
end

-- Creates a labelled checkbox row with a hover tooltip. onClick receives the
-- new checked state as a boolean.
local function Checkbox(f, y, label, tooltip, onClick)
    local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", PAD, y)
    cb.label = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cb.label:SetText(label)
    cb.label:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(label, 1, 1, 1)
        GameTooltip:AddLine(tooltip, 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", GameTooltip_Hide)
    return cb
end

-- Creates a full-width action button row.
local function ActionButton(f, y, text, onClick)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(200, 22)
    b:SetPoint("TOPLEFT", PAD + 4, y)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function Header(f, y, text)
    local fs = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", PAD, y)
    fs:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
    fs:SetText(text)
end

-- Builds the window once. Refresh fills the checkbox states.
local function BuildFrame()
    local f = UI.CreateWindow("ParchmentConfigFrame", {
        title = "Settings", width = 320, height = 380,
        minW = 300, minH = 380, maxW = 460, maxH = 520, dbKey = "configWindow",
    })
    -- Restored geometry may predate a taller layout; programmatic SetSize is
    -- not clamped by the resize bounds, so enforce the minimum here.
    if f:GetHeight() < 380 then f:SetHeight(380) end

    local y = -48
    Header(f, y, "GENERAL"); y = y - 24

    f.dmCheck = Checkbox(f, y, "DM mode",
        "Act as the DM: your initiative edits broadcast to the group, and you "
        .. "may send your ruleset with 'Share system'. When off, you receive "
        .. "the DM's sync and submit your own initiative instead. Toggling "
        .. "this never sends anything by itself.",
        function(checked)
            ns.Comm.SetDM(checked)
            RefreshDependents()
        end)
    y = y - 28

    f.rollsCheck = Checkbox(f, y, "Public initiative rolls",
        "Roll initiative with the in-game dice roller so the whole party sees "
        .. "the result, instead of a hidden local d20.",
        function(checked)
            ns.Addon.db.profile.publicRolls = checked
            RefreshDependents()
        end)
    y = y - 28

    f.minimapCheck = Checkbox(f, y, "Minimap button",
        "Show the Parchment button on the minimap.",
        function(checked)
            if ns.Minimap then ns.Minimap.SetShown(checked) end
        end)
    y = y - 36

    Header(f, y, "SYSTEMS"); y = y - 26
    ActionButton(f, y, "Choose active system", function() ns.Systems.OpenPicker() end); y = y - 26
    ActionButton(f, y, "Delete a system", function() ns.Systems.OpenDeletePicker() end); y = y - 26
    ActionButton(f, y, "Import / Export", function() ns.OpenModule("import") end); y = y - 26
    local share = ActionButton(f, y, "Share system with group", ns.ShareSystem); y = y - 36
    share:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Share system", 1, 1, 1)
        GameTooltip:AddLine("Sends your active system to the party/raid (DM mode only). "
            .. "Recipients are asked before adopting it.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    share:SetScript("OnLeave", GameTooltip_Hide)

    Header(f, y, "DATA"); y = y - 26
    local save = ActionButton(f, y, "Save to Disk", ns.SaveToDisk)
    save:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Reloads the UI to write all Parchment changes to disk.", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    save:SetScript("OnLeave", GameTooltip_Hide)

    return f
end

-- Fills the checkbox states from the live profile.
Refresh = function(self)
    local p = ns.Addon.db.profile
    self.dmCheck:SetChecked(ns.Comm and ns.Comm.IsDM() or false)
    self.rollsCheck:SetChecked(p.publicRolls and true or false)
    self.minimapCheck:SetChecked(not (p.minimap and p.minimap.hide))
end

-- Returns the singleton frame, building it on first use.
local function GetFrame()
    if not ConfigUI.frame then ConfigUI.frame = BuildFrame() end
    return ConfigUI.frame
end

function ConfigUI.Open()
    local f = GetFrame()
    Refresh(f)
    f:Show()
end

function ConfigUI.Toggle()
    local f = GetFrame()
    if f:IsShown() then f:Hide() else ConfigUI.Open() end
end

-- Re-syncs the checkboxes when a setting changes elsewhere (slash command,
-- minimap menu) while the window is open.
function ConfigUI.RefreshIfShown()
    if ConfigUI.frame and ConfigUI.frame:IsShown() then Refresh(ConfigUI.frame) end
end

ns.RegisterModule("config", ConfigUI.Toggle)
