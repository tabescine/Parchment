-- Parchment - Window
--
-- Shared window chrome used by the addon's panels. CreateWindow returns a
-- styled frame that is draggable, resizable (with a corner grip), closeable by
-- button or Escape, and remembers its size and position across sessions. The
-- caller fills the body; this file owns only the frame, its title, and the
-- behaviours common to every Parchment window.
--
-- Reads from: ns.Addon.db (for geometry persistence, keyed by opts.dbKey).
-- Exposes on ns.UI: .CreateWindow, .Signed, .Debounce, .SetPlaceholder, and the
--   shared palette constants.

local ADDON, ns = ...

-- Shared palette, reused by the panels that render into these windows.
ns.UI = ns.UI or {}
local UI = ns.UI
UI.GOLD = { 0.78, 0.66, 0.41 }
UI.HEAD = { 0.85, 0.72, 0.45 }
UI.TEXT = { 0.92, 0.90, 0.85 }
UI.DIM = { 0.62, 0.60, 0.55 }
UI.GREEN = { 0.55, 0.85, 0.55 }
UI.RED = { 0.90, 0.45, 0.45 }
UI.LINE = { 0.45, 0.38, 0.24, 0.7 }
UI.HILITE = { 0.85, 0.72, 0.45, 0.18 }

-- Formats a number with an explicit sign ("+2", "-1", "+0").
function UI.Signed(n)
    return (n >= 0 and "+" or "") .. n
end

-- Wraps fn in a debouncer: each call cancels any pending run and reschedules it
-- `delay` seconds out, so only the last call in a burst (quiet for `delay`)
-- actually runs fn. Used to collapse per-keystroke and per-resize-pixel work
-- into a single trailing pass. Falls back to running immediately when C_Timer is
-- unavailable (the out-of-client tests). Forwards the final call's arguments.
function UI.Debounce(delay, fn)
    local timer
    return function(...)
        if not (C_Timer and C_Timer.NewTimer) then return fn(...) end
        local args, n = { ... }, select("#", ...)
        if timer then timer:Cancel() end
        timer = C_Timer.NewTimer(delay, function()
            timer = nil
            fn(unpack(args, 1, n))
        end)
    end
end

-- Adds grey placeholder text to an EditBox, shown while it is empty and
-- unfocused. anchor defaults to "LEFT" (single-line boxes); pass "TOPLEFT"
-- for multi-line ones (the hint then wraps to the box width). Uses
-- HookScript so the box's own handlers keep running - call this AFTER all
-- SetScript wiring on the box (SetScript replaces hooked chains).
function UI.SetPlaceholder(editBox, text, anchor)
    -- Multi-line boxes from InputScrollFrameTemplate ship a managed
    -- placeholder (EditBox.Instructions, toggled by the template) - and the
    -- template sizes the box after creation, which collapses a hand-anchored
    -- hint to zero width. Prefer the native one there.
    if editBox.Instructions and editBox.IsMultiLine and editBox:IsMultiLine() then
        editBox.Instructions:SetText(text)
        return editBox.Instructions
    end
    local hint = editBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    if anchor == "TOPLEFT" then
        hint:SetPoint("TOPLEFT", 2, -2)
        hint:SetPoint("RIGHT", -2, 0)
        hint:SetJustifyH("LEFT")
    else
        hint:SetPoint("LEFT", 2, 0)
    end
    hint:SetText(text)
    local function Update()
        hint:SetShown(editBox:GetText() == "" and not editBox:HasFocus())
    end
    editBox:HookScript("OnEditFocusGained", Update)
    editBox:HookScript("OnEditFocusLost", Update)
    editBox:HookScript("OnTextChanged", Update)
    Update()
    return hint
end

local BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
}

-- Saves a frame's size and anchor to its db slot.
local function SaveGeometry(f, dbKey)
    local db = ns.Addon and ns.Addon.db
    if not (db and dbKey) then return end
    db.profile[dbKey] = db.profile[dbKey] or {}
    local g = db.profile[dbKey]
    g.width, g.height = f:GetWidth(), f:GetHeight()
    local point, _, relPoint, x, y = f:GetPoint()
    g.point, g.relPoint, g.x, g.y = point, relPoint, x, y
end

