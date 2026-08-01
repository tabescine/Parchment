-- Parchment - Character Wizard (UI)
--
-- A guided, stepped creator for a brand-new character: Identity -> Traits ->
-- Attributes -> Proficiencies -> Review. It edits a draft (not the active
-- character); Finish saves the draft, makes it active, and opens the editor for
-- any further tweaks. Reuses ns.Widgets.Stepper, ns.Dialogs.Pick and the
-- ns.CharacterEditor budgets/warnings; validation is soft (shown, never blocks).
--
-- Reads from: ns.CharacterEditor, ns.CharacterSheet.Compute, ns.GetSystem,
--   ns.GetItemLibrary, ns.Widgets, ns.Dialogs, ns.UI, ns.CharacterEditorUI.
-- Exposes on ns.CharacterWizardUI: Open, RefreshIfShown (Finish is the
--   wizard's own final step).
-- Registers the "new" module opener with Core.

local ADDON, ns = ...

local UI = ns.UI
local CE = ns.CharacterEditor
local Form = ns.CharacterForm
local PAD, ROW_H, CTRL_X = 16, 26, 110
-- Traits come before Attributes so trait-granted attribute points are in the
-- budget when the player allocates. Proficiencies follow Attributes (their
-- skill/weapon targets depend on the final modifiers).
local STEPS = { "Identity", "Traits", "Attributes", "Proficiencies", "Review" }

local WizardUI = {}
ns.CharacterWizardUI = WizardUI

local Refresh

-- The shared form (labels, pickers, value fill) lives in ns.CharacterForm; the
-- wizard binds the builders to its own control column (CTRL_X) below.
local Label = Form.Label
local function FieldButton(p, y, width) return Form.FieldButton(p, CTRL_X, y, width) end
local function TextBox(p, y, width) return Form.TextBox(p, CTRL_X, y, width) end

-- Still referenced directly by the Review step's summary text.
local TraitName = ns.Widgets.TraitName

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
    Label(p1, "Quote", PAD, y); f.quoteBox = TextBox(p1, y, 250)

    -- Attributes page (shown at step 3). May be empty on first run (no system
    -- imported yet); the NoSystem overlay covers the form until one is.
    local p2 = NewPage(f); f.pages[3] = p2
    y = -PAD
    y = Form.BuildAttributeRows(f, p2, system, PAD, CTRL_X, y, ROW_H)
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
    Label(p3, "Cast attr", PAD, y); f.castBtn = FieldButton(p3, y, 120)

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
        box:SetScript("OnTextChanged", function(self, user)
            if user and f.draft then f.draft[field] = self:GetText() end
        end)
    end
    textCommit(f.nameBox, "name"); textCommit(f.playerBox, "player"); textCommit(f.quoteBox, "quote")

    -- During creation the cap is the point-buy maximum (10); higher values come
    -- later via level points and are handled in the editor, not the wizard. The
    -- cap is read at event time so a reimported system's value is honored.
    for id, st in pairs(f.steppers) do
        st:OnStep(function(delta)
            if not f.draft then return end
            -- Floor at point_buy.min (not a hardcoded 1), matching CE.NewBlank's
            -- seeding and CE.Warnings' check - else a player could step below the
            -- base and harvest points the accounting treats as unspent.
            local pb = ns.GetSystem().point_buy
            local minAttr = (pb and pb.min) or 1
            local maxAttr = (pb and pb.max) or 10
            local v = (f.draft.attributes[id] or minAttr) + delta
            f.draft.attributes[id] = math.max(minAttr, math.min(maxAttr, v))
            Refresh(f)
        end)
    end

    -- Field pickers: the shared form wires them, reading f.draft live and
    -- refreshing the current step afterward.
    Form.WirePickers(f, function() return f.draft end, function() Refresh(f) end)

    return f
end

-- Saves the draft, makes it active, and opens the editor.
local function Commit(self)
    CE.InitResources(self.draft, ns.GetSystem())
    CE.SaveNew(ns.NextCharacterKey(), self.draft)
    self:Hide()
    if ns.CharacterEditorUI then ns.CharacterEditorUI.Open() end
    if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
end

-- Soft warnings never block creation (the review lists them), but Finishing with
-- them present is confirmed so it cannot be an accident.
StaticPopupDialogs["PARCHMENT_WIZARD_WARN"] = {
    text = "This character still has %s. Create it anyway?",
    button1 = "Create", button2 = CANCEL,
    OnAccept = function(_, self) Commit(self) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function WizardUI.Finish(self)
    local warns = CE.Warnings(self.draft, ns.GetSystem())
    if #warns > 0 then
        StaticPopup_Show("PARCHMENT_WIZARD_WARN",
            #warns .. " warning" .. (#warns == 1 and "" or "s"), nil, self)
        return
    end
    Commit(self)
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

    local sheet = ns.CharacterSheet.Compute(d, system, ns.GetItemLibrary())
    local origins, tg = Form.FillCommon(self, d, system, sheet, false)
    self.profHint:SetText(string.format(
        "Suggested targets: %d skills, %d weapons, %d saves (primary is automatic).",
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

-- The wizard's attribute page is laid out from the system loaded at build time;
-- the shared helper rebuilds the frame when the attribute set changes (the draft
-- is dropped - it belonged to the old system; see WizardUI.RefreshIfShown).
local function GetFrame()
    return ns.UI.RebuildableFrame(WizardUI, BuildFrame, Form.AttrSignature)
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
