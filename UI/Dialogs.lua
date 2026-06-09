-- Parchment - Dialogs
--
-- Reusable modal-style dialogs. Currently a single checklist picker used to
-- collect perk-driven choices (skills, weapons, damage types) and reusable by
-- the editor/wizard. One pooled frame is reused across calls.
--
-- Reads from: ns.UI (shared window + palette).
-- Exposes on ns.Dialogs: .Pick{ title, prompt, items, max, selected, onConfirm }

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
    f.sel = {}
    for _, id in ipairs(opts.selected or {}) do f.sel[#f.sel + 1] = id end
    RenderRows(f)
    f:Show()
    f:Raise()
end
