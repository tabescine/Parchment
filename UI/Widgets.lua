-- Parchment - Widgets
--
-- Small shared UI controls and picker item-list builders used by the editor
-- and wizard. Selection inputs (dropdowns, multi-select) reuse
-- ns.Dialogs.Pick; the builders turn system records into Pick items
-- ({ id, name, tooltip? }). The only custom control is a numeric Stepper.
--
-- Reads from: ns.UI (palette), ns.FindById, ns.AttrName, ns.GetSystem,
--   ns.CharacterSheet.EffectType (at call time - Widgets loads first).
-- Exposes on ns.Widgets: .Stepper, .ScrollingEdit, .ListItems, .AttrItems,
--   .TraitItems, .RacialItems, .SaveItems, .TraitName, .CandidateSet,
--   .AttrPickText, .EffectSummary

local ADDON, ns = ...

local Widgets = {}
ns.Widgets = Widgets

-- A multi-line EditBox inside a scroll frame filling `container` (a bordered
-- frame the caller styles). Long text scrolls within the border instead of
-- overflowing it onto whatever sits below, and the view follows the cursor
-- while typing (the standard scrolling-edit pattern, hand-rolled because
-- InputScrollFrameTemplate's own cursor tracking makes typed input jump).
-- Clicking the container's empty area focuses the box. Returns the EditBox.
function Widgets.ScrollingEdit(container)
    local scroll = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -7)
    scroll:SetPoint("BOTTOMRIGHT", -26, 7)
    local e = CreateFrame("EditBox", nil, scroll)
    e:SetMultiLine(true)
    e:SetAutoFocus(false)
    e:SetFontObject(ChatFontNormal)
    local c = ns.UI.TEXT
    e:SetTextColor(c[1], c[2], c[3])
    e:SetWidth(10)
    scroll:SetScrollChild(e)
    scroll:SetScript("OnSizeChanged", function(_, w) e:SetWidth(w) end)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    e:SetScript("OnCursorChanged", function(_, _, cursorY, _, cursorH)
        local offset = scroll:GetVerticalScroll()
        local viewH = scroll:GetHeight()
        local top = -(cursorY or 0)
        if top < offset then
            scroll:SetVerticalScroll(math.max(0, top))
        elseif top + (cursorH or 0) > offset + viewH then
            scroll:SetVerticalScroll(top + (cursorH or 0) - viewH)
        end
    end)
    container:EnableMouse(true)
    container:SetScript("OnMouseDown", function() e:SetFocus() end)
    return e
end

-- Picker item-list builders, shared by the editor and wizard.

