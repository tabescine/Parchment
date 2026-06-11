-- Parchment - Character Wizard (UI)
--
-- A guided, stepped creator for a brand-new character: Identity -> Traits ->
-- Attributes -> Proficiencies -> Review. It edits a draft (not the active
-- character); Finish saves the draft, makes it active, and opens the editor for
-- any further tweaks. Reuses ns.Widgets.Stepper, ns.Dialogs.Pick and the
-- ns.CharacterEditor budgets/warnings; validation is soft (shown, never blocks).
--
-- Reads from: ns.CharacterEditor, ns.CharacterSheet.Compute, ns.GetSystem,
--   ns.Widgets, ns.Dialogs, ns.UI, ns.CharacterEditorUI.
-- Exposes on ns.CharacterWizardUI: Open, RefreshIfShown (Finish is the
--   wizard's own final step).
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

local Signed = ns.UI.Signed

-- Picker item-list builders, shared with the editor (see UI/Widgets.lua).
local W = ns.Widgets
local ListItems, AttrItems, TraitItems = W.ListItems, W.AttrItems, W.TraitItems
local RacialItems, SaveItems, TraitName = W.RacialItems, W.SaveItems, W.TraitName

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

    -- Attributes page (shown at step 3). May be empty on first run (no system
    -- imported yet); the NoSystem overlay covers the form until one is.
    local p2 = NewPage(f); f.pages[3] = p2
    y = -PAD
    f.steppers, f.modText = {}, {}
    for _, attr in ipairs(system.attributes or {}) do
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
    -- later via level points and are handled in the editor, not the wizard. The
    -- cap is read at event time so a reimported system's value is honored.
    for id, st in pairs(f.steppers) do
        st:OnStep(function(delta)
            if not f.draft then return end
            local pb = ns.GetSystem().point_buy
            local maxAttr = (pb and pb.max) or 10
            local v = (f.draft.attributes[id] or 5) + delta
            f.draft.attributes[id] = math.max(1, math.min(maxAttr, v))
            Refresh(f)
        end)
    end

    -- Field pickers. Each guards on f.draft both at click time and again in
    -- the apply callback: ns.Dialogs.Pick is not modal, so the wizard can be
    -- cancelled (clearing the draft) while a picker is open.
    f.raceBtn:SetScript("OnClick", function()
        if not f.draft then return end
        local items = {}
        for _, r in ipairs(CE.Races(ns.GetSystem())) do items[#items + 1] = { id = r, name = r } end
        if #items == 0 then
            ns.Print("the loaded system defines no races - add a top-level `races` list or race lists on its racial traits.")
            return
        end
        Pick(f, "Race", "Choose a race", items, 1, { f.draft.race },
            function(ids) if f.draft then f.draft.race = ids[1] end end)
    end)
    f.racialBtn:SetScript("OnClick", function()
        if not f.draft then return end
        Pick(f, "Racial Trait", "Choose a racial trait (hover for details)", RacialItems(ns.GetSystem(), f.draft.race), 1,
            { f.draft.racial_trait },
            function(ids) if f.draft then f.draft.racial_trait = (ids[1] ~= "__none") and ids[1] or nil end end)
    end)
    f.originBtn:SetScript("OnClick", function()
        if not f.draft then return end
        Pick(f, "Origin Traits", "Choose up to two (hover for details)", TraitItems(ns.GetSystem().origin_traits), 2,
            f.draft.origin_traits, function(ids) if f.draft then f.draft.origin_traits = ids end end)
    end)
    f.primaryBtn:SetScript("OnClick", function()
        if not f.draft then return end
        Pick(f, "Primary Attribute", "Choose the primary attribute", AttrItems(ns.GetSystem()), 1,
            { f.draft.primary_attribute }, function(ids) if f.draft then f.draft.primary_attribute = ids[1] end end)
    end)
    f.acBtn:SetScript("OnClick", function()
        if not f.draft then return end
        Pick(f, "AC Attribute", "Choose the attribute that governs AC", AttrItems(ns.GetSystem()), 1,
            { f.draft.ac_attribute }, function(ids) if f.draft then f.draft.ac_attribute = ids[1] end end)
    end)
    f.initBtn:SetScript("OnClick", function()
        if not f.draft then return end
        Pick(f, "Initiative Attribute", "Choose the attribute that governs initiative", AttrItems(ns.GetSystem()), 1,
            { f.draft.init_attribute }, function(ids) if f.draft then f.draft.init_attribute = ids[1] end end)
    end)
    f.skillsBtn:SetScript("OnClick", function()
        if not f.draft then return end
        local skills = ns.GetSystem().skills or {}
        Pick(f, "Accomplished Skills", "Mark accomplished skills", ListItems(skills), #skills,
            f.draft.accomplished_skills, function(ids) if f.draft then f.draft.accomplished_skills = ids end end)
    end)
    f.weaponsBtn:SetScript("OnClick", function()
        if not f.draft then return end
        local weapons = ns.GetSystem().weapons or {}
        Pick(f, "Accomplished Weapons", "Mark accomplished weapons", ListItems(weapons), #weapons,
            f.draft.accomplished_weapons, function(ids) if f.draft then f.draft.accomplished_weapons = ids end end)
    end)
    f.savesBtn:SetScript("OnClick", function()
        if not f.draft then return end
        Pick(f, "Accomplished Saves", "Primary save is auto; choose one more", SaveItems(ns.GetSystem(), f.draft.primary_attribute),
            #(ns.GetSystem().attributes or {}), f.draft.accomplished_saves,
            function(ids) if f.draft then f.draft.accomplished_saves = ids end end)
    end)

    return f
end

-- Saves the draft, makes it active, and opens the editor.
function WizardUI.Finish(self)
    CE.InitResources(self.draft, ns.GetSystem())
    CE.SaveNew(ns.NextCharacterKey(), self.draft)
    self:Hide()
    if ns.CharacterEditorUI then ns.CharacterEditorUI.Open() end
    if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
end

-- Redraws the current step.
Refresh = function(self)
    if not ns.HasSystem() then ns.UI.NoSystem(self); return end
    ns.UI.HideEmpty(self)
    local system = ns.GetSystem()
    local d = self.draft
    if not d then return end
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
    for _, attr in ipairs(system.attributes or {}) do
        local st = self.steppers[attr.id]
        if st then
            st:SetText(tostring((d.attributes or {})[attr.id] or 1))
            local a = modById[attr.id]
            self.modText[attr.id]:SetText(a and Signed(a.modifier) or "")
        end
    end
    local used, avail = CE.AttributePoints(d, system)
    local pc = (used == avail) and UI.GREEN or (used > avail and UI.RED or UI.HEAD)
    self.pointsText:SetTextColor(pc[1], pc[2], pc[3])
    self.pointsText:SetText(string.format("Attribute points: %d / %d", used, avail))

    self.racialBtn:SetText(d.racial_trait and TraitName(system, "racial_traits", d.racial_trait) or "(none)")
    local origins = {}
    for _, id in ipairs(d.origin_traits or {}) do origins[#origins + 1] = TraitName(system, "origin_traits", id) end
    self.originBtn:SetText(#origins > 0 and table.concat(origins, ", ") or "(none)")
    self.primaryBtn:SetText(ns.AttrName(d.primary_attribute))
    self.acBtn:SetText(ns.AttrName(d.ac_attribute))
    self.initBtn:SetText(ns.AttrName(d.init_attribute))

    local tg = CE.AccomplishTargets(sheet)
    self.skillsBtn:SetText(string.format("%d / %d", #(d.accomplished_skills or {}), tg.skills))
    self.weaponsBtn:SetText(string.format("%d / %d", #(d.accomplished_weapons or {}), tg.weapons))
    self.savesBtn:SetText(string.format("%d / %d", #(d.accomplished_saves or {}), tg.saves))
    self.profHint:SetText(string.format("Suggested targets: %d skills, %d weapons, %d saves (primary is automatic).",
        tg.skills, tg.weapons, tg.saves))

    if self.step == #STEPS then
        local lines = {
            "|cffc8a868" .. (d.name or "?") .. "|r" .. (d.race ~= "" and ("  -  " .. d.race) or ""),
            "Primary " .. ns.AttrName(d.primary_attribute) .. ", AC " .. ns.AttrName(d.ac_attribute)
                .. ", Init " .. ns.AttrName(d.init_attribute),
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

-- The wizard's attribute page is laid out from the system loaded at build
-- time; rebuild the frame when the attribute set changes (the draft is not
-- carried over - it belonged to the old system).
local function AttrSignature()
    local ids = {}
    for _, a in ipairs(ns.GetSystem().attributes or {}) do ids[#ids + 1] = tostring(a.id) end
    return table.concat(ids, "\31")
end

local function GetFrame()
    local sig = AttrSignature()
    local f = WizardUI.frame
    if f and f.attrSignature ~= sig then
        f:Hide()
        f:SetParent(nil)
        WizardUI.frame = nil
    end
    if not WizardUI.frame then
        WizardUI.frame = BuildFrame()
        WizardUI.frame.attrSignature = sig
    end
    return WizardUI.frame
end

-- Opens the wizard with a fresh draft.
function WizardUI.Open()
    local f = GetFrame()
    if not ns.HasSystem() then
        ns.UI.NoSystem(f)
        f:Show()
        return
    end
    f.draft = CE.NewBlank()
    f.step = 1
    Refresh(f)
    f:Show()
end

-- Refreshes the wizard when it is open. If the system changed mid-creation the
-- frame was rebuilt and the old draft dropped, so restart with a fresh one.
function WizardUI.RefreshIfShown()
    if not (WizardUI.frame and WizardUI.frame:IsShown()) then return end
    local f = GetFrame()
    if f.draft then
        Refresh(f)
        f:Show()
    else
        WizardUI.Open()
    end
end

ns.RegisterModule("new", WizardUI.Open)
