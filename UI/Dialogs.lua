-- Parchment - Dialogs
--
-- Reusable modal-style dialogs: a checklist picker used to collect selection
-- picks (skills, weapons, attributes) and a searchable, categorized icon
-- picker for item/library icons. Each is one pooled frame reused across
-- calls. The icon list is a curated set of stock texture names (the icon
-- field itself accepts any name); categories cover the gear slots so pants,
-- rings and trinkets are as reachable as swords.
--
-- Reads from: ns.UI (shared window + palette), ns.Comm (DM recognition).
-- Exposes on ns.Dialogs: .Pick{ title, prompt, items, max, selected, onConfirm },
--   .PickIcon{ selected, onPick },
--   .ConfirmDMSwitch(current, claimant), .ConfirmDMTakeover(current, onAccept)

local ADDON, ns = ...

local UI = ns.UI
local ROW_H = 20

-- The icon picker's curated catalogue: stock texture names, grouped the way a
-- player thinks about equipment. Names only (never paths) - the same
-- restriction the schema puts on stored icons.
local ICON_TEX_PATH = "Interface\\Icons\\"
local ICON_GROUPS = {
    { label = "Weapons", icons = {
        "INV_Sword_04", "INV_Sword_23", "INV_Sword_48", "INV_Weapon_Shortblade_05",
        "INV_Weapon_Shortblade_25", "INV_Axe_02", "INV_Axe_09", "INV_Hammer_05",
        "INV_Mace_02", "INV_Spear_05", "INV_Staff_13", "INV_Staff_20", "INV_Wand_07",
        "INV_Weapon_Bow_02", "INV_Weapon_Bow_07", "INV_Weapon_Crossbow_02",
        "INV_Weapon_Rifle_01", "INV_ThrowingKnife_02",
    } },
    { label = "Shields", icons = {
        "INV_Shield_04", "INV_Shield_05", "INV_Shield_06", "INV_Shield_09", "INV_Shield_10",
    } },
    { label = "Head", icons = {
        "INV_Helmet_03", "INV_Helmet_06", "INV_Helmet_15", "INV_Helmet_29",
        "INV_Helmet_51", "INV_Misc_Bandana_03", "INV_Misc_Crown_01",
    } },
    { label = "Chest & shoulders", icons = {
        "INV_Chest_Cloth_07", "INV_Chest_Cloth_21", "INV_Chest_Leather_01",
        "INV_Chest_Leather_09", "INV_Chest_Chain", "INV_Chest_Chain_05",
        "INV_Chest_Plate02", "INV_Chest_Plate04", "INV_Shirt_05",
        "INV_Shoulder_01", "INV_Shoulder_09",
    } },
    { label = "Hands & arms", icons = {
        "INV_Gauntlets_04", "INV_Gauntlets_05", "INV_Gauntlets_17",
        "INV_Bracer_02", "INV_Bracer_07",
    } },
    { label = "Waist & legs", icons = {
        "INV_Belt_04", "INV_Belt_13", "INV_Pants_02", "INV_Pants_04",
        "INV_Pants_08", "INV_Pants_12",
    } },
    { label = "Feet & back", icons = {
        "INV_Boots_01", "INV_Boots_05", "INV_Boots_08", "INV_Boots_Cloth_03",
        "INV_Misc_Cape_02", "INV_Misc_Cape_11", "INV_Misc_Cape_18", "INV_Misc_Cape_20",
    } },
    { label = "Rings", icons = {
        "INV_Jewelry_Ring_03", "INV_Jewelry_Ring_05", "INV_Jewelry_Ring_08",
        "INV_Jewelry_Ring_14", "INV_Jewelry_Ring_17", "INV_Jewelry_Ring_22",
    } },
    { label = "Necks & trinkets", icons = {
        "INV_Jewelry_Necklace_03", "INV_Jewelry_Necklace_07", "INV_Jewelry_Necklace_11",
        "INV_Jewelry_Talisman_01", "INV_Jewelry_Talisman_07", "INV_Jewelry_Talisman_12",
        "INV_Misc_PocketWatch_01",
    } },
    { label = "Containers", icons = {
        "INV_Misc_Bag_08", "INV_Misc_Bag_10", "INV_Misc_Bag_11", "INV_Box_01", "INV_Crate_01",
    } },
    { label = "Potions & food", icons = {
        "INV_Potion_51", "INV_Potion_54", "INV_Potion_93", "INV_Alchemy_Elixir_04",
        "INV_Drink_05", "INV_Drink_10", "INV_Misc_Food_11", "INV_Misc_Food_15",
        "INV_Misc_Food_23",
    } },
    { label = "Books & scrolls", icons = {
        "INV_Misc_Book_07", "INV_Misc_Book_09", "INV_Misc_Book_11",
        "INV_Scroll_03", "INV_Scroll_08", "INV_Misc_Note_01", "INV_Misc_Map_01",
    } },
    { label = "Tools & lights", icons = {
        "INV_Misc_Rope_01", "INV_Misc_Lantern_01", "INV_Misc_Key_03",
        "INV_Misc_Wrench_01", "INV_Misc_Bomb_04", "INV_Misc_Spyglass_02",
        "INV_Misc_Bell_01", "INV_Hammer_20",
    } },
    { label = "Valuables", icons = {
        "INV_Misc_Coin_02", "INV_Misc_Coin_17", "INV_Misc_Gem_Ruby_01",
        "INV_Misc_Gem_Sapphire_02", "INV_Misc_Gem_Emerald_02", "INV_Misc_Gem_Pearl_03",
    } },
    { label = "Oddments", icons = {
        "INV_Misc_Ammo_Arrow_01", "INV_Misc_Ammo_Bullet_01", "INV_Misc_Herb_01",
        "INV_Misc_Flower_02", "INV_Mushroom_11", "INV_Misc_MonsterClaw_03",
        "INV_Misc_Bone_HumanSkull_01", "INV_Misc_QuestionMark",
    } },
}

