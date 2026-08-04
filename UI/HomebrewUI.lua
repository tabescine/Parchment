-- Parchment - Homebrew Wizard (UI)
--
-- A guided, stepped creator for homebrew feats and spells (char.custom_feats /
-- char.custom_spells entries): Basics (name, level, description) -> Details
-- (type, cost, range, save, click-to-roll check; spells add school, rank,
-- damage, concentration)
-- -> Effects (repeatable rows) -> Review. It edits a draft, never the stored
-- record: Finish hands the draft to ns.Homebrew.Commit (append when creating,
-- replace when editing) and refreshes the open windows. Deleting goes through
-- the same module. Reached from the feats browser / spellbook Homebrew rails.
--
-- The effect rows are generated from ns.CharacterSheet.EFFECT_TYPES, so the
-- pickers, labels and target lists cannot drift from what Compute actually
-- folds into the sheet. Target lists come from the live system (attributes,
-- skills, spell schools); a system that declares none degrades to a hint
-- instead of an empty picker. Validation is soft: the review lists what
-- Schema.ValidateCharacter reports, but nothing blocks saving.
--
-- The level a record is gained at may sit above the character's: Compute
-- keeps it out of the totals and Picks charges nothing until it is reached,
-- and the review says so as information (a whole path may be written ahead).
--
-- Reads from: ns.CharacterSheet.EFFECT_TYPES/EffectType, ns.Homebrew,
--   ns.Schema.ValidateCharacter, ns.GetSystem, ns.GetSpellPack,
--   ns.GetActiveCharacter, ns.GetCharacter, ns.SetCharacter,
--   ns.Systems.RefreshAll, ns.Widgets, ns.Dialogs, ns.CharacterForm, ns.UI.
-- Exposes on ns.HomebrewUI: Open(kind, index), Delete(kind, index), .frame.

local ADDON, ns = ...

local UI = ns.UI
local HB = ns.Homebrew
local Form = ns.CharacterForm
local CS = ns.CharacterSheet

local PAD, ROW_H, CTRL_X = 16, 26, 96
local STEPS = { "Basics", "Details", "Effects", "Review" }

local EFFECT_ROW_H = 26
local COL_TYPE, COL_TARGET, COL_VALUE, COL_MOD, COL_DEL = 0, 112, 212, 288, 378
local MAX_EFFECTS = 10
local VALUE_CAP, LEVEL_CAP, RANK_CAP = 99, 99, 10

local NONE_ID = "__none"

local KIND_LABEL = { feat = "Feat", spell = "Spell" }

local HomebrewUI = {}
ns.HomebrewUI = HomebrewUI

local Refresh

local Label = Form.Label
local FieldButton = Form.FieldButton

-- Draft records.

-- Coerces a record into the shape the wizard edits, leaving any field it does
-- not own untouched. Cost is kept as a table only while it has content.
local function Normalize(rec, char, kind)
    rec.name = tostring(rec.name or "")
    rec.description = tostring(rec.description or "")
    rec.level = math.max(1, math.min(LEVEL_CAP, math.floor(tonumber(rec.level) or char.level or 1)))
    rec.effects = type(rec.effects) == "table" and rec.effects or {}
    rec.cost = type(rec.cost) == "table" and rec.cost or {}
    rec.cost.ap = tonumber(rec.cost.ap)
    rec.cost.mana = tonumber(rec.cost.mana)
    rec.check = type(rec.check) == "table" and rec.check or nil
    if kind == "spell" then
        rec.rank = math.max(1, math.min(RANK_CAP, math.floor(tonumber(rec.rank) or 1)))
        rec.concentration = rec.concentration and true or nil
    end
    return rec
end

-- Drops the draft-only scaffolding a stored record must not carry (an empty
-- cost table would encode as {} and read as "has a cost" downstream).
local function Strip(rec)
    if type(rec.cost) == "table" and not rec.cost.ap and not rec.cost.mana then
        rec.cost = nil
    end
    if type(rec.check) == "table" and not (rec.check.attribute or rec.check.skill) then
        rec.check = nil
    end
    if rec.type == "" then rec.type = nil end
    if rec.range == "" then rec.range = nil end
    if rec.damage == "" then rec.damage = nil end
    if rec.school == "" then rec.school = nil end
    return rec
end

local function NewDraft(char, kind)
    return Normalize({ id = HB.NextId(char, kind), name = "", description = "", effects = {} },
        char, kind)
