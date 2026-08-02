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
local SIDEBAR_W = 128
local ROW_H = 30
local NAV_H = 26

-- Blizzard textures for the sidebar entries (TRP3-style flat nav; Parchment
-- ships no art). The friends-list bar is cropped past its rounded left cap;
-- the quest-title gradient marks the selected entry.
local TEX_HOVER = "Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar"
local TEX_SELECTED = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

-- Stock interface sounds (read off _G: absent in the headless tests).
local PlaySound, SOUNDKIT = _G.PlaySound, _G.SOUNDKIT

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

-- Repaints every sidebar entry: label (with the panel's live count when it
-- declares one), selected band, and font. Selection disables the entry - it
-- is "where you are", not an unavailable screen; motion scripts stay alive so
-- a truncation tooltip could still fire (the TRP3 pattern).
local function UpdateSidebar(self)
    for _, p in ipairs(panels) do
        local b = p.button
        if b then
            local selected = p.id == self.current
            local label = p.label
            if p.count then
                local ok, n = pcall(p.count)
                if ok and n then label = label .. "  (" .. n .. ")" end
            end
            b.label:SetText(label)
            b.label:SetFontObject(selected and _G.GameFontNormal or _G.GameFontHighlight)
            b.sel:SetShown(selected)
            b:SetEnabled(not selected)
        end
    end
end

