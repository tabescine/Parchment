-- Parchment - Import / Export (UI)
--
-- The import/export modal: a large multi-line text box plus buttons to export
-- the active character or the system (a toggle picks JSON or TOML) and to
-- import pasted JSON, TOML, or Lua.
-- Import results (success or the reason for failure) show in a status line; a
-- successful import refreshes the character sheet if it is open.
--
-- Reads from: ns.ImportExport, ns.UI, ns.CharacterSheetUI.
-- Exposes on ns.ImportExportUI: Open, Toggle.
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
    self.status:SetText(msg or "")
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
    ShowText(self, IE.ExportSystem(self.format))
    SetStatus(self, "Exported system as " .. self.format:upper() .. ". Press Ctrl+C to copy.", false)
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

-- Builds the window once.
local function BuildFrame()
    local f = UI.CreateWindow("ParchmentIEFrame", {
        title = "Import / Export", width = 480, height = 470,
        minW = 360, minH = 320, maxW = 760, maxH = 900, dbKey = "ieWindow",
    })
    f.format = "json"

    -- Instructions under the title.
    local instr = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    instr:SetPoint("TOPLEFT", 16, -42)
    instr:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    instr:SetJustifyH("LEFT")
    instr:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    instr:SetText("Export copies data out in the chosen format. Import auto-detects "
        .. "JSON, TOML or a Lua table. Click the box, then Ctrl+A/Ctrl+C to copy or Ctrl+V to paste. "
        .. "Large pastes are captured instantly - use Clear before pasting over an export.")

    -- Bordered text area containing a scrolling multi-line edit box.
    local box = CreateFrame("Frame", nil, f, "BackdropTemplate")
    box:SetPoint("TOPLEFT", 14, -64)
    box:SetPoint("BOTTOMRIGHT", -14, 92)
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

    -- Status line.
    f.status = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.status:SetPoint("BOTTOMLEFT", 16, 68)
    f.status:SetPoint("BOTTOMRIGHT", -16, 68)
    f.status:SetJustifyH("LEFT")
    f.status:SetWordWrap(false)

    -- Top button row: export actions and the format toggle.
    local expChar = MakeButton(f, "Export Char", 88, function() DoExportCharacter(f) end)
    expChar:SetPoint("BOTTOMLEFT", 16, 40)
    local expSys = MakeButton(f, "Export System", 96, function() DoExportSystem(f) end)
    expSys:SetPoint("BOTTOMLEFT", 108, 40)
    f.formatBtn = MakeButton(f, "Format: JSON", 110, function() ToggleFormat(f) end)
    f.formatBtn:SetPoint("BOTTOMLEFT", 208, 40)

    -- Bottom button row: import and clear.
    local importBtn = MakeButton(f, "Import", 64, function() DoImport(f) end)
    importBtn:SetPoint("BOTTOMLEFT", 16, 12)
    local clearBtn = MakeButton(f, "Clear", 56, function()
        f.pasteData = nil
        f.editBox:SetText("")
        f.editBox:SetMaxBytes(PASTE_CAP)
        SetStatus(f, "", false)
    end)
    clearBtn:SetPoint("BOTTOMLEFT", 84, 12)

    return f
end

-- Returns the singleton frame, building it on first use.
local function GetFrame()
    if not ImportExportUI.frame then ImportExportUI.frame = BuildFrame() end
    return ImportExportUI.frame
end

function ImportExportUI.Open()
    local f = GetFrame()
    SetStatus(f, "", false)
    f:Show()
end

function ImportExportUI.Toggle()
    local f = GetFrame()
    if f:IsShown() then f:Hide() else ImportExportUI.Open() end
end

ns.RegisterModule("import", ImportExportUI.Toggle)
