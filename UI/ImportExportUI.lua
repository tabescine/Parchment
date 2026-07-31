-- Parchment - Import / Export (UI)
--
-- The Import / Export panel of the hub window: a large multi-line text box
-- plus buttons to export the active character, the system or the item library
-- (a toggle picks JSON or TOML) and to import pasted JSON, TOML, or Lua - one
-- Import button for all three, since the paste is auto-detected.
-- Import results (success or the reason for failure) show in a status line; a
-- successful import refreshes every data-driven window. The status line is
-- deliberately NOT cleared on show - an import's outcome survives hub
-- refreshes triggered by the import itself.
--
-- Reads from: ns.ImportExport, ns.UI, ns.HubUI, ns.Systems, ns.CharacterSheetUI.
-- Exposes on ns.ImportExportUI: Open, Toggle (thin wrappers over the hub's
--   import panel).
-- Registers the "import" module opener with Core.

local ADDON, ns = ...

local UI = ns.UI
local IE = ns.ImportExport

-- Paste capture. A paste fires OnChar once per character, and a multi-line
-- edit box re-flows its whole text on every insertion - pasting a 100KB system
-- froze the client for seconds. The box is therefore byte-capped (cheap to lay
-- out) while OnChar still sees every pasted character: the full string is
-- accumulated per frame and kept aside for Import, and the box only shows a
-- short notice. Export lifts the cap to display the full copyable text;
-- Clear restores it.
local PASTE_CAP = 2500   -- bytes the edit box itself may hold in paste mode
local PASTE_BURST = 32   -- chars arriving in one frame that count as a paste

local ImportExportUI = {}
ns.ImportExportUI = ImportExportUI

