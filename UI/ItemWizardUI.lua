-- Parchment - Item Wizard and Library panel (UI)
--
-- The two faces of the item library: a stepped creator window (Kind -> Details
-- -> Review) that writes one library item, and the hub's Items panel listing
-- what the library holds. A panel row follows the addon's click grammar: left
-- reads the item in the link viewer, shift links it in chat, right opens its
-- actions (edit, give, duplicate, delete) as a context menu. The Give/Copy/X
-- buttons stay on the row as visible affordances for the same flows. The
-- wizard is a singleton built on ns.UI.CreateWindow; the browser is a panel
-- registered with ns.HubUI and has no window of its own. The panel's New item
-- button toggles a type picker (one card per kind) that opens the wizard
-- already on the chosen kind.
--
-- The library is global and system-independent, so equipment and gear can be
-- authored with no system loaded at all; only a weapon item's optional link to
-- a system weapon needs one, and without it the item is simply a display item.
-- No character is needed either - only the step that hands an item to one. That
-- is the sheet's add flow: pick a library item of a kind (or "(new item...)",
-- which opens the wizard), instantiate it via ns.Items.Instantiate and append it
-- to char.inventory.
--
-- Inventories hold references, so editing an item here updates every character
-- carrying it on the next render, and deleting one leaves those rows showing as
-- missing. The confirmations say so - it is the feature, not a caveat.
--
-- Reads from: ns.UI, ns.HubUI, ns.Widgets, ns.CharacterForm, ns.Dialogs,
--   ns.Items, ns.ChatLinks, ns.ChatLinkUI,
--   ns.Schema.ValidateItem, the item library API (ns.GetItemLibrary,
--   ns.GetItem, ns.SetItem, ns.DeleteItem, ns.NextItemKey), ns.GetSystem,
--   ns.FindById, ns.GetActiveCharacter, ns.GetCharacter, ns.SetCharacter,
--   ns.DeepCopy, ns.Systems.RefreshAll, ns.Print.
-- Exposes on ns.ItemWizardUI: Open(id, kind, charKey), AddFlow(kind),
--   AddToCharacter(item, charKey), ConfirmDelete(id), Duplicate(id),
--   OpenBrowser, ToggleBrowser (both route to the hub's Items panel),
--   RefreshIfShown, and .frame (the wizard).
-- Registers the hub's "items" panel and the "items" module opener with Core.

local ADDON, ns = ...

local UI = ns.UI
local Form = ns.CharacterForm

local PAD, ROW_H, CTRL_X = 16, 26, 110
local STEPS = { "Kind", "Details", "Review" }
local BONUS_CAP = 99
local ROW_BROWSE_H = 30

-- Picker ids for the two synthetic entries: no linked weapon, and "author a new
-- item" at the top of the add flow's list.
local NONE_ID = "__none"
local NEW_ID = "__new"

-- The item kinds, in the order the first step offers them. `hint` is what the
-- kind means mechanically - the wizard is where a player learns that a weapon
-- item's bonus needs a linked weapon to land on.
local KINDS = {
    { id = "weapon", label = "Weapon",
      hint = "Carried and wielded. Its bonus adds to the attack rolls of the system weapon"
          .. " you link it to." },
    { id = "equipment", label = "Equipment",
      hint = "Worn. Its AC bonus counts while equipped, and pieces stack." },
    { id = "gear", label = "Gear",
      hint = "Everything else: counted rather than equipped (rope, rations, a lantern)." },
}
local KIND_LABEL = { weapon = "Weapon", equipment = "Equipment", gear = "Gear" }

-- A few icons per kind, offered as click-to-fill swatches beside the icon field
-- (a full icon browser is a window of its own; the field takes any texture name).
local ICON_PATH = "Interface\\Icons\\"
local ICON_UNKNOWN = ICON_PATH .. "INV_Misc_QuestionMark"
local ICON_SUGGESTIONS = {
    weapon = { "INV_Sword_04", "INV_Weapon_Bow_07", "INV_Staff_13" },
    equipment = { "INV_Chest_Chain", "INV_Shield_04", "INV_Helmet_03" },
    gear = { "INV_Misc_Bag_08", "INV_Misc_Rope_01", "INV_Drink_05" },
}

-- The panel's kind filter, cycled by one button.
local FILTERS = {
    { label = "All" },
    { label = "Weapons", kind = "weapon" },
    { label = "Equipment", kind = "equipment" },
    { label = "Gear", kind = "gear" },
}

-- The panel keeps one header line: the row gestures normally, a filter warning
-- while nothing matches. The two never apply at once, and the hub body is too
-- narrow to spend a second line on.
local BROWSE_HINT = "Click an item to read it, shift-click to link it in chat,"
    .. " right-click for its actions."

-- Every gesture a library row carries, one green line in its tooltip: the row
-- has no visible chrome saying which button does what.
local ROW_HINTS = {
    "Click: read it in its own window",
    "Shift-click: link it in chat",
    "Right-click: actions",
    "Give / Copy / X: hand out, duplicate, delete",
}

-- The "New item" type picker: a panel of one card per kind, opening upwards
-- from the button it hangs off.
local PICK_W, PICK_PAD, CARD_H, CARD_GAP, CARD_ICON = 320, 12, 54, 4, 36
local PICK_BACKDROP = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 6, right = 6, top = 6, bottom = 6 },
}
local TEX_HOVER = "Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar"

local ItemWizardUI = {}
ns.ItemWizardUI = ItemWizardUI

local Refresh

local Label = Form.Label
local FieldButton = Form.FieldButton

-- Shared helpers.

