-- Parchment - Perk Wizard (UI)
--
-- A guided, stepped creator for a homebrew perk (a char.custom_perks entry):
-- Basics (name, level, description) -> Effects (repeatable rows) -> Review.
-- It edits a draft, never the stored perk: Finish hands the draft to
-- ns.PerkTree.CommitPerk (append when creating, replace when editing) and
-- refreshes the open windows. Deleting a perk goes through the same module.
--
-- The effect rows are generated from ns.CharacterSheet.EFFECT_TYPES, so the
-- pickers, labels and target lists cannot drift from what Compute actually
-- folds into the sheet. Target lists come from the live system (attributes,
-- skills, spell schools); a system that declares none degrades to a hint
-- instead of an empty picker. Validation is soft: the review lists what
-- Schema.ValidateCharacter reports, but nothing blocks saving.
--
-- The level a perk is gained at may sit above the character's: Compute keeps
-- such a perk out of the totals until it is reached, and the review says so as
-- information (not a warning - a whole ability path is meant to be written up
-- front, so it must not ask to confirm).
--
-- Reads from: ns.CharacterSheet.EFFECT_TYPES/EffectType, ns.PerkTree,
--   ns.Schema.ValidateCharacter, ns.GetSystem, ns.GetActiveCharacter,
--   ns.GetCharacter, ns.SetCharacter, ns.Systems.RefreshAll, ns.Widgets,
--   ns.Dialogs, ns.CharacterForm, ns.UI.
-- Exposes on ns.PerkWizardUI: Open(index), Delete(index), and .frame.
-- Registers the "perkwizard" module opener with Core.

local ADDON, ns = ...

local UI = ns.UI
local PT = ns.PerkTree
local Form = ns.CharacterForm
local CS = ns.CharacterSheet

local PAD, ROW_H, CTRL_X = 16, 26, 96
local STEPS = { "Basics", "Effects", "Review" }

-- Effect-row metrics: column offsets from the row's left edge, and the cap on
-- how many rows a perk may carry (the page is a fixed height, and a perk with
-- a dozen effects is already past what a sheet can show readably).
local EFFECT_ROW_H = 26
local COL_TYPE, COL_TARGET, COL_VALUE, COL_MOD, COL_DEL = 0, 112, 212, 288, 378
local MAX_EFFECTS = 10
local VALUE_CAP, LEVEL_CAP = 99, 99

-- Picker id for the "unset" entry: no spell school (the effect then applies to
-- every school) and no add_modifier attribute.
local NONE_ID = "__none"

local PerkWizardUI = {}
ns.PerkWizardUI = PerkWizardUI

local Refresh

-- Shared form builders (the effect rows pass their own column x per control).
local Label = Form.Label
local FieldButton = Form.FieldButton

-- Draft records.

-- Returns the first free "hb-N" id for a character's homebrew perks. The id is
-- not read by the engine (effects fold by perk name), but it keeps the record
-- self-contained, like the ids imported perks carry.
local function NextPerkId(char)
    local used = {}
    for _, p in ipairs(char.custom_perks or {}) do
        if type(p) == "table" then used[p.id] = true end
    end
    local n = 0
    repeat
        n = n + 1
    until not used["hb-" .. n]
    return "hb-" .. n
end

-- Coerces a perk record into the shape the wizard edits, leaving any field it
-- does not own (e.g. `replaces` on an imported perk) untouched.
local function Normalize(perk, char)
    perk.name = tostring(perk.name or "")
    perk.description = tostring(perk.description or "")
    perk.level = math.max(1, math.min(LEVEL_CAP, math.floor(tonumber(perk.level) or char.level or 1)))
    perk.effects = type(perk.effects) == "table" and perk.effects or {}
    return perk
end

local function NewDraft(char)
    return Normalize({ id = NextPerkId(char), name = "", description = "", effects = {} }, char)
end

-- Effect display and picker items.