-- Records as plain items (skills, weapons, ...).
function Widgets.ListItems(list)
    local out = {}
    for _, r in ipairs(list or {}) do out[#out + 1] = { id = r.id, name = r.name } end
    return out
end

-- Attributes, optionally filtered to an { id = true } allow-set.
function Widgets.AttrItems(system, allow)
    local out = {}
    for _, a in ipairs(system.attributes or {}) do
        if not allow or allow[a.id] then out[#out + 1] = { id = a.id, name = a.name } end
    end
    return out
end

-- Trait records, with the description as a hover tooltip.
function Widgets.TraitItems(list)
    local out = {}
    for _, r in ipairs(list or {}) do
        out[#out + 1] = { id = r.id, name = r.name, tooltip = r.description }
    end
    return out
end

-- Racial traits available to a race, plus a "(none)" entry; descriptions as
-- tooltips. A trait with allowed_races is limited to those races, one without
-- is open to every race, and disallowed_races excludes races ("any but X").
-- No race name means anything to the engine - all are system data.
function Widgets.RacialItems(system, race)
    local out = { { id = "__none", name = "(none)" } }
    for _, t in ipairs(system.racial_traits or {}) do
        local ok = true
        if t.allowed_races and #t.allowed_races > 0 then
            ok = false
            for _, r in ipairs(t.allowed_races) do
                if r == race then ok = true end
            end
        end
        for _, r in ipairs(t.disallowed_races or {}) do
            if r == race then ok = false end
        end
        if ok then out[#out + 1] = { id = t.id, name = t.name, tooltip = t.description } end
    end
    return out
end

-- Attribute saves as items, marking and describing the primary save.
function Widgets.SaveItems(system, primary)
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

-- Display name of a trait id in a system list ("racial_traits"/"origin_traits").
function Widgets.TraitName(system, listKey, id)
    local t = ns.FindById(system[listKey], id)
    return t and t.name or id
end

-- The { id = true } allow-set for a derived_stats candidate list
-- (ac_attributes / init_attributes), or nil when absent (= no restriction).
function Widgets.CandidateSet(list)
    if not (list and #list > 0) then return nil end
    local set = {}
    for _, id in ipairs(list) do set[id] = true end
    return set
end

-- Button text for an AC/initiative attribute: the explicit pick, or the
-- sheet's effective attribute tagged "(auto)" when the system's candidate
-- list decides (no pick = best candidate wins).
function Widgets.AttrPickText(pick, effective)
    if pick then return ns.AttrName(pick) end
    return ns.AttrName(effective) .. " |cff9e998c(auto)|r"
end

-- One line describing an effect record from the shared vocabulary ("Saving
-- throw: Alpha +1", "Armor Class +2"), with targets resolved against the
-- loaded system's names (raw ids when it does not define them - item effects
-- can arrive on a sheet authored under another system). Shared by the item
-- wizard, the library rows and the sheet's inventory tooltips.
function Widgets.EffectSummary(e)
    if type(e) ~= "table" then return "?" end
    local spec = ns.CharacterSheet.EffectType(e.type)
    -- An unknown type is echoed back so the player can see what an import
    -- carried; it is wire text, so it is sanitized and capped first.
    if not spec then return ns.SafeText(e.type) .. " (not applied)" end

    -- The target's display name, by target family.
    local text = spec.label
    if spec.target == "attribute" then
        text = text .. ": " .. ns.AttrName(e[spec.target_key] or "?")
    elseif spec.target == "skill" then
        local id = e.skill or e.id
        local rec = ns.FindById(ns.GetSystem().skills, id)
        text = text .. ": " .. tostring(rec and rec.name or id or "?")
    elseif spec.target == "school" and e.school then
        local name = tostring(e.school)
        for _, s in ipairs(ns.GetSystem().spell_schools or {}) do
            if (type(s) == "table" and s.id or s) == e.school then
                name = (type(s) == "table" and s.name) or tostring(s)
            end
        end
        text = text .. ": " .. name
    end

    -- The numbers: accomplishment grants are on/off, everything else signed.
    if spec.id ~= "accomplish_skill" then
        text = text .. "  " .. ns.UI.Signed(tonumber(e.value) or 0)
        if e.per_level then text = text .. " per level" end
        if e.add_modifier then
            text = text .. "  and " .. ns.AttrName(e.add_modifier) .. " modifier"
        end
    end
    return text
end

-- A stepper click's signed delta: 5 while Shift is held, so allocating an
-- attribute is not ten clicks. IsShiftKeyDown is guarded - the pure-Lua tests
-- have no WoW API.
local function StepDelta(sign)
    return sign * ((IsShiftKeyDown and IsShiftKeyDown()) and 5 or 1)
end

-- Hover tooltip on a stepper button, documenting the Shift step.
local function StepTip(btn, text)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1)
        GameTooltip:AddLine("Shift: steps by 5.", 0.85, 0.82, 0.75)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", GameTooltip_Hide)
end

-- Creates a [-] value [+] stepper. Call f:OnStep(fn) where fn(delta) applies the
-- change, and f:SetText(text) to display the current value. Holding Shift steps
-- by 5 - every caller clamps its own range, so a coarse step cannot overshoot it.
function Widgets.Stepper(parent, width)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width or 96, 22)

    local minus = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    minus:SetSize(22, 20)
    minus:SetText("-")
    minus:SetPoint("LEFT")

    local plus = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    plus:SetSize(22, 20)
    plus:SetText("+")
    plus:SetPoint("RIGHT")

    local val = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    val:SetPoint("LEFT", minus, "RIGHT", 2, 0)
    val:SetPoint("RIGHT", plus, "LEFT", -2, 0)
    val:SetJustifyH("CENTER")
    f.val = val

    StepTip(minus, "Decrease")
    StepTip(plus, "Increase")

    function f:SetText(t) val:SetText(t) end
    function f:OnStep(fn)
        minus:SetScript("OnClick", function() fn(StepDelta(-1)) end)
        plus:SetScript("OnClick", function() fn(StepDelta(1)) end)
    end
    return f
end