-- The texture for a stored icon name, or the question mark when it is unset or
-- not a plain texture name (the same restriction the schema enforces, so an
-- icon can never reach into a texture path).
local function IconPath(icon)
    if type(icon) == "string" and icon:match("^[%w_%-]+$") then return ICON_PATH .. icon end
    return ICON_UNKNOWN
end

-- Display name of a linked system weapon (the raw id when the loaded system
-- does not define it - the link dangles, the item still works).
local function WeaponName(id)
    local weapon = ns.FindById(ns.GetSystem().weapons, id)
    return weapon and weapon.name or id
end

-- One line describing what an item does, shared by the review step, the panel
-- rows and their tooltips.
local function MechanicsText(item)
    if item.kind == "weapon" then
        local bonus = UI.Signed(tonumber(item.bonus) or 0)
        return item.weapon_id and (bonus .. " to " .. WeaponName(item.weapon_id) .. " attack rolls")
            or (bonus .. " attack (no weapon linked)")
    elseif item.kind == "equipment" then
        local text = UI.Signed(tonumber(item.ac_bonus) or 0) .. " AC while equipped"
        local cap = tonumber(item.ac_mod_cap)
        if cap then
            text = text .. ", caps the AC attribute modifier at " .. UI.Signed(cap)
        end
        return text
    end
    return "carried in stacks of " .. (tonumber(item.default_count) or 1)
end

