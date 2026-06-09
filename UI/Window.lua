-- Parchment - Window
--
-- Shared window chrome used by the addon's panels. CreateWindow returns a
-- styled frame that is draggable, resizable (with a corner grip), closeable by
-- button or Escape, and remembers its size and position across sessions. The
-- caller fills the body; this file owns only the frame, its title, and the
-- behaviours common to every Parchment window.
--
-- Reads from: ns.Addon.db (for geometry persistence, keyed by opts.dbKey).
-- Exposes on ns.UI: .CreateWindow, and the shared palette constants.

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

    -- Close button + Escape support.
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    tinsert(UISpecialFrames, globalName)

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
