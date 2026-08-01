-- Parchment - Hub (UI)
--
-- The management window (/pmt hub, minimap left-click): one window with a
-- left sidebar of panels and a content pane, TRP3-style. Panels are the
-- visit-and-close screens (characters, settings, ...); the play windows
-- (sheet, combat, feats, party) stay independent on purpose, so they can be
-- open side by side during a session.
--
-- Panels self-register at load via ns.HubUI.RegisterPanel{ id, label, order,
-- Build, Refresh }: Build(panel) creates the widgets once into the provided
-- frame (lazily, on first show); Refresh(panel) re-fills them on every show.
-- This file owns the shell and the Characters panel (the roster: select,
-- delete, create, edit).
--
-- Reads from: ns.UI, ns.GetCharacters, ns.GetActiveCharacter,
--   ns.SetActiveCharacter, ns.OpenModule, ns.Systems, ns.Party.
-- Exposes on ns.HubUI: Open(panelId?), Toggle(panelId?), RegisterPanel,
--   RefreshIfShown(panelId?).
-- Registers the "hub" and "characters" module openers with Core.

local ADDON, ns = ...

local UI = ns.UI
local PAD = 14
local SIDEBAR_W = 116
local ROW_H = 30

-- Font for the selected sidebar button (see Select): gold, and the same size
-- as UIPanelButtonTemplate's normal font. Read off _G so a client without it
-- simply keeps the template's greyed-out disabled font.
local SELECTED_FONT = _G.GameFontNormal

local HubUI = {}
ns.HubUI = HubUI

-- Ordered panel registry. All registrations happen at file-load time (the
-- .toc loads panel files before any user interaction builds the frame).
local panels = {}

function HubUI.RegisterPanel(def)
    panels[#panels + 1] = def
    table.sort(panels, function(a, b) return (a.order or 50) < (b.order or 50) end)
end

local function PanelById(id)
    for _, p in ipairs(panels) do
        if p.id == id then return p end
    end
end

-- Shows a panel: sidebar buttons reflect the selection (the active panel's
-- button is disabled - it is "where you are", not an unavailable screen, hence
-- the SELECTED_FONT set in BuildFrame), the panel frame is built lazily and
-- refreshed on every show.
local function Select(self, id)
    local chosen = PanelById(id) or PanelById(self.current) or panels[1]
    if not chosen then return end
    self.current = chosen.id
    for _, p in ipairs(panels) do
        if p.button then p.button:SetEnabled(p ~= chosen) end
        if p.frame then p.frame:Hide() end
    end
    if not chosen.frame then
        chosen.frame = CreateFrame("Frame", nil, self.body)
        chosen.frame:SetAllPoints(self.body)
        chosen.Build(chosen.frame)
    end
    chosen.frame:Show()
    if chosen.Refresh then chosen.Refresh(chosen.frame) end
end

local function BuildFrame()
    local f = UI.CreateWindow("ParchmentHubFrame", {
        title = "Parchment", width = 620, height = 480,
        minW = 540, minH = 380, maxW = 940, maxH = 820, dbKey = "hubWindow",
    })

    -- Sidebar.
    local y = -46
    for _, p in ipairs(panels) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(SIDEBAR_W, 24)
        b:SetPoint("TOPLEFT", PAD, y)
        -- Selection is expressed by disabling the button (Select), so its
        -- disabled font is what carries the "you are here" reading.
        if SELECTED_FONT and b.SetDisabledFontObject then
            b:SetDisabledFontObject(SELECTED_FONT)
        end
        b:SetText(p.label)
        b:SetScript("OnClick", function() Select(f, p.id) end)
        p.button = b
        y = y - 27
    end

    local divider = f:CreateTexture(nil, "BACKGROUND")
    divider:SetColorTexture(UI.LINE[1], UI.LINE[2], UI.LINE[3], UI.LINE[4])
    divider:SetPoint("TOPLEFT", PAD + SIDEBAR_W + 7, -46)
    divider:SetPoint("BOTTOMLEFT", PAD + SIDEBAR_W + 7, 14)
    divider:SetWidth(1)

    -- Content pane; panel frames fill it.
    f.body = CreateFrame("Frame", nil, f)
    f.body:SetPoint("TOPLEFT", PAD + SIDEBAR_W + 16, -46)
    f.body:SetPoint("BOTTOMRIGHT", -PAD, 14)

    return f
end

local function GetFrame()
    if not HubUI.frame then HubUI.frame = BuildFrame() end
    return HubUI.frame
end

-- Opens the hub on a panel (or the last shown / first registered one).
function HubUI.Open(panelId)
    local f = GetFrame()
    Select(f, panelId)
    f:Show()
end

-- Toggles the hub; with panelId, an open hub showing another panel switches
-- to it instead of closing.
function HubUI.Toggle(panelId)
    local f = GetFrame()
    if f:IsShown() and (not panelId or f.current == panelId) then
        f:Hide()
    else
        HubUI.Open(panelId)
    end
end

-- Re-runs the current panel's Refresh while the hub is open. With panelId,
-- only when that panel is the one showing.
function HubUI.RefreshIfShown(panelId)
    local f = HubUI.frame
    if not (f and f:IsShown()) then return end
    if panelId and f.current ~= panelId then return end
    local p = PanelById(f.current)
    if p and p.frame and p.Refresh then p.Refresh(p.frame) end
end

-- Characters panel ----------------------------------------------------------

-- Active-character changes ripple to every window that renders it.
local function ActiveChanged()
    if ns.Systems then ns.Systems.RefreshAll() end
    if ns.Party then ns.Party.OnVitalsChanged() end
end

local function CreateCharRow(content)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_H)

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    hl:SetColorTexture(UI.HILITE[1], UI.HILITE[2], UI.HILITE[3], UI.HILITE[4])

    row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 6, -2)
    row.name:SetJustifyH("LEFT")
    row.meta = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.meta:SetPoint("BOTTOMLEFT", 6, 2)
    row.meta:SetJustifyH("LEFT")
    row.meta:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    local del = CreateFrame("Button", nil, row)
    del:SetSize(16, 16)
    del:SetPoint("RIGHT", -6, 0)
    del:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    del:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    del:SetScript("OnClick", function()
        if row.key then
            StaticPopup_Show("PARCHMENT_DELETE_CHAR", row.charName or row.key, nil, row.key)
        end
    end)
    del:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Delete " .. (row.charName or "character"), 1, 1, 1)
        GameTooltip:Show()
    end)
    del:SetScript("OnLeave", GameTooltip_Hide)

    -- Right edges (short of the X) so a long name/meta truncates instead of
    -- rendering underneath the button.
    row.name:SetPoint("RIGHT", del, "LEFT", -4, 0)
    row.name:SetWordWrap(false)
    row.meta:SetPoint("RIGHT", del, "LEFT", -4, 0)
    row.meta:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        if self.key and ns.SetActiveCharacter(self.key) then
            ActiveChanged()
            HubUI.RefreshIfShown("characters")
        end
    end)
    return row