-- Appends a library item to a character's inventory. Returns true when it
-- landed. The instance is thin (a reference plus per-character state), so
-- everything shown on the sheet keeps coming from the library.
function ItemWizardUI.AddToCharacter(item, charKey)
    local char = charKey and ns.GetCharacter(charKey)
    if not char then char, charKey = ns.GetActiveCharacter() end
    if not (char and charKey) then
        ns.Print("no active character to give this to - create one first.")
        return false
    end
    local entry = ns.Items.Instantiate(item)
    if not entry then return false end
    char.inventory = char.inventory or {}
    char.inventory[#char.inventory + 1] = entry
    ns.SetCharacter(charKey, char)
    ns.Print("gave '" .. (item.name or "item") .. "' to " .. (char.name or charKey) .. ".")
    ns.Systems.RefreshAll()
    return true
end

-- Draft records (the wizard edits a draft, never a stored item).

local function ClampBonus(value)
    local n = math.floor(tonumber(value) or 0)
    return math.max(-BONUS_CAP, math.min(BONUS_CAP, n))
end

-- The AC modifier cap is optional: nil means "no cap" (light armor, plain
-- clothing), so unlike ClampBonus this preserves nil instead of coercing to 0,
-- and a cap is never negative (heavy armor is cap 0).
local function ClampCap(value)
    if value == nil then return nil end
    local n = tonumber(value)
    if not n or n ~= n then return nil end
    return math.max(0, math.min(BONUS_CAP, math.floor(n)))
end

-- Coerces a draft into the shape a library item has, dropping the fields the
-- chosen kind does not own: switching kind mid-edit must not leave an AC bonus
-- on a weapon, which no page would then show and no mechanic would read. `id`
-- and `version` are dropped too - ns.SetItem stamps both on save.
local function Normalize(d)
    d.name = tostring(d.name or "")
    d.description = tostring(d.description or "")
    d.kind = KIND_LABEL[d.kind] and d.kind or "gear"
    if type(d.icon) ~= "string" or d.icon == "" then d.icon = nil end
    d.id, d.version = nil, nil
    if d.kind == "weapon" then
        d.bonus = ClampBonus(d.bonus)
        if type(d.weapon_id) ~= "string" then d.weapon_id = nil end
        d.ac_bonus, d.ac_mod_cap, d.default_count = nil, nil, nil
    elseif d.kind == "equipment" then
        d.ac_bonus = ClampBonus(d.ac_bonus)
        d.ac_mod_cap = ClampCap(d.ac_mod_cap)
        d.bonus, d.weapon_id, d.default_count = nil, nil, nil
    else
        d.default_count = ns.Items.ClampCount(d.default_count) or 1
        d.bonus, d.weapon_id, d.ac_bonus, d.ac_mod_cap = nil, nil, nil, nil
    end
    return d
end

-- Soft warnings for the review step: what the schema reports for the draft as a
-- stored record, plus the two things it cannot see (an unnamed item, a weapon
-- link the loaded system does not define). Never blocks saving.
local function Warnings(d)
    local out = {}
    if d.name == "" then out[#out + 1] = "no name" end

    local probe = ns.DeepCopy(d)
    probe.id = "draft"
    local ok, issues = ns.Schema.ValidateItem(probe)
    if not ok then
        for _, issue in ipairs(issues) do out[#out + 1] = issue end
    end

    if d.kind == "weapon" and d.weapon_id and ns.HasSystem()
        and not ns.FindById(ns.GetSystem().weapons, d.weapon_id) then
        out[#out + 1] = "links a weapon '" .. d.weapon_id
            .. "' the loaded system does not define (no attack bonus will apply)"
    end
    return out
end

-- Page fill.

local function FillKind(f, d)
    -- The chosen kind is the highlighted one, never the disabled one: a greyed
    -- button reads as "not available" rather than "selected". Clicking the kind
    -- already chosen is a harmless no-op.
    for _, b in ipairs(f.kindBtns) do
        if b.kindId == d.kind then b:LockHighlight() else b:UnlockHighlight() end
    end
    f.kindNote:SetText("Selected: |cffc8a868" .. (KIND_LABEL[d.kind] or "?") .. "|r")
end

local function FillDetails(f, d)
    if not f.nameBox:HasFocus() then f.nameBox:SetText(d.name) end
    if not f.descBox:HasFocus() then f.descBox:SetText(d.description) end
    if not f.iconBox:HasFocus() then f.iconBox:SetText(d.icon or "") end
    f.iconPreview:SetTexture(IconPath(d.icon))

    local suggestions = ICON_SUGGESTIONS[d.kind] or {}
    for i, b in ipairs(f.iconBtns) do
        local name = suggestions[i]
        b.iconName = name
        b:SetShown(name ~= nil)
        if name then b.tex:SetTexture(ICON_PATH .. name) end
    end

    -- Two kind-specific rows, filled by whichever control the kind uses.
    if d.kind == "weapon" then
        f.rowALabel:SetText("Weapon link")
        f.linkBtn:Show()
        f.linkBtn:SetText(d.weapon_id and WeaponName(d.weapon_id) or "(none)")
        f.stepperA:Hide()
        f.rowBLabel:Show()
        f.rowBLabel:SetText("Attack bonus")
        f.stepperB:Show()
        f.stepperB:SetText(UI.Signed(d.bonus or 0))
    else
        f.linkBtn:Hide()
        f.stepperA:Show()
        if d.kind == "equipment" then
            f.rowALabel:SetText("AC bonus")
            f.stepperA:SetText(UI.Signed(d.ac_bonus or 0))
            -- Row B is the optional modifier cap: "(none)" means the wearer
            -- keeps their full AC attribute modifier (light armor); 0 is heavy
            -- armor, 2/3 the usual medium-armor caps.
            f.rowBLabel:Show()
            f.rowBLabel:SetText("Modifier cap")
            f.stepperB:Show()
            f.stepperB:SetText(d.ac_mod_cap and UI.Signed(d.ac_mod_cap) or "(none)")
        else
            f.rowBLabel:Hide()
            f.stepperB:Hide()
            f.rowALabel:SetText("Count per stack")
            f.stepperA:SetText(tostring(d.default_count or 1))
        end
    end
end

local function FillReview(f, d)
    local lines = {
        "|cffc8a868" .. (d.name ~= "" and d.name or "(unnamed item)") .. "|r   -   "
            .. (KIND_LABEL[d.kind] or "?"),
        d.description ~= "" and d.description or "|cff9e998cNo description.|r",
        " ",
        MechanicsText(d),
        "Icon: " .. (d.icon or "|cff9e998c(default)|r"),
        " ",
    }
    if f.editId then
        lines[#lines + 1] = "|cff9e998cSaving updates every character carrying this item.|r"
        lines[#lines + 1] = " "
    end

    local warns = Warnings(d)
    if #warns > 0 then
        lines[#lines + 1] = "|cffe67272Warnings:|r"
        for _, w in ipairs(warns) do lines[#lines + 1] = "|cffe67272- " .. w .. "|r" end
    else
        lines[#lines + 1] = "|cff66d966No warnings. Ready to save.|r"
    end
    f.review:SetText(table.concat(lines, "\n"))
end

-- Redraws the current step. The wizard needs neither a system nor a character:
-- the library is global, and only the weapon link reads the loaded system.
Refresh = function(self)
    local d = self.draft
    if not d then return end
    Normalize(d)

    self.stepLabel:SetText("Step " .. self.step .. " of " .. #STEPS .. ":  " .. STEPS[self.step])
    for i, p in ipairs(self.pages) do p:SetShown(i == self.step) end
    self.backBtn:SetEnabled(self.step > 1)
    self.nextBtn:SetText(self.step == #STEPS and "Save" or "Next")

    FillKind(self, d)
    FillDetails(self, d)
    if self.step == #STEPS then FillReview(self, d) end
end

-- Commit.

local function Commit(self)
    local d = self.draft
    if not d then
        self:Hide()
        return
    end
    local id = self.editId or ns.NextItemKey()
    local item = ns.SetItem(id, Normalize(d))
    local charKey, editing = self.addToKey, self.editId ~= nil
    self.draft, self.editId, self.addToKey = nil, nil, nil
    self:Hide()

    ns.Print((editing and "updated item '" or "saved item '")
        .. ((item and item.name) or "?") .. "' in your library.")
    -- Handing it over refreshes on its own; otherwise the Items panel and any
    -- open sheet still need to see the new record.
    if item and charKey then
        ItemWizardUI.AddToCharacter(item, charKey)
    else
        ns.Systems.RefreshAll()
    end
end

-- Soft warnings never block saving (the review lists them), but Finishing with
-- them present is confirmed so it cannot be an accident.
StaticPopupDialogs["PARCHMENT_ITEM_WARN"] = {
    text = "This item still has %s. Save it anyway?",
    button1 = "Save", button2 = CANCEL,
    OnAccept = function(_, self) Commit(self) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Deleting an item is destructive for every character holding it (their rows go
-- missing), so it is confirmed and says as much.
StaticPopupDialogs["PARCHMENT_DELETE_ITEM"] = {
    text = "Delete the item \"%s\" from your library?\n\n"
        .. "Characters carrying it keep the entry and show it as missing until they drop it.",
    button1 = DELETE, button2 = CANCEL,
    OnAccept = function(_, data)
        if not (data and data.id) then return end
        ns.DeleteItem(data.id)
        ns.Print("deleted item '" .. (data.name or data.id) .. "' from your library.")
        -- An open draft for the deleted item would save it straight back.
        local f = ItemWizardUI.frame
        if f and f:IsShown() and f.editId == data.id then f:Hide() end
        ns.Systems.RefreshAll()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function Finish(self)
    if not self.draft then
        self:Hide()
        return
    end
    local warns = Warnings(Normalize(self.draft))
    if #warns > 0 then
        StaticPopup_Show("PARCHMENT_ITEM_WARN",
            #warns .. " warning" .. (#warns == 1 and "" or "s"), nil, self)
        return
    end
    Commit(self)
end

-- Wizard frame.

local function NewPage(f)
    local p = CreateFrame("Frame", nil, f)
    p:SetPoint("TOPLEFT", 0, -70)
    p:SetPoint("BOTTOMRIGHT", 0, 44)
    p:Hide()
    return p
end

-- One 22px icon swatch that fills the icon field when clicked.
local function IconSwatch(f, parent, x, y)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(22, 22)
    b:SetPoint("TOPLEFT", x, y)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetAllPoints()
    b:SetScript("OnClick", function(self)
        if not (f.draft and self.iconName) then return end
        f.draft.icon = self.iconName
        Refresh(f)
    end)
    b:SetScript("OnEnter", function(self)
        if not self.iconName then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.iconName, 1, 1, 1)
        GameTooltip:AddLine("Click: use this icon", 0.56, 0.78, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    return b
end

local function BuildKindPage(f)
    local p = NewPage(f)
    f.pages[1] = p

    local intro = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", PAD, -PAD)
    intro:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
    intro:SetJustifyH("LEFT")
    intro:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    intro:SetText("What kind of item is this? The kind decides what it does on a sheet.")

    f.kindBtns = {}
    local y = -PAD - 26
    for _, kind in ipairs(KINDS) do
        local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
        b:SetSize(100, 22)
        b:SetPoint("TOPLEFT", PAD, y)
        b:SetText(kind.label)
        b.kindId = kind.id
        b:SetScript("OnClick", function()
            if not f.draft then return end
            f.draft.kind = kind.id
            Refresh(f)
        end)
        local hint = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        hint:SetPoint("TOPLEFT", PAD + 110, y - 2)
        hint:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
        hint:SetJustifyH("LEFT")
        hint:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
        hint:SetText(kind.hint)
        f.kindBtns[#f.kindBtns + 1] = b
        y = y - 46
    end

    f.kindNote = p:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.kindNote:SetPoint("TOPLEFT", PAD, y - 6)
    f.kindNote:SetTextColor(UI.HEAD[1], UI.HEAD[2], UI.HEAD[3])
end

local function BuildDetailsPage(f)
    local p = NewPage(f)
    f.pages[2] = p

    local y = -PAD
    Label(p, "Name", PAD, y)
    f.nameBox = Form.TextBox(p, CTRL_X, y, 230)
    y = y - ROW_H

    -- Icon: a texture name, a live preview, and per-kind suggestions.
    Label(p, "Icon", PAD, y)
    f.iconBox = Form.TextBox(p, CTRL_X, y, 120)
    f.iconPreview = p:CreateTexture(nil, "ARTWORK")
    f.iconPreview:SetSize(32, 32)
    f.iconPreview:SetPoint("TOPLEFT", CTRL_X + 138, y + 4)
    f.iconBtns = {}
    for i = 1, 3 do
        f.iconBtns[i] = IconSwatch(f, p, CTRL_X + 180 + (i - 1) * 26, y + 4)
    end
    y = y - 40

    -- Two kind-specific rows: weapon uses both (link, bonus), the others one.
    f.rowALabel = Label(p, "", PAD, y)
    f.linkBtn = FieldButton(p, CTRL_X, y, 160)
    f.stepperA = ns.Widgets.Stepper(p, 96)
    f.stepperA:SetPoint("TOPLEFT", CTRL_X + 6, y + 1)
    y = y - ROW_H

    f.rowBLabel = Label(p, "", PAD, y)
    f.stepperB = ns.Widgets.Stepper(p, 96)
    f.stepperB:SetPoint("TOPLEFT", CTRL_X + 6, y + 1)
    y = y - ROW_H

    Label(p, "Description", PAD, y)
    y = y - 18

    -- Bordered multi-line box (the homebrew wizard's pattern: a plain EditBox, not
    -- InputScrollFrameTemplate, whose cursor tracking makes typed input jump).
    local descFrame = CreateFrame("Frame", nil, p, "BackdropTemplate")
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
end

-- Wires the details controls to the live draft (a picker is not modal, so the
-- draft is re-read at apply time rather than captured).
local function WireDetails(f)
    f.nameBox:SetScript("OnTextChanged", function(box, user)
        if user and f.draft then f.draft.name = box:GetText() end
    end)
    f.descBox:SetScript("OnTextChanged", function(box, user)
        if user and f.draft then f.draft.description = box:GetText() end
    end)
    f.iconBox:SetScript("OnTextChanged", function(box, user)
        if not (user and f.draft) then return end
        local text = box:GetText()
        f.draft.icon = text ~= "" and text or nil
        f.iconPreview:SetTexture(IconPath(f.draft.icon))
    end)

    f.linkBtn:SetScript("OnClick", function()
        if not f.draft then return end
        local items = { { id = NONE_ID, name = "(none)" } }
        for _, w in ipairs(ns.Widgets.ListItems(ns.GetSystem().weapons)) do
            items[#items + 1] = w
        end
        if #items == 1 then
            ns.Print("the loaded system defines no weapons to link - the item still works,"
                .. " it just has nothing to boost.")
            return
        end
        ns.Dialogs.Pick({
            title = "Weapon", prompt = "Whose attack rolls does this item's bonus join?",
            items = items, max = 1, selected = { f.draft.weapon_id },
            onConfirm = function(ids)
                if not f.draft then return end
                f.draft.weapon_id = (ids[1] and ids[1] ~= NONE_ID) and ids[1] or nil
                Refresh(f)
            end,
        })
    end)

    f.stepperA:OnStep(function(delta)
        local d = f.draft
        if not d then return end
        if d.kind == "equipment" then
            d.ac_bonus = ClampBonus((d.ac_bonus or 0) + delta)
        else
            d.default_count = ns.Items.ClampCount((d.default_count or 1) + delta) or 1
        end
        Refresh(f)
    end)
    f.stepperB:OnStep(function(delta)
        local d = f.draft
        if not d then return end
        if d.kind == "equipment" then
            -- The cap steps through its "off" state below zero:
            -- (none) -> +0 -> +1 -> ... and back down past 0 to (none).
            if d.ac_mod_cap == nil then
                if delta > 0 then d.ac_mod_cap = 0 end
            else
                local n = d.ac_mod_cap + delta
                d.ac_mod_cap = n < 0 and nil or math.min(BONUS_CAP, n)
            end
        else
            d.bonus = ClampBonus((d.bonus or 0) + delta)
        end
        Refresh(f)
    end)

    UI.SetPlaceholder(f.nameBox, "Item name")
    UI.SetPlaceholder(f.iconBox, "inv_misc_bag_08")
    UI.SetPlaceholder(f.descBox, "What it is, in your own words", "TOPLEFT")
end

local function BuildFrame()
    local f = UI.CreateWindow("ParchmentItemWizardFrame", {
        title = "New Item", width = 470, height = 440,
        minW = 450, minH = 380, maxW = 620, maxH = 900, dbKey = "itemWizardWindow",
    })
    f.step = 1
    f.pages = {}

    f.stepLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.stepLabel:SetPoint("TOPLEFT", PAD, -44)
    f.stepLabel:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])

    BuildKindPage(f)
    BuildDetailsPage(f)

    -- Page 3: Review.
    local p3 = NewPage(f)
    f.pages[3] = p3
    f.review = p3:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.review:SetPoint("TOPLEFT", PAD, -PAD)
    f.review:SetPoint("RIGHT", p3, "RIGHT", -PAD, 0)
    f.review:SetJustifyH("LEFT")

    -- Navigation.
    f.backBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.backBtn:SetSize(70, 22)
    f.backBtn:SetText("Back")
    f.backBtn:SetPoint("BOTTOMLEFT", PAD, 12)
    f.backBtn:SetScript("OnClick", function() f.step = math.max(1, f.step - 1); Refresh(f) end)
    f.cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.cancelBtn:SetSize(70, 22)
    f.cancelBtn:SetText(CANCEL)
    f.cancelBtn:SetPoint("BOTTOM", 0, 12)
    f.cancelBtn:SetScript("OnClick", function() f:Hide() end)
    f.nextBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.nextBtn:SetSize(70, 22)
    f.nextBtn:SetText("Next")
    f.nextBtn:SetPoint("BOTTOMRIGHT", -PAD, 12)
    f.nextBtn:SetScript("OnClick", function()
        if f.step < #STEPS then f.step = f.step + 1; Refresh(f) else Finish(f) end
    end)

    WireDetails(f)
    return f
end

local function GetFrame()
    if not ItemWizardUI.frame then ItemWizardUI.frame = BuildFrame() end
    return ItemWizardUI.frame
end

-- Opens the wizard.
--
-- id      - a library id to edit (deep-copied into the draft, so the stored
--           item is untouched until Save); nil drafts a new item
-- kind    - the kind a new draft starts on (default "gear")
-- charKey - when set, saving also hands the item to that character (the sheet's
--           add flow); nil authors library-only
function ItemWizardUI.Open(id, kind, charKey)
    local f = GetFrame()
    local existing = id and ns.GetItemLibrary()[id]
    if type(existing) ~= "table" then existing = nil end

    f.editId = existing and id or nil
    f.addToKey = charKey
    f.draft = Normalize(existing and ns.DeepCopy(existing)
        or { name = "", kind = kind or "gear", description = "" })
    f.step = existing and 2 or 1     -- editing starts where the fields are
    f.titleFS:SetText(existing and "Edit Item" or "New Item")
    Refresh(f)
    f:Show()
    f:Raise()
end

-- Asks to delete a library item (used by the panel's rows).
function ItemWizardUI.ConfirmDelete(id)
    local item = ns.GetItemLibrary()[id]
    if type(item) ~= "table" then return end
    StaticPopup_Show("PARCHMENT_DELETE_ITEM", item.name or id, nil,
        { id = id, name = item.name })
end

-- Stores a copy of an item under a fresh key. The suffix is dropped rather than
-- truncated when the name is already at the schema's cap.
function ItemWizardUI.Duplicate(id)
    local item = ns.GetItemLibrary()[id]
    if type(item) ~= "table" then return end
    local copy = ns.DeepCopy(item)
    local name = tostring(copy.name or "Item")
    copy.name = (#name + 7 <= 64) and (name .. " (copy)") or name
    copy.version = nil
    local stored = ns.SetItem(ns.NextItemKey(), copy)
    ns.Print("copied '" .. (stored and stored.name or name) .. "' into your library.")
    ns.Systems.RefreshAll()
end

-- The add flow: pick a library item of `kind` (nil = any kind) for the active
-- character, or author a new one. Called from the sheet's section headers.
function ItemWizardUI.AddFlow(kind)
    local char, charKey = ns.GetActiveCharacter()
    if not char then
        ns.Print("no active character to add an item to - create one first.")
        return
    end

    local list = {}
    for id, item in pairs(ns.GetItemLibrary()) do
        if type(item) == "table" and (not kind or item.kind == kind) then
            list[#list + 1] = { id = id, name = tostring(item.name or id) }
        end
    end
    table.sort(list, function(a, b)
        if a.name == b.name then return a.id < b.id end
        return a.name < b.name
    end)

    local items = { { id = NEW_ID, name = "|cffc8a868(new item...)|r" } }
    for _, entry in ipairs(list) do items[#items + 1] = entry end

    ns.Dialogs.Pick({
        title = "Add " .. (KIND_LABEL[kind] or "Item"),
        prompt = (#list > 0 and "Choose from your item library.")
            or (kind and ("Your library has no " .. (KIND_LABEL[kind] or "item"):lower()
                .. " yet - write one.")
                or "Your library is empty - write your first item."),
        items = items, max = 1,
        onConfirm = function(ids)
            local id = ids[1]
            if not id then return end
            if id == NEW_ID then
                ItemWizardUI.Open(nil, kind or "gear", charKey)
                return
            end
            local item = ns.GetItemLibrary()[id]
            if type(item) == "table" then ItemWizardUI.AddToCharacter(item, charKey) end
        end,
    })
end

-- Library panel (the hub's Items screen).

-- The library as a sorted list, filtered by kind and a name/id substring.
local function LibraryList(kind, query)
    local out = {}
    for id, item in pairs(ns.GetItemLibrary()) do
        if type(item) == "table" and (not kind or item.kind == kind) then
            local hay = (tostring(item.name or "") .. " " .. id):lower()
            if query == "" or hay:find(query, 1, true) then
                out[#out + 1] = { id = id, item = item }
            end
        end
    end
    table.sort(out, function(a, b)
        local an, bn = tostring(a.item.name or a.id), tostring(b.item.name or b.id)
        if an == bn then return a.id < b.id end
        return an < bn
    end)
    return out
end

-- Fills the shared row tooltip for one library entry. The lines are appended
-- one by one: an array constructor holding a conditional field truncates the
-- list at the first nil in Lua 5.1.
local function FillRowTip(row, id, item)
    row.tipTitle = item.name or id
    local lines = {}
    lines[#lines + 1] = { "Kind", KIND_LABEL[item.kind] or "?" }
    lines[#lines + 1] = { "ID", id }
    lines[#lines + 1] = { "Version", tonumber(item.version) or 1 }
    if item.kind == "weapon" then
        lines[#lines + 1] = { "Attack bonus", UI.Signed(tonumber(item.bonus) or 0) }
        if item.weapon_id then
            lines[#lines + 1] = { "Linked weapon", WeaponName(item.weapon_id) }
        end
    elseif item.kind == "equipment" then
        lines[#lines + 1] = { "AC bonus", UI.Signed(tonumber(item.ac_bonus) or 0) }
        if tonumber(item.ac_mod_cap) then
            lines[#lines + 1] = { "Modifier cap", UI.Signed(tonumber(item.ac_mod_cap)) }
        end
    end
    -- The description goes in whole: it is schema-capped at 512 characters and
    -- a plain string line wraps in the tooltip, so nothing needs cutting.
    local desc = tostring(item.description or "")
    if desc ~= "" then lines[#lines + 1] = desc end
    row.tipLines = lines
    row.tipHints = ROW_HINTS
end

-- The four verbs a library row carries. Both the row buttons and the
-- right-click menu call these, so a duplicated affordance is never a second
-- implementation.
local function RowEdit(row)
    if row.itemId then ItemWizardUI.Open(row.itemId) end
end

local function RowGive(row)
    if row.item then ItemWizardUI.AddToCharacter(row.item, nil) end
end

local function RowDuplicate(row)
    if row.itemId then ItemWizardUI.Duplicate(row.itemId) end
end

local function RowDelete(row)
    if row.itemId then ItemWizardUI.ConfirmDelete(row.itemId) end
end

-- The row's manage menu (modern Menu API; without it right-click falls back to
-- the edit the menu leads with). Every entry documents itself on hover.
local function RowMenu(row)
    if not MenuUtil then
        RowEdit(row)
        return
    end
    local name = (row.item and row.item.name) or row.itemId or "?"
    MenuUtil.CreateContextMenu(row, function(_, root)
        root:CreateTitle(name)
        local tip = MenuUtil.SetElementTooltip
        local e = root:CreateButton("Edit", function() RowEdit(row) end)
        if tip then tip(e, "Every character carrying it follows the edit.") end
        e = root:CreateButton("Give to a character", function() RowGive(row) end)
        if tip then tip(e, "Adds it to the active character's inventory.") end
        e = root:CreateButton("Duplicate", function() RowDuplicate(row) end)
        if tip then tip(e, "Stores a second copy, named '(copy)', to edit freely.") end
        e = root:CreateButton(DELETE or "Delete", function() RowDelete(row) end)
        if tip then tip(e, "Asks first. Carriers keep the entry, showing it as missing.") end
    end)
end

local function CreateItemRow(content)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_BROWSE_H)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    UI.RowVisuals(row)
    UI.WireRowTip(row)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", 6, 0)

    row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 32, -2)
    row.name:SetPoint("RIGHT", row, "RIGHT", -126, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.meta = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.meta:SetPoint("BOTTOMLEFT", 32, 2)
    row.meta:SetPoint("RIGHT", row, "RIGHT", -126, 0)
    row.meta:SetJustifyH("LEFT")
    row.meta:SetWordWrap(false)
    row.meta:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    local function SmallButton(text, x, onClick)
        local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        b:SetSize(44, 18)
        b:SetPoint("RIGHT", x, 0)
        b:SetText(text)
        b:SetScript("OnClick", onClick)
        return b
    end
    -- "Give" stays clickable without an active character: the attempt says why
    -- in chat, where a disabled button (which swallows its own hover) could not.
    row.addBtn = SmallButton("Give", -74, function() RowGive(row) end)
    row.addBtn:SetScript("OnEnter", function(self)
        local _, key = ns.GetActiveCharacter()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(key and "Give it to the active character"
            or "No active character to give this to.", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row.addBtn:SetScript("OnLeave", GameTooltip_Hide)
    row.copyBtn = SmallButton("Copy", -26, function() RowDuplicate(row) end)

    row.delBtn = CreateFrame("Button", nil, row)
    row.delBtn:SetSize(16, 16)
    row.delBtn:SetPoint("RIGHT", -6, 0)
    row.delBtn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    row.delBtn:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    row.delBtn:SetScript("OnClick", function() RowDelete(row) end)

    -- Shift wins over a plain left click (the sheet's inventory rows read the
    -- same way), then right manages, then left reads.
    row:SetScript("OnClick", function(self, mouseButton)
        if not self.item then return end
        if mouseButton ~= "RightButton" and IsShiftKeyDown and IsShiftKeyDown() then
            ns.ChatLinks.PostLink(ns.ChatLinks.Item(self.item))
            return
        end
        if mouseButton == "RightButton" then
            RowMenu(self)
            return
        end
        if ns.ChatLinkUI then ns.ChatLinkUI.Show(ns.ChatLinks.Item(self.item)) end
    end)
    return row
end

-- The empty state masks the panel body but not its header row, so the controls
-- it makes pointless (a filter and a search over nothing) are hidden with it -
-- HideEmpty only drops the overlay, it cannot know what went with it.
local function SetControlsShown(panel, shown)
    panel.kindBtn:SetShown(shown)
    panel.searchBox:SetShown(shown)
    panel.newBtn:SetShown(shown)
end

local function RefreshPanel(panel)
    local content = panel.content
    content.rows = content.rows or {}
    for _, r in ipairs(content.rows) do r:Hide() end

    local filter = FILTERS[panel.filterIndex or 1]
    -- The dropdown carries the selection as its own text; the cycle-button
    -- fallback needs the "Kind:" prefix to read as a filter at all.
    if panel.kindBtn.OverwriteText then
        panel.kindBtn:OverwriteText(filter.label)
    elseif panel.kindBtn.SetText then
        panel.kindBtn:SetText("Kind: " .. filter.label)
    end
    local list = LibraryList(filter.kind, tostring(panel.query or ""):lower())

    -- An empty library gets the full empty state; a filter that matches nothing
    -- only gets a line, because the search box it would cover is the way out.
    if next(ns.GetItemLibrary()) == nil then
        ns.UI.Empty(panel, "Your item library is empty.\n\nItems live here, not on a character:"
            .. " write one and hand it to whoever carries it.",
            "Create your first item", function() ItemWizardUI.Open() end)
        SetControlsShown(panel, false)
        panel.msg:SetText("")
        content:SetHeight(10)
        return
    end
    ns.UI.HideEmpty(panel)
    SetControlsShown(panel, true)
    panel.msg:SetText(#list == 0 and "|cffffcc00Nothing matches that filter.|r" or BROWSE_HINT)

    local y = -2
    for i, entry in ipairs(list) do
        local row = content.rows[i] or CreateItemRow(content)
        content.rows[i] = row
        row.itemId, row.item = entry.id, entry.item
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)
        row.icon:SetTexture(IconPath(entry.item.icon))
        row.name:SetText(entry.item.name or entry.id)
        row.name:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
        row.meta:SetText((KIND_LABEL[entry.item.kind] or "?") .. "  -  " .. MechanicsText(entry.item))
        FillRowTip(row, entry.id, entry.item)
        row:Show()
        y = y - ROW_BROWSE_H
    end
    content:SetHeight(math.max(10, -y + 2))
end

-- One option card in the type picker: kind icon, kind name, and the same hint
-- the wizard's first step gives that kind. Clicking it drafts an item of it.
local function KindCard(picker, kind, y)
    local card = CreateFrame("Button", nil, picker)
    card:SetHeight(CARD_H)
    card:SetPoint("TOPLEFT", PICK_PAD, y)
    card:SetPoint("TOPRIGHT", -PICK_PAD, y)

    local hl = card:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(TEX_HOVER)
    hl:SetTexCoord(0.25, 1, 0, 1)
    hl:SetBlendMode("ADD")
    hl:SetAlpha(0.6)

    local icon = card:CreateTexture(nil, "ARTWORK")
    icon:SetSize(CARD_ICON, CARD_ICON)
    icon:SetPoint("LEFT", 6, 0)
    local suggested = (ICON_SUGGESTIONS[kind.id] or {})[1]
    icon:SetTexture(suggested and (ICON_PATH .. suggested) or ICON_UNKNOWN)

    local title = card:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", CARD_ICON + 14, -4)
    title:SetJustifyH("LEFT")
    title:SetText(kind.label)

    -- Two lines, whatever the kind writes: the card grid stays even.
    local hint = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", CARD_ICON + 14, -24)
    hint:SetPoint("RIGHT", card, "RIGHT", -6, 0)
    hint:SetHeight(26)
    hint:SetJustifyH("LEFT")
    hint:SetJustifyV("TOP")
    hint:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    if hint.SetMaxLines then hint:SetMaxLines(2) end
    hint:SetText(kind.hint)

    card:SetScript("OnClick", function()
        picker:Hide()
        ItemWizardUI.Open(nil, kind.id)
    end)
    return card
end

-- The panel's type picker, built once and parented to the panel so it travels
-- with it. Cards are permanent (KINDS is static), so there is nothing to pool
-- per render.
local function GetKindPicker(panel)
    if panel.kindPicker then return panel.kindPicker end

    local picker = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    picker:SetSize(PICK_W, PICK_PAD * 2 + 22 + #KINDS * (CARD_H + CARD_GAP) - CARD_GAP)
    picker:SetPoint("BOTTOMLEFT", panel.newBtn, "TOPLEFT", 0, 6)
    picker:SetFrameLevel(panel:GetFrameLevel() + 10)
    picker:SetBackdrop(PICK_BACKDROP)
    picker:EnableMouse(true)     -- swallows clicks that would otherwise drag the window
    picker:Hide()

    local head = picker:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    head:SetPoint("TOPLEFT", PICK_PAD, -PICK_PAD)
    head:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
    head:SetText("What kind of item?")

    local y = -PICK_PAD - 22
    for _, kind in ipairs(KINDS) do
        KindCard(picker, kind, y)
        y = y - CARD_H - CARD_GAP
    end

    -- The hub hides a panel on every sidebar switch (and with the window); the
    -- picker must not be left armed to reappear with it.
    panel:HookScript("OnHide", function() picker:Hide() end)
    panel.kindPicker = picker
    return picker
end

-- Builds the panel into the frame the hub hands over. Everything is anchored to
-- that frame's edges: the hub body is ~370px wide at the window's minimum size,
-- so the search box takes whatever the filter button leaves rather than a fixed
-- width, and the row texts truncate against their buttons.
local function BuildPanel(panel)
    panel.filterIndex = 1

    -- The kind filter is a real dropdown (radio entries; the button text
    -- follows the selection) - a cycle button hides the other choices. Falls
    -- back to cycling only when the client lacks the dropdown template.
    local hasDropdown = pcall(CreateFrame, "DropdownButton")
    if hasDropdown then
        panel.kindBtn = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
        panel.kindBtn:SetSize(110, 20)
        panel.kindBtn:SetPoint("TOPLEFT", 0, -2)
        panel.kindBtn:SetupMenu(function(_, root)
            for i, filter in ipairs(FILTERS) do
                root:CreateRadio(filter.label,
                    function() return panel.filterIndex == i end,
                    function()
                        panel.filterIndex = i
                        RefreshPanel(panel)
                    end)
            end
        end)
    else
        panel.kindBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        panel.kindBtn:SetSize(110, 20)
        panel.kindBtn:SetPoint("TOPLEFT", 0, -2)
        panel.kindBtn:SetScript("OnClick", function()
            panel.filterIndex = (panel.filterIndex % #FILTERS) + 1
            RefreshPanel(panel)
        end)
    end

    -- Live filter, debounced and only on real edits (OnTextChanged also fires
    -- for programmatic SetText).
    panel.searchBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    panel.searchBox:SetHeight(18)
    panel.searchBox:SetPoint("LEFT", panel.kindBtn, "RIGHT", 16, 0)
    panel.searchBox:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
    panel.searchBox:SetAutoFocus(false)
    panel.searchBox:SetScript("OnEscapePressed", function(box) box:SetText(""); box:ClearFocus() end)
    panel.searchBox:SetScript("OnEnterPressed", function(box) box:ClearFocus() end)
    local runSearch = UI.Debounce(0.15, function() RefreshPanel(panel) end)
    panel.searchBox:SetScript("OnTextChanged", function(box, user)
        if not user or box:GetText() == panel.query then return end
        panel.query = box:GetText()
        runSearch()
    end)
    UI.SetPlaceholder(panel.searchBox, "Search items")

    panel.msg = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    panel.msg:SetPoint("TOPLEFT", 4, -28)
    panel.msg:SetPoint("RIGHT", panel, "RIGHT", -4, 0)
    panel.msg:SetJustifyH("LEFT")
    panel.msg:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    local scroll = CreateFrame("ScrollFrame", "ParchmentItemScroll", panel,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -56)
    scroll:SetPoint("BOTTOMRIGHT", -26, 34)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    content.rows = {}
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
    panel.content = content

    -- New item opens the type picker rather than the wizard: the kind decides
    -- what the item does, so it is the one choice worth making up front.
    panel.newBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.newBtn:SetSize(90, 22)
    panel.newBtn:SetText("New item")
    panel.newBtn:SetPoint("BOTTOMLEFT", 0, 4)
    panel.newBtn:SetScript("OnClick", function()
        local picker = GetKindPicker(panel)
        if picker:IsShown() then picker:Hide() else picker:Show() end
    end)
end

-- The library has no window of its own: both openers route to the hub panel.
function ItemWizardUI.OpenBrowser()
    ns.HubUI.Open("items")
end

function ItemWizardUI.ToggleBrowser()
    ns.HubUI.Toggle("items")
end

-- Re-renders the open wizard and the Items panel while the hub shows it (called
-- by ns.Systems.RefreshAll after any item or inventory change).
function ItemWizardUI.RefreshIfShown()
    local f = ItemWizardUI.frame
    if f and f:IsShown() and f.draft then Refresh(f) end
    ns.HubUI.RefreshIfShown("items")
end

ns.HubUI.RegisterPanel({
    id = "items", label = "Items", order = 40, icon = "inv_misc_bag_08",
    count = function()
        local n = 0
        for _ in pairs(ns.GetItemLibrary()) do n = n + 1 end
        return n
    end,
    Build = BuildPanel, Refresh = RefreshPanel,
})

ns.RegisterModule("items", ItemWizardUI.ToggleBrowser)