-- Shows a panel: the sidebar reflects the selection, the page title takes the
-- panel's label, and the panel frame is built lazily and refreshed on every
-- show.
local function Select(self, id)
    local chosen = PanelById(id) or PanelById(self.current) or panels[1]
    if not chosen then return end
    self.current = chosen.id
    UpdateSidebar(self)
    self.pageTitle:SetText(chosen.label)
    for _, p in ipairs(panels) do
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

    -- Sidebar: flat nav entries (icon + label) instead of gray panel buttons.
    -- Hover lights the row additively; the selected entry carries a gold band
    -- and gold text and stops reacting (see UpdateSidebar).
    local y = -46
    for _, p in ipairs(panels) do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(SIDEBAR_W, NAV_H)
        b:SetPoint("TOPLEFT", PAD, y)
        b:SetMotionScriptsWhileDisabled(true)

        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(TEX_HOVER)
        hl:SetTexCoord(0.25, 1, 0, 1)
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.6)

        b.sel = b:CreateTexture(nil, "BACKGROUND")
        b.sel:SetAllPoints()
        b.sel:SetTexture(TEX_SELECTED)
        b.sel:SetAlpha(0.7)
        b.sel:Hide()

        if p.icon then
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetSize(16, 16)
            b.icon:SetPoint("LEFT", 4, 0)
            b.icon:SetTexture("Interface\\Icons\\" .. p.icon)
        end
        b.label = b:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        b.label:SetPoint("LEFT", p.icon and 26 or 6, 0)
        b.label:SetPoint("RIGHT", -2, 0)
        b.label:SetJustifyH("LEFT")
        b.label:SetWordWrap(false)
        b.label:SetText(p.label)

        b:SetScript("OnClick", function()
            if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
            Select(f, p.id)
        end)
        p.button = b
        y = y - NAV_H - 2
    end

    -- Window open/close sounds (stock SOUNDKIT; guarded for headless tests).
    f:HookScript("OnShow", function()
        if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.ACHIEVEMENT_MENU_OPEN) end
    end)
    f:HookScript("OnHide", function()
        if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.ACHIEVEMENT_MENU_CLOSE) end
    end)

    local divider = f:CreateTexture(nil, "BACKGROUND")
    divider:SetColorTexture(UI.LINE[1], UI.LINE[2], UI.LINE[3], UI.LINE[4])
    divider:SetPoint("TOPLEFT", PAD + SIDEBAR_W + 7, -46)
    divider:SetPoint("BOTTOMLEFT", PAD + SIDEBAR_W + 7, 14)
    divider:SetWidth(1)

    -- Page header: the panel's name large, over a gold rule (the Blizzard
    -- options-divider atlas when the client has it, a plain line otherwise).
    f.pageTitle = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    f.pageTitle:SetPoint("TOPLEFT", PAD + SIDEBAR_W + 16, -46)
    f.pageTitle:SetJustifyH("LEFT")
    local rule = f:CreateTexture(nil, "ARTWORK")
    local okAtlas = pcall(rule.SetAtlas, rule, "Options_HorizontalDivider", true)
    if not okAtlas then
        rule:SetColorTexture(UI.LINE[1], UI.LINE[2], UI.LINE[3], UI.LINE[4])
        rule:SetHeight(1)
    end
    rule:SetPoint("TOPLEFT", f.pageTitle, "BOTTOMLEFT", 0, -6)
    rule:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    rule:SetVertexColor(1, 0.675, 0.125)

    -- Content pane; panel frames fill it, below the header.
    f.body = CreateFrame("Frame", nil, f)
    f.body:SetPoint("TOPLEFT", PAD + SIDEBAR_W + 16, -84)
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
    UpdateSidebar(f)   -- data changed somewhere; the nav counts follow it
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
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Engraved row band + additive hover bar (both Blizzard textures; the
    -- band's TexCoords slice the thin title gradient out of the achievement
    -- frame sheet - the trick TRP3 Extended's database rows use).
    local band = row:CreateTexture(nil, "BACKGROUND")
    band:SetPoint("TOPLEFT", 0, -1)
    band:SetPoint("BOTTOMRIGHT", 0, 1)
    band:SetTexture("Interface\\ACHIEVEMENTFRAME\\UI-Achievement-Title")
    band:SetTexCoord(0, 1, 0.40625, 0.60125)
    band:SetAlpha(0.35)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    hl:SetTexture("Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar")
    hl:SetTexCoord(0.25, 1, 0, 1)
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.6)
    UI.WireRowTip(row)

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

    -- Left-click activates; right-click opens the secondary verbs as a
    -- context menu (modern Menu API; without it right-click just activates
    -- too). Every entry documents itself with a hover tooltip.
    local function Activate(self)
        if self.key and ns.SetActiveCharacter(self.key) then
            ActiveChanged()
            HubUI.RefreshIfShown("characters")
        end
    end
    row:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" and MenuUtil then
            local key, name = self.key, self.charName or self.key or "?"
            MenuUtil.CreateContextMenu(self, function(_, root)
                root:CreateTitle(name)
                local tip = MenuUtil.SetElementTooltip
                local e = root:CreateButton("Set active", function() Activate(self) end)
                if tip then tip(e, "Every window renders the active character.") end
                e = root:CreateButton("Edit", function()
                    Activate(self)
                    ns.OpenModule("edit")
                end)
                if tip then tip(e, "Makes it active and opens the editor.") end
                e = root:CreateButton(DELETE or "Delete", function()
                    StaticPopup_Show("PARCHMENT_DELETE_CHAR", name, nil, key)
                end)
                if tip then tip(e, "Asks first. Export a backup from Import / export.") end
            end)
            return
        end
        Activate(self)
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
        row.tipTitle = ch.name or entry.key
        local lines = { { "Level", ch.level or "?" } }
        if ch.race and ch.race ~= "" then lines[#lines + 1] = { "Race", ch.race } end
        lines[#lines + 1] = { "Key", entry.key }
        row.tipLines = lines
        row.tipHints = active
            and { "This is the active character.", "Right-click: actions" }
            or { "Click: make it the active character", "Right-click: actions" }
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
    id = "characters", label = "Characters", order = 10, icon = "inv_helmet_20",
    count = function()
        local n = 0
        for _ in pairs(ns.GetCharacters()) do n = n + 1 end
        return n
    end,
    Build = BuildCharacters, Refresh = RefreshCharacters,
})

ns.RegisterModule("hub", function() HubUI.Toggle() end)
ns.RegisterModule("characters", function() HubUI.Toggle("characters") end)
