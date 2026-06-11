-- Parchment - Widgets
--
-- Small shared UI controls and picker item-list builders used by the editor
-- and wizard. Selection inputs (dropdowns, multi-select) reuse
-- ns.Dialogs.Pick; the builders turn system records into Pick items
-- ({ id, name, tooltip? }). The only custom control is a numeric Stepper.
--
-- Reads from: ns.UI (palette), ns.FindById.
-- Exposes on ns.Widgets: .Stepper, .ListItems, .AttrItems, .TraitItems,
--   .RacialItems, .SaveItems, .TraitName

local ADDON, ns = ...

local UI = ns.UI
local Widgets = {}
ns.Widgets = Widgets

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

-- Creates a [-] value [+] stepper. Call f:OnStep(fn) where fn(delta) applies the
-- change, and f:SetText(text) to display the current value.
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

    function f:SetText(t) val:SetText(t) end
    function f:OnStep(fn)
        minus:SetScript("OnClick", function() fn(-1) end)
        plus:SetScript("OnClick", function() fn(1) end)
    end
    return f
end
