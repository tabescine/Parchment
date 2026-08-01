-- Parchment - Config (UI)
--
-- The Settings panel of the hub window (/pmt config opens the hub there):
-- checkboxes for the profile toggles (DM mode, public initiative rolls,
-- vitals sharing, minimap button) with a status line naming the recognized
-- DM, plus shortcuts to the system library and saving. Pure UI over
-- db.profile - it owns no state of its own, so the slash commands and the
-- minimap menu stay equally valid ways to flip the same settings (they
-- refresh this panel when it shows, and vice versa). The DM checkbox routes
-- through ns.RequestDMRole, so the take-over confirm holds here too.
--
-- Reads from: ns.Addon.db.profile, ns.Comm, ns.Minimap, ns.Systems, ns.UI,
--   ns.HubUI (panel registration and open/refresh).
-- Exposes on ns.ConfigUI: Open, Toggle, RefreshIfShown (thin wrappers over
--   the hub's settings panel, kept so callers need not know where it lives).
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

-- Builds the panel widgets once into the hub-provided frame. Refresh fills
-- the checkbox states.
local function BuildContent(f)
    local y = -8
    Header(f, y, "GENERAL"); y = y - 24

    f.dmCheck = Checkbox(f, y, "DM mode",
        "Act as the DM: your initiative edits broadcast to the group, and you "
        .. "may send your ruleset with 'Share system'. When off, you receive "
        .. "the DM's sync and submit your own initiative instead. Turning it "
        .. "on announces the role to your group (so two active DMs notice "
        .. "each other); sharing your system stays a separate, explicit action.",
        function(checked)
            -- The shared claim/step-down path: announces the change and asks
            -- before taking over from a recognized DM (the checkbox snaps
            -- back until that is confirmed).
            ns.RequestDMRole(checked)
            RefreshDependents()
        end)
    y = y - 26

    -- Who currently holds the role, from this client's point of view.
    f.dmStatus = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.dmStatus:SetPoint("TOPLEFT", PAD + 30, y - 2)
    y = y - 20

    f.rollsCheck = Checkbox(f, y, "Public rolls",
        "Roll with the in-game dice roller so the whole party sees the result "
        .. "- initiative and sheet checks alike - instead of a hidden local "
        .. "d20. Sheet checks also post their breakdown to party chat.",
        function(checked)
            ns.Addon.db.profile.publicRolls = checked
            RefreshDependents()
        end)
    y = y - 28

    f.vitalsCheck = Checkbox(f, y, "Share vitals with party",
        "Broadcast your character's HP/Mana/AC snapshot to group members for "
        .. "their party overview (/pmt party). Turn off to keep your vitals "
        .. "private - you still see members who share theirs.",
        function(checked)
            ns.Addon.db.profile.shareVitals = checked
            if checked and ns.Party then ns.Party.OnVitalsChanged() end
        end)
    y = y - 28

    f.minimapCheck = Checkbox(f, y, "Minimap button",
        "Show the Parchment button on the minimap.",
        function(checked)
            if ns.Minimap then ns.Minimap.SetShown(checked) end
        end)
    y = y - 36

    Header(f, y, "SYSTEMS"); y = y - 26
    ActionButton(f, y, "Manage systems", function() ns.HubUI.Open("systems") end); y = y - 26
    ActionButton(f, y, "Import / Export", function() ns.HubUI.Open("import") end); y = y - 26
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
    local save = ActionButton(f, y, "Save (reloads UI)", ns.SaveToDisk)
    save:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Reloads the UI to write all Parchment changes to disk.", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    save:SetScript("OnLeave", GameTooltip_Hide)
end

-- Fills the checkbox states from the live profile.
Refresh = function(self)
    local p = ns.Addon.db.profile
    self.dmCheck:SetChecked(ns.Comm and ns.Comm.IsDM() or false)
    self.rollsCheck:SetChecked(p.publicRolls and true or false)
    self.vitalsCheck:SetChecked(p.shareVitals ~= false)
    self.minimapCheck:SetChecked(not (p.minimap and p.minimap.hide))
    local rec = ns.Comm and ns.Comm.RecognizedDM()
    if ns.Comm and ns.Comm.IsDM() then
        self.dmStatus:SetText("You are the DM.")
        self.dmStatus:SetTextColor(UI.GREEN[1], UI.GREEN[2], UI.GREEN[3])
    elseif rec then
        self.dmStatus:SetText("Recognized DM: " .. rec)
        self.dmStatus:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
    else
        self.dmStatus:SetText("No DM recognized in your group yet.")
        self.dmStatus:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    end
end

ns.HubUI.RegisterPanel({
    id = "settings", label = "Settings", order = 90, icon = "trade_engineering",
    Build = BuildContent, Refresh = Refresh,
})

function ConfigUI.Open()
    ns.HubUI.Open("settings")
end

function ConfigUI.Toggle()
    ns.HubUI.Toggle("settings")
end

-- Re-syncs the checkboxes when a setting changes elsewhere (slash command,
-- minimap menu) while the panel shows.
function ConfigUI.RefreshIfShown()
    ns.HubUI.RefreshIfShown("settings")
end

ns.RegisterModule("config", ConfigUI.Toggle)