end

local function RefreshCharacters(panel)
    local content = panel.content
    content.rows = content.rows or {}
    for _, r in ipairs(content.rows) do r:Hide() end

    local list = {}
    for key, ch in pairs(ns.GetCharacters()) do
        list[#list + 1] = { key = key, ch = ch }
    end
    table.sort(list, function(a, b) return (a.ch.name or a.key) < (b.ch.name or b.key) end)

    if #list == 0 then
        ns.UI.Empty(panel, "No characters yet.\n\nCreate one to get started, or import an existing one.",
            "Create a character", function() ns.OpenModule("new") end,
            "Import a character", function() ns.OpenModule("import") end)
        content:SetHeight(10)
        return
    end
    ns.UI.HideEmpty(panel)

    local _, activeKey = ns.GetActiveCharacter()
    local y = -2
    for i, entry in ipairs(list) do
        local row = content.rows[i] or CreateCharRow(content)
        content.rows[i] = row
        local ch = entry.ch
        row.key, row.charName = entry.key, ch.name
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)
        local active = entry.key == activeKey
        row.name:SetText((ch.name or entry.key) .. (active and "  |cff66d966(active)|r" or ""))
        local nameC = active and UI.GOLD or UI.TEXT
        row.name:SetTextColor(nameC[1], nameC[2], nameC[3])
        row.meta:SetText("level " .. (ch.level or "?")
            .. (ch.race and ch.race ~= "" and ("  -  " .. ch.race) or "")
            .. "  -  [" .. entry.key .. "]")
        row:Show()
        y = y - ROW_H
    end
    content:SetHeight(math.max(10, -y + 2))
end

local function BuildCharacters(panel)
    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 4, -4)
    hint:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    hint:SetText("Click a character to make it active. X deletes (asks first).")

    local scroll = CreateFrame("ScrollFrame", "ParchmentHubCharScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -24)
    scroll:SetPoint("BOTTOMRIGHT", -26, 34)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
    panel.content = content

    local function btn(text, width, x, onClick)
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetSize(width, 22)
        b:SetPoint("BOTTOMLEFT", x, 4)
        b:SetText(text)
        b:SetScript("OnClick", onClick)
        return b
    end
    btn("New", 56, 0, function() ns.OpenModule("new") end)
    btn("Edit", 56, 60, function() ns.OpenModule("edit") end)
    btn("Import / Export", 110, 120, function() ns.OpenModule("import") end)
end

HubUI.RegisterPanel({
    id = "characters", label = "Characters", order = 10,
    Build = BuildCharacters, Refresh = RefreshCharacters,
})

ns.RegisterModule("hub", function() HubUI.Toggle() end)
ns.RegisterModule("characters", function() HubUI.Toggle("characters") end)