-- The system's spell schools as picker items (records or plain strings), led by
-- the "(all schools)" entry. Never empty, so the picker always opens.
local function SchoolItems(system)
    local items = { { id = NONE_ID, name = "(all schools)" } }
    for _, s in ipairs(system.spell_schools or {}) do
        local id = type(s) == "table" and s.id or s
        local name = (type(s) == "table" and s.name) or tostring(s)
        if id then items[#items + 1] = { id = id, name = name } end
    end
    return items
end

-- Picker items for an effect type's target, or nil when the type takes none.
-- An empty list means the loaded system declares nothing of that kind.
local function TargetItems(spec, system)
    if spec.target == "attribute" then return ns.Widgets.AttrItems(system) end
    if spec.target == "skill" then return ns.Widgets.ListItems(system.skills) end
    if spec.target == "school" then return SchoolItems(system) end
    return nil
end

-- Display name of an effect's current target ("(choose)" when unset).
local function TargetName(spec, e)
    local id = e[spec.target_key]
    if spec.target == "attribute" then return id and ns.AttrName(id) or "(choose)" end
    if spec.target == "skill" then
        local rec = ns.FindById(ns.GetSystem().skills, id)
        return rec and rec.name or id or "(choose)"
    end
    if spec.target == "school" then
        if not id then return "(all schools)" end
        for _, s in ipairs(ns.GetSystem().spell_schools or {}) do
            if (type(s) == "table" and s.id or s) == id then
                return (type(s) == "table" and s.name) or tostring(s)
            end
        end
        return tostring(id)
    end
    return "-"
end

-- One-line summary of an effect for the review step ("Skill: Athletics +2").
local function EffectSummary(e)
    local spec = CS.EffectType(e.type)
    if not spec then return tostring(e.type or "?") .. " (not applied)" end
    local text = spec.label
    if spec.target ~= "none" then text = text .. ": " .. TargetName(spec, e) end
    text = text .. "  " .. UI.Signed(e.value or 0)
    if e.add_modifier then text = text .. "  and " .. ns.AttrName(e.add_modifier) .. " modifier" end
    return text
end

-- Soft warnings for the review step: whatever Schema reports for a character
-- carrying only this perk, plus the two shape problems the schema cannot see
-- (an unnamed perk, an effect with no target picked). Never blocks.
local function Warnings(f, d)
    local out = {}
    if d.name == "" then out[#out + 1] = "no name" end
    for i, e in ipairs(d.effects) do
        local spec = CS.EffectType(e.type)
        if not spec then
            out[#out + 1] = "effect " .. i .. " has no type"
        elseif spec.target ~= "none" and spec.target ~= "school" and not e[spec.target_key] then
            out[#out + 1] = "effect " .. i .. " (" .. spec.label .. ") has no target"
        end
    end

    -- Schema issues come from a shallow copy of the character whose homebrew
    -- perks are just this draft. Whatever the character already reports without
    -- any homebrew perk is subtracted, so the review only ever blames the perk
    -- being authored.
    local char = f.charKey and ns.GetCharacter(f.charKey)
    if char then
        local probe = {}
        for k, v in pairs(char) do probe[k] = v end
        probe.custom_perks = {}
        local _, baseline = ns.Schema.ValidateCharacter(probe, ns.GetSystem())
        local known = {}
        for _, issue in ipairs(baseline or {}) do known[issue] = true end

        probe.custom_perks = { d }
        local ok, issues = ns.Schema.ValidateCharacter(probe, ns.GetSystem())
        if not ok then
            for _, issue in ipairs(issues) do
                if not known[issue] then out[#out + 1] = issue end
            end
        end
    end
    return out
end

-- Effect rows (pooled: built once, reused, hidden when the draft shrinks).

-- The effect a row currently edits, re-read at click time (a picker is not
-- modal, so the draft may have changed under it).
local function EffectAt(f, row)
    return f.draft and f.draft.effects[row.index]
end

-- Opens a checklist picker for one field of a row's effect.
local function PickInto(f, row, title, prompt, items, selected, apply)
    ns.Dialogs.Pick({
        title = title, prompt = prompt, items = items, max = 1, selected = selected,
        onConfirm = function(ids)
            local e = EffectAt(f, row)
            if e then apply(e, ids[1]) end
            Refresh(f)
        end,
    })
end

local function CreateEffectRow(f, index)
    local page = f.pages[2]
    local row = CreateFrame("Frame", nil, page)
    row:SetSize(400, EFFECT_ROW_H)
    row:SetPoint("TOPLEFT", PAD, -PAD - (index - 1) * EFFECT_ROW_H)
    row.index = index

    row.typeBtn = FieldButton(row, COL_TYPE, -4, 106)
    row.typeBtn:SetScript("OnClick", function()
        -- Types whose target list the loaded system cannot fill (no skills, no
        -- attributes) are left out rather than offered as a dead end.
        local items = {}
        for _, spec in ipairs(CS.EFFECT_TYPES) do
            local targets = TargetItems(spec, ns.GetSystem())
            if not targets or #targets > 0 then
                items[#items + 1] = { id = spec.id, name = spec.label }
            end
        end
        local e = EffectAt(f, row)
        PickInto(f, row, "Effect", "What does this perk change?", items, { e and e.type },
            function(eff, id)
                if not id or id == eff.type then return end
                -- Switching type drops the old type's target fields, which
                -- would otherwise linger as data no picker can reach.
                eff.type, eff.id, eff.skill, eff.school, eff.add_modifier = id, nil, nil, nil, nil
            end)
    end)

    row.targetBtn = FieldButton(row, COL_TARGET, -4, 94)
    row.targetBtn:SetScript("OnClick", function()
        local e = EffectAt(f, row)
        local spec = e and CS.EffectType(e.type)
        if not (spec and spec.target ~= "none") then return end
        local items = TargetItems(spec, ns.GetSystem())
        if #items == 0 then
            ns.Print("the loaded system defines no " .. spec.target .. "s to target.")
            return
        end
        PickInto(f, row, spec.label, "Choose a target", items, { e[spec.target_key] },
            function(eff, id)
                eff[spec.target_key] = (id and id ~= NONE_ID) and id or nil
            end)
    end)

    row.stepper = ns.Widgets.Stepper(row, 72)
    row.stepper:SetPoint("TOPLEFT", COL_VALUE, -2)
    row.stepper:OnStep(function(delta)
        local e = EffectAt(f, row)
        if not e then return end
        e.value = math.max(-VALUE_CAP, math.min(VALUE_CAP, (e.value or 0) + delta))
        Refresh(f)
    end)

    row.modBtn = FieldButton(row, COL_MOD, -4, 84)
    row.modBtn:SetScript("OnClick", function()
        local e = EffectAt(f, row)
        local spec = e and CS.EffectType(e.type)
        if not (spec and spec.add_modifier) then return end
        local items = { { id = NONE_ID, name = "(none)" } }
        for _, a in ipairs(ns.Widgets.AttrItems(ns.GetSystem())) do items[#items + 1] = a end
        PickInto(f, row, "Add Modifier", "Also add an attribute's modifier", items, { e.add_modifier },
            function(eff, id)
                eff.add_modifier = (id and id ~= NONE_ID) and id or nil
            end)
    end)

    row.delBtn = FieldButton(row, COL_DEL, -4, 22)
    row.delBtn:SetText("X")
    row.delBtn:SetScript("OnClick", function()
        if not f.draft then return end
        table.remove(f.draft.effects, row.index)
        Refresh(f)
    end)

    return row
end

local function AcquireEffectRow(f, index)
    local row = f.effectRows[index]
    if not row then
        row = CreateEffectRow(f, index)
        f.effectRows[index] = row
    end
    row:Show()
    return row
end

-- Page fill.

local function FillBasics(f, d)
    if not f.nameBox:HasFocus() then f.nameBox:SetText(d.name) end
    if not f.descBox:HasFocus() then f.descBox:SetText(d.description) end
    f.levelStepper:SetText(tostring(d.level))
end

local function FillEffects(f, d)
    for i, e in ipairs(d.effects) do
        local row = AcquireEffectRow(f, i)
        local spec = CS.EffectType(e.type)
        row.typeBtn:SetText(spec and spec.label or "(choose)")
        local hasTarget = spec and spec.target ~= "none"
        row.targetBtn:SetShown(hasTarget and true or false)
        if hasTarget then row.targetBtn:SetText(TargetName(spec, e)) end
        row.stepper:SetText(UI.Signed(e.value or 0))
        local hasMod = spec and spec.add_modifier
        row.modBtn:SetShown(hasMod and true or false)
        if hasMod then
            row.modBtn:SetText(e.add_modifier and (ns.AttrName(e.add_modifier) .. " mod") or "+ modifier")
        end
    end
    for i = #d.effects + 1, #f.effectRows do f.effectRows[i]:Hide() end

    f.addBtn:ClearAllPoints()
    f.addBtn:SetPoint("TOPLEFT", PAD, -PAD - #d.effects * EFFECT_ROW_H - 4)
    f.addBtn:SetEnabled(#d.effects < MAX_EFFECTS)
end

local function FillReview(f, d)
    local lines = {
        "|cffc8a868" .. (d.name ~= "" and d.name or "(unnamed perk)") .. "|r   -   gained at level " .. d.level,
        d.description ~= "" and d.description or "|cff9e998cNo description.|r",
        " ",
    }
    if #d.effects == 0 then
        lines[#lines + 1] = "|cff9e998cNo effects - this perk is text only.|r"
    else
        for _, e in ipairs(d.effects) do lines[#lines + 1] = "- " .. EffectSummary(e) end
    end
    lines[#lines + 1] = " "

    -- Planning ahead is what the level field is for, so a perk gained later is
    -- stated as information only - never a warning, which would ask to confirm.
    local char = f.charKey and ns.GetCharacter(f.charKey)
    local charLevel = tonumber(char and char.level) or 1
    if d.level > charLevel then
        lines[#lines + 1] = "|cff9e998cPending: this perk stays inactive until level "
            .. d.level .. " (the character is level " .. charLevel .. ").|r"
        lines[#lines + 1] = " "
    end

    local warns = Warnings(f, d)
    if #warns > 0 then
        lines[#lines + 1] = "|cffe67272Warnings:|r"
        for _, w in ipairs(warns) do lines[#lines + 1] = "|cffe67272- " .. w .. "|r" end
    else
        lines[#lines + 1] = "|cff66d966No warnings. Ready to save.|r"
    end
    f.review:SetText(table.concat(lines, "\n"))
end

-- Redraws the current step.
Refresh = function(self)
    if not ns.HasSystem() then
        ns.UI.NoSystem(self)
        return
    end
    local char = self.charKey and ns.GetCharacter(self.charKey)
    if not char then
        ns.UI.Empty(self, "No character yet.\n\nCreate one before writing homebrew perks.",
            "Create a character", function() ns.OpenModule("new") end)
        return
    end
    ns.UI.HideEmpty(self)
    local d = self.draft
    if not d then return end

    self.stepLabel:SetText("Step " .. self.step .. " of " .. #STEPS .. ":  " .. STEPS[self.step])
    for i, p in ipairs(self.pages) do p:SetShown(i == self.step) end
    self.backBtn:SetEnabled(self.step > 1)
    self.nextBtn:SetText(self.step == #STEPS and "Save" or "Next")
    self.deleteBtn:SetShown(self.editIndex ~= nil)

    FillBasics(self, d)
    FillEffects(self, d)
    if self.step == #STEPS then FillReview(self, d) end
end

-- Commit and delete, both through the ns data API and the PerkTree seam.

local function Commit(self)
    local char = self.charKey and ns.GetCharacter(self.charKey)
    if not (char and self.draft) then
        self:Hide()
        return
    end
    PT.CommitPerk(char, self.draft, self.editIndex)
    ns.SetCharacter(self.charKey, char)
    self.draft = nil
    self:Hide()
    ns.Systems.RefreshAll()
end

-- Soft warnings never block saving (the review lists them), but Finishing with
-- them present is confirmed so it cannot be an accident.
StaticPopupDialogs["PARCHMENT_PERK_WARN"] = {
    text = "This perk still has %s. Save it anyway?",
    button1 = "Save", button2 = CANCEL,
    OnAccept = function(_, self) Commit(self) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Deleting is destructive and cannot be undone in game, so it is confirmed.
StaticPopupDialogs["PARCHMENT_PERK_DELETE"] = {
    text = "Delete the homebrew perk '%s'?",
    button1 = DELETE, button2 = CANCEL,
    OnAccept = function(_, data)
        if not data then return end
        local char = ns.GetCharacter(data.key)
        if not (char and PT.DeletePerk(char, data.index)) then return end
        ns.SetCharacter(data.key, char)
        -- Any open draft for this character now points at a shifted list.
        local f = PerkWizardUI.frame
        if f and f:IsShown() and f.charKey == data.key then f:Hide() end
        ns.Systems.RefreshAll()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function Finish(self)
    if not self.draft then
        self:Hide()
        return
    end
    local warns = Warnings(self, self.draft)
    if #warns > 0 then
        StaticPopup_Show("PARCHMENT_PERK_WARN",
            #warns .. " warning" .. (#warns == 1 and "" or "s"), nil, self)
        return
    end
    Commit(self)
end

local function NewPage(f)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 0, -70)
    p:SetPoint("BOTTOMRIGHT", 0, 44)
    p:Hide()
    return p
end

local function BuildFrame()
    local f = UI.CreateWindow("ParchmentPerkWizardFrame", {
        title = "New Homebrew Perk", width = 470, height = 470,
        minW = 450, minH = 400, maxW = 620, maxH = 900, dbKey = "perkWizardWindow",
    })
    f.step = 1
    f.pages = {}
    f.effectRows = {}

    f.stepLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.stepLabel:SetPoint("TOPLEFT", PAD, -44)
    f.stepLabel:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])

    -- Page 1: Basics.
    local p1 = NewPage(f); f.pages[1] = p1
    local y = -PAD
    Label(p1, "Name", PAD, y)
    f.nameBox = Form.TextBox(p1, CTRL_X, y, 250); y = y - ROW_H
    Label(p1, "Level", PAD, y)
    f.levelStepper = ns.Widgets.Stepper(p1, 96)
    f.levelStepper:SetPoint("TOPLEFT", CTRL_X + 6, y + 1); y = y - ROW_H
    Label(p1, "Description", PAD, y); y = y - 18

    -- Bordered multi-line description box filling the rest of the page - the
    -- character editor's NotesBox pattern (a plain EditBox, no scroll frame:
    -- InputScrollFrameTemplate's cursor tracking makes typed input jump).
    local descFrame = CreateFrame("Frame", nil, p1, "BackdropTemplate")
    descFrame:SetPoint("TOPLEFT", PAD, y)
    descFrame:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    descFrame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    descFrame:SetBackdropColor(0, 0, 0, 0.5)
    descFrame:SetBackdropBorderColor(UI.LINE[1], UI.LINE[2], UI.LINE[3], 1)
    f.descBox = CreateFrame("EditBox", nil, descFrame)
    f.descBox:SetMultiLine(true)
    f.descBox:SetAutoFocus(false)
    f.descBox:SetFontObject(ChatFontNormal)
    f.descBox:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
    f.descBox:SetPoint("TOPLEFT", 8, -7)
    f.descBox:SetPoint("BOTTOMRIGHT", -8, 7)
    f.descBox:SetScript("OnEscapePressed", f.descBox.ClearFocus)

    -- Page 2: Effects (rows are pooled and laid out on refresh).
    local p2 = NewPage(f); f.pages[2] = p2
    f.addBtn = CreateFrame("Button", nil, p2, "UIPanelButtonTemplate")
    f.addBtn:SetSize(110, 20)
    f.addBtn:SetText("+ Add effect")
    f.addBtn:SetScript("OnClick", function()
        local d = f.draft
        if not d or #d.effects >= MAX_EFFECTS then return end
        d.effects[#d.effects + 1] = { type = CS.EFFECT_TYPES[1].id, value = 1 }
        Refresh(f)
    end)
    f.effectHint = p2:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.effectHint:SetPoint("BOTTOMLEFT", PAD, PAD)
    f.effectHint:SetPoint("RIGHT", p2, "RIGHT", -PAD, 0)
    f.effectHint:SetJustifyH("LEFT")
    f.effectHint:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    f.effectHint:SetText("Effects fold into the sheet's totals. A perk with none is fine - "
        .. "its text still shows on the ability path.")

    -- Page 3: Review.
    local p3 = NewPage(f); f.pages[3] = p3
    f.review = p3:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.review:SetPoint("TOPLEFT", PAD, -PAD)
    f.review:SetPoint("RIGHT", p3, "RIGHT", -PAD, 0)
    f.review:SetJustifyH("LEFT")

    -- Navigation.
    f.backBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.backBtn:SetSize(70, 22); f.backBtn:SetText("Back"); f.backBtn:SetPoint("BOTTOMLEFT", PAD, 12)
    f.backBtn:SetScript("OnClick", function() f.step = math.max(1, f.step - 1); Refresh(f) end)
    f.deleteBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.deleteBtn:SetSize(70, 22); f.deleteBtn:SetText(DELETE)
    f.deleteBtn:SetPoint("BOTTOMLEFT", PAD + 76, 12)
    f.deleteBtn:SetScript("OnClick", function() PerkWizardUI.Delete(f.editIndex) end)
    f.cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.cancelBtn:SetSize(70, 22); f.cancelBtn:SetText(CANCEL); f.cancelBtn:SetPoint("BOTTOM", 40, 12)
    f.cancelBtn:SetScript("OnClick", function() f:Hide() end)
    f.nextBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.nextBtn:SetSize(70, 22); f.nextBtn:SetText("Next"); f.nextBtn:SetPoint("BOTTOMRIGHT", -PAD, 12)
    f.nextBtn:SetScript("OnClick", function()
        if f.step < #STEPS then f.step = f.step + 1; Refresh(f) else Finish(f) end
    end)

    -- Input wiring (reads the live draft; a typed edit lands immediately).
    f.nameBox:SetScript("OnTextChanged", function(self, user)
        if user and f.draft then f.draft.name = self:GetText() end
    end)
    f.descBox:SetScript("OnTextChanged", function(self, user)
        if user and f.draft then f.draft.description = self:GetText() end
    end)
    f.levelStepper:OnStep(function(delta)
        if not f.draft then return end
        f.draft.level = math.max(1, math.min(LEVEL_CAP, f.draft.level + delta))
        Refresh(f)
    end)
    UI.SetPlaceholder(f.nameBox, "Perk name")
    UI.SetPlaceholder(f.descBox, "What the perk does, in your own words", "TOPLEFT")

    return f
end

local function GetFrame()
    if not PerkWizardUI.frame then PerkWizardUI.frame = BuildFrame() end
    return PerkWizardUI.frame
end

-- Opens the wizard on the active character. With no index a fresh perk is
-- drafted; with one, that custom_perks entry is deep-copied into the draft, so
-- the stored perk is untouched until Save.
function PerkWizardUI.Open(index)
    local f = GetFrame()
    if not ns.HasSystem() then
        f.draft, f.charKey, f.editIndex = nil, nil, nil
        ns.UI.NoSystem(f)
        f:Show()
        return
    end
    local char, key = ns.GetActiveCharacter()
    if not char then
        f.draft, f.charKey, f.editIndex = nil, nil, nil
        Refresh(f)
        f:Show()
        return
    end

    f.charKey = key
    -- A malformed stored entry (a scalar from a hand-edited import) is treated
    -- as "not there" and drafts a new perk rather than blowing up mid-edit.
    local existing = index and (char.custom_perks or {})[index]
    if type(existing) ~= "table" then existing = nil end
    f.editIndex = existing and index or nil
    f.draft = existing and Normalize(ns.DeepCopy(existing), char) or NewDraft(char)
    f.step = 1
    f.titleFS:SetText(f.editIndex and "Edit Homebrew Perk" or "New Homebrew Perk")
    Refresh(f)
    f:Show()
end

-- Asks to delete the active character's homebrew perk at index.
function PerkWizardUI.Delete(index)
    local char, key = ns.GetActiveCharacter()
    local perk = char and index and (char.custom_perks or {})[index]
    if not perk then return end
    StaticPopup_Show("PARCHMENT_PERK_DELETE", perk.name or "?", nil, { key = key, index = index })
end

ns.RegisterModule("perkwizard", function() PerkWizardUI.Open() end)
