-- Parchment - Initiative Tracker (UI)
--
-- The initiative window: a scrolling, click-to-select turn order driven by
-- InitiativeTracker, with controls to add combatants (by total or by rolling
-- d20 + modifier), add the active character, advance the turn, and reset. The
-- current turn is highlighted; the round shows in the title.
--
-- Reads from: ns.InitiativeTracker, ns.GetActiveCharacter, ns.GetSystem,
--   ns.CharacterSheet.Compute, ns.UI (shared window + palette).
-- Registers the "initiative" module opener with Core.

local ADDON, ns = ...

local ROW_H = 20
local UI = ns.UI
local IT = ns.InitiativeTracker

local InitiativeUI = {}
ns.InitiativeUI = InitiativeUI

-- Forward declaration so row/button scripts can refresh the window.
local Refresh, CanEdit, Sync

-- Creates a small text button using the standard panel button look.
local function MakeButton(parent, text, width, tooltip)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    if tooltip then
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tooltip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
    end
    return b
end

-- Creates an input box.
local function MakeEditBox(parent, width, numeric)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    if numeric then e:SetNumeric(true) end
    return e
end

-- Creates one pooled combatant row (a clickable line with a remove button).
local function CreateRow(content)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_H)

    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints(row)
    hl:SetColorTexture(UI.HILITE[1], UI.HILITE[2], UI.HILITE[3], UI.HILITE[4])
    row.hl = hl

    row.num = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.num:SetPoint("LEFT", 4, 0)
    row.num:SetWidth(20)
    row.num:SetJustifyH("RIGHT")
    row.num:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.num, "RIGHT", 8, 0)
    row.name:SetJustifyH("LEFT")

    row.init = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.init:SetPoint("RIGHT", -26, 0)
    row.init:SetJustifyH("RIGHT")
    row.init:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])

    local rm = CreateFrame("Button", nil, row)
    rm:SetSize(16, 16)
    rm:SetPoint("RIGHT", -4, 0)
    rm:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    rm:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    rm:SetScript("OnClick", function()
        if not CanEdit() then return end
        IT.Remove(row.index)
        Refresh(InitiativeUI.frame)
        Sync()
    end)
    row.remove = rm

    row:SetScript("OnClick", function()
        if not CanEdit() then return end
        IT.SetCurrent(row.index)
        Refresh(InitiativeUI.frame)
        Sync()
    end)
    return row
end

-- Rebuilds the combatant list from current state.
local function RenderList(self)
    local state = IT.GetState()
    local content = self.content
    content.rows = content.rows or {}
    for _, r in ipairs(content.rows) do r:Hide() end

    local y = -2
    for i, c in ipairs(state.combatants) do
        local row = content.rows[i] or CreateRow(content)
        content.rows[i] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)
        row.index = i
        row.num:SetText(i .. ".")
        row.name:SetText(c.name)
        local isCurrent = (i == state.current)
        if isCurrent then
            row.name:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
        elseif c.isNPC then
            row.name:SetTextColor(UI.RED[1], UI.RED[2], UI.RED[3])
        else
            row.name:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
        end
        row.init:SetText(tostring(c.init))
        row.hl:SetShown(isCurrent)
        row:Show()
        y = y - ROW_H
    end
    content:SetHeight(math.max(10, -y + 2))
end

-- True when this client may edit the order: the DM, or anyone playing solo
-- (outside a group the tracker is purely local). Players in a group are
-- read-only and submit their initiative to the DM instead.
CanEdit = function()
    return (not ns.Comm) or ns.Comm.IsDM() or not IsInGroup()
end

-- Broadcasts the current order to the group when acting as DM.
Sync = function()
    if ns.Comm and ns.Comm.IsDM() then ns.Comm.Send("INIT", IT.GetState()) end
end

-- Updates the title (round) and the list, and reflects the current role on the
-- editing controls.
function Refresh(self)
    local state = IT.GetState()
    local round = state.round or 0
    local title = round > 0 and ("Initiative  -  Round " .. round) or "Initiative"
    if ns.Comm and ns.Comm.IsDM() then title = title .. "  |cff8ec6ff(DM)|r" end
    self.titleFS:SetText(title)

    local editable = CanEdit()
    self.addBtn:SetEnabled(editable)
    self.rollBtn:SetEnabled(editable)
    self.nextBtn:SetEnabled(editable)
    self.resetBtn:SetEnabled(editable)
    self.meBtn:SetText(editable and "Me" or "Submit")
    if self.publicCheck and ns.Addon and ns.Addon.db then
        self.publicCheck:SetChecked(ns.Addon.db.profile.publicRolls)
    end
    RenderList(self)
end

-- Commits the name/value inputs as a combatant. rolled=true treats the value as
-- a d20 modifier; otherwise it is the initiative total.
local function CommitInput(self, rolled)
    if not CanEdit() then return end
    local name = self.nameBox:GetText()
    local value = tonumber(self.modBox:GetText()) or 0
    self.nameBox:SetText("")
    self.modBox:SetText("")
    self.nameBox:ClearFocus()
    self.modBox:ClearFocus()
    if rolled then
        -- May resolve asynchronously (public rolls); refresh in the callback.
        IT.AddRolled(name, value, false, function() Refresh(self); Sync() end)
    else
        IT.Add(name, value)
        Refresh(self)
        Sync()
    end
end

