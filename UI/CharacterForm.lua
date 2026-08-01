-- Parchment - Character Form (shared editor/wizard form)
--
-- The editor (active character) and the wizard (a draft) render the same
-- character form: the same labelled fields, attribute steppers, trait/proficiency
-- pickers, and value fill. This module owns that shared form so a fix or a
-- schema change lands once instead of being copied into both windows.
--
-- Both windows drive it through a target accessor: `get()` returns the table
-- being edited (the editor's f.char or the wizard's f.draft, which can change or
-- vanish under a non-modal picker), and `after()` is each window's post-apply
-- refresh. Layout differs only in a couple of constants, passed per call.
--
-- Reads from: ns.UI, ns.Widgets, ns.CharacterEditor, ns.Dialogs, ns.GetSystem,
--   ns.DerivedConfig, ns.AttrName, ns.Print.
-- Exposes on ns.CharacterForm: Label, FieldButton, TextBox, BuildAttributeRows,
--   AttrSignature, WirePickers, FillCommon.

local ADDON, ns = ...

local UI = ns.UI
local W = ns.Widgets
local CE = ns.CharacterEditor
local Signed = UI.Signed

local Form = {}
ns.CharacterForm = Form

-- Widget builders. Each window keeps a tiny wrapper that binds its own control
-- column (ctrlX), so the call sites stay unchanged while the body lives here.

-- A static field label at (x, y).
function Form.Label(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
    fs:SetText(text)
    return fs
end

-- A picker button in the control column. The label is clipped to the button so a
-- long value (e.g. two origin traits) does not spill outside it.
function Form.FieldButton(parent, ctrlX, y, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 200, 20)
    b:SetPoint("TOPLEFT", ctrlX, y + 1)
    local fs = b:GetFontString()
    if fs then fs:SetWidth((width or 200) - 12); fs:SetWordWrap(false) end
    return b
end

-- A single-line text input in the control column.
function Form.TextBox(parent, ctrlX, y, width)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width or 200, 20)
    e:SetPoint("TOPLEFT", ctrlX + 6, y)
    e:SetAutoFocus(false)
    e:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
    e:SetScript("OnEscapePressed", e.ClearFocus)
    return e
end

-- Lays out one stepper + modifier label per attribute into `parent`, populating
-- f.steppers and f.modText. Returns the y after the last row.
function Form.BuildAttributeRows(f, parent, system, labelX, ctrlX, y, rowH)
    f.steppers, f.modText = {}, {}
    for _, attr in ipairs(system.attributes or {}) do
        Form.Label(parent, attr.name, labelX, y)
        local st = W.Stepper(parent, 96)
        st:SetPoint("TOPLEFT", ctrlX, y + 1)
        f.steppers[attr.id] = st
        local m = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        m:SetPoint("TOPLEFT", ctrlX + 104, y)
        m:SetTextColor(UI.HEAD[1], UI.HEAD[2], UI.HEAD[3])
        f.modText[attr.id] = m
        y = y - rowH
    end
    return y
end

