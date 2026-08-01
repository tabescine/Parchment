-- Parchment - Dialogs
--
-- Reusable modal-style dialogs. Currently a single checklist picker used to
-- collect selection picks (skills, weapons, attributes) and reusable by
-- the editor/wizard. One pooled frame is reused across calls.
--
-- Reads from: ns.UI (shared window + palette), ns.Comm (DM recognition).
-- Exposes on ns.Dialogs: .Pick{ title, prompt, items, max, selected, onConfirm },
--   .ConfirmDMSwitch(current, claimant), .ConfirmDMTakeover(current, onAccept)

local ADDON, ns = ...

local UI = ns.UI
local ROW_H = 20

local Dialogs = {}
ns.Dialogs = Dialogs

local frame
local RenderRows

-- True when id is currently selected.
local function IsSelected(f, id)
    for _, v in ipairs(f.sel) do
        if v == id then return true end
    end
    return false
end

-- Toggles an item, respecting the max (max == 1 replaces; otherwise caps).
local function Toggle(f, id)
    for i, v in ipairs(f.sel) do
        if v == id then table.remove(f.sel, i); RenderRows(f); return end
    end
    if f.max == 1 then
        f.sel = { id }
    elseif #f.sel < f.max then
        f.sel[#f.sel + 1] = id
    else
        return
    end
    RenderRows(f)
end

-- Creates one pooled checklist row.
local function CreateRow(f)
    local row = CreateFrame("Button", nil, f.content)
    row:SetHeight(ROW_H)
    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints(row)
    hl:SetColorTexture(UI.HILITE[1], UI.HILITE[2], UI.HILITE[3], UI.HILITE[4])
    row.hl = hl
    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", 6, 0)
    row.label:SetPoint("RIGHT", -6, 0)
    row.label:SetJustifyH("LEFT")
    row:SetScript("OnClick", function() Toggle(f, row.itemId) end)
    row:SetScript("OnEnter", function(self)
        if not self.tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tipTitle or " ", 1, 1, 1)
        GameTooltip:AddLine(self.tip, 0.85, 0.82, 0.75, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
end

-- Rebuilds the visible rows and the counter from f.items / f.sel.
RenderRows = function(f)
    local content = f.content
    content.rows = content.rows or {}
    for _, r in ipairs(content.rows) do r:Hide() end
    local y = -2
    for i, item in ipairs(f.items) do
        local row = content.rows[i] or CreateRow(f)
        content.rows[i] = row
        row.itemId = item.id
        row.tip = item.tooltip
        row.tipTitle = item.name
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)
        local on = IsSelected(f, item.id)
        row.label:SetText((on and "|cff66d966[x]|r  " or "|cff888888[ ]|r  ") .. item.name)
        row.hl:SetShown(on)
        row:Show()
        y = y - ROW_H
    end
    content:SetHeight(math.max(10, -y + 2))
    f.counter:SetText("Selected " .. #f.sel .. " / " .. f.max)
end

local function Build()
    local f = UI.CreateWindow("ParchmentDialog", {
        title = "Choose", width = 300, height = 400,
        minW = 240, minH = 240, maxW = 420, maxH = 760, dbKey = "dialogWindow",
    })
    f:SetFrameStrata("FULLSCREEN_DIALOG")  -- above other Parchment windows

    f.prompt = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.prompt:SetPoint("TOPLEFT", 16, -44)
    f.prompt:SetPoint("RIGHT", f, "RIGHT", -110, 0)
    f.prompt:SetJustifyH("LEFT")
    f.prompt:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    f.counter = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.counter:SetPoint("TOPRIGHT", -16, -44)
    f.counter:SetTextColor(UI.HEAD[1], UI.HEAD[2], UI.HEAD[3])

    local scroll = CreateFrame("ScrollFrame", "ParchmentDialogScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -66)
    scroll:SetPoint("BOTTOMRIGHT", -32, 46)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    content.rows = {}
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
    f.content = content

    local confirm = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    confirm:SetSize(90, 22)
    confirm:SetText("Confirm")
    confirm:SetPoint("BOTTOMRIGHT", -16, 14)
    confirm:SetScript("OnClick", function()
        local cb, sel = f.onConfirm, f.sel
        f:Hide()
        if cb then cb(sel) end
    end)

    local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancel:SetSize(80, 22)
    cancel:SetText("Cancel")
    cancel:SetPoint("BOTTOMLEFT", 16, 14)
    cancel:SetScript("OnClick", function() f:Hide() end)

    return f
end

-- Opens the checklist picker.
--
-- opts: title, prompt, items (list of {id, name}), max (default 1),
--   selected (list of pre-selected ids), onConfirm(selectedIds).
function Dialogs.Pick(opts)
    frame = frame or Build()
    local f = frame
    f.titleFS:SetText(opts.title or "Choose")
    f.prompt:SetText(opts.prompt or "")
    f.items = opts.items or {}
    f.max = opts.max or 1
    f.onConfirm = opts.onConfirm
    -- Seed the pre-selected ids, but never past the cap: an over-cap character
    -- (imports allow one - CE.Warnings only warns) must not open at "3 / 2" and
    -- confirm all three, which would round-trip the over-cap state through the
    -- very dialog whose job is to enforce the cap.
    f.sel = {}
    for _, id in ipairs(opts.selected or {}) do
        if #f.sel >= f.max then break end
        f.sel[#f.sel + 1] = id
    end
    RenderRows(f)
    f:Show()
    f:Raise()
end

-- DM-clash prompts. Both default to the non-destructive choice (keep the current
-- DM / cancel) so Escape or a dismissed popup never leaves a client DM-less or
-- mid-fight: switching or taking over is always an explicit click.

-- Shown on a client when a DIFFERENT player claims DM while one is already
-- recognized: switch to the claimant, or keep the current DM (the default).
StaticPopupDialogs["PARCHMENT_DM_SWITCH"] = {
    text = "%s is claiming DM, but you recognize %s.\n\nSwitch to them?",
    button1 = "Switch",
    button2 = "Keep",
    OnAccept = function(_, data)
        if data and data.claimant then ns.Comm.SetRecognizedDM(data.claimant) end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Shown to a player who runs /pmt dm while already recognizing someone else:
-- confirm the take-over before claiming, so a stray command cannot silently
-- fight an existing DM. onAccept performs the claim.
StaticPopupDialogs["PARCHMENT_DM_TAKEOVER"] = {
    text = "%s is already DM.\n\nTake over the role?",
    button1 = "Take over",
    button2 = CANCEL,
    OnAccept = function(_, data)
        if data and data.onAccept then data.onAccept() end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Offers to switch this client's recognized DM from `current` to `claimant`.
function Dialogs.ConfirmDMSwitch(current, claimant)
    StaticPopup_Show("PARCHMENT_DM_SWITCH", claimant or "Someone", current or "your DM",
        { claimant = claimant })
end

-- Confirms taking the DM role over from `current`; onAccept runs on confirm.
function Dialogs.ConfirmDMTakeover(current, onAccept)
    StaticPopup_Show("PARCHMENT_DM_TAKEOVER", current or "Someone", nil, { onAccept = onAccept })
end
