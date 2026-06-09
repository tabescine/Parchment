-- Parchment - Character Wizard (UI)
--
-- A guided, stepped creator for a brand-new character: Identity -> Attributes ->
-- Traits -> Proficiencies -> Review. It edits a draft (not the active
-- character); Finish saves the draft, makes it active, and opens the editor for
-- any further tweaks. Reuses ns.Widgets.Stepper, ns.Dialogs.Pick and the
-- ns.CharacterEditor budgets/warnings; validation is soft (shown, never blocks).
--
-- Reads from: ns.CharacterEditor, ns.CharacterSheet.Compute, ns.GetSystem,
--   ns.Widgets, ns.Dialogs, ns.UI, ns.CharacterEditorUI.
-- Registers the "new" module opener with Core.

local ADDON, ns = ...

local UI = ns.UI
local CE = ns.CharacterEditor
local PAD, ROW_H, CTRL_X = 16, 26, 110
-- Traits come before Attributes so trait-granted attribute points are in the
-- budget when the player allocates. Proficiencies follow Attributes (their
-- skill/weapon targets depend on the final modifiers).
local STEPS = { "Identity", "Traits", "Attributes", "Proficiencies", "Review" }

local WizardUI = {}
ns.CharacterWizardUI = WizardUI

local Refresh

local function Signed(n) return (n >= 0 and "+" or "") .. n end

-- Item-list builders (mirror the editor's, kept local so the wizard is
-- self-contained).
local function ListItems(list)
    local out = {}
    for _, r in ipairs(list or {}) do out[#out + 1] = { id = r.id, name = r.name } end
    return out
end
local function AttrItems(system, allow)
    local out = {}
    for _, a in ipairs(system.attributes or {}) do
        if not allow or allow[a.id] then out[#out + 1] = { id = a.id, name = a.name } end
    end
    return out
end
local function TraitItems(list)
    local out = {}
    for _, r in ipairs(list or {}) do out[#out + 1] = { id = r.id, name = r.name, tooltip = r.description } end
    return out
end
local function RacialItems(system, race)
    local out = { { id = "__none", name = "(none)" } }
    for _, t in ipairs(system.racial_traits or {}) do
        for _, r in ipairs(t.allowed_races or {}) do
            if r == race or (r == "all_but_human" and race ~= "human" and race ~= "") then
                out[#out + 1] = { id = t.id, name = t.name, tooltip = t.description }
                break
            end
        end
    end
    return out
end
local function SaveItems(system, primary)
    local out = {}
    for _, a in ipairs(system.attributes or {}) do
        out[#out + 1] = { id = a.id, name = a.name .. (a.id == primary and "  (primary)" or "") }
    end
    return out
end
local function AttrName(system, id)
    for _, a in ipairs(system.attributes or {}) do if a.id == id then return a.name end end
    return id or "(none)"
end
local function TraitName(system, key, id)
    for _, t in ipairs(system[key] or {}) do if t.id == id then return t.name end end
    return id
end

-- Small widget helpers.
local function Label(p, text, x, y)
    local fs = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x, y); fs:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3]); fs:SetText(text)
    return fs
end
local function FieldButton(p, y, width)
    local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    b:SetSize(width or 200, 20); b:SetPoint("TOPLEFT", CTRL_X, y + 1)
    local fs = b:GetFontString(); if fs then fs:SetWidth((width or 200) - 12); fs:SetWordWrap(false) end
    return b
end
local function TextBox(p, y, width)
    local e = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    e:SetSize(width or 200, 20); e:SetPoint("TOPLEFT", CTRL_X + 6, y); e:SetAutoFocus(false)
    e:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3]); e:SetScript("OnEscapePressed", e.ClearFocus)
    return e
end

-- Opens a picker that writes into the draft and refreshes.
local function Pick(f, title, prompt, items, max, selected, apply)
    ns.Dialogs.Pick({ title = title, prompt = prompt, items = items, max = max, selected = selected,
        onConfirm = function(ids) apply(ids); Refresh(f) end })
end

local function NewPage(f)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 0, -70)
    p:SetPoint("BOTTOMRIGHT", 0, 44)
    p:Hide()
    return p
end

