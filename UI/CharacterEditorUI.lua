-- Parchment - Character Editor (UI)
--
-- A scrolling form that edits the active character live: identity, attributes
-- (with point-buy budget), traits, primary/AC/init attributes, accomplished
-- skills/weapons/saves, a guided Level Up, and notes. A warnings area shows soft
-- validation. New / Characters / Delete / Close manage the roster. Selection
-- inputs reuse ns.Dialogs.Pick; numeric inputs use ns.Widgets.Stepper.
--
-- Edits mutate the live character (and refresh the sheet/perk viewer); there is
-- no per-field undo, but import/export provides backup.
--
-- Reads from: ns.CharacterEditor, ns.CharacterSheet.Compute, ns.GetSystem,
--   ns.GetItemLibrary, ns.GetActiveCharacter, ns.GetCharacters, ns.Dialogs,
--   ns.Widgets, ns.UI.
-- Exposes on ns.CharacterEditorUI: Open, Toggle, RefreshIfShown (the rest of
--   the table is the panel's own button handlers).
-- Registers the "edit" module opener with Core.

local ADDON, ns = ...

local UI = ns.UI
local CE = ns.CharacterEditor
local Form = ns.CharacterForm
local PAD, ROW_H, CTRL_X = 14, 26, 120

-- Confirm dialog for deleting a character (destructive).
StaticPopupDialogs["PARCHMENT_DELETE_CHAR"] = {
    text = "Delete character \"%s\"?\n\nThis cannot be undone once you save to disk.",
    button1 = DELETE or "Delete",
    button2 = CANCEL,
    OnAccept = function(_, key)
        ns.CharacterEditor.Delete(key)
        -- Refresh every window that shows the character (RefreshAll covers the
        -- perk tree, whose self.char would otherwise point at the deleted table)
        -- and push vitals, mirroring the hub roster's delete path.
        if ns.Systems then ns.Systems.RefreshAll() end
        if ns.Party then ns.Party.OnVitalsChanged() end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local EditorUI = {}
ns.CharacterEditorUI = EditorUI

local Refresh

local Signed = ns.UI.Signed

-- Returns the character's hit die size and final VIT modifier.
-- The hit die size and the modifier of the system's HP attribute (if any).
local function HitDieAndHpMod(char)
    local sheet = ns.CharacterSheet.Compute(char, ns.GetSystem(), ns.GetItemLibrary())
    local die = ns.CharacterEditor.HitDieSize(sheet.derived.hit_dice)
    local hpAttr = ns.DerivedConfig().hp_attribute
    local hpMod = 0
    if hpAttr then
        for _, a in ipairs(sheet.attributes) do if a.id == hpAttr then hpMod = a.modifier end end
    end
    return die, hpMod
end

-- Average HP contributed per level: the HP attribute's modifier + the hit die's
-- average ((die + 1) / 2). Differences between two of these are whole numbers
-- (each die-band step and each +1 modifier is +1).
local function PerLevelHp(char)
    local die, hpMod = HitDieAndHpMod(char)
    return hpMod + (die + 1) / 2
end

-- Recomputes and redraws the editor plus the sheet / perk viewer if open.
-- Also pushes a (throttled) vitals update to the group - edits here can
-- change HP/Mana/level, which the party overview displays.
local function Changed(self)
    Refresh(self)
    if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
    if ns.PerkTreeUI and ns.PerkTreeUI.frame and ns.PerkTreeUI.frame:IsShown() then
        ns.PerkTreeUI.Open()
    end
    if ns.Party then ns.Party.OnVitalsChanged() end
end

-- The shared form (labels, pickers, value fill) lives in ns.CharacterForm; the
-- editor binds the builders to its own control column (CTRL_X) below.
local Label = Form.Label

local function Header(content, text, y)
    local fs = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", PAD, y)
    fs:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
    fs:SetText(text)
    local line = content:CreateTexture(nil, "BACKGROUND")
    line:SetColorTexture(UI.LINE[1], UI.LINE[2], UI.LINE[3], UI.LINE[4])
    line:SetPoint("TOPLEFT", PAD, y - 16)
    line:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    line:SetHeight(1)
end

local function FieldButton(content, y, width) return Form.FieldButton(content, CTRL_X, y, width) end
local function TextBox(content, y, width) return Form.TextBox(content, CTRL_X, y, width) end

-- A bordered multi-line text area (for notes) that wraps within its width.
-- Spans from PAD to the content's right edge so it grows with the window.
local function NotesBox(content, y, height)
    local box = CreateFrame("Frame", nil, content, "BackdropTemplate")
    box:SetPoint("TOPLEFT", PAD, y)
    box:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    box:SetHeight(height)
    box:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    box:SetBackdropColor(0, 0, 0, 0.4)
    box:SetBackdropBorderColor(0.45, 0.38, 0.24, 1)
    local e = CreateFrame("EditBox", nil, box)
    e:SetMultiLine(true)
    e:SetAutoFocus(false)
    e:SetFontObject(ChatFontNormal)
    e:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
    e:SetPoint("TOPLEFT", 8, -7)
    e:SetPoint("BOTTOMRIGHT", -8, 7)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    return e
end

-- Builds the editor once. Lays out persistent widgets; Refresh fills values.
local function BuildFrame()
    local system = ns.GetSystem()
    local f = UI.CreateWindow("ParchmentEditFrame", {
        title = "Character Editor", width = 440, height = 600,
        minW = 400, minH = 400, maxW = 600, maxH = 1000, dbKey = "editWindow",
    })

    local scroll = CreateFrame("ScrollFrame", "ParchmentEditScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", PAD, -44)
    scroll:SetPoint("BOTTOMRIGHT", -32, 44)
    local c = CreateFrame("Frame", nil, scroll)
    c:SetSize(380, 10)
    scroll:SetScrollChild(c)
    scroll:SetScript("OnSizeChanged", function(_, w) c:SetWidth(w) end)
    f.content = c

    local y = -PAD
    local function adv() y = y - ROW_H end

    -- Identity.
    Label(c, "Name", PAD, y); f.nameBox = TextBox(c, y, 220); adv()
    Label(c, "Player", PAD, y); f.playerBox = TextBox(c, y, 220); adv()
    Label(c, "Race", PAD, y); f.raceBtn = FieldButton(c, y); adv()
    Label(c, "Quote", PAD, y); f.quoteBox = TextBox(c, y, 250); adv()

    -- Level + level-up.
    Label(c, "Level", PAD, y)
    f.levelText = c:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.levelText:SetPoint("TOPLEFT", CTRL_X, y)
    f.levelText:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
    f.levelUpBtn = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    f.levelUpBtn:SetSize(76, 20); f.levelUpBtn:SetText("Level Up"); f.levelUpBtn:SetPoint("TOPLEFT", CTRL_X + 34, y + 1)
    f.levelDownBtn = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    f.levelDownBtn:SetSize(86, 20); f.levelDownBtn:SetText("Level Down")
    f.levelDownBtn:SetPoint("TOPLEFT", CTRL_X + 114, y + 1)
    adv()

    -- Resources: editable max HP / Mana, and an ad-hoc HP gain roll.
    y = y - 8; Header(c, "RESOURCES", y); y = y - 24
    Label(c, "Max HP", PAD, y); f.maxHpBox = TextBox(c, y, 60); f.maxHpBox:SetNumeric(true); adv()
    Label(c, "Max Mana", PAD, y); f.maxManaBox = TextBox(c, y, 60); f.maxManaBox:SetNumeric(true); adv()
    Label(c, "Gain HP", PAD, y)
    f.hpBox = TextBox(c, y, 44); f.hpBox:SetNumeric(true)
    f.rollBtn = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    f.rollBtn:SetSize(48, 20); f.rollBtn:SetText("Roll"); f.rollBtn:SetPoint("TOPLEFT", CTRL_X + 56, y + 1)
    f.addHpBtn = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    f.addHpBtn:SetSize(48, 20); f.addHpBtn:SetText("Add"); f.addHpBtn:SetPoint("TOPLEFT", CTRL_X + 108, y + 1)
    adv()
    f.hpBreakdown = c:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.hpBreakdown:SetPoint("TOPLEFT", CTRL_X, y + 2)
    f.hpBreakdown:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    adv()

    -- Attributes. May be empty on first run (no system imported yet); the
    -- NoSystem overlay covers the form and GetFrame rebuilds on system change.
    y = y - 10; Header(c, "ATTRIBUTES", y); y = y - 24
    y = Form.BuildAttributeRows(f, c, system, PAD, CTRL_X, y, ROW_H)
    f.pointsText = c:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.pointsText:SetPoint("TOPLEFT", PAD, y); adv()

    -- Traits and key attributes.
    y = y - 6; Header(c, "TRAITS", y); y = y - 24
    Label(c, "Racial", PAD, y); f.racialBtn = FieldButton(c, y); adv()
    Label(c, "Origins", PAD, y); f.originBtn = FieldButton(c, y); adv()
    Label(c, "Primary", PAD, y); f.primaryBtn = FieldButton(c, y, 120); adv()
    Label(c, "AC attr", PAD, y); f.acBtn = FieldButton(c, y, 120); adv()
    Label(c, "Init attr", PAD, y); f.initBtn = FieldButton(c, y, 120); adv()

    -- Accomplished.
    y = y - 6; Header(c, "ACCOMPLISHED", y); y = y - 24
    Label(c, "Skills", PAD, y); f.skillsBtn = FieldButton(c, y, 160); adv()
    Label(c, "Weapons", PAD, y); f.weaponsBtn = FieldButton(c, y, 160); adv()
    Label(c, "Saves", PAD, y); f.savesBtn = FieldButton(c, y, 160); adv()

    -- Notes.
    y = y - 6; Header(c, "NOTES", y); y = y - 22
    local NOTES_H = 72
    f.notesBox = NotesBox(c, y, NOTES_H)
    y = y - NOTES_H - 8

    -- Warnings.
    Header(c, "WARNINGS", y); y = y - 22
    f.warnText = c:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.warnText:SetPoint("TOPLEFT", PAD, y); f.warnText:SetWidth(330); f.warnText:SetJustifyH("LEFT")
    f.warnText:SetTextColor(UI.RED[1], UI.RED[2], UI.RED[3])
    c:SetHeight(-y + 120)

    -- Bottom button bar (outside the scroll).
    local function bar(text, w, x, onClick)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(w, 22); b:SetText(text); b:SetPoint("BOTTOMLEFT", x, 12)
        b:SetScript("OnClick", onClick)
        return b
    end
    bar("Characters", 84, PAD, function() EditorUI.PickCharacter(f) end)
    bar("New", 50, PAD + 88, function() EditorUI.NewCharacter(f) end)
    bar("Delete", 60, PAD + 142, function() EditorUI.DeleteCharacter(f) end)

    local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveBtn:SetSize(96, 22); saveBtn:SetText("Save to Disk"); saveBtn:SetPoint("BOTTOMRIGHT", -PAD, 12)
    saveBtn:SetScript("OnClick", ns.SaveToDisk)
    saveBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Reloads the UI to write all Parchment changes to disk.", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    saveBtn:SetScript("OnLeave", GameTooltip_Hide)

    -- Wire the text fields (read live f.char at event time). These are cosmetic:
    -- none changes a derived stat, so they never trigger a recompute cascade. The
    -- sheet refresh (name -> title, quote -> subtitle, notes -> body) is debounced
    -- so it runs once after typing settles, not per keystroke; `player` is not
    -- shown on the sheet at all, so it refreshes nothing.
    local refreshSheet = ns.UI.Debounce(0.2, function()
        if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
    end)
    local function textCommit(box, field, affectsSheet)
        box:SetScript("OnTextChanged", function(self, user)
            if not (user and f.char) then return end
            f.char[field] = self:GetText()
            if affectsSheet then refreshSheet() end
        end)
    end
    textCommit(f.nameBox, "name", true); textCommit(f.playerBox, "player", false)
    textCommit(f.quoteBox, "quote", true); textCommit(f.notesBox, "notes", true)

    for id, st in pairs(f.steppers) do
        st:OnStep(function(delta)
            if not f.char then return end
            -- System config is read at event time (not captured at build) so a
            -- reimported system's modifier table / derived config is honored.
            -- Base attributes may exceed the creation cap of 10 post-creation
            -- (level milestone points and traits push toward the 11/12 perk
            -- requirements), so the stepper allows the modifier table's range.
            -- Only fall back to a default cap when the system has NO modifier
            -- table; a short one is its real range (a system with an 8-entry
            -- table caps at 8, which CE.Warnings also enforces).
            local maxAttr = #(ns.GetSystem().modifier_table or {})
            if maxAttr == 0 then maxAttr = 20 end
            local cfg = ns.DerivedConfig()
            local hpAttr = cfg.hp_attribute
            f.char.attributes = f.char.attributes or {}
            local newVal = math.max(1, math.min(maxAttr, (f.char.attributes[id] or 1) + delta))
            -- Systems that opt into retroactive HP (derived_stats.retroactive_hp)
            -- re-grant HP when the HP attribute changes: each previous level gains
            -- the change in per-level HP (HP-modifier delta + hit-die average
            -- delta). The current/new level is rolled separately via Gain HP.
            if cfg.retroactive_hp and hpAttr and id == hpAttr then
                local level = f.char.level or 1
                local before = PerLevelHp(f.char)
                f.char.attributes[id] = newVal
                local after = PerLevelHp(f.char)
                -- Round: per-level HP deltas are whole, but keep HP integral
                -- regardless of how a system defines its hit die / modifiers.
                local retro = math.floor((after - before) * (level - 1) + 0.5)
                if retro ~= 0 then
                    f.char.max_hp = (f.char.max_hp or 0) + retro
                    f.char.current_hp = (f.char.current_hp or 0) + retro
                    f.note = string.format("%s change: %+d HP retroactively (%d level%s).",
                        ns.AttrName(id), retro, level - 1, (level - 1) == 1 and "" or "s")
                end
            else
                f.char.attributes[id] = newVal
            end
            Changed(f)
        end)
    end

    -- Field pickers (race, traits, key attributes, proficiencies): the shared
    -- form wires them, reading f.char live and refreshing via Changed afterward.
    Form.WirePickers(f, function() return f.char end, function() Changed(f) end)

    -- Hover tooltips on the accomplished count buttons explaining the target.
    local function countTip(btn, build)
        btn:SetScript("OnEnter", function(self)
            if not f.char then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local sheet = ns.CharacterSheet.Compute(f.char, ns.GetSystem(), ns.GetItemLibrary())
            build(GameTooltip, sheet)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", GameTooltip_Hide)
    end
    countTip(f.skillsBtn, function(tt, sheet)
        local tg = CE.AccomplishTargets(sheet)
        tt:AddLine("Accomplished Skills", UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
        tt:AddLine("Skills you start accomplished in.  Target: " .. tg.skills, 0.9, 0.9, 0.9, true)
        tt:AddLine(CE.AccomplishTargetDesc("skills"), 0.56, 0.78, 1)
        tt:AddLine("Chosen: " .. #(f.char.accomplished_skills or {}), 0.78, 0.66, 0.41)
    end)
    countTip(f.weaponsBtn, function(tt, sheet)
        local tg = CE.AccomplishTargets(sheet)
        tt:AddLine("Accomplished Weapons", UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
        tt:AddLine("Weapons you start accomplished in.  Target: " .. tg.weapons, 0.9, 0.9, 0.9, true)
        tt:AddLine(CE.AccomplishTargetDesc("weapons"), 0.56, 0.78, 1)
        tt:AddLine("Chosen: " .. #(f.char.accomplished_weapons or {}), 0.78, 0.66, 0.41)
    end)
    countTip(f.savesBtn, function(tt, sheet)
        local tg = CE.AccomplishTargets(sheet)
        tt:AddLine("Accomplished Saves", UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
        tt:AddLine("Primary attribute's save (automatic) plus your choices.  Target: " .. tg.saves, 0.9, 0.9, 0.9, true)
        tt:AddLine("Primary: " .. ns.AttrName(f.char.primary_attribute), 0.78, 0.66, 0.41)
    end)

    -- Resource editing.
    f.rollBtn:SetScript("OnClick", function() EditorUI.RollHP(f) end)
    f.rollBtn:SetScript("OnEnter", function(self)
        if not f.char then return end
        local die, hpMod = HitDieAndHpMod(f.char)
        local hpAttr = ns.DerivedConfig().hp_attribute
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Roll Hit Points", 1, 1, 1)
        if hpAttr then
            GameTooltip:AddLine("Rolls 1d" .. die .. " + " .. ns.AttrName(hpAttr)
                .. " modifier (" .. Signed(hpMod) .. "), minimum 1.", 0.85, 0.82, 0.75, true)
        else
            GameTooltip:AddLine("Rolls 1d" .. die .. ", minimum 1.", 0.85, 0.82, 0.75, true)
        end
        GameTooltip:Show()
    end)
    f.rollBtn:SetScript("OnLeave", GameTooltip_Hide)
    f.addHpBtn:SetScript("OnClick", function() EditorUI.AddHP(f) end)
    f.levelUpBtn:SetScript("OnClick", function() EditorUI.DoLevelUp(f) end)
    f.levelDownBtn:SetScript("OnClick", function() EditorUI.DoLevelDown(f) end)
    local function maxCommit(box, field)
        box:SetScript("OnEnterPressed", function(self)
            if f.char then
                local n = tonumber(self:GetText())
                if n then f.char[field] = math.max(0, math.min(99999, math.floor(n))) end
            end
            self:ClearFocus(); Changed(f)
        end)
    end
    maxCommit(f.maxHpBox, "max_hp"); maxCommit(f.maxManaBox, "max_mana")

    return f
end

-- Rolls a hit die + the HP attribute's modifier (minimum 1) into the HP-gain box
-- and shows the breakdown beneath it. The minimum avoids a negative, which a
-- numeric edit box cannot display.
function EditorUI.RollHP(self)
    if not self.char then return end
    local die, hpMod = HitDieAndHpMod(self.char)
    local roll = math.random(1, die)
    local raw = roll + hpMod
    local total = math.max(1, raw)
    self.hpBox:SetText(tostring(total))
    local text = (hpMod ~= 0)
        and string.format("d%d: %d %s %d = %d", die, roll, hpMod >= 0 and "+" or "-", math.abs(hpMod), raw)
        or string.format("d%d: %d", die, roll)
    if total ~= raw then text = text .. "  (min " .. total .. ")" end
    self.hpBreakdown:SetText(text)
end

-- Adds the Gain HP value to both maximum and current HP (an ad-hoc gain that is
-- not a level-up).
function EditorUI.AddHP(self)
    if not self.char then return end
    -- Floor and ignore non-numeric input, and clamp the resulting totals to the
    -- same [0, 99999] range the max HP/mana boxes enforce, so a stray "1e300" or
    -- a large negative cannot push an absurd value into the character.
    local hp = tonumber(self.hpBox:GetText())
    if not hp then return end
    hp = math.floor(hp)
    if hp == 0 then return end
    self.char.max_hp = math.max(0, math.min(99999, (self.char.max_hp or 0) + hp))
    self.char.current_hp = math.max(0, math.min(99999, (self.char.current_hp or 0) + hp))
    self.hpBox:SetText("")
    self.hpBreakdown:SetText("")
    self.note = string.format("%+d HP (max %d)", hp, self.char.max_hp)
    Changed(self)
end

-- Raises the level only. HP is added separately via the Gain HP roll/Add, so
-- the player controls the hit-point gain rather than it being auto-applied.
function EditorUI.DoLevelUp(self)
    if not self.char then return end
    local ok, notes = CE.LevelUp(self.char, 0, ns.GetSystem())
    if ok then
        self.note = "Level " .. self.char.level .. ": " .. table.concat(notes, ", ")
            .. ".  Use Gain HP to add hit points."
    else
        self.note = notes[1]
    end
    Changed(self)
end

-- Lowers the level by one (undo an accidental level-up). HP is unchanged.
function EditorUI.DoLevelDown(self)
    if not self.char then return end
    local ok, note = CE.LevelDown(self.char, ns.GetSystem())
    self.note = ok and ("Level down: " .. note .. ".  Adjust HP manually if needed.") or note
    Changed(self)
end

function EditorUI.NewCharacter(self)
    local char = CE.NewBlank()
    CE.SaveNew(ns.NextCharacterKey(), char)
    Changed(self)
end

function EditorUI.DeleteCharacter(self)
    local char, key = ns.GetActiveCharacter()
    if key then StaticPopup_Show("PARCHMENT_DELETE_CHAR", char.name or key, nil, key) end
end

-- Commits any uncommitted resource-box edits to the current character. The max
-- HP/Mana boxes only commit on Enter, so without this a character switch would
-- silently discard a typed-but-not-entered value.
local function CommitPending(self)
    if not self.char then return end
    local function commit(box, field)
        if not box then return end
        local n = tonumber(box:GetText())
        if n then self.char[field] = math.max(0, math.min(99999, math.floor(n))) end
    end
    commit(self.maxHpBox, "max_hp")
    commit(self.maxManaBox, "max_mana")
end

function EditorUI.PickCharacter(self)
    local items = {}
    for key, ch in pairs(ns.GetCharacters()) do items[#items + 1] = { id = key, name = ch.name or key } end
    ns.Dialogs.Pick({ title = "Characters", prompt = "Switch active character", items = items, max = 1,
        selected = { select(2, ns.GetActiveCharacter()) },
        onConfirm = function(ids)
            CommitPending(self)
            if ids[1] then ns.SetActiveCharacter(ids[1]) end
            Changed(self)
        end })
end

-- Fills every widget from the active character.
Refresh = function(self)
    if not ns.HasSystem() then
        self.char = nil
        self.titleFS:SetText("Character Editor")
        ns.UI.NoSystem(self)
        return
    end
    local char, key = ns.GetActiveCharacter()
    self.char = char
    local system = ns.GetSystem()
    if not char then
        self.titleFS:SetText("Character Editor")
        ns.UI.Empty(self, "No character yet.\n\nCreate one to start editing, or import an existing one.",
            "Create a character", function() ns.OpenModule("new") end,
            "Import a character", function() ns.OpenModule("import") end)
        return
    end
    ns.UI.HideEmpty(self)
    self.titleFS:SetText("Editing: " .. (char.name or key or "?"))

    local sheet = ns.CharacterSheet.Compute(char, system, ns.GetItemLibrary())
    Form.FillCommon(self, char, system, sheet, true)

    -- Editor-only fields (the wizard has none of these).
    local function setBox(box, v) if not box:HasFocus() then box:SetText(v or "") end end
    setBox(self.notesBox, char.notes)
    self.hpBreakdown:SetText("")
    setBox(self.maxHpBox, tostring(char.max_hp or 0))
    setBox(self.maxManaBox, tostring(char.max_mana or 0))
    self.levelText:SetText(tostring(char.level or 1))

    local warns = CE.Warnings(char, system)
    if self.note then table.insert(warns, 1, "|cff66d966" .. self.note .. "|r"); self.note = nil end
    self.warnText:SetText(#warns > 0 and table.concat(warns, "\n") or "|cff66d966No warnings.|r")
end

-- Returns the singleton frame, rebuilt by the shared helper when the system's
-- attribute set changes (its rows are laid out from the system at build time).
local function GetFrame()
    return ns.UI.RebuildableFrame(EditorUI, BuildFrame, Form.AttrSignature)
end

function EditorUI.Open()
    local f = GetFrame()
    Refresh(f)
    f:Show()
end

function EditorUI.Toggle()
    local f = GetFrame()
    if f:IsShown() then f:Hide() else EditorUI.Open() end
end

-- Refreshes (and if needed rebuilds) the editor when it is open, e.g. after an
-- import or a system switch.
function EditorUI.RefreshIfShown()
    if EditorUI.frame and EditorUI.frame:IsShown() then EditorUI.Open() end
end

ns.RegisterModule("edit", EditorUI.Toggle)
