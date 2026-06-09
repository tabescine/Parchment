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
local Refresh

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
        IT.Remove(row.index)
        Refresh(InitiativeUI.frame)
    end)
    row.remove = rm

    row:SetScript("OnClick", function()
        IT.SetCurrent(row.index)
        Refresh(InitiativeUI.frame)
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

-- Updates the title (round) and the list.
function Refresh(self)
    local state = IT.GetState()
    local round = state.round or 0
    self.titleFS:SetText(round > 0 and ("Initiative  -  Round " .. round) or "Initiative")
    RenderList(self)
end

-- Commits the name/value inputs as a combatant. rolled=true treats the value as
-- a d20 modifier; otherwise it is the initiative total.
local function CommitInput(self, rolled)
    local name = self.nameBox:GetText()
    local value = tonumber(self.modBox:GetText()) or 0
    if rolled then IT.AddRolled(name, value) else IT.Add(name, value) end
    self.nameBox:SetText("")
    self.modBox:SetText("")
    self.nameBox:ClearFocus()
    self.modBox:ClearFocus()
    Refresh(self)
end

-- Adds the active character, rolling d20 + their computed initiative.
local function AddActiveCharacter(self)
    local char = ns.GetActiveCharacter()
    if not char then return end
    local sheet = ns.CharacterSheet.Compute(char, ns.GetSystem())
    if sheet then IT.AddRolled(sheet.name, sheet.derived.initiative, false) end
    Refresh(self)
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
    local addBtn = MakeButton(f, "Add", 42, "Add a combatant using the value as their initiative total.")
    addBtn:SetPoint("BOTTOMLEFT", 170, 41)
    local rollBtn = MakeButton(f, "Roll", 42, "Add a combatant, rolling d20 + the value as a modifier.")
    rollBtn:SetPoint("BOTTOMLEFT", 214, 41)

    -- Action row: Me, Next, Reset, round.
    local meBtn = MakeButton(f, "Me", 42, "Add your active character, rolling d20 + their initiative.")
    meBtn:SetPoint("BOTTOMLEFT", 18, 14)
    local nextBtn = MakeButton(f, "Next", 54, "Advance to the next turn.")
    nextBtn:SetPoint("BOTTOMLEFT", 64, 14)
    local resetBtn = MakeButton(f, "Reset", 54, "Clear all combatants.")
    resetBtn:SetPoint("BOTTOMLEFT", 122, 14)

    -- Wire actions.
    addBtn:SetScript("OnClick", function() CommitInput(f, false) end)
    rollBtn:SetScript("OnClick", function() CommitInput(f, true) end)
    meBtn:SetScript("OnClick", function() AddActiveCharacter(f) end)
    nextBtn:SetScript("OnClick", function() IT.Next(); Refresh(f) end)
    resetBtn:SetScript("OnClick", function() IT.Reset(); Refresh(f) end)
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