-- Creates a panel button.
local function MakeButton(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-- Sets the status line text and colour (red on error, green on success).
local function SetStatus(self, msg, isError)
    local c = isError and UI.RED or UI.GREEN
    self.status:SetTextColor(c[1], c[2], c[3])
    -- Long parse errors (with line:column and a hint) used to run off the edge;
    -- the status now wraps, but cap the length so a giant paste cannot fill it.
    msg = msg or ""
    if #msg > 400 then msg = msg:sub(1, 400) .. " ..." end
    self.status:SetText(msg)
end

-- Puts text in the box and selects it so the user can immediately copy. The
-- byte cap is lifted so the full export is present for Ctrl+C (one SetText is
-- a single re-flow - cheap, unlike a per-character paste).
local function ShowText(self, text)
    self.pasteData = nil
    self.editBox:SetMaxBytes(0)
    self.editBox:SetText(text)
    self.editBox:SetFocus()
    self.editBox:HighlightText()
    self.editBox:SetCursorPosition(0)
end

-- Collects one frame's worth of typed/pasted characters. A burst bigger than
-- PASTE_BURST is a paste: the full string replaces any previous payload, the
-- box shows only a notice + preview, and Import reads the captured string.
local function ProcessPaste(self)
    local buffer = self.pasteBuffer
    local n = #buffer
    self.pasteBuffer, self.pasteScheduled = {}, false
    if n <= PASTE_BURST then return end

    local text = table.concat(buffer)
    self.pasteData = text
    self.editBox:SetText(string.format("--- captured a %d-character paste ---\n%s ...",
        #text, text:sub(1, 180)))
    self.editBox:SetCursorPosition(0)
    self.editBox:ClearFocus()
    SetStatus(self, string.format("Captured %d pasted characters. Click Import.", #text), false)
end

local function DoExportCharacter(self)
    local str, err = IE.ExportCharacter(nil, self.format)
    if not str then return SetStatus(self, err, true) end
    ShowText(self, str)
    SetStatus(self, "Exported active character as " .. self.format:upper() .. ". Press Ctrl+C to copy.", false)
end

local function DoExportSystem(self)
    local str, err = IE.ExportSystem(self.format)
    if not str then return SetStatus(self, err, true) end
    ShowText(self, str)
    SetStatus(self, "Exported system as " .. self.format:upper() .. ". Press Ctrl+C to copy.", false)
end

local function DoExportItems(self)
    local str, err = IE.ExportItems(self.format)
    if not str then return SetStatus(self, err, true) end
    ShowText(self, str)
    SetStatus(self, "Exported the item library as " .. self.format:upper() .. ". Press Ctrl+C to copy.", false)
end

-- Flips the export format between JSON and TOML and relabels the toggle.
local function ToggleFormat(self)
    self.format = (self.format == "json") and "toml" or "json"
    self.formatBtn:SetText("Format: " .. self.format:upper())
end

local function DoImport(self)
    local ok, msg = IE.Import(self.pasteData or self.editBox:GetText())
    SetStatus(self, msg, not ok)
    if not ok then return end
    -- Refresh every data-driven window: a character import must reach the
    -- editor and perk viewer too, not just the sheet.
    if ns.Systems and ns.Systems.RefreshAll then
        ns.Systems.RefreshAll()
    elseif ns.CharacterSheetUI then
        ns.CharacterSheetUI.RefreshIfShown()
    end
end

-- Builds the panel widgets once into the hub-provided frame.
local function BuildContent(f)
    f.format = "json"

    -- Instructions at the top of the panel.
    local instr = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    instr:SetPoint("TOPLEFT", 2, -2)
    instr:SetPoint("RIGHT", f, "RIGHT", -2, 0)
    instr:SetJustifyH("LEFT")
    instr:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    instr:SetText("Export copies a character, the system or your item library out in the chosen "
        .. "format. Import auto-detects JSON, TOML or a Lua table, and what it holds. "
        .. "Click the box, then Ctrl+A/Ctrl+C to copy or Ctrl+V to paste. "
        .. "Large pastes are captured instantly - use Clear before pasting over an export.")

    -- Bordered text area containing a scrolling multi-line edit box.
    local box = CreateFrame("Frame", nil, f, "BackdropTemplate")
    box:SetPoint("TOPLEFT", 0, -62)
    box:SetPoint("BOTTOMRIGHT", 0, 88)
    box:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    box:SetBackdropColor(0, 0, 0, 0.5)
    box:SetBackdropBorderColor(0.45, 0.38, 0.24, 1)

    local scroll = CreateFrame("ScrollFrame", "ParchmentIEScroll", box, "InputScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -8, 8)
    local editBox = scroll.EditBox
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetMaxLetters(0)
    editBox:SetMaxBytes(PASTE_CAP)
    editBox:SetAutoFocus(false)
    editBox:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
    editBox:SetScript("OnEscapePressed", editBox.ClearFocus)
    if scroll.CharCount then scroll.CharCount:Hide() end
    f.editBox = editBox

    -- Paste capture (see top of file). HookScript: the template's own
    -- OnTextChanged handler drives the scroll bar and must keep running.
    f.pasteBuffer, f.pasteScheduled = {}, false
    editBox:HookScript("OnChar", function(_, c)
        f.pasteBuffer[#f.pasteBuffer + 1] = c
        if not f.pasteScheduled then
            f.pasteScheduled = true
            C_Timer.After(0, function() ProcessPaste(f) end)
        end
    end)
    editBox:HookScript("OnTextChanged", function(_, userInput)
        -- A manual edit invalidates a captured paste (the notice text would
        -- no longer match it). The capture itself sets text programmatically,
        -- so it is unaffected; during a paste this clears nothing of value
        -- because pasteData is only set on the next frame.
        if userInput then f.pasteData = nil end
    end)
    UI.SetPlaceholder(editBox,
        "Paste a system, character or item library here (JSON, TOML, or Lua - comments are "
        .. "fine), or use the Export buttons below.", "TOPLEFT")

    -- Status line.
    f.status = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.status:SetPoint("BOTTOMLEFT", 2, 64)
    f.status:SetPoint("BOTTOMRIGHT", -2, 64)
    f.status:SetJustifyH("LEFT")
    f.status:SetWordWrap(true)

    -- Top button row: the three export actions. The format toggle sits on the
    -- bottom row instead: three exports plus a 110px toggle would run past the
    -- panel's right edge once the hub is dragged down to its minimum width.
    local expChar = MakeButton(f, "Export Char", 88, function() DoExportCharacter(f) end)
    expChar:SetPoint("BOTTOMLEFT", 0, 34)
    local expSys = MakeButton(f, "Export System", 96, function() DoExportSystem(f) end)
    expSys:SetPoint("BOTTOMLEFT", 92, 34)
    local expItems = MakeButton(f, "Export Items", 92, function() DoExportItems(f) end)
    expItems:SetPoint("BOTTOMLEFT", 192, 34)

    -- Bottom button row: import, clear and the format toggle.
    local importBtn = MakeButton(f, "Import", 64, function() DoImport(f) end)
    importBtn:SetPoint("BOTTOMLEFT", 0, 6)
    local clearBtn = MakeButton(f, "Clear", 56, function()
        f.pasteData = nil
        f.editBox:SetText("")
        f.editBox:SetMaxBytes(PASTE_CAP)
        SetStatus(f, "", false)
    end)
    clearBtn:SetPoint("BOTTOMLEFT", 68, 6)
    f.formatBtn = MakeButton(f, "Format: JSON", 110, function() ToggleFormat(f) end)
    f.formatBtn:SetPoint("BOTTOMLEFT", 128, 6)
end

-- No Refresh on purpose: nothing in the panel goes stale, and clearing the
-- status on show would wipe an import's own outcome (the import triggers a
-- RefreshAll that re-shows this very panel).
ns.HubUI.RegisterPanel({
    id = "import", label = "Import / Export", order = 50,
    Build = BuildContent,
})

function ImportExportUI.Open()
    ns.HubUI.Open("import")
end

function ImportExportUI.Toggle()
    ns.HubUI.Toggle("import")
end

ns.RegisterModule("import", ImportExportUI.Toggle)