-- Icon grid geometry: swatch size, gap, and the vertical room a group header
-- takes. Columns follow the live content width, so a resized window reflows.
local SWATCH, SWATCH_GAP, GROUP_HEAD_H = 28, 4, 22

local Dialogs = {}
ns.Dialogs = Dialogs

local frame
local RenderRows

-- True when id is currently selected.
local function IsSelected(f, id)
    for _, v in ipairs(f.sel) do
        if v == id then return true end
    end
    return false
end

-- Toggles an item, respecting the max (max == 1 replaces; otherwise caps).
local function Toggle(f, id)
    for i, v in ipairs(f.sel) do
        if v == id then table.remove(f.sel, i); RenderRows(f); return end
    end
    if f.max == 1 then
        f.sel = { id }
    elseif #f.sel < f.max then
        f.sel[#f.sel + 1] = id
    else
        return
    end
    RenderRows(f)
end

-- Creates one pooled checklist row.
local function CreateRow(f)
    local row = CreateFrame("Button", nil, f.content)
    row:SetHeight(ROW_H)
    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints(row)
    hl:SetColorTexture(UI.HILITE[1], UI.HILITE[2], UI.HILITE[3], UI.HILITE[4])
    row.hl = hl
    row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", 6, 0)
    row.label:SetPoint("RIGHT", -6, 0)
    row.label:SetJustifyH("LEFT")
    row:SetScript("OnClick", function() Toggle(f, row.itemId) end)
    row:SetScript("OnEnter", function(self)
        if not self.tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tipTitle or " ", 1, 1, 1)
        GameTooltip:AddLine(self.tip, 0.85, 0.82, 0.75, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
end

-- Rebuilds the visible rows and the counter from f.items / f.sel.
RenderRows = function(f)
    local content = f.content
    content.rows = content.rows or {}
    for _, r in ipairs(content.rows) do r:Hide() end
    local y = -2
    for i, item in ipairs(f.items) do
        local row = content.rows[i] or CreateRow(f)
        content.rows[i] = row
        row.itemId = item.id
        row.tip = item.tooltip
        row.tipTitle = item.name
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)
        local on = IsSelected(f, item.id)
        row.label:SetText((on and "|cff66d966[x]|r  " or "|cff888888[ ]|r  ") .. item.name)
        row.hl:SetShown(on)
        row:Show()
        y = y - ROW_H
    end
    content:SetHeight(math.max(10, -y + 2))
    f.counter:SetText("Selected " .. #f.sel .. " / " .. f.max)
end

local function Build()
    local f = UI.CreateWindow("ParchmentDialog", {
        title = "Choose", width = 300, height = 400,
        minW = 240, minH = 240, maxW = 420, maxH = 760, dbKey = "dialogWindow",
    })
    f:SetFrameStrata("FULLSCREEN_DIALOG")  -- above other Parchment windows

    f.prompt = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.prompt:SetPoint("TOPLEFT", 16, -44)
    f.prompt:SetPoint("RIGHT", f, "RIGHT", -110, 0)
    f.prompt:SetJustifyH("LEFT")
    f.prompt:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    f.counter = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.counter:SetPoint("TOPRIGHT", -16, -44)
    f.counter:SetTextColor(UI.HEAD[1], UI.HEAD[2], UI.HEAD[3])

    local scroll = CreateFrame("ScrollFrame", "ParchmentDialogScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -66)
    scroll:SetPoint("BOTTOMRIGHT", -32, 46)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    content.rows = {}
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
    f.content = content

    local confirm = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    confirm:SetSize(90, 22)
    confirm:SetText("Confirm")
    confirm:SetPoint("BOTTOMRIGHT", -16, 14)
    confirm:SetScript("OnClick", function()
        local cb, sel = f.onConfirm, f.sel
        f:Hide()
        if cb then cb(sel) end
    end)

    local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancel:SetSize(80, 22)
    cancel:SetText("Cancel")
    cancel:SetPoint("BOTTOMLEFT", 16, 14)
    cancel:SetScript("OnClick", function() f:Hide() end)

    return f
end

-- Opens the checklist picker.
--
-- opts: title, prompt, items (list of {id, name}), max (default 1),
--   selected (list of pre-selected ids), onConfirm(selectedIds).
function Dialogs.Pick(opts)
    frame = frame or Build()
    local f = frame
    f.titleFS:SetText(opts.title or "Choose")
    f.prompt:SetText(opts.prompt or "")
    f.items = opts.items or {}
    f.max = opts.max or 1
    f.onConfirm = opts.onConfirm
    -- Seed the pre-selected ids, but never past the cap: an over-cap character
    -- (imports allow one - CE.Warnings only warns) must not open at "3 / 2" and
    -- confirm all three, which would round-trip the over-cap state through the
    -- very dialog whose job is to enforce the cap.
    f.sel = {}
    for _, id in ipairs(opts.selected or {}) do
        if #f.sel >= f.max then break end
        f.sel[#f.sel + 1] = id
    end
    RenderRows(f)
    f:Show()
    f:Raise()
end

-- Icon picker.

local iconFrame
local RenderIcons

-- One pooled icon swatch: the texture, a hover ring via the standard highlight,
-- and a gold backdrop marking the current selection.
local function CreateSwatch(f)
    local b = CreateFrame("Button", nil, f.iconContent)
    b:SetSize(SWATCH, SWATCH)
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetPoint("TOPLEFT", -2, 2)
    b.sel:SetPoint("BOTTOMRIGHT", 2, -2)
    b.sel:SetColorTexture(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3], 0.8)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetAllPoints()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnClick", function(self)
        local cb, name = f.onPick, self.iconName
        f:Hide()
        if cb and name then cb(name) end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.iconName or "?", 1, 1, 1)
        GameTooltip:AddLine("Click: use this icon", 0.56, 0.78, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    return b
end

-- Lays out every group that survives the query as a header plus a grid of
-- swatches. Pools (headers and swatches separately) are index-reused; the
-- column count follows the live content width, so resizing reflows.
RenderIcons = function(f)
    local content = f.iconContent
    for _, s in ipairs(content.swatches) do s:Hide() end
    for _, h in ipairs(content.headers) do h:Hide() end

    local width = content:GetWidth()
    if width < SWATCH then width = 300 end
    local cols = math.max(4, math.floor((width - 4) / (SWATCH + SWATCH_GAP)))
    local query = tostring(f.query or ""):lower()
    local selected = type(f.selected) == "string" and f.selected:lower() or nil

    local si, hi = 0, 0
    local y = -2
    local shown = 0
    for _, group in ipairs(ICON_GROUPS) do
        -- The group's matching icons (all of them on an empty query).
        local names = {}
        for _, name in ipairs(group.icons) do
            if query == "" or name:lower():find(query, 1, true) then
                names[#names + 1] = name
            end
        end

        if #names > 0 then
            hi = hi + 1
            local head = content.headers[hi]
            if not head then
                head = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
                head:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
                content.headers[hi] = head
            end
            head:ClearAllPoints()
            head:SetPoint("TOPLEFT", 4, y - 6)
            head:SetText(group.label)
            head:Show()
            y = y - GROUP_HEAD_H

            for i, name in ipairs(names) do
                si = si + 1
                shown = shown + 1
                local b = content.swatches[si] or CreateSwatch(f)
                content.swatches[si] = b
                local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", 4 + col * (SWATCH + SWATCH_GAP),
                    y - row * (SWATCH + SWATCH_GAP))
                b.iconName = name
                b.tex:SetTexture(ICON_TEX_PATH .. name)
                b.sel:SetShown(selected ~= nil and name:lower() == selected)
                b:Show()
            end
            y = y - math.ceil(#names / cols) * (SWATCH + SWATCH_GAP) - 4
        end
    end

    f.iconMsg:SetText(shown == 0 and "|cffffcc00Nothing matches. The icon field still takes"
        .. " any texture name.|r" or "")
    content:SetHeight(math.max(10, -y + 2))
end

local function BuildIconPicker()
    local f = UI.CreateWindow("ParchmentIconPickerFrame", {
        title = "Choose an Icon", width = 360, height = 440,
        minW = 300, minH = 300, maxW = 560, maxH = 800, dbKey = "iconPickerWindow",
    })
    f:SetFrameStrata("FULLSCREEN_DIALOG")  -- above the wizard that opened it

    f.searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.searchBox:SetHeight(18)
    f.searchBox:SetPoint("TOPLEFT", 22, -44)
    f.searchBox:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.searchBox:SetAutoFocus(false)
    f.searchBox:SetScript("OnEscapePressed", function(box) box:SetText(""); box:ClearFocus() end)
    f.searchBox:SetScript("OnEnterPressed", function(box) box:ClearFocus() end)
    f.searchBox:SetScript("OnTextChanged", function(box, user)
        if not user then return end
        f.query = box:GetText()
        RenderIcons(f)
    end)
    UI.SetPlaceholder(f.searchBox, "Search icons (sword, ring, pants, ...)")

    f.iconMsg = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.iconMsg:SetPoint("TOPLEFT", 16, -68)
    f.iconMsg:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.iconMsg:SetJustifyH("LEFT")

    local scroll = CreateFrame("ScrollFrame", "ParchmentIconPickerScroll", f,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -66)
    scroll:SetPoint("BOTTOMRIGHT", -32, 40)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    content.swatches, content.headers = {}, {}
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w)
        content:SetWidth(w)
        if f:IsShown() then RenderIcons(f) end
    end)
    f.iconContent = content

    local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancel:SetSize(80, 22)
    cancel:SetText(CANCEL)
    cancel:SetPoint("BOTTOMRIGHT", -16, 12)
    cancel:SetScript("OnClick", function() f:Hide() end)

    return f
end

-- Opens the icon picker.
--
-- opts: selected (the current icon name, highlighted case-insensitively),
--   onPick(name) - called with the chosen texture name after the window closes.
function Dialogs.PickIcon(opts)
    iconFrame = iconFrame or BuildIconPicker()
    local f = iconFrame
    opts = opts or {}
    f.selected = opts.selected
    f.onPick = opts.onPick
    f.query = ""
    f.searchBox:SetText("")
    RenderIcons(f)
    f:Show()
    f:Raise()
end

-- DM-clash prompts. Both default to the non-destructive choice (keep the current
-- DM / cancel) so Escape or a dismissed popup never leaves a client DM-less or
-- mid-fight: switching or taking over is always an explicit click.

-- Shown on a client when a DIFFERENT player claims DM while one is already
-- recognized: switch to the claimant, or keep the current DM (the default).
StaticPopupDialogs["PARCHMENT_DM_SWITCH"] = {
    text = "%s is claiming DM, but you recognize %s.\n\nSwitch to them?",
    button1 = "Switch",
    button2 = "Keep",
    OnAccept = function(_, data)
        if data and data.claimant then ns.Comm.SetRecognizedDM(data.claimant) end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Shown to a player who runs /pmt dm while already recognizing someone else:
-- confirm the take-over before claiming, so a stray command cannot silently
-- fight an existing DM. onAccept performs the claim.
StaticPopupDialogs["PARCHMENT_DM_TAKEOVER"] = {
    text = "%s is already DM.\n\nTake over the role?",
    button1 = "Take over",
    button2 = CANCEL,
    OnAccept = function(_, data)
        if data and data.onAccept then data.onAccept() end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Offers to switch this client's recognized DM from `current` to `claimant`.
function Dialogs.ConfirmDMSwitch(current, claimant)
    StaticPopup_Show("PARCHMENT_DM_SWITCH", claimant or "Someone", current or "your DM",
        { claimant = claimant })
end

-- Confirms taking the DM role over from `current`; onAccept runs on confirm.
function Dialogs.ConfirmDMTakeover(current, onAccept)
    StaticPopup_Show("PARCHMENT_DM_TAKEOVER", current or "Someone", nil, { onAccept = onAccept })
end