end

-- Effect display and picker items (shared with the retired perk wizard's
-- design: everything derives from CS.EFFECT_TYPES).

local function SchoolItems(system)
    local items = { { id = NONE_ID, name = "(all schools)" } }
    for _, s in ipairs(system.spell_schools or {}) do
        local id = type(s) == "table" and s.id or s
        local name = (type(s) == "table" and s.name) or tostring(s)
        if id then items[#items + 1] = { id = id, name = name } end
    end
    return items
end

-- The active spell pack's schools as picker items (falling back to the
-- system's spell_schools), led by "(none)". For the spell draft's own school.
local function DraftSchoolItems()
    local items = { { id = NONE_ID, name = "(none)" } }
    local pack = ns.GetSpellPack()
    local list = pack and pack.schools or ns.GetSystem().spell_schools or {}
    for _, s in ipairs(list) do
        local id = type(s) == "table" and s.id or s
        local name = (type(s) == "table" and s.name) or tostring(s)
        if id then items[#items + 1] = { id = id, name = name } end
    end
    return items
end

-- Display name for a school id, resolved against pack then system schools.
local function SchoolName(id)
    if not id then return "(none)" end
    local pack = ns.GetSpellPack()
    for _, list in ipairs({ pack and pack.schools, ns.GetSystem().spell_schools }) do
        for _, s in ipairs(type(list) == "table" and list or {}) do
            if (type(s) == "table" and s.id or s) == id then
                return (type(s) == "table" and s.name) or tostring(s)
            end
        end
    end
    return tostring(id)
end

local function TargetItems(spec, system)
    if spec.target == "attribute" then return ns.Widgets.AttrItems(system) end
    if spec.target == "skill" then return ns.Widgets.ListItems(system.skills) end
    if spec.target == "school" then return SchoolItems(system) end
    return nil
end

-- The id an effect points at, or nil when it has none yet. Skill-targeted types
-- take the generic `id` as an alias for `skill` (ns.CharacterSheet's skill and
-- accomplish_skill both apply `e.skill or e.id`), so an imported record written
-- as { type = "skill", id = "s1" } reads here exactly as the sheet folds it.
-- Mirrors the item wizard's helper of the same name.
local function TargetId(spec, e)
    local id = spec.target_key and e[spec.target_key] or nil
    if id == nil and spec.target == "skill" then return e.id end
    return id
end

local function TargetName(spec, e)
    local id = TargetId(spec, e)
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

local function EffectSummary(e)
    local spec = CS.EffectType(e.type)
    if not spec then return ns.SafeText(e.type) .. " (not applied)" end
    local text = spec.label
    if spec.target ~= "none" then text = text .. ": " .. TargetName(spec, e) end
    text = text .. "  " .. UI.Signed(e.value or 0)
    if e.per_level then text = text .. " per level" end
    if e.add_modifier then text = text .. "  and " .. ns.AttrName(e.add_modifier) .. " modifier" end
    return text
end

-- Display name for a click-to-roll check ({ attribute = id } or
-- { skill = id }), or "(none)".
local function CheckName(check)
    if type(check) ~= "table" then return "(none)" end
    if check.attribute then return ns.AttrName(check.attribute) end
    if check.skill then
        local rec = ns.FindById(ns.GetSystem().skills, check.skill)
        return rec and rec.name or tostring(check.skill)
    end
    return "(none)"
end

-- The draft's mechanics on one line, as the pickers and sheet will show them.
local function MetaSummary(d, kind)
    local parts = {}
    if kind == "spell" then
        parts[#parts + 1] = SchoolName(d.school) .. " rank " .. (d.rank or 1)
    end
    if d.type and d.type ~= "" then parts[#parts + 1] = d.type end
    if d.check then parts[#parts + 1] = CheckName(d.check) .. " check" end
    local cost = ns.FormatCost(d.cost)
    if cost then parts[#parts + 1] = cost end
    if d.range and d.range ~= "" then parts[#parts + 1] = "Range: " .. d.range end
    if d.save then parts[#parts + 1] = ns.AttrName(d.save) .. " save" end
    if d.concentration then parts[#parts + 1] = "Concentration" end
    if d.damage and d.damage ~= "" then parts[#parts + 1] = d.damage end
    if #parts == 0 then return nil end
    return table.concat(parts, "  -  ")
end

-- Soft warnings for the review step, via a probe character whose homebrew of
-- this kind is just the draft; baseline issues are subtracted so the review
-- only ever blames the record being authored.
local function Warnings(f, d)
    local out = {}
    if d.name == "" then out[#out + 1] = "no name" end
    for i, e in ipairs(d.effects) do
        local spec = CS.EffectType(e.type)
        if not spec then
            out[#out + 1] = "effect " .. i .. " has an unknown type '"
                .. tostring(e.type or "?") .. "' (not applied)"
        elseif spec.target ~= "none" and spec.target ~= "school" and not TargetId(spec, e) then
            out[#out + 1] = "effect " .. i .. " (" .. spec.label .. ") has no target"
        end
    end

    local char = f.charKey and ns.GetCharacter(f.charKey)
    if char then
        local field = HB.Field(f.kind)
        local probe = {}
        for k, v in pairs(char) do probe[k] = v end
        probe[field] = {}
        local _, baseline = ns.Schema.ValidateCharacter(probe, ns.GetSystem())
        local known = {}
        for _, issue in ipairs(baseline or {}) do known[issue] = true end

        probe[field] = { Strip(ns.DeepCopy(d)) }
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

local function EffectAt(f, row)
    return f.draft and f.draft.effects[row.index]
end

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
    local page = f.pages[3]
    local row = CreateFrame("Frame", nil, page)
    row:SetSize(400, EFFECT_ROW_H)
    row:SetPoint("TOPLEFT", PAD, -PAD - (index - 1) * EFFECT_ROW_H)
    row.index = index

    row.typeBtn = FieldButton(row, COL_TYPE, -4, 106)
    row.typeBtn:SetScript("OnClick", function()
        local items = {}
        for _, spec in ipairs(CS.EFFECT_TYPES) do
            local targets = TargetItems(spec, ns.GetSystem())
            if not targets or #targets > 0 then
                items[#items + 1] = { id = spec.id, name = spec.label }
            end
        end
        local e = EffectAt(f, row)
        PickInto(f, row, "Effect", "What does this change?", items, { e and e.type },
            function(eff, id)
                if not id or id == eff.type then return end
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
        PickInto(f, row, spec.label, "Choose a target", items, { TargetId(spec, e) },
            function(eff, id)
                eff[spec.target_key] = (id and id ~= NONE_ID) and id or nil
                -- Drop the `id` alias an import may have used, so a stale one
                -- cannot outrank the pick just made (see TargetId).
                if spec.target == "skill" and spec.target_key ~= "id" then eff.id = nil end
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

local function FillDetails(f, d)
    local spell = f.kind == "spell"
    if not f.typeBox:HasFocus() then f.typeBox:SetText(d.type or "") end
    if not f.rangeBox:HasFocus() then f.rangeBox:SetText(d.range or "") end
    f.apStepper:SetText(tostring(d.cost.ap or 0))
    f.manaStepper:SetText(tostring(d.cost.mana or 0))
    f.saveBtn:SetText(d.save and ns.AttrName(d.save) or "(none)")
    f.checkBtn:SetText(CheckName(d.check))
    for _, w in ipairs(f.spellWidgets) do w:SetShown(spell) end
    if spell then
        f.schoolBtn:SetText(SchoolName(d.school))
        f.rankStepper:SetText(tostring(d.rank or 1))
        if not f.damageBox:HasFocus() then f.damageBox:SetText(d.damage or "") end
        f.concCheck:SetChecked(d.concentration and true or false)
    end
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
    local label = KIND_LABEL[f.kind]:lower()
    local lines = {
        "|cffc8a868" .. (d.name ~= "" and d.name or "(unnamed " .. label .. ")")
            .. "|r   -   gained at level " .. d.level,
    }
    local meta = MetaSummary(d, f.kind)
    if meta then lines[#lines + 1] = "|cff8ec6ff" .. meta .. "|r" end
    lines[#lines + 1] = d.description ~= "" and d.description or "|cff9e998cNo description.|r"
    lines[#lines + 1] = " "
    if #d.effects == 0 then
        lines[#lines + 1] = "|cff9e998cNo effects - this " .. label .. " is text only.|r"
    else
        for _, e in ipairs(d.effects) do lines[#lines + 1] = "- " .. EffectSummary(e) end
    end
    lines[#lines + 1] = " "

    local char = f.charKey and ns.GetCharacter(f.charKey)
    local charLevel = tonumber(char and char.level) or 1
    if d.level > charLevel then
        lines[#lines + 1] = "|cff9e998cPending: this " .. label .. " stays inactive until level "
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
        ns.UI.Empty(self, "No character yet.\n\nCreate one before writing homebrew.",
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
    FillDetails(self, d)
    FillEffects(self, d)
    if self.step == #STEPS then FillReview(self, d) end
end

-- Commit and delete, both through the ns data API and the Homebrew seam.

local function Commit(self)
    local char = self.charKey and ns.GetCharacter(self.charKey)
    if not (char and self.draft) then
        self:Hide()
        return
    end
    HB.Commit(char, self.kind, Strip(self.draft), self.editIndex)
    ns.SetCharacter(self.charKey, char)
    self.draft = nil
    self:Hide()
    ns.Systems.RefreshAll()
end

StaticPopupDialogs["PARCHMENT_HOMEBREW_WARN"] = {
    text = "This still has %s. Save it anyway?",
    button1 = "Save", button2 = CANCEL,
    OnAccept = function(_, self) Commit(self) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["PARCHMENT_HOMEBREW_DELETE"] = {
    text = "Delete the homebrew %s '%s'?",
    button1 = DELETE, button2 = CANCEL,
    OnAccept = function(_, data)
        if not data then return end
        local char = ns.GetCharacter(data.key)
        if not (char and ns.Homebrew.Delete(char, data.kind, data.index)) then return end
        ns.SetCharacter(data.key, char)
        local f = HomebrewUI.frame
        if f and f:IsShown() and f.charKey == data.key and f.kind == data.kind then f:Hide() end
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
        StaticPopup_Show("PARCHMENT_HOMEBREW_WARN",
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
    local f = UI.CreateWindow("ParchmentHomebrewFrame", {
        title = "New Homebrew", width = 470, height = 470,
        minW = 450, minH = 400, maxW = 620, maxH = 900, dbKey = "homebrewWindow",
    })
    f.step = 1
    f.kind = "feat"
    f.pages = {}
    f.effectRows = {}
    f.spellWidgets = {}

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
    -- Scrolls inside the border: a long description must not overflow the
    -- page onto the navigation buttons.
    f.descBox = ns.Widgets.ScrollingEdit(descFrame)

    -- Page 2: Details (the picker/sheet metadata; spell rows toggle by kind).
    local p2 = NewPage(f); f.pages[2] = p2
    y = -PAD
    Label(p2, "Type", PAD, y)
    f.typeBox = Form.TextBox(p2, CTRL_X, y, 160); y = y - ROW_H
    Label(p2, "Cost (AP)", PAD, y)
    f.apStepper = ns.Widgets.Stepper(p2, 96)
    f.apStepper:SetPoint("TOPLEFT", CTRL_X + 6, y + 1); y = y - ROW_H
    Label(p2, "Cost (Mana)", PAD, y)
    f.manaStepper = ns.Widgets.Stepper(p2, 96)
    f.manaStepper:SetPoint("TOPLEFT", CTRL_X + 6, y + 1); y = y - ROW_H
    Label(p2, "Range", PAD, y)
    f.rangeBox = Form.TextBox(p2, CTRL_X, y, 160); y = y - ROW_H
    Label(p2, "Save", PAD, y)
    f.saveBtn = FieldButton(p2, CTRL_X, y, 120); y = y - ROW_H
    Label(p2, "Check", PAD, y)
    f.checkBtn = FieldButton(p2, CTRL_X, y, 160); y = y - ROW_H

    local function spellRow(widget)
        f.spellWidgets[#f.spellWidgets + 1] = widget
        return widget
    end
    spellRow(Label(p2, "School", PAD, y))
    f.schoolBtn = spellRow(FieldButton(p2, CTRL_X, y, 160)); y = y - ROW_H
    spellRow(Label(p2, "Rank", PAD, y))
    f.rankStepper = spellRow(ns.Widgets.Stepper(p2, 96))
    f.rankStepper:SetPoint("TOPLEFT", CTRL_X + 6, y + 1); y = y - ROW_H
    spellRow(Label(p2, "Damage", PAD, y))
    f.damageBox = spellRow(Form.TextBox(p2, CTRL_X, y, 160)); y = y - ROW_H
    spellRow(Label(p2, "Concentration", PAD, y))
    f.concCheck = spellRow(CreateFrame("CheckButton", nil, p2, "UICheckButtonTemplate"))
    f.concCheck:SetSize(24, 24)
    f.concCheck:SetPoint("TOPLEFT", CTRL_X + 2, y + 4)

    f.detailHint = p2:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.detailHint:SetPoint("BOTTOMLEFT", PAD, PAD)
    f.detailHint:SetPoint("RIGHT", p2, "RIGHT", -PAD, 0)
    f.detailHint:SetJustifyH("LEFT")
    f.detailHint:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    f.detailHint:SetText("Everything here is quick-reference display (pickers and sheet). "
        .. "Leave a field empty to omit it; unusual costs (HP, favors) belong in the description. "
        .. "A check makes the sheet row roll it on click.")

    -- Page 3: Effects (rows are pooled and laid out on refresh).
    local p3 = NewPage(f); f.pages[3] = p3
    f.addBtn = CreateFrame("Button", nil, p3, "UIPanelButtonTemplate")
    f.addBtn:SetSize(110, 20)
    f.addBtn:SetText("+ Add effect")
    f.addBtn:SetScript("OnClick", function()
        local d = f.draft
        if not d or #d.effects >= MAX_EFFECTS then return end
        d.effects[#d.effects + 1] = { type = CS.EFFECT_TYPES[1].id, value = 1 }
        Refresh(f)
    end)
    f.effectHint = p3:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.effectHint:SetPoint("BOTTOMLEFT", PAD, PAD)
    f.effectHint:SetPoint("RIGHT", p3, "RIGHT", -PAD, 0)
    f.effectHint:SetJustifyH("LEFT")
    f.effectHint:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    f.effectHint:SetText("Effects fold into the sheet's totals. An entry with none is fine - "
        .. "its text still shows on the sheet and in the pickers.")

    -- Page 4: Review.
    local p4 = NewPage(f); f.pages[4] = p4
    f.review = p4:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.review:SetPoint("TOPLEFT", PAD, -PAD)
    f.review:SetPoint("RIGHT", p4, "RIGHT", -PAD, 0)
    f.review:SetJustifyH("LEFT")

    -- Navigation.
    f.backBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.backBtn:SetSize(70, 22); f.backBtn:SetText("Back"); f.backBtn:SetPoint("BOTTOMLEFT", PAD, 12)
    f.backBtn:SetScript("OnClick", function() f.step = math.max(1, f.step - 1); Refresh(f) end)
    f.deleteBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.deleteBtn:SetSize(70, 22); f.deleteBtn:SetText(DELETE)
    f.deleteBtn:SetPoint("BOTTOMLEFT", PAD + 76, 12)
    f.deleteBtn:SetScript("OnClick", function() HomebrewUI.Delete(f.kind, f.editIndex) end)
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
    f.typeBox:SetScript("OnTextChanged", function(self, user)
        if user and f.draft then f.draft.type = self:GetText():lower() end
    end)
    f.rangeBox:SetScript("OnTextChanged", function(self, user)
        if user and f.draft then f.draft.range = self:GetText() end
    end)
    f.damageBox:SetScript("OnTextChanged", function(self, user)
        if user and f.draft then f.draft.damage = self:GetText() end
    end)
    f.levelStepper:OnStep(function(delta)
        if not f.draft then return end
        f.draft.level = math.max(1, math.min(LEVEL_CAP, f.draft.level + delta))
        Refresh(f)
    end)
    f.apStepper:OnStep(function(delta)
        if not f.draft then return end
        local v = math.max(0, math.min(VALUE_CAP, (f.draft.cost.ap or 0) + delta))
        f.draft.cost.ap = v > 0 and v or nil
        Refresh(f)
    end)
    f.manaStepper:OnStep(function(delta)
        if not f.draft then return end
        local v = math.max(0, math.min(VALUE_CAP, (f.draft.cost.mana or 0) + delta))
        f.draft.cost.mana = v > 0 and v or nil
        Refresh(f)
    end)
    f.rankStepper:OnStep(function(delta)
        if not f.draft then return end
        f.draft.rank = math.max(1, math.min(RANK_CAP, (f.draft.rank or 1) + delta))
        Refresh(f)
    end)
    f.saveBtn:SetScript("OnClick", function()
        if not f.draft then return end
        local items = { { id = NONE_ID, name = "(none)" } }
        for _, a in ipairs(ns.Widgets.AttrItems(ns.GetSystem())) do items[#items + 1] = a end
        ns.Dialogs.Pick({
            title = "Saving Throw", prompt = "Which save does this force?",
            items = items, max = 1, selected = { f.draft.save or NONE_ID },
            onConfirm = function(ids)
                if not f.draft then return end
                f.draft.save = (ids[1] and ids[1] ~= NONE_ID) and ids[1] or nil
                Refresh(f)
            end,
        })
    end)
    -- The check picker offers every attribute and skill in one list; the two
    -- are distinguished by an id prefix so a skill named like an attribute
    -- cannot collide.
    f.checkBtn:SetScript("OnClick", function()
        if not f.draft then return end
        local system = ns.GetSystem()
        local items = { { id = NONE_ID, name = "(none)" } }
        for _, a in ipairs(ns.Widgets.AttrItems(system)) do
            items[#items + 1] = { id = "a:" .. a.id, name = a.name .. "  (attribute)" }
        end
        for _, s in ipairs(system.skills or {}) do
            if type(s) == "table" and s.id then
                items[#items + 1] = { id = "s:" .. s.id, name = (s.name or s.id) .. "  (skill)" }
            end
        end
        local c, sel = f.draft.check, NONE_ID
        if type(c) == "table" and c.attribute then sel = "a:" .. c.attribute
        elseif type(c) == "table" and c.skill then sel = "s:" .. c.skill end
        ns.Dialogs.Pick({
            title = "Check", prompt = "Which check does using this ability roll? "
                .. "The sheet row then rolls it on click.",
            items = items, max = 1, selected = { sel },
            onConfirm = function(ids)
                if not f.draft then return end
                local id = ids[1]
                if not id or id == NONE_ID then
                    f.draft.check = nil
                else
                    local kind, ref = id:match("^(%a):(.+)$")
                    f.draft.check = kind == "a" and { attribute = ref } or { skill = ref }
                end
                Refresh(f)
            end,
        })
    end)
    f.schoolBtn:SetScript("OnClick", function()
        if not f.draft then return end
        ns.Dialogs.Pick({
            title = "School", prompt = "Which school does this belong to?",
            items = DraftSchoolItems(), max = 1, selected = { f.draft.school or NONE_ID },
            onConfirm = function(ids)
                if not f.draft then return end
                f.draft.school = (ids[1] and ids[1] ~= NONE_ID) and ids[1] or nil
                Refresh(f)
            end,
        })
    end)
    f.concCheck:SetScript("OnClick", function(self)
        if f.draft then f.draft.concentration = self:GetChecked() and true or nil end
    end)
    UI.SetPlaceholder(f.nameBox, "Name")
    UI.SetPlaceholder(f.descBox, "The rules text, in your own words", "TOPLEFT")
    UI.SetPlaceholder(f.typeBox, "active / passive / reaction ...")
    UI.SetPlaceholder(f.rangeBox, "melee / self / 15m / touch ...")
    UI.SetPlaceholder(f.damageBox, "e.g. 2d6 shadow")

    return f
end

local function GetFrame()
    if not HomebrewUI.frame then HomebrewUI.frame = BuildFrame() end
    return HomebrewUI.frame
end

-- Opens the wizard on the active character for a kind ("feat"/"spell"). With
-- no index a fresh record is drafted; with one, that entry is deep-copied
-- into the draft, so the stored record is untouched until Save.
function HomebrewUI.Open(kind, index)
    local f = GetFrame()
    f.kind = (kind == "spell") and "spell" or "feat"
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
    local existing = index and HB.List(char, f.kind)[index]
    if type(existing) ~= "table" then existing = nil end
    f.editIndex = existing and index or nil
    f.draft = existing and Normalize(ns.DeepCopy(existing), char, f.kind) or NewDraft(char, f.kind)
    f.step = 1
    f.titleFS:SetText((f.editIndex and "Edit Homebrew " or "New Homebrew ") .. KIND_LABEL[f.kind])
    Refresh(f)
    f:Show()
end

-- Asks to delete the active character's homebrew record of a kind at index.
function HomebrewUI.Delete(kind, index)
    local char, key = ns.GetActiveCharacter()
    local rec = char and index and ns.Homebrew.List(char, kind)[index]
    if not rec then return end
    StaticPopup_Show("PARCHMENT_HOMEBREW_DELETE", KIND_LABEL[kind]:lower(), rec.name or "?",
        { key = key, kind = kind, index = index })
end
