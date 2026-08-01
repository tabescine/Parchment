-- Phase 6: the shared editor/wizard form. WirePickers and FillCommon operate on
-- widgets passed in (no CreateFrame), so they unit-test directly with stubs -
-- the point being that one tested implementation now backs both windows.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")

local ns = {}
T.load(ns, "UI/Window.lua")          -- ns.UI: Signed, RebuildableFrame, palette
local UI = ns.UI

-- ns.UI.RebuildableFrame: build once, reuse while the signature is stable,
-- rebuild (hiding + orphaning the stale frame) when it changes.
do
    local holder, built, sig = {}, 0, "A"
    local function builder()
        built = built + 1
        return { hidden = false, Hide = function(s) s.hidden = true end, SetParent = function() end }
    end
    local function sigfn() return sig end

    local f1 = UI.RebuildableFrame(holder, builder, sigfn)
    assert(built == 1 and holder.frame == f1 and f1.attrSignature == "A")
    local f2 = UI.RebuildableFrame(holder, builder, sigfn)
    assert(built == 1 and f2 == f1, "same signature must reuse the frame")
    sig = "B"
    local f3 = UI.RebuildableFrame(holder, builder, sigfn)
    assert(built == 2 and f3 ~= f1, "a changed signature must rebuild")
    assert(f1.hidden and holder.frame == f3, "the stale frame must be hidden and replaced")
end

-- Stub the logic layers the form drives, so we test the form's wiring/fill, not
-- CharacterEditor or Widgets internals.
local lastPick
ns.Dialogs = { Pick = function(opts) lastPick = opts end }
ns.Print = function() end
ns.AttrName = function(id) return "Attr(" .. tostring(id) .. ")" end
ns.DerivedConfig = function() return { ac_attributes = nil, init_attributes = nil } end
ns.GetSystem = function()
    return {
        attributes = { { id = "str", name = "Strength" } },
        skills = { { id = "s1", name = "Stealth" }, { id = "s2", name = "Lore" } },
        weapons = { { id = "w1", name = "Sword" } },
        origin_traits = {}, racial_traits = {},
    }
