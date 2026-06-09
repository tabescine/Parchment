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
--   ns.GetActiveCharacter, ns.GetCharacters, ns.Dialogs, ns.Widgets, ns.UI.
-- Registers the "edit" module opener with Core.

local ADDON, ns = ...

local UI = ns.UI
local CE = ns.CharacterEditor
local PAD, ROW_H, CTRL_X = 14, 26, 120

local EditorUI = {}
ns.CharacterEditorUI = EditorUI

local Refresh

-- Signed integer (+3 / -2 / +0).
local function Signed(n) return (n >= 0 and "+" or "") .. n end

-- Recomputes and redraws the editor plus the sheet / perk viewer if open.
local function Changed(self)
    Refresh(self)
    if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
    if ns.PerkTreeUI and ns.PerkTreeUI.frame and ns.PerkTreeUI.frame:IsShown() then
        ns.PerkTreeUI.Open()
    end
end

-- Opens a picker and applies the result, then refreshes.
local function Pick(self, title, prompt, items, max, selected, apply)
    ns.Dialogs.Pick({
        title = title, prompt = prompt, items = items, max = max, selected = selected,
        onConfirm = function(ids) apply(ids); Changed(self) end,
    })
end

-- Item-list builders from the system.
local function AttrItems(system, allow)
    local out = {}
    for _, a in ipairs(system.attributes or {}) do
        if not allow or allow[a.id] then out[#out + 1] = { id = a.id, name = a.name } end
    end
    return out
end
-- Trait records as picker items, with the description as a hover tooltip.
local function TraitItems(list)
    local out = {}
    for _, r in ipairs(list or {}) do
        out[#out + 1] = { id = r.id, name = r.name, tooltip = r.description }
    end
    return out
end
local function AttrName(system, id)
    for _, a in ipairs(system.attributes or {}) do if a.id == id then return a.name end end
    return id or "(none)"
end

-- Racial traits available to a race (allowed_races match, or the all-but-human
-- wildcard for any non-human), each with its description as a tooltip.
local function RacialItems(system, race)
    local out = { { id = "__none", name = "(none)" } }
    for _, t in ipairs(system.racial_traits or {}) do
        local ok = false
        for _, r in ipairs(t.allowed_races or {}) do
            if r == race or (r == "all_but_human" and race ~= "human" and race ~= "") then ok = true end
        end
        if ok then out[#out + 1] = { id = t.id, name = t.name, tooltip = t.description } end
    end
    return out
end

-- Attribute saves as picker items, marking and describing the primary save.
local function SaveItems(system, primary)
    local out = {}
    for _, a in ipairs(system.attributes or {}) do
        out[#out + 1] = {
            id = a.id,
            name = a.name .. (a.id == primary and "  (primary)" or ""),
            tooltip = a.id == primary and "Automatically accomplished as your primary attribute's save." or nil,
        }
    end
    return out
end

local function TraitName(system, listKey, id)
    for _, t in ipairs(system[listKey] or {}) do if t.id == id then return t.name end end
    return id
end

-- Creates a static label at (x, y).
local function Label(content, text, x, y)
    local fs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
    fs:SetText(text)
    return fs
end

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

local function FieldButton(content, y, width)
    local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    b:SetSize(width or 200, 20)
    b:SetPoint("TOPLEFT", CTRL_X, y + 1)
    -- Clip the label to the button so long values (e.g. two origin traits) do
    -- not spill outside the button graphic.
    local fs = b:GetFontString()
    if fs then fs:SetWidth((width or 200) - 12); fs:SetWordWrap(false) end
    return b
end

local function TextBox(content, y, width)
    local e = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    e:SetSize(width or 200, 20)
    e:SetPoint("TOPLEFT", CTRL_X + 6, y)
    e:SetAutoFocus(false)
    e:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
    e:SetScript("OnEscapePressed", e.ClearFocus)
    return e
end

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
    f.levelUpBtn:SetSize(78, 20); f.levelUpBtn:SetText("Level Up"); f.levelUpBtn:SetPoint("TOPLEFT", CTRL_X + 40, y + 1)
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

    -- Attributes.
    y = y - 10; Header(c, "ATTRIBUTES", y); y = y - 24
    f.steppers, f.modText = {}, {}
    for _, attr in ipairs(system.attributes) do
        Label(c, attr.name, PAD, y)
        local st = ns.Widgets.Stepper(c, 96)
        st:SetPoint("TOPLEFT", CTRL_X, y + 1)
        f.steppers[attr.id] = st
        local m = c:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        m:SetPoint("TOPLEFT", CTRL_X + 104, y)
        m:SetTextColor(UI.HEAD[1], UI.HEAD[2], UI.HEAD[3])
        f.modText[attr.id] = m
        adv()
    end
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

    -- Wire inputs (read live f.char at event time).
    local function textCommit(box, field)
        box:SetScript("OnTextChanged", function(self, user)
            if user and f.char then f.char[field] = self:GetText(); if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end end
        end)
    end
    textCommit(f.nameBox, "name"); textCommit(f.playerBox, "player")
    textCommit(f.quoteBox, "quote"); textCommit(f.notesBox, "notes")

    -- Base attributes may exceed the creation cap of 10 post-creation (level
    -- milestone points and traits push toward the 11/12 perk requirements), so
    -- the stepper allows up to the modifier table's range.
    local maxAttr = #(system.modifier_table or {})
    if maxAttr < 10 then maxAttr = 20 end
    for id, st in pairs(f.steppers) do
        st:OnStep(function(delta)
            if not f.char then return end
            f.char.attributes = f.char.attributes or {}
            local v = (f.char.attributes[id] or 5) + delta
            f.char.attributes[id] = math.max(1, math.min(maxAttr, v))
            Changed(f)
        end)
    end

    f.raceBtn:SetScript("OnClick", function()
        local items = {}
        for _, r in ipairs(CE.Races(ns.GetSystem())) do items[#items + 1] = { id = r, name = r } end
        Pick(f, "Race", "Choose a race", items, 1, { f.char and f.char.race }, function(ids) f.char.race = ids[1] end)
    end)
    f.racialBtn:SetScript("OnClick", function()
        Pick(f, "Racial Trait", "Choose a racial trait (hover for details)", RacialItems(ns.GetSystem(), f.char.race), 1,
            { f.char.racial_trait }, function(ids) f.char.racial_trait = (ids[1] ~= "__none") and ids[1] or nil end)
    end)
    f.originBtn:SetScript("OnClick", function()
        Pick(f, "Origin Traits", "Choose up to two (hover for details)", TraitItems(ns.GetSystem().origin_traits), 2,
            f.char.origin_traits, function(ids) f.char.origin_traits = ids end)
    end)
    f.primaryBtn:SetScript("OnClick", function()
        Pick(f, "Primary Attribute", "Choose the primary attribute", AttrItems(ns.GetSystem()), 1,
            { f.char.primary_attribute }, function(ids) f.char.primary_attribute = ids[1] end)
    end)
    f.acBtn:SetScript("OnClick", function()
        Pick(f, "AC Attribute", "Agility, Sense or Luck", AttrItems(ns.GetSystem(), { agi = true, sen = true, luk = true }), 1,
            { f.char.ac_attribute }, function(ids) f.char.ac_attribute = ids[1] end)
    end)
    f.initBtn:SetScript("OnClick", function()
        Pick(f, "Initiative Attribute", "Agility or Sense", AttrItems(ns.GetSystem(), { agi = true, sen = true }), 1,
            { f.char.init_attribute }, function(ids) f.char.init_attribute = ids[1] end)
    end)
    f.skillsBtn:SetScript("OnClick", function()
        local items = {}
        for _, s in ipairs(ns.GetSystem().skills) do items[#items + 1] = { id = s.id, name = s.name } end
        Pick(f, "Accomplished Skills", "Mark accomplished skills", items, #items,
            f.char.accomplished_skills, function(ids) f.char.accomplished_skills = ids end)
    end)
    f.weaponsBtn:SetScript("OnClick", function()
        local items = {}
        for _, wpn in ipairs(ns.GetSystem().weapons) do items[#items + 1] = { id = wpn.id, name = wpn.name } end
        Pick(f, "Accomplished Weapons", "Mark accomplished weapons", items, #items,
            f.char.accomplished_weapons, function(ids) f.char.accomplished_weapons = ids end)
    end)
    f.savesBtn:SetScript("OnClick", function()
        Pick(f, "Accomplished Saves", "Primary save is auto; choose one more", SaveItems(ns.GetSystem(), f.char.primary_attribute),
            #ns.GetSystem().attributes, f.char.accomplished_saves, function(ids) f.char.accomplished_saves = ids end)
    end)

    -- Hover tooltips on the accomplished count buttons explaining the target.
    local function countTip(btn, build)
        btn:SetScript("OnEnter", function(self)
            if not f.char then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            build(GameTooltip, ns.CharacterSheet.Compute(f.char, ns.GetSystem()))
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", GameTooltip_Hide)
    end
    local function mod(sheet, id) for _, a in ipairs(sheet.attributes) do if a.id == id then return a.modifier end end return 0 end
    countTip(f.skillsBtn, function(tt, sheet)
        local tg = CE.AccomplishTargets(sheet)
        local intMod = mod(sheet, "int")
        local add = math.max(0, intMod)
        tt:AddLine("Accomplished Skills", UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
        tt:AddLine("3 base, plus your Intellect modifier when positive.", 0.9, 0.9, 0.9, true)
        tt:AddLine("Intellect modifier " .. Signed(intMod) .. " adds +" .. add .. ".  Target: " .. tg.skills, 0.56, 0.78, 1)
        tt:AddLine("Chosen: " .. #(f.char.accomplished_skills or {}), 0.78, 0.66, 0.41)
    end)
    countTip(f.weaponsBtn, function(tt, sheet)
        local tg = CE.AccomplishTargets(sheet)
        local hi = math.max(mod(sheet, "pow"), mod(sheet, "agi"))
        local add = math.max(0, hi)
        tt:AddLine("Accomplished Weapons", UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
        tt:AddLine("5 base, plus the higher of Power/Agility modifier when positive.", 0.9, 0.9, 0.9, true)
        tt:AddLine("Higher modifier " .. Signed(hi) .. " adds +" .. add .. ".  Target: " .. tg.weapons, 0.56, 0.78, 1)
        tt:AddLine("Chosen: " .. #(f.char.accomplished_weapons or {}), 0.78, 0.66, 0.41)
    end)
    countTip(f.savesBtn, function(tt, sheet)
        tt:AddLine("Accomplished Saves", UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
        tt:AddLine("Your primary attribute's save (automatic) plus one of your choice = 2.", 0.9, 0.9, 0.9, true)
        tt:AddLine("Primary: " .. AttrName(ns.GetSystem(), f.char.primary_attribute), 0.78, 0.66, 0.41)
    end)

    -- Resource editing.
    f.rollBtn:SetScript("OnClick", function() EditorUI.RollHP(f) end)
    f.addHpBtn:SetScript("OnClick", function() EditorUI.AddHP(f) end)
    f.levelUpBtn:SetScript("OnClick", function() EditorUI.DoLevelUp(f) end)
    local function maxCommit(box, field)
        box:SetScript("OnEnterPressed", function(self)
            if f.char then f.char[field] = tonumber(self:GetText()) or 0 end
            self:ClearFocus(); Changed(f)
        end)
    end
    maxCommit(f.maxHpBox, "max_hp"); maxCommit(f.maxManaBox, "max_mana")

    return f
end

-- Rolls a hit die + VIT modifier into the HP-gain box.
function EditorUI.RollHP(self)
    if not self.char then return end
    local sheet = ns.CharacterSheet.Compute(self.char, ns.GetSystem())
    local die = tonumber(tostring(sheet.derived.hit_dice):match("d(%d+)")) or 6
    local vitMod = 0
    for _, a in ipairs(sheet.attributes) do if a.id == "vit" then vitMod = a.modifier end end
    self.hpBox:SetText(tostring(math.random(1, die) + vitMod))
end

-- Adds the Gain HP value to both maximum and current HP (an ad-hoc gain that is
-- not a level-up).
function EditorUI.AddHP(self)
    if not self.char then return end
    local hp = tonumber(self.hpBox:GetText()) or 0
    if hp == 0 then return end
    self.char.max_hp = (self.char.max_hp or 0) + hp
    self.char.current_hp = (self.char.current_hp or 0) + hp
    self.hpBox:SetText("")
    self.note = "+" .. hp .. " HP (max " .. self.char.max_hp .. ")"
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

function EditorUI.NewCharacter(self)
    local char = CE.NewBlank()
    local base, key, n = "Character", nil, 0
    repeat n = n + 1; key = base .. "-" .. n until not (ParchmentCharDB.characters and ParchmentCharDB.characters[key])
    CE.SaveNew(key, char)
    Changed(self)
end

function EditorUI.DeleteCharacter(self)
    local _, key = ns.GetActiveCharacter()
    if key then CE.Delete(key); Changed(self) end
    if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
end

function EditorUI.PickCharacter(self)
    local items = {}
    for key, ch in pairs(ns.GetCharacters()) do items[#items + 1] = { id = key, name = ch.name or key } end
    ns.Dialogs.Pick({ title = "Characters", prompt = "Switch active character", items = items, max = 1,
        selected = { select(2, ns.GetActiveCharacter()) },
        onConfirm = function(ids) if ids[1] then ns.SetActiveCharacter(ids[1]) end; Changed(self) end })
end

-- Fills every widget from the active character.
Refresh = function(self)
    local char, key = ns.GetActiveCharacter()
    self.char = char
    local system = ns.GetSystem()
    if not char then
        self.titleFS:SetText("Character Editor - no character")
        self.warnText:SetText("No character. Use New to create one.")
        return
    end
    self.titleFS:SetText("Editing: " .. (char.name or key or "?"))

    local sheet = ns.CharacterSheet.Compute(char, system)
    local function setBox(box, v) if not box:HasFocus() then box:SetText(v or "") end end
    setBox(self.nameBox, char.name); setBox(self.playerBox, char.player)
    setBox(self.quoteBox, char.quote); setBox(self.notesBox, char.notes)
    setBox(self.maxHpBox, tostring(char.max_hp or 0))
    setBox(self.maxManaBox, tostring(char.max_mana or 0))

    self.raceBtn:SetText(char.race ~= "" and char.race or "(choose)")
    self.levelText:SetText(tostring(char.level or 1))

    local modById = {}
    for _, a in ipairs(sheet.attributes) do modById[a.id] = a end
    for _, attr in ipairs(system.attributes) do
        self.steppers[attr.id]:SetText(tostring((char.attributes or {})[attr.id] or 1))
        local a = modById[attr.id]
        self.modText[attr.id]:SetText(a and (Signed(a.modifier) .. (a.bonus ~= 0 and "  (" .. a.final .. ")" or "")) or "")
    end

    local used, avail = CE.AttributePoints(char, system)
    local pc = (used == avail) and UI.GREEN or (used > avail and UI.RED or UI.HEAD)
    self.pointsText:SetTextColor(pc[1], pc[2], pc[3])
    self.pointsText:SetText(string.format("Attribute points: %d / %d", used, avail))

    self.racialBtn:SetText(char.racial_trait and TraitName(system, "racial_traits", char.racial_trait) or "(none)")
    local origins = {}
    for _, id in ipairs(char.origin_traits or {}) do origins[#origins + 1] = TraitName(system, "origin_traits", id) end
    self.originBtn:SetText(#origins > 0 and table.concat(origins, ", ") or "(none)")
    self.primaryBtn:SetText(AttrName(system, char.primary_attribute))
    self.acBtn:SetText(AttrName(system, char.ac_attribute))
    self.initBtn:SetText(AttrName(system, char.init_attribute))

    local tg = CE.AccomplishTargets(sheet)
    self.skillsBtn:SetText(string.format("%d / %d", #(char.accomplished_skills or {}), tg.skills))
    self.weaponsBtn:SetText(string.format("%d / %d", #(char.accomplished_weapons or {}), tg.weapons))
    self.savesBtn:SetText(string.format("%d / %d", #(char.accomplished_saves or {}), tg.saves))

    local warns = CE.Warnings(char, system)
    if self.note then table.insert(warns, 1, "|cff66d966" .. self.note .. "|r"); self.note = nil end
    self.warnText:SetText(#warns > 0 and table.concat(warns, "\n") or "|cff66d966No warnings.|r")
end

local function GetFrame()
    if not EditorUI.frame then EditorUI.frame = BuildFrame() end
    return EditorUI.frame
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

ns.RegisterModule("edit", EditorUI.Toggle)