-- "Me": as DM/solo, adds the active character (rolled). As a player in a group,
-- submits the rolled initiative to the DM instead.
local function AddActiveCharacter(self)
    if not ns.HasSystem() then
        ns.Print("no system loaded - import one with /pmt import to add your character.")
        return
    end
    local char = ns.GetActiveCharacter()
    if not char then return end
    local sheet = ns.CharacterSheet.Compute(char, ns.GetSystem())
    if not sheet then return end
    if CanEdit() then
        IT.AddRolled(sheet.name, sheet.derived.initiative, false, function() Refresh(self); Sync() end)
    else
        IT.RequestRoll(sheet.derived.initiative, function(total)
            local ok, err = ns.Comm.Send("INITSUBMIT", { name = sheet.name, init = total })
            ns.Print(ok and ("submitted initiative " .. total .. " to the DM.") or (err or "submit failed."))
        end)
    end
end

-- Builds the window and its controls once.
local function BuildFrame()
    local f = UI.CreateWindow("ParchmentInitFrame", {
        title = "Initiative", width = 340, height = 440,
        minW = 280, minH = 260, maxW = 560, maxH = 900, dbKey = "initiativeWindow",
    })

    -- Scrolling combatant list.
    local scroll = CreateFrame("ScrollFrame", "ParchmentInitScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -46)
    scroll:SetPoint("BOTTOMRIGHT", -32, 72)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    content.rows = {}
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
    f.content = content

    -- Input row: name, value, Add, Roll.
    f.nameBox = MakeEditBox(f, 104, false)
    f.nameBox:SetPoint("BOTTOMLEFT", 18, 42)
    f.modBox = MakeEditBox(f, 30, true)
    f.modBox:SetPoint("BOTTOMLEFT", 134, 42)
    f.addBtn = MakeButton(f, "Add", 42, "Add a combatant using the value as their initiative total.")
    f.addBtn:SetPoint("BOTTOMLEFT", 170, 41)
    f.rollBtn = MakeButton(f, "Roll", 42, "Add a combatant, rolling d20 + the value as a modifier.")
    f.rollBtn:SetPoint("BOTTOMLEFT", 214, 41)

    -- Action row: Me/Submit, Next, Reset, round.
    f.meBtn = MakeButton(f, "Me", 42, "DM/solo: add your active character (rolled). Player: submit your initiative to the DM.")
    f.meBtn:SetPoint("BOTTOMLEFT", 18, 14)
    f.nextBtn = MakeButton(f, "Next", 54, "Advance to the next turn.")
    f.nextBtn:SetPoint("BOTTOMLEFT", 64, 14)
    f.resetBtn = MakeButton(f, "Reset", 54, "Clear all combatants.")
    f.resetBtn:SetPoint("BOTTOMLEFT", 122, 14)

    -- Public-roll toggle: route Roll/Me through the in-game dice roller so the
    -- whole party sees the result, instead of a hidden local d20.
    f.publicCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.publicCheck:SetSize(22, 22)
    f.publicCheck:SetPoint("BOTTOMRIGHT", -8, 12)
    f.publicLabel = f.publicCheck:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.publicLabel:SetPoint("RIGHT", f.publicCheck, "LEFT", -1, 0)
    f.publicLabel:SetText("Public roll")
    f.publicCheck:SetScript("OnClick", function(self)
        if ns.Addon and ns.Addon.db then
            ns.Addon.db.profile.publicRolls = self:GetChecked() and true or false
        end
    end)
    f.publicCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Public rolls", 1, 1, 1)
        GameTooltip:AddLine("Roll with the in-game dice roller so the whole party "
            .. "sees it, instead of a hidden local d20.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    f.publicCheck:SetScript("OnLeave", GameTooltip_Hide)

    -- Wire actions.
    f.addBtn:SetScript("OnClick", function() CommitInput(f, false) end)
    f.rollBtn:SetScript("OnClick", function() CommitInput(f, true) end)
    f.meBtn:SetScript("OnClick", function() AddActiveCharacter(f) end)
    f.nextBtn:SetScript("OnClick", function() if CanEdit() then IT.Next(); Refresh(f); Sync() end end)
    f.resetBtn:SetScript("OnClick", function() if CanEdit() then IT.Reset(); Refresh(f); Sync() end end)
    f.nameBox:SetScript("OnEnterPressed", function() CommitInput(f, false) end)
    f.modBox:SetScript("OnEnterPressed", function() CommitInput(f, false) end)

    f.OnResize = function(self) RenderList(self) end
    return f
end

-- Returns the singleton frame, building it on first use.
local function GetFrame()
    if not InitiativeUI.frame then InitiativeUI.frame = BuildFrame() end
    return InitiativeUI.frame
end

function InitiativeUI.Open()
    local f = GetFrame()
    Refresh(f)
    f:Show()
end

function InitiativeUI.Toggle()
    local f = GetFrame()
    if f:IsShown() then f:Hide() else InitiativeUI.Open() end
end

ns.RegisterModule("initiative", InitiativeUI.Toggle)

-- Refreshes the tracker window if it is open.
local function RefreshIfShown()
    if InitiativeUI.frame and InitiativeUI.frame:IsShown() then Refresh(InitiativeUI.frame) end
end
InitiativeUI.RefreshIfShown = RefreshIfShown

-- Sync handlers: players adopt the DM's broadcast order; the DM accepts player
-- initiative submissions, adds them, and rebroadcasts.
if ns.Comm then
    ns.Comm.On("INIT", function(state)
        -- The DM's own state is the source of truth; ignore other broadcasts.
        if ns.Comm.IsDM() then return end
        if type(state) == "table" then
            IT.SetState(state)
            RefreshIfShown()
        end
    end)
    ns.Comm.On("INITSUBMIT", function(payload, sender)
        if not ns.Comm.IsDM() then return end
        if type(payload) ~= "table" or type(payload.name) ~= "string" then return end
        local init = tonumber(payload.init) or 0
        if IT.Add(payload.name, init, false) then
            ns.Print((sender or "a player") .. " submitted initiative " .. init .. ".")
            RefreshIfShown()
            Sync()
        end
    end)
end