end
ns.Widgets = {
    Stepper = function() end,
    ListItems = function(list)
        local o = {}
        for _, r in ipairs(list or {}) do o[#o + 1] = { id = r.id, name = r.name } end
        return o
    end,
    AttrItems = function() return { { id = "str", name = "Strength" } } end,
    TraitItems = function() return {} end,
    RacialItems = function() return {} end,
    SaveItems = function() return {} end,
    CandidateSet = function() return nil end,
    TraitName = function(_, kind, id) return kind .. ":" .. id end,
    AttrPickText = function(sel, derived) return sel or derived or "?" end,
}
ns.CharacterEditor = {
    Races = function() return { "Human", "Elf" } end,
    AttributePoints = function() return 3, 5 end,
    AccomplishTargets = function() return { skills = 2, weapons = 1, saves = 1 } end,
}
T.load(ns, "UI/CharacterForm.lua")
local Form = ns.CharacterForm

-- A minimal stub widget: records the last text and any wired scripts.
local function widget()
    local w = {}
    function w:SetText(t) self.text = t end
    function w:GetText() return self.text or "" end
    function w:SetScript(ev, fn) self.scripts = self.scripts or {}; self.scripts[ev] = fn end
    function w:HasFocus() return false end
    function w:SetTextColor() end
    return w
end

local BTNS = { "raceBtn", "racialBtn", "originBtn", "primaryBtn", "acBtn",
    "initBtn", "castBtn", "skillsBtn", "weaponsBtn", "savesBtn" }
local function formFrame()
    local f = { steppers = { str = widget() }, modText = { str = widget() } }
    for _, name in ipairs({ "nameBox", "playerBox", "quoteBox", "pointsText" }) do f[name] = widget() end
    for _, name in ipairs(BTNS) do f[name] = widget() end
    return f
end

-- WirePickers: each button gets an OnClick; clicking opens a Pick, and confirming
-- writes the chosen id into the live target and calls after().
do
    local target = { race = "", accomplished_skills = {} }
    local afterCount = 0
    local f = formFrame()
    Form.WirePickers(f, function() return target end, function() afterCount = afterCount + 1 end)
    for _, name in ipairs(BTNS) do
        assert(f[name].scripts and f[name].scripts.OnClick, name .. " was not wired")
    end

    -- Race: builds items from CE.Races, applies the chosen id, refreshes.
    f.raceBtn.scripts.OnClick()
    assert(lastPick and #lastPick.items == 2 and lastPick.items[1].id == "Human")
    lastPick.onConfirm({ "Elf" })
    assert(target.race == "Elf" and afterCount == 1, "race pick must apply and refresh")

    -- Racial trait: "__none" maps back to nil (the no-selection sentinel).
    f.racialBtn.scripts.OnClick()
    lastPick.onConfirm({ "rt9" })
    assert(target.racial_trait == "rt9")
    f.racialBtn.scripts.OnClick()
    lastPick.onConfirm({ "__none" })
    assert(target.racial_trait == nil, "__none must clear the racial trait")

    -- Skills: the whole id list is stored.
    f.skillsBtn.scripts.OnClick()
    lastPick.onConfirm({ "s1", "s2" })
    assert(#target.accomplished_skills == 2 and target.accomplished_skills[2] == "s2")

    -- Guard: when the target is gone (picker open across a cancel), clicking is
    -- inert - no Pick, no apply, no refresh.
    local before, gone = afterCount, formFrame()
    Form.WirePickers(gone, function() return nil end, function() afterCount = afterCount + 1 end)
    lastPick = nil
    gone.raceBtn.scripts.OnClick()
    assert(lastPick == nil and afterCount == before, "a nil target must make pickers inert")
end

-- FillCommon: fills the shared widgets from the target + computed sheet.
do
    local target = {
        name = "Bob", player = "P", quote = "Q", race = "Human",
        attributes = { str = 7 }, racial_trait = "rt1", origin_traits = { "o1" },
        primary_attribute = "str", ac_attribute = "agi", init_attribute = "agi",
        accomplished_skills = { "s1" }, accomplished_weapons = {}, accomplished_saves = { "sv1" },
    }
    local system = { attributes = { { id = "str", name = "Strength" } } }
    local sheet = {
        attributes = { { id = "str", modifier = 2, bonus = 1, final = 8 } },
        derived = { ac_attribute = "agi", init_attribute = "agi" },
    }
    local f = formFrame()
    local origins, tg = Form.FillCommon(f, target, system, sheet, true)

    assert(f.nameBox.text == "Bob" and f.playerBox.text == "P" and f.quoteBox.text == "Q")
    assert(f.raceBtn.text == "Human")
    assert(f.steppers.str.text == "7")
    assert(f.modText.str.text == "|cff9e998cmod|r +2   |cff9e998ctotal|r 8", f.modText.str.text)
    assert(f.pointsText.text == "Attribute points: 3 / 5")
    assert(f.racialBtn.text == "racial_traits:rt1")
    assert(f.originBtn.text == "origin_traits:o1")
    assert(f.primaryBtn.text == "Attr(str)")
    assert(f.acBtn.text == "agi" and f.initBtn.text == "agi")
    assert(f.castBtn.text == "(none)", "no cast attribute reads as (none)")
    assert(f.skillsBtn.text == "1 / 2" and f.weaponsBtn.text == "0 / 1" and f.savesBtn.text == "1 / 1")
    assert(origins[1] == "origin_traits:o1" and tg.skills == 2)

    -- showTotal=false (the wizard) omits the trait-adjusted total.
    local f2 = formFrame()
    Form.FillCommon(f2, target, system, sheet, false)
    assert(f2.modText.str.text == "|cff9e998cmod|r +2", f2.modText.str.text)
end