-- Restores a previously saved size and anchor, if any.
local function RestoreGeometry(f, dbKey)
    local db = ns.Addon and ns.Addon.db
    local g = db and dbKey and db.profile[dbKey]
    if not (g and g.width) then return end
    f:SetSize(g.width, g.height)
    if g.point then
        f:ClearAllPoints()
        f:SetPoint(g.point, UIParent, g.relPoint or g.point, g.x or 0, g.y or 0)
    end
end

-- Creates a Parchment window.
--
-- globalName - global frame name (required for Escape-to-close).
-- opts: title, width, height, minW, minH, maxW, maxH, dbKey
--
-- Returns the frame. The frame gains f.titleFS (set via f.titleFS:SetText) and
-- honours an optional f.OnResize() callback fired while the user resizes it.
function UI.CreateWindow(globalName, opts)
    local f = CreateFrame("Frame", globalName, UIParent, "BackdropTemplate")
    f:SetSize(opts.width, opts.height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetResizable(true)
    f:SetResizeBounds(opts.minW or 240, opts.minH or 200, opts.maxW or 900, opts.maxH or 1000)
    f:SetBackdrop(BACKDROP)

    -- Drag to move (saves position on release).
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SaveGeometry(self, opts.dbKey) end)

    -- Close button + Escape support. Registration is idempotent: a window may
    -- be rebuilt under the same global name (e.g. after a system swap) and
    -- must not accumulate duplicate UISpecialFrames entries.
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    local registered = false
    for _, name in ipairs(UISpecialFrames) do
        if name == globalName then registered = true end
    end
    if not registered then tinsert(UISpecialFrames, globalName) end

    -- Title.
    f.titleFS = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    f.titleFS:SetPoint("TOPLEFT", 16, -16)
    f.titleFS:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
    f.titleFS:SetText(opts.title or "Parchment")

    -- Bottom-right resize grip.
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -6, 6)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing(); SaveGeometry(f, opts.dbKey) end)

    -- Re-layout hook while resizing.
    f:SetScript("OnSizeChanged", function(self)
        if self.OnResize then self:OnResize() end
    end)

    RestoreGeometry(f, opts.dbKey)
    f:Hide()
    return f
end

-- Shows a centered empty-state message with up to two action buttons over a
-- window, used when there is no system or no character to render. Created
-- once per frame and reused. Pass buttonText/onClick for the primary action
-- (e.g. create) and button2Text/onClick2 for an alternative (e.g. import).
function UI.Empty(frame, message, buttonText, onClick, button2Text, onClick2)
    local e = frame._emptyState
    if not e then
        -- A full-body panel so it masks any persistent widgets behind it.
        e = CreateFrame("Frame", nil, frame)
        e:SetPoint("TOPLEFT", 8, -44)
        e:SetPoint("BOTTOMRIGHT", -8, 8)
        e:EnableMouse(true)
        local bg = e:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.05, 0.05, 0.06, 0.96)
        e.msg = e:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        e.msg:SetPoint("CENTER", 0, 16)
        e.msg:SetWidth(300)
        e.msg:SetJustifyH("CENTER")
        e.msg:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
        e.btn = CreateFrame("Button", nil, e, "UIPanelButtonTemplate")
        e.btn:SetSize(160, 24)
        e.btn:SetPoint("TOP", e.msg, "BOTTOM", 0, -16)
        e.btn2 = CreateFrame("Button", nil, e, "UIPanelButtonTemplate")
        e.btn2:SetSize(160, 24)
        e.btn2:SetPoint("TOP", e.btn, "BOTTOM", 0, -6)
        frame._emptyState = e
    end
    e.msg:SetText(message or "")
    if buttonText and onClick then
        e.btn:SetText(buttonText)
        e.btn:SetScript("OnClick", onClick)
        e.btn:Show()
    else
        e.btn:Hide()
    end
    if button2Text and onClick2 then
        e.btn2:SetText(button2Text)
        e.btn2:SetScript("OnClick", onClick2)
        e.btn2:Show()
    else
        e.btn2:Hide()
    end
    e:Show()
    e:Raise()
    return e
end

-- Hides a window's empty-state overlay, if any.
function UI.HideEmpty(frame)
    if frame._emptyState then frame._emptyState:Hide() end
end

-- Convenience: the standard "no system loaded" empty state with an Import button.
function UI.NoSystem(frame)
    return UI.Empty(frame, "No system loaded.\n\nImport a ruleset to begin.",
        "Import a system", function() if ns.OpenModule then ns.OpenModule("import") end end)
end