-- The attribute-set signature: a frame is laid out from the system loaded at
-- build time, so a change in the attribute set means the frame must be rebuilt
-- (see ns.UI.RebuildableFrame). Names are part of the signature - reimporting
-- a system that renames attributes (same ids) must also refresh the row labels.
function Form.AttrSignature()
    local ids = {}
    for _, a in ipairs(ns.GetSystem().attributes or {}) do
        ids[#ids + 1] = tostring(a.id) .. "\30" .. tostring(a.name)
    end
    return table.concat(ids, "\31")
end

-- Wires the trait/proficiency/race pickers on f's buttons. get() returns the
-- live target table (re-read at click AND apply time, since ns.Dialogs.Pick is
-- not modal); after() is the post-apply refresh. Identical for both windows
-- apart from those two callbacks - that identity is the whole point.
function Form.WirePickers(f, get, after)
    local function Pick(title, prompt, items, max, selected, apply)
        ns.Dialogs.Pick({
            title = title, prompt = prompt, items = items, max = max, selected = selected,
            onConfirm = function(ids) apply(ids); after() end,
        })
    end

    f.raceBtn:SetScript("OnClick", function()
        local t = get(); if not t then return end
        local items = {}
        for _, r in ipairs(CE.Races(ns.GetSystem())) do items[#items + 1] = { id = r, name = r } end
        if #items == 0 then
            ns.Print("the loaded system defines no races - add a top-level `races` list"
                .. " or race lists on its racial traits.")
            return
        end
        Pick("Race", "Choose a race", items, 1, { t.race },
            function(ids) local tt = get(); if tt then tt.race = ids[1] end end)
    end)
    f.racialBtn:SetScript("OnClick", function()
        local t = get(); if not t then return end
        Pick("Racial Trait", "Choose a racial trait (hover for details)",
            W.RacialItems(ns.GetSystem(), t.race), 1, { t.racial_trait },
            function(ids)
                local tt = get()
                if tt then tt.racial_trait = (ids[1] ~= "__none") and ids[1] or nil end
            end)
    end)
    f.originBtn:SetScript("OnClick", function()
        local t = get(); if not t then return end
        Pick("Origin Traits", "Choose up to two (hover for details)",
            W.TraitItems(ns.GetSystem().origin_traits), 2, t.origin_traits,
            function(ids) local tt = get(); if tt then tt.origin_traits = ids end end)
    end)
    f.primaryBtn:SetScript("OnClick", function()
        local t = get(); if not t then return end
        Pick("Primary Attribute", "Choose the primary attribute", W.AttrItems(ns.GetSystem()), 1,
            { t.primary_attribute },
            function(ids) local tt = get(); if tt then tt.primary_attribute = ids[1] end end)
    end)
    -- AC/init pickers are restricted to the system's candidate lists when
    -- declared (e.g. "Agility, Sense or Luck"); without one, any attribute.
    f.acBtn:SetScript("OnClick", function()
        local t = get(); if not t then return end
        local allow = W.CandidateSet(ns.DerivedConfig().ac_attributes)
        Pick("AC Attribute", "Choose the attribute that governs AC",
            W.AttrItems(ns.GetSystem(), allow), 1, { t.ac_attribute },
            function(ids) local tt = get(); if tt then tt.ac_attribute = ids[1] end end)
    end)
    f.initBtn:SetScript("OnClick", function()
        local t = get(); if not t then return end
        local allow = W.CandidateSet(ns.DerivedConfig().init_attributes)
        Pick("Initiative Attribute", "Choose the attribute that governs initiative",
            W.AttrItems(ns.GetSystem(), allow), 1, { t.init_attribute },
            function(ids) local tt = get(); if tt then tt.init_attribute = ids[1] end end)
    end)
    -- Cast attribute: restricted to the active spell pack's candidates when
    -- one declares them; without a pack, any attribute. "(none)" clears the
    -- pick - the character then casts by the classic primary-attribute rule.
    f.castBtn:SetScript("OnClick", function()
        local t = get(); if not t then return end
        local pack = ns.GetSpellPack()
        local allow = W.CandidateSet(pack and pack.cast_attributes or nil)
        local items = { { id = "__none", name = "(none)" } }
        for _, it in ipairs(W.AttrItems(ns.GetSystem(), allow)) do items[#items + 1] = it end
        Pick("Cast Attribute", "Choose the spellcasting attribute", items, 1,
            { t.cast_attribute or "__none" },
            function(ids)
                local tt = get()
                if tt then tt.cast_attribute = (ids[1] ~= "__none") and ids[1] or nil end
            end)
    end)
    f.skillsBtn:SetScript("OnClick", function()
        local t = get(); if not t then return end
        local items = W.ListItems(ns.GetSystem().skills)
        Pick("Accomplished Skills", "Mark accomplished skills", items, #items,
            t.accomplished_skills,
            function(ids) local tt = get(); if tt then tt.accomplished_skills = ids end end)
    end)
    f.weaponsBtn:SetScript("OnClick", function()
        local t = get(); if not t then return end
        local items = W.ListItems(ns.GetSystem().weapons)
        Pick("Accomplished Weapons", "Mark accomplished weapons", items, #items,
            t.accomplished_weapons,
            function(ids) local tt = get(); if tt then tt.accomplished_weapons = ids end end)
    end)
    f.savesBtn:SetScript("OnClick", function()
        local t = get(); if not t then return end
        Pick("Accomplished Saves", "Primary save is auto; choose one more",
            W.SaveItems(ns.GetSystem(), t.primary_attribute),
            #(ns.GetSystem().attributes or {}), t.accomplished_saves,
            function(ids) local tt = get(); if tt then tt.accomplished_saves = ids end end)
    end)
end

-- Fills the shared widgets from `target` and its computed `sheet`. showTotal adds
-- the trait-adjusted total beside a modifier (the editor shows it; the wizard
-- does not). Returns the origin-trait display names and the accomplish targets,
-- which the wizard reuses for its review/hint without recomputing.
function Form.FillCommon(f, target, system, sheet, showTotal)
    local function setBox(box, v) if not box:HasFocus() then box:SetText(v or "") end end
    setBox(f.nameBox, target.name)
    setBox(f.playerBox, target.player)
    setBox(f.quoteBox, target.quote)
    f.raceBtn:SetText((target.race and target.race ~= "") and target.race or "(choose)")

    local modById = {}
    for _, a in ipairs(sheet.attributes) do modById[a.id] = a end
    for _, attr in ipairs(system.attributes or {}) do
        local st = f.steppers[attr.id]
        if st then
            st:SetText(tostring((target.attributes or {})[attr.id] or 1))
            local a = modById[attr.id]
            local total = (showTotal and a and a.bonus ~= 0)
                and ("   |cff9e998ctotal|r " .. a.final) or ""
            f.modText[attr.id]:SetText(a and ("|cff9e998cmod|r " .. Signed(a.modifier) .. total) or "")
        end
    end

    local used, avail = CE.AttributePoints(target, system)
    local pc = (used == avail) and UI.GREEN or (used > avail and UI.RED or UI.HEAD)
    f.pointsText:SetTextColor(pc[1], pc[2], pc[3])
    f.pointsText:SetText(string.format("Attribute points: %d / %d", used, avail))

    f.racialBtn:SetText(target.racial_trait
        and W.TraitName(system, "racial_traits", target.racial_trait) or "(none)")
    local origins = {}
    for _, id in ipairs(target.origin_traits or {}) do
        origins[#origins + 1] = W.TraitName(system, "origin_traits", id)
    end
    f.originBtn:SetText(#origins > 0 and table.concat(origins, ", ") or "(none)")
    f.primaryBtn:SetText(ns.AttrName(target.primary_attribute))
    f.acBtn:SetText(W.AttrPickText(target.ac_attribute, sheet.derived.ac_attribute))
    f.initBtn:SetText(W.AttrPickText(target.init_attribute, sheet.derived.init_attribute))
    f.castBtn:SetText(target.cast_attribute and ns.AttrName(target.cast_attribute) or "(none)")

    local tg = CE.AccomplishTargets(sheet)
    f.skillsBtn:SetText(string.format("%d / %d", #(target.accomplished_skills or {}), tg.skills))
    f.weaponsBtn:SetText(string.format("%d / %d", #(target.accomplished_weapons or {}), tg.weapons))
    f.savesBtn:SetText(string.format("%d / %d", #(target.accomplished_saves or {}), tg.saves))
    return origins, tg
end