local function BuildFrame()
    local system = ns.GetSystem()
    local f = UI.CreateWindow("ParchmentWizardFrame", {
        title = "New Character", width = 440, height = 560,
        minW = 400, minH = 420, maxW = 600, maxH = 1000, dbKey = "wizardWindow",
    })
    f.step = 1
    f.pages = {}

    f.stepLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.stepLabel:SetPoint("TOPLEFT", PAD, -44)
    f.stepLabel:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])

    -- Page 1: Identity.
    local p1 = NewPage(f); f.pages[1] = p1
    local y = -PAD
    Label(p1, "Name", PAD, y); f.nameBox = TextBox(p1, y, 220); y = y - ROW_H
    Label(p1, "Player", PAD, y); f.playerBox = TextBox(p1, y, 220); y = y - ROW_H
    Label(p1, "Race", PAD, y); f.raceBtn = FieldButton(p1, y); y = y - ROW_H
    Label(p1, "Quote", PAD, y); f.quoteBox = TextBox(p1, y, 250); y = y - ROW_H

    -- Attributes page (shown at step 3).
    local p2 = NewPage(f); f.pages[3] = p2
    y = -PAD
    f.steppers, f.modText = {}, {}
    for _, attr in ipairs(system.attributes) do
        Label(p2, attr.name, PAD, y)
        local st = ns.Widgets.Stepper(p2, 96); st:SetPoint("TOPLEFT", CTRL_X, y + 1)
        f.steppers[attr.id] = st
        local m = p2:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        m:SetPoint("TOPLEFT", CTRL_X + 104, y); m:SetTextColor(UI.HEAD[1], UI.HEAD[2], UI.HEAD[3])
        f.modText[attr.id] = m
        y = y - ROW_H
    end
    f.pointsText = p2:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.pointsText:SetPoint("TOPLEFT", PAD, y - 4)

    -- Traits page (shown at step 2).
    local p3 = NewPage(f); f.pages[2] = p3
    y = -PAD
    Label(p3, "Racial", PAD, y); f.racialBtn = FieldButton(p3, y); y = y - ROW_H
    Label(p3, "Origins", PAD, y); f.originBtn = FieldButton(p3, y); y = y - ROW_H
    Label(p3, "Primary", PAD, y); f.primaryBtn = FieldButton(p3, y, 120); y = y - ROW_H
    Label(p3, "AC attr", PAD, y); f.acBtn = FieldButton(p3, y, 120); y = y - ROW_H
    Label(p3, "Init attr", PAD, y); f.initBtn = FieldButton(p3, y, 120); y = y - ROW_H

    -- Page 4: Proficiencies.
    local p4 = NewPage(f); f.pages[4] = p4
    y = -PAD
    Label(p4, "Skills", PAD, y); f.skillsBtn = FieldButton(p4, y, 160); y = y - ROW_H
    Label(p4, "Weapons", PAD, y); f.weaponsBtn = FieldButton(p4, y, 160); y = y - ROW_H
    Label(p4, "Saves", PAD, y); f.savesBtn = FieldButton(p4, y, 160); y = y - ROW_H
    f.profHint = p4:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.profHint:SetPoint("TOPLEFT", PAD, y - 6); f.profHint:SetPoint("RIGHT", p4, "RIGHT", -PAD, 0)
    f.profHint:SetJustifyH("LEFT"); f.profHint:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    -- Page 5: Review.
    local p5 = NewPage(f); f.pages[5] = p5
    f.review = p5:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.review:SetPoint("TOPLEFT", PAD, -PAD); f.review:SetPoint("RIGHT", p5, "RIGHT", -PAD, 0)
    f.review:SetJustifyH("LEFT")

    -- Navigation.
    f.backBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.backBtn:SetSize(70, 22); f.backBtn:SetText("Back"); f.backBtn:SetPoint("BOTTOMLEFT", PAD, 12)
    f.backBtn:SetScript("OnClick", function() f.step = math.max(1, f.step - 1); Refresh(f) end)
    f.cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.cancelBtn:SetSize(70, 22); f.cancelBtn:SetText("Cancel"); f.cancelBtn:SetPoint("BOTTOM", 0, 12)
    f.cancelBtn:SetScript("OnClick", function() f:Hide() end)
    f.nextBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.nextBtn:SetSize(70, 22); f.nextBtn:SetText("Next"); f.nextBtn:SetPoint("BOTTOMRIGHT", -PAD, 12)
    f.nextBtn:SetScript("OnClick", function()
        if f.step < #STEPS then f.step = f.step + 1; Refresh(f) else WizardUI.Finish(f) end
    end)

    -- Input wiring (reads live f.draft).
    local function textCommit(box, field)
        box:SetScript("OnTextChanged", function(self, user) if user and f.draft then f.draft[field] = self:GetText() end end)
    end
    textCommit(f.nameBox, "name"); textCommit(f.playerBox, "player"); textCommit(f.quoteBox, "quote")

    -- During creation the cap is the point-buy maximum (10); higher values come
    -- later via level points and are handled in the editor, not the wizard.
    local maxAttr = (system.point_buy and system.point_buy.max) or 10
    for id, st in pairs(f.steppers) do
        st:OnStep(function(delta)
            if not f.draft then return end
            local v = (f.draft.attributes[id] or 5) + delta
            f.draft.attributes[id] = math.max(1, math.min(maxAttr, v))
            Refresh(f)
        end)
    end

    f.raceBtn:SetScript("OnClick", function()
        local items = {}
        for _, r in ipairs(CE.Races(ns.GetSystem())) do items[#items + 1] = { id = r, name = r } end
        Pick(f, "Race", "Choose a race", items, 1, { f.draft.race }, function(ids) f.draft.race = ids[1] end)
    end)
    f.racialBtn:SetScript("OnClick", function()
        Pick(f, "Racial Trait", "Choose a racial trait (hover for details)", RacialItems(ns.GetSystem(), f.draft.race), 1,
            { f.draft.racial_trait }, function(ids) f.draft.racial_trait = (ids[1] ~= "__none") and ids[1] or nil end)
    end)
    f.originBtn:SetScript("OnClick", function()
        Pick(f, "Origin Traits", "Choose up to two (hover for details)", TraitItems(ns.GetSystem().origin_traits), 2,
            f.draft.origin_traits, function(ids) f.draft.origin_traits = ids end)
    end)
    f.primaryBtn:SetScript("OnClick", function()
        Pick(f, "Primary Attribute", "Choose the primary attribute", AttrItems(ns.GetSystem()), 1,
            { f.draft.primary_attribute }, function(ids) f.draft.primary_attribute = ids[1] end)
    end)
    f.acBtn:SetScript("OnClick", function()
        Pick(f, "AC Attribute", "Agility, Sense or Luck", AttrItems(ns.GetSystem(), { agi = true, sen = true, luk = true }), 1,
            { f.draft.ac_attribute }, function(ids) f.draft.ac_attribute = ids[1] end)
    end)
    f.initBtn:SetScript("OnClick", function()
        Pick(f, "Initiative Attribute", "Agility or Sense", AttrItems(ns.GetSystem(), { agi = true, sen = true }), 1,
            { f.draft.init_attribute }, function(ids) f.draft.init_attribute = ids[1] end)
    end)
    f.skillsBtn:SetScript("OnClick", function()
        Pick(f, "Accomplished Skills", "Mark accomplished skills", ListItems(ns.GetSystem().skills), #ns.GetSystem().skills,
            f.draft.accomplished_skills, function(ids) f.draft.accomplished_skills = ids end)
    end)
    f.weaponsBtn:SetScript("OnClick", function()
        Pick(f, "Accomplished Weapons", "Mark accomplished weapons", ListItems(ns.GetSystem().weapons), #ns.GetSystem().weapons,
            f.draft.accomplished_weapons, function(ids) f.draft.accomplished_weapons = ids end)
    end)
    f.savesBtn:SetScript("OnClick", function()
        Pick(f, "Accomplished Saves", "Primary save is auto; choose one more", SaveItems(ns.GetSystem(), f.draft.primary_attribute),
            #ns.GetSystem().attributes, f.draft.accomplished_saves, function(ids) f.draft.accomplished_saves = ids end)
    end)

    return f
end

-- Saves the draft, makes it active, and opens the editor.
function WizardUI.Finish(self)
    local key, n = nil, 0
    repeat n = n + 1; key = "Character-" .. n until not (ParchmentCharDB.characters and ParchmentCharDB.characters[key])
    CE.SaveNew(key, self.draft)
    self:Hide()
    if ns.CharacterEditorUI then ns.CharacterEditorUI.Open() end
    if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
end

-- Redraws the current step.
Refresh = function(self)
    local system = ns.GetSystem()
    local d = self.draft
    self.stepLabel:SetText("Step " .. self.step .. " of " .. #STEPS .. ":  " .. STEPS[self.step])
    for i, p in ipairs(self.pages) do p:SetShown(i == self.step) end
    self.backBtn:SetEnabled(self.step > 1)
    self.nextBtn:SetText(self.step == #STEPS and "Finish" or "Next")

    local function setBox(box, v) if not box:HasFocus() then box:SetText(v or "") end end
    setBox(self.nameBox, d.name); setBox(self.playerBox, d.player); setBox(self.quoteBox, d.quote)
    self.raceBtn:SetText(d.race ~= "" and d.race or "(choose)")

    local sheet = ns.CharacterSheet.Compute(d, system)
    local modById = {}
    for _, a in ipairs(sheet.attributes) do modById[a.id] = a end
    for _, attr in ipairs(system.attributes) do
        self.steppers[attr.id]:SetText(tostring((d.attributes or {})[attr.id] or 1))
        local a = modById[attr.id]
        self.modText[attr.id]:SetText(a and Signed(a.modifier) or "")
    end
    local used, avail = CE.AttributePoints(d, system)
    local pc = (used == avail) and UI.GREEN or (used > avail and UI.RED or UI.HEAD)
    self.pointsText:SetTextColor(pc[1], pc[2], pc[3])
    self.pointsText:SetText(string.format("Attribute points: %d / %d", used, avail))

    self.racialBtn:SetText(d.racial_trait and TraitName(system, "racial_traits", d.racial_trait) or "(none)")
    local origins = {}
    for _, id in ipairs(d.origin_traits or {}) do origins[#origins + 1] = TraitName(system, "origin_traits", id) end
    self.originBtn:SetText(#origins > 0 and table.concat(origins, ", ") or "(none)")
    self.primaryBtn:SetText(AttrName(system, d.primary_attribute))
    self.acBtn:SetText(AttrName(system, d.ac_attribute))
    self.initBtn:SetText(AttrName(system, d.init_attribute))

    local tg = CE.AccomplishTargets(sheet)
    self.skillsBtn:SetText(string.format("%d / %d", #(d.accomplished_skills or {}), tg.skills))
    self.weaponsBtn:SetText(string.format("%d / %d", #(d.accomplished_weapons or {}), tg.weapons))
    self.savesBtn:SetText(string.format("%d / %d", #(d.accomplished_saves or {}), tg.saves))
    self.profHint:SetText(string.format("Targets: %d skills (3 + Int mod), %d weapons (5 + higher of Pow/Agi), 2 saves (primary + one).",
        tg.skills, tg.weapons))

    if self.step == #STEPS then
        local lines = {
            "|cffc8a868" .. (d.name or "?") .. "|r" .. (d.race ~= "" and ("  -  " .. d.race) or ""),
            "Primary " .. AttrName(system, d.primary_attribute) .. ", AC " .. AttrName(system, d.ac_attribute)
                .. ", Init " .. AttrName(system, d.init_attribute),
            "Racial: " .. (d.racial_trait and TraitName(system, "racial_traits", d.racial_trait) or "none")
                .. "   Origins: " .. (#origins > 0 and table.concat(origins, ", ") or "none"),
            "Accomplished: " .. #(d.accomplished_skills or {}) .. " skills, "
                .. #(d.accomplished_weapons or {}) .. " weapons, " .. #(d.accomplished_saves or {}) .. " saves",
            " ",
        }
        local warns = CE.Warnings(d, system)
        if #warns > 0 then
            lines[#lines + 1] = "|cffe67272Warnings:|r"
            for _, wn in ipairs(warns) do lines[#lines + 1] = "|cffe67272- " .. wn .. "|r" end
        else
            lines[#lines + 1] = "|cff66d966No warnings. Ready to create.|r"
        end
        self.review:SetText(table.concat(lines, "\n"))
    end
end

local function GetFrame()
    if not WizardUI.frame then WizardUI.frame = BuildFrame() end
    return WizardUI.frame
end

-- Opens the wizard with a fresh draft.
function WizardUI.Open()
    local f = GetFrame()
    f.draft = CE.NewBlank()
    f.step = 1
    Refresh(f)
    f:Show()
end

ns.RegisterModule("new", WizardUI.Open)
