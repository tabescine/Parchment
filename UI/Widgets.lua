-- Parchment - Widgets
--
-- Small shared UI controls used by the editor and wizard. Selection inputs
-- (dropdowns, multi-select) reuse ns.Dialogs.Pick, so the only custom control
-- here is a numeric Stepper.
--
-- Reads from: ns.UI (palette).
-- Exposes on ns.Widgets: .Stepper

local ADDON, ns = ...

local UI = ns.UI
local Widgets = {}
ns.Widgets = Widgets

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
