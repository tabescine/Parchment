-- Parchment - Character Sheet (UI)
--
-- Builds and drives the character sheet window. Owns one reusable frame: a
-- draggable, Escape-closable panel with a fixed vitals header (editable current
-- HP/Mana) and a scrolling body that renders the computed sheet - attributes,
-- derived stats, skills and saves, weapons, traits, feats and spells
-- and notes.
--
-- All layout is data-driven from ns.CharacterSheet.Compute; nothing here knows
-- any specific ruleset, so whatever system the user imports renders too. The
-- quick-reference sections render homebrew as it comes: a record flagged
-- pending (gained at a level the character has not reached) is dimmed and
-- labelled instead of hidden.
--
-- The inventory sections (weapons / equipment / gear) are the sheet's only
-- editing surface besides the vitals boxes: a state icon toggles equipped, gear
-- rows carry a -/+ counter, right-clicking a row drops the item (a missing one
-- offers the same on left-click, since it has nothing else to do).
-- Every such click goes through ns.Items, persists via ns.SetCharacter and then
-- refreshes - a display entry's `index` into char.inventory is only valid for
-- the render that produced it, so nothing is mutated twice in a row.
--
-- An equipped weapon row also shows and rolls that item's own attack total
-- (weapon skill + the item's bonus); the WEAPON SKILLS rows above stay bare
-- proficiencies, so a character holding two blades rolls the one being swung.
--
-- Reads from: ns.GetActiveCharacter, ns.GetSystem, ns.GetItemLibrary,
--   ns.CharacterSheet.Compute, ns.Items, ns.SetCharacter, ns.Systems.RefreshAll,
--   ns.ItemWizardUI (the
--   inventory headers' add flow).
-- Exposes on ns.CharacterSheetUI: Open, Toggle, RefreshIfShown, and
--   ShowCharacter (read-only view of a received/cached character).
-- Registers the "sheet" module opener with Core.

local ADDON, ns = ...

-- Layout metrics and palette.
local FRAME_W, FRAME_H = 540, 620
local MIN_W, MIN_H = 420, 360
local MAX_W, MAX_H = 900, 1000
local PAD = 16
local INDENT = 14
-- Shared palette from UI/Window.lua; STAR and STRIPE are sheet-specific.
local C_GOLD = ns.UI.GOLD
local C_HEAD = ns.UI.HEAD
local C_TEXT = ns.UI.TEXT
local C_DIM = ns.UI.DIM
local C_STAR = { 1.0, 0.82, 0.0 }
local C_LINE = ns.UI.LINE
local C_STRIPE = { 1.0, 0.95, 0.85, 0.04 }

-- Inventory rows: one 16px icon showing (and toggling) the item's state, and
-- (gear) a counter whose parts sit at these right-edge offsets. The item's own
-- icon is deliberately NOT repeated here - a second, inert picture beside the
-- state icon reads as a duplicate; item icons belong to the library browser and
-- the wizard, where they identify a record rather than a state. Textures are
-- Blizzard's own; Parchment ships no art.
local ICON_SIZE = 16
local INV_ROW_H = 18
local ICON_PATH = "Interface\\Icons\\"
local ICON_STASHED = ICON_PATH .. "INV_Misc_Bag_08"
local ICON_HELD = ICON_PATH .. "Ability_MeleeDamage"
local ICON_WORN = ICON_PATH .. "INV_Chest_Chain"
local CNT_PLUS_X, CNT_VALUE_X, CNT_MINUS_X = PAD - 2, PAD + 18, PAD + 48

local CharacterSheetUI = {}
ns.CharacterSheetUI = CharacterSheetUI

-- Formats a number with an explicit sign (+3, -2, +0).
local Signed = ns.UI.Signed

-- Trims trailing ".0" off a number formatted for display (13.0 -> 13). Coerces
-- and tolerates a nil/non-number (a malformed remote sheet) with a "?" instead
-- of throwing on math.floor.
local function Num(n)
    n = tonumber(n)
    if not n then return "?" end
    if n == math.floor(n) then return tostring(math.floor(n)) end
    return tostring(n)
end

-- Soft-blue inline tag naming the trait(s)/record(s) that modified a stat, so it is
-- obvious why a total differs from the raw modifier. Returns "" when none.
local function SourceTag(sources)
    if not sources or #sources == 0 then return "" end
    return "  |cff8ec6ff(" .. table.concat(sources, ", ") .. ")|r"
end

-- Body canvas helpers. Each operates on the content frame and advances a
-- vertical cursor (self.y). Text regions are pooled and reused across renders.

-- Begins a fresh layout pass: rewind the cursor and the pool cursors.
local function CanvasReset(content)
    content.y = -PAD
    content.used = 0
    content.texUsed = 0
    content.btnUsed = 0
    content.iconUsed = 0
    content.rowIndex = 0
end

-- Returns the next pooled hover button (transparent, spans a row or paragraph)
-- used to show a breakdown tooltip and/or handle a click (roll a check, post a
-- entry, drop an item). Scripts read btn.tip(GameTooltip), btn.roll =
-- { label, modifier } or { hint, click } for the left button, and btn.rightClick
-- for the right one (all set fresh on every render). A row that sets no
-- rightClick ignores right clicks entirely.
local function AcquireBtn(content)
    content.btnUsed = content.btnUsed + 1
    local b = content.btnPool[content.btnUsed]
    if not b then
        b = CreateFrame("Button", nil, content)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnEnter", function(self)
            if not (self.tip or self.roll) then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.tip then self.tip(GameTooltip) end
            if self.roll then
                GameTooltip:AddLine(self.roll.hint or ("Click: roll d20 " .. Signed(self.roll.modifier)),
                    0.56, 0.78, 1)
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        b:SetScript("OnClick", function(self, button)
            -- The right button is the secondary, destructive action (an
            -- inventory row drops its item); only rows that wire one react.
            if button == "RightButton" then
                if self.rightClick then self.rightClick() end
                return
            end
            if not self.roll then return end
            -- A spec may carry a custom click (e.g. the Initiative row joins
            -- combat) instead of the default d20 check.
            if self.roll.click then
                self.roll.click()
            else
                ns.Dice.Check(self.roll.label, self.roll.modifier)
            end
        end)
        content.btnPool[content.btnUsed] = b
    end
    b:ClearAllPoints()
    -- Clear last render's tip/roll/rightClick: a pooled button reused by a row
    -- that sets none must not carry a stale tooltip or click from its previous
    -- use - a leftover rightClick would drop items from a skill row.
    b.tip, b.roll, b.rightClick = nil, nil, nil
    b:Show()
    return b
end

-- Returns the next pooled FontString, creating it on demand. Pooled regions are
-- reused across renders and across roles (row label, row value, paragraph), so
-- every layout property a helper might set is reset here. In particular anchors
-- must be cleared: SetPoint adds a point rather than replacing, so a stale
-- opposite anchor would stretch the text full-width and centre it.
local function Acquire(content, font)
    content.used = content.used + 1
    local fs = content.pool[content.used]
    if not fs then
        fs = content:CreateFontString(nil, "ARTWORK", font)
        content.pool[content.used] = fs
    end
    fs:ClearAllPoints()
    fs:SetWidth(0)
    fs:SetWordWrap(true)
    fs:SetJustifyH("LEFT")
    fs:SetFontObject(_G[font])
    fs:Show()
    return fs
end

-- Returns the next pooled background texture, creating it on demand. Anchors are
-- cleared for the same reason as Acquire.
local function AcquireTex(content)
    content.texUsed = content.texUsed + 1
    local t = content.texPool[content.texUsed]
    if not t then
        t = content:CreateTexture(nil, "BACKGROUND")
        content.texPool[content.texUsed] = t
    end
    t:ClearAllPoints()
    t:Show()
    return t
end

-- Returns the next pooled icon button: a small square carrying either a texture
-- (an item's icon, its equipped state) or a glyph (the gear counter's -/+).
-- They sit above the row-wide hover buttons, so a passive one disables its own
-- mouse and lets the row's tooltip show through. Scripts read b.tip(GameTooltip)
-- and b.click, both cleared here so a reused button carries nothing stale.
local function AcquireIconBtn(content)
    content.iconUsed = content.iconUsed + 1
    local b = content.iconPool[content.iconUsed]
    if not b then
        b = CreateFrame("Button", nil, content)
        b:SetSize(ICON_SIZE, ICON_SIZE)
        b:SetFrameLevel(content:GetFrameLevel() + 5)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetAllPoints()
        b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.label:SetPoint("CENTER")
        b:SetScript("OnEnter", function(self)
            if not self.tip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            self.tip(GameTooltip)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        b:SetScript("OnClick", function(self) if self.click then self.click() end end)
        content.iconPool[content.iconUsed] = b
    end
    b:ClearAllPoints()
    b:SetSize(ICON_SIZE, ICON_SIZE)   -- a counter glyph borrowed it narrower
    b.tip, b.click = nil, nil
    b.tex:SetTexture(nil)
    b.tex:Hide()
    b.label:SetText("")
    b:EnableMouse(true)
    b:Show()
    return b
end

-- Hides pooled regions left over from a previous, longer render.
local function CanvasFinish(content)
    for i = content.used + 1, #content.pool do content.pool[i]:Hide() end
    for i = content.texUsed + 1, #content.texPool do content.texPool[i]:Hide() end
    for i = content.btnUsed + 1, #content.btnPool do content.btnPool[i]:Hide() end
    for i = content.iconUsed + 1, #content.iconPool do content.iconPool[i]:Hide() end
    content:SetHeight(-content.y + PAD)
end

-- Adds a gold section header followed by a thin divider rule. Resets the row
-- stripe parity so each section starts its banding fresh. When `action`
-- ({ text, hint, click }) is given, its label sits right-aligned on the header
-- line with a pooled hover button over it - the same pools every other row
-- uses, so a header affordance costs no new widget class.
local function Header(content, text, action)
    content.y = content.y - 12
    local fs = Acquire(content, "GameFontNormal")
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, content.y)
    fs:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3])
    fs:SetText(text)
    if action then
        local a = Acquire(content, "GameFontHighlightSmall")
        a:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, content.y - 2)
        a:SetJustifyH("RIGHT")
        a:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3])
        a:SetText(action.text)
        local b = AcquireBtn(content)
        b:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD + 4, content.y)
        b:SetSize(90, 16)
        b.roll = { hint = action.hint, click = action.click }
    end
    content.y = content.y - 18

    local line = AcquireTex(content)
    line:SetColorTexture(C_LINE[1], C_LINE[2], C_LINE[3], C_LINE[4])
    line:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, content.y + 3)
    line:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, content.y + 3)
    line:SetHeight(1)
    content.y = content.y - 7
    content.rowIndex = 0
end

-- Adds a label/value row with the value right-aligned. Data rows (non-empty
-- label) alternate a faint background stripe so the eye tracks each label to
-- its value; continuation rows (empty label) are left unstriped. When `tip` is
-- given, a hover button over the row shows tip(GameTooltip); when `roll`
-- ({ label, modifier }) is given, clicking the row rolls that check.
local function Row(content, label, value, indent, valColor, tip, roll)
    if label and label ~= "" then
        content.rowIndex = content.rowIndex + 1
        if content.rowIndex % 2 == 0 then
            local stripe = AcquireTex(content)
            stripe:SetColorTexture(C_STRIPE[1], C_STRIPE[2], C_STRIPE[3], C_STRIPE[4])
            stripe:SetPoint("TOPLEFT", content, "TOPLEFT", 4, content.y + 2)
            stripe:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, content.y + 2)
            stripe:SetHeight(16)
        end
    end

    local x = PAD + (indent or 0)
    local l = Acquire(content, "GameFontHighlightSmall")
    l:SetPoint("TOPLEFT", content, "TOPLEFT", x, content.y)
    l:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
    l:SetText(label)

    local v = Acquire(content, "GameFontHighlightSmall")
    v:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, content.y)
    local c = valColor or C_TEXT
    v:SetTextColor(c[1], c[2], c[3])
    v:SetText(value or "")

    if tip or roll then
        local b = AcquireBtn(content)
        b:SetPoint("TOPLEFT", content, "TOPLEFT", 4, content.y + 2)
        b:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, content.y + 2)
        b:SetHeight(16)
        b.tip = tip
        b.roll = roll
    end
    content.y = content.y - 16
end

-- Adds a full-width wrapped paragraph (descriptions, notes). title is bolded
-- gold inline; body wraps beneath the available width. When `roll` ({ hint,
-- click }) is given, a hover button over the paragraph handles the click.
local function Paragraph(content, title, body, color, roll)
    local width = content:GetWidth() - PAD * 2
    local fs = Acquire(content, "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, content.y)
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    local c = color or C_DIM
    fs:SetTextColor(c[1], c[2], c[3])
    local text = title and ("|cffc8a868" .. title .. "|r  " .. (body or "")) or (body or "")
    fs:SetText(text)
    local h = fs:GetStringHeight()
    if roll then
        local b = AcquireBtn(content)
        b:SetPoint("TOPLEFT", content, "TOPLEFT", 4, content.y + 2)
        b:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, content.y + 2)
        b:SetHeight(h + 4)
        b.roll = roll
    end
    content.y = content.y - h - 6
end

-- Section renderers. Each draws one block of the sheet into the body canvas,
-- advancing content.y, and is called in order by RenderBody. They share a small
-- ctx built once per render: modById (attribute entry by id), the accomplishment
-- bonus, viewChar (set when showing a read-only received sheet), and rollSpec -
-- which yields a click-to-roll spec for the own character and nil for a viewed
-- one (its modifiers are not yours to roll).

-- Overview: level, hit dice, and the derived stats. The effect shares fall out
-- as differences from the structural parts, so the tooltips are arithmetic on
-- the displayed numbers and cannot drift from them.
local function RenderOverview(content, sheet, ctx)
    local d = sheet.derived
    local cfg = ns.DerivedConfig()
    local function aName(id) return id and ctx.modById[id] and ctx.modById[id].name or id or "(none)" end
    local function aMod(id) return id and ctx.modById[id] and ctx.modById[id].modifier or 0 end
    local function fxTerm(x) return x ~= 0 and (" " .. Signed(x) .. " effects") or "" end
    local function Tip(title, line)
        return function(tt)
            tt:AddLine(title, C_GOLD[1], C_GOLD[2], C_GOLD[3])
            tt:AddLine(line, 0.9, 0.9, 0.9, true)
        end
    end

    -- Derived stats, two readable rows of pairs.
    Header(content, "OVERVIEW")
    Row(content, "Level", tostring(sheet.level))
    Row(content, "Hit Dice", sheet.derived.hit_dice, 0, nil,
        cfg.hit_die_attribute and Tip("Hit Dice",
            "Level " .. sheet.level .. " x the die for the " .. aName(cfg.hit_die_attribute)
            .. " modifier (" .. Signed(aMod(cfg.hit_die_attribute)) .. ").") or nil)
    -- Equipped equipment is named separately from the effect share, so the
    -- points a breastplate contributes are visible as such; both fall out as
    -- differences from the structural parts.
    local acEquip = d.ac_equipment
    local acFromGear = acEquip and acEquip.total or 0
    Row(content, "Armor Class", tostring(d.ac), 0, C_GOLD, Tip("Armor Class",
        "base " .. cfg.ac_base .. " + " .. aName(d.ac_attribute) .. " modifier "
        .. Signed(aMod(d.ac_attribute))
        .. (acEquip and (" " .. Signed(acFromGear) .. " equipment ("
            .. table.concat(acEquip.sources, ", ") .. ")") or "")
        .. fxTerm(d.ac - cfg.ac_base - aMod(d.ac_attribute) - acFromGear)))
    -- Initiative is gold (interactive): clicking rolls it and joins combat,
    -- via the same path as the combat window's Me/Submit button.
    Row(content, "Initiative", Signed(d.initiative), 0, C_GOLD, Tip("Initiative",
        aName(d.init_attribute) .. " modifier " .. Signed(aMod(d.init_attribute))
        .. fxTerm(d.initiative - aMod(d.init_attribute))),
        (not ctx.viewChar) and {
            label = "Initiative", modifier = d.initiative,
            hint = "Click: roll initiative and join the combat tracker",
            click = function() if ns.InitiativeUI then ns.InitiativeUI.AddSelf() end end,
        } or nil)
    local moveSteps = cfg.movement_attribute and math.max(0, aMod(cfg.movement_attribute)) or 0
    local moveStruct = cfg.movement_base + moveSteps * cfg.movement_per_step
    Row(content, "Movement", Num(d.movement) .. "m", 0, nil, Tip("Movement",
        "base " .. Num(cfg.movement_base)
        .. (cfg.movement_attribute and (" + " .. Num(cfg.movement_per_step) .. "m per positive "
            .. aName(cfg.movement_attribute) .. " modifier (" .. moveSteps .. ")") or "")
        .. fxTerm(d.movement - moveStruct)))
    Row(content, "Actions", tostring(d.actions), 0, nil, Tip("Actions",
        "base " .. cfg.actions_base
        .. (d.actions ~= cfg.actions_base
            and (" " .. Signed(d.actions - cfg.actions_base) .. " from level bonuses / effects") or "")))
    if d.save_dc then   -- casters only; non-casters carry no save DC
        Row(content, "Save DC", tostring(d.save_dc), 0, C_GOLD, Tip("Save DC",
            "base " .. cfg.save_dc_base .. " + " .. aName(d.primary_attribute) .. " modifier "
            .. Signed(aMod(d.primary_attribute)) .. " + accomplished " .. Signed(d.accomplishment)
            .. fxTerm(d.save_dc - cfg.save_dc_base - aMod(d.primary_attribute) - d.accomplishment)))
    end
    Row(content, "Accomplishment Bonus", Signed(d.accomplishment), 0, nil, Tip("Accomplishment Bonus",
        "From the system's accomplishment table at level " .. sheet.level .. "."))
    Row(content, "Primary Attribute", d.primary_attribute or "-")
    if d.cast_attribute then
        Row(content, "Cast Attribute", aName(d.cast_attribute), 0, nil, Tip("Cast Attribute",
            "Spellcasting is driven by " .. aName(d.cast_attribute) .. " (modifier "
            .. Signed(aMod(d.cast_attribute)) .. "). It gates spell ranks in the spellbook."))
    end
    -- The shared pick ledger (feats, spells, homebrew), own sheet only: a viewed
    -- character counts against the VIEWER's system and packs, which may not be
    -- the ones it was built with.
    if not ctx.viewChar and ctx.char then
        local spent, budget = ns.Picks.Points(ctx.char)
        Row(content, "Picks", spent .. " / " .. budget,
            0, spent > budget and ns.UI.RED or nil, Tip("Picks",
            "One shared pool buys feat ranks, spells and homebrew: "
            .. spent .. " spent of " .. budget .. " at level " .. sheet.level .. "."))
    end
    if d.attack_modifier ~= 0 then
        Row(content, "Global Attack Modifier", Signed(d.attack_modifier), 0, C_DIM)
    end
end

-- Attributes render as two right-aligned columns (total | mod) under dim column
-- heads, so the numbers line up down the sheet. The total keeps its trait
-- breakdown inline, dimmed ("8 +1 =  9"); the modifier is gold because it is the
-- number a row click rolls with.
local function RenderAttributes(content, sheet, ctx)
    Header(content, "ATTRIBUTES")
    local MOD_X, TOTAL_X = PAD, PAD + 48   -- column right edges, from the right
    local totalHead = Acquire(content, "GameFontHighlightSmall")
    totalHead:SetPoint("TOPRIGHT", content, "TOPRIGHT", -TOTAL_X, content.y)
    totalHead:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
    totalHead:SetText("total")
    local modHead = Acquire(content, "GameFontHighlightSmall")
    modHead:SetPoint("TOPRIGHT", content, "TOPRIGHT", -MOD_X, content.y)
    modHead:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
    modHead:SetText("mod")
    content.y = content.y - 14
    for _, a in ipairs(sheet.attributes) do
        local rowY = content.y
        Row(content, a.name, "", 0, nil, nil, ctx.rollSpec(a.name .. " check", a.modifier))
        local total = Acquire(content, "GameFontHighlightSmall")
        total:SetPoint("TOPRIGHT", content, "TOPRIGHT", -TOTAL_X, rowY)
        total:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
        total:SetText(a.bonus ~= 0
            and string.format("|cff9e998c%d %s =|r  %d", a.base, Signed(a.bonus), a.final)
            or tostring(a.final))
        local mod = Acquire(content, "GameFontHighlightSmall")
        mod:SetPoint("TOPRIGHT", content, "TOPRIGHT", -MOD_X, rowY)
        mod:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3])
        mod:SetText(Signed(a.modifier))
        if #a.sources > 0 then
            Row(content, "", table.concat(a.sources, ", "), INDENT, C_DIM)
        end
    end
end

-- Skills and saves, grouped under each attribute's saving throw. Each row
-- carries a hover tooltip breaking down how its total is reached.
local function RenderSkills(content, sheet, ctx)
    Header(content, "SKILLS & SAVING THROWS")
    local saveByAttr = {}
    for _, s in ipairs(sheet.saves) do saveByAttr[s.id] = s end
    local accomplishment = ctx.accomplishment
    local primary = sheet.derived.primary_attribute
    local skillsByAttr = {}
    for _, sk in ipairs(sheet.skills) do
        skillsByAttr[sk.attribute] = skillsByAttr[sk.attribute] or {}
        table.insert(skillsByAttr[sk.attribute], sk)
    end

    local function breakdownTip(title, attr, accomplished, sources, total)
        return function(tt)
            tt:AddLine(title, C_GOLD[1], C_GOLD[2], C_GOLD[3])
            tt:AddLine(attr.name .. " modifier: " .. Signed(attr.modifier), 0.9, 0.9, 0.9)
            if accomplished then tt:AddLine("Accomplished: " .. Signed(accomplishment), 0.9, 0.9, 0.9) end
            if sources and #sources > 0 then
                tt:AddLine("Modified by: " .. table.concat(sources, ", "), 0.56, 0.78, 1)
            end
            tt:AddLine("Total: " .. Signed(total), C_GOLD[1], C_GOLD[2], C_GOLD[3])
        end
    end

    for _, a in ipairs(sheet.attributes) do
        local save = saveByAttr[a.id]
        local isPrimary = (a.id == primary)
        local saveLabel = a.name:upper() .. " Saving Throw"
            .. (save and save.accomplished and "  *" or "")
            .. (isPrimary and "  |cffc8a868(primary)|r" or "")
            .. (save and SourceTag(save.sources) or "")
        Row(content, saveLabel, save and Signed(save.total) or "-", 0,
            save and save.accomplished and C_STAR or C_HEAD,
            save and breakdownTip(a.name .. " Saving Throw", a, save.accomplished, save.sources, save.total),
            save and ctx.rollSpec(a.name .. " save", save.total))
        for _, sk in ipairs(skillsByAttr[a.id] or {}) do
            local name = (sk.accomplished and "* " or "") .. sk.name .. SourceTag(sk.sources)
            Row(content, name, Signed(sk.total), INDENT, sk.accomplished and C_STAR or C_TEXT,
                breakdownTip(sk.name, a, sk.accomplished, sk.sources, sk.total),
                ctx.rollSpec(sk.name, sk.total))
        end
    end
end

-- Weapon proficiencies as aligned columns (atk | damage); atk is gold - clicking
-- the row rolls the attack. Versatile/properties detail hovers. These are skill
-- rows, so no item bonus reaches them: an equipped weapon rolls from its own
-- inventory row below.
local function RenderWeapons(content, sheet, ctx)
    local accomplishment = ctx.accomplishment
    local modById = ctx.modById
    if #sheet.weapons > 0 then
        Header(content, "WEAPON SKILLS (accomplished)")
        local W_ATK_X, W_DMG_X = PAD + 60, PAD   -- column right edges
        local atkHead = Acquire(content, "GameFontHighlightSmall")
        atkHead:SetPoint("TOPRIGHT", content, "TOPRIGHT", -W_ATK_X, content.y)
        atkHead:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
        atkHead:SetText("atk")
        local dmgHead = Acquire(content, "GameFontHighlightSmall")
        dmgHead:SetPoint("TOPRIGHT", content, "TOPRIGHT", -W_DMG_X, content.y)
        dmgHead:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
        dmgHead:SetText("damage")
        content.y = content.y - 14
        for _, w in ipairs(sheet.weapons) do
            local rowY = content.y
            local props = #w.properties > 0 and ("  [" .. table.concat(w.properties, ", ") .. "]") or ""
            local weapon = w
            Row(content, w.name .. props, "", 0, nil, function(tt)
                tt:AddLine(weapon.name, C_GOLD[1], C_GOLD[2], C_GOLD[3])
                tt:AddLine("Damage: " .. (weapon.damage or "-")
                    .. (weapon.versatile and ("  (two-handed " .. weapon.versatile .. ")") or ""), 0.9, 0.9, 0.9)
                if #weapon.properties > 0 then
                    tt:AddLine("Properties: " .. table.concat(weapon.properties, ", "), 0.9, 0.9, 0.9)
                end
                if weapon.attack_total then
                    local attr = modById[weapon.attack_attribute]
                    tt:AddLine("Attack: " .. Signed(weapon.attack_total) .. " ("
                        .. (attr and attr.name or weapon.attack_attribute) .. " modifier "
                        .. Signed(attr and attr.modifier or 0) .. " + accomplished "
                        .. Signed(accomplishment)
                        .. (sheet.derived.attack_modifier ~= 0
                            and (" " .. Signed(sheet.derived.attack_modifier) .. " global") or "")
                        .. ")", 0.9, 0.9, 0.9)
                else
                    tt:AddLine("Accomplished: adds " .. Signed(accomplishment) .. " to attack rolls", 0.56, 0.78, 1)
                end
            end, w.attack_total and ctx.rollSpec(w.name .. " attack", w.attack_total) or nil)
            local atk = Acquire(content, "GameFontHighlightSmall")
            atk:SetPoint("TOPRIGHT", content, "TOPRIGHT", -W_ATK_X, rowY)
            if w.attack_total then
                atk:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3])
                atk:SetText(Signed(w.attack_total))
            else
                atk:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
                atk:SetText("-")
            end
            local dmg = Acquire(content, "GameFontHighlightSmall")
            dmg:SetPoint("TOPRIGHT", content, "TOPRIGHT", -W_DMG_X, rowY)
            dmg:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
            dmg:SetText(w.damage or "-")
        end
    end
end

-- Inventory. Rows render Compute's display entries; the only handle back into
-- the character is entry.index, and every mutation below invalidates the ones
-- after it (removal shifts them), so each click persists and re-renders rather
-- than touching a second row.

-- Runs a mutation against the active character, persisting and refreshing every
-- window when it reports a change. Nothing happens on a viewed sheet: those
-- clicks are never wired in the first place.
local function ApplyToActive(mutate)
    local char, key = ns.GetActiveCharacter()
    if not (char and key) then return end
    if not mutate(char) then return end
    ns.SetCharacter(key, char)
    ns.Systems.RefreshAll()
end

-- Flips one inventory entry between equipped and stashed.
local function ToggleItem(index)
    ApplyToActive(function(char) return ns.Items.ToggleEquipped(char, index) ~= nil end)
end

-- Steps a gear entry's counter (the helper clamps it into [0, MAX_COUNT]). The
-- current count is re-read from the character, not from the rendered row.
local function StepCount(index, delta)
    ApplyToActive(function(char)
        local entry = type(char.inventory) == "table" and char.inventory[index]
        if type(entry) ~= "table" then return false end
        return ns.Items.SetCount(char, index, (tonumber(entry.count) or 0) + delta) ~= nil
    end)
end

-- Dropping an item is destructive (the entry, not the library item), so it is
-- confirmed. The data is the inventory index the row was rendered from.
StaticPopupDialogs["PARCHMENT_ITEM_REMOVE"] = {
    text = "Remove '%s' from this character's inventory?\n\nYour item library is not touched.",
    button1 = "Remove", button2 = CANCEL,
    OnAccept = function(_, index)
        ApplyToActive(function(char) return ns.Items.Remove(char, index) end)
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- The row's headline: the item name plus what it is worth ("Flame Dagger +2",
-- "Chainmail +1 AC"), with a weapon item's linked weapon dimmed after it. A
-- reference that did not resolve names itself (the sentinel is called "Missing
-- item"), so it needs nothing appended - the dimmed row and its tooltip say it.
local function ItemLabel(entry, kind)
    local text = entry.name or "?"
    if entry.missing then return text end
    if kind == "weapon" then
        if entry.bonus ~= 0 then text = text .. " " .. Signed(entry.bonus) end
        if entry.weapon_name then text = text .. "  |cff9e998c" .. entry.weapon_name .. "|r" end
    elseif kind == "equipment" then
        if entry.ac_bonus ~= 0 then text = text .. " " .. Signed(entry.ac_bonus) .. " AC" end
    end
    return text
end

-- Hover breakdown for an inventory row: what the item is, what it does, and
-- (for a reference the library cannot resolve) what happened to it. `own` is
-- true on the player's own sheet, where the row can also be dropped.
local function ItemTip(entry, kind, own)
    return function(tt)
        tt:AddLine(entry.name or "?", C_GOLD[1], C_GOLD[2], C_GOLD[3])
        if entry.missing then
            tt:AddLine("Missing from your item library.", 0.9, 0.45, 0.45, true)
            tt:AddLine("It was deleted, or this sheet came from a player whose items you"
                .. " do not have.", 0.9, 0.9, 0.9, true)
            return
        end
        if entry.description and entry.description ~= "" then
            tt:AddLine(entry.description, 0.85, 0.82, 0.75, true)
        end
        if kind == "weapon" then
            if entry.weapon_name then
                tt:AddLine("Adds " .. Signed(entry.bonus) .. " to " .. entry.weapon_name
                    .. " attack rolls while equipped.", 0.9, 0.9, 0.9, true)
            elseif entry.weapon_id then
                tt:AddLine("Linked to a weapon this system does not define - no attack bonus"
                    .. " applies.", 0.9, 0.9, 0.9, true)
            elseif entry.bonus ~= 0 then
                tt:AddLine("No weapon linked, so its " .. Signed(entry.bonus)
                    .. " has nothing to apply to.", 0.9, 0.9, 0.9, true)
            end
            -- The number this item swings for, broken into the weapon skill it
            -- rides on and the item's own bonus (the skill part is exactly what
            -- the proficiency row above shows).
            if entry.equipped and entry.attack_total then
                local parts = entry.attack_parts or {}
                tt:AddLine("Attack: " .. Signed(entry.attack_total) .. " ("
                    .. (entry.weapon_name or "weapon") .. " skill " .. Signed(parts.base or 0)
                    .. " " .. Signed(parts.bonus or 0) .. " item)", 0.9, 0.9, 0.9)
            end
            tt:AddLine(entry.equipped and "Equipped." or "Stashed.", 0.56, 0.78, 1)
        elseif kind == "equipment" then
            if entry.ac_bonus ~= 0 then
                tt:AddLine("Adds " .. Signed(entry.ac_bonus) .. " AC while equipped.", 0.9, 0.9, 0.9)
            end
            tt:AddLine(entry.equipped and "Equipped." or "Stashed.", 0.56, 0.78, 1)
        else
            tt:AddLine("Carried: " .. (entry.count or 0), 0.9, 0.9, 0.9)
        end
        if entry.source == "wire" then
            tt:AddLine("Shown from the shared sheet - your library does not have this item.",
                0.62, 0.60, 0.55, true)
        end
        if own then
            tt:AddLine("Right-click: remove from inventory", C_DIM[1], C_DIM[2], C_DIM[3])
        end
    end
end

-- The state icon: held/worn when equipped, the backpack when stashed, and a
-- plain backpack for gear (nothing to toggle). Clicking equips or stashes on
-- the own sheet; a viewed sheet still explains the state it shows.
local function StateIcon(content, entry, kind, ctx, y)
    local b = AcquireIconBtn(content)
    b:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y + 1)
    if kind == "gear" then
        b.tex:SetTexture(ICON_STASHED)
        b.tex:Show()
        b:EnableMouse(false)                     -- the row tooltip shows through
        return
    end
    b.tex:SetTexture(entry.equipped and (kind == "weapon" and ICON_HELD or ICON_WORN) or ICON_STASHED)
    b.tex:Show()
    local equipped, index = entry.equipped, entry.index
    b.tip = function(tt)
        tt:AddLine(equipped and "Equipped" or "Stashed", C_GOLD[1], C_GOLD[2], C_GOLD[3])
        if not ctx.viewChar then
            tt:AddLine(equipped and "Click: stash it (its bonus stops counting)"
                or "Click: equip it", 0.56, 0.78, 1)
        end
    end
    if not ctx.viewChar then
        b.click = function() ToggleItem(index) end
    end
end

-- A gear row's counter: the count, flanked by -/+ click targets on the own
-- sheet. Both call the clamping helper, so the ends simply stop.
local function GearCounter(content, entry, ctx, y)
    local value = Acquire(content, "GameFontHighlightSmall")
    value:SetPoint("TOPRIGHT", content, "TOPRIGHT", -CNT_VALUE_X, y)
    value:SetJustifyH("RIGHT")
    value:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
    value:SetText("x" .. (entry.count or 0))
    if ctx.viewChar then return end

    local index = entry.index
    local function step(glyph, x, delta, hint)
        local b = AcquireIconBtn(content)
        b:SetSize(14, ICON_SIZE)
        b:SetPoint("TOPRIGHT", content, "TOPRIGHT", -x, y + 1)
        b.label:SetText(glyph)
        b.label:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3])
        b.tip = function(tt) tt:AddLine(hint, 0.56, 0.78, 1) end
        b.click = function() StepCount(index, delta) end
    end
    step("-", CNT_MINUS_X, -1, "Click: carry one less")
    step("+", CNT_PLUS_X, 1, "Click: carry one more")
end

-- An equipped weapon's own attack total, gold at the row's right edge, plus the
-- click-to-roll spec for the row (nil on a viewed sheet). A stashed weapon shows
-- nothing - it is in the bag - and so does one whose link names no weapon skill
-- this character is accomplished with.
local function WeaponAttackValue(content, entry, kind, ctx, y)
    if kind ~= "weapon" or not (entry.equipped and entry.attack_total) then return nil end
    local atk = Acquire(content, "GameFontHighlightSmall")
    atk:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, y)
    atk:SetJustifyH("RIGHT")
    atk:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3])
    atk:SetText(Signed(entry.attack_total))
    return ctx.rollSpec((entry.name or "Weapon") .. " attack", entry.attack_total)
end

-- One inventory row: the state icon, the headline, and (gear) the counter or
-- (an equipped weapon) its attack total. The row-wide hover button carries the
-- breakdown, a left-click affordance (the attack roll on a weapon, removal on a
-- missing item) and, on the own sheet, right-click to drop the item - the same
-- convention the feat and spell pickers use for removing an entry.
local function InventoryRow(content, entry, kind, ctx)
    local y = content.y
    content.rowIndex = content.rowIndex + 1
    if content.rowIndex % 2 == 0 then
        local stripe = AcquireTex(content)
        stripe:SetColorTexture(C_STRIPE[1], C_STRIPE[2], C_STRIPE[3], C_STRIPE[4])
        stripe:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y + 2)
        stripe:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, y + 2)
        stripe:SetHeight(INV_ROW_H)
    end

    StateIcon(content, entry, kind, ctx, y)
    local x = PAD + ICON_SIZE + 4

    local label = Acquire(content, "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
    local c = entry.missing and C_DIM or C_TEXT
    label:SetTextColor(c[1], c[2], c[3])
    label:SetText(ItemLabel(entry, kind))

    -- A missing item has no library record to count against: its row offers
    -- removal instead of a counter.
    if kind == "gear" and not entry.missing then GearCounter(content, entry, ctx, y) end
    local roll = WeaponAttackValue(content, entry, kind, ctx, y)

    local b = AcquireBtn(content)
    b:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y + 2)
    b:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, y + 2)
    b:SetHeight(INV_ROW_H)
    local own = not ctx.viewChar
    b.tip = ItemTip(entry, kind, own and not entry.missing)
    local index, name = entry.index, entry.name
    local function Drop() StaticPopup_Show("PARCHMENT_ITEM_REMOVE", name or "?", nil, index) end
    if entry.missing and own then
        b.roll = { hint = "Click: remove it from this inventory", click = Drop }
    else
        b.roll = roll
    end
    if own then b.rightClick = Drop end
    content.y = content.y - INV_ROW_H
end

-- The header affordance that opens the add flow for a kind (nil = any kind).
-- Own sheet only: a viewed inventory is not yours to add to.
local function AddAction(ctx, kind)
    if ctx.viewChar or not ns.ItemWizardUI then return nil end
    return {
        text = "+ add item", hint = "Click: add an item from your library",
        click = function() ns.ItemWizardUI.AddFlow(kind) end,
    }
end

local function InventorySection(content, title, entries, kind, ctx)
    if #entries == 0 then return end
    Header(content, title, AddAction(ctx, kind))
    for _, entry in ipairs(entries) do InventoryRow(content, entry, kind, ctx) end
end

-- The three inventory sections, each shown only when it has rows. A character
-- carrying nothing has no inventory at all (Compute leaves it nil): one header
-- then keeps the add flow reachable from the sheet instead of only from the
-- library browser.
local function RenderInventory(content, sheet, ctx)
    local inv = sheet.inventory
    if not inv then
        local action = AddAction(ctx, nil)
        if not action then return end
        Header(content, "INVENTORY", action)
        Paragraph(content, nil, "Nothing carried yet.", C_DIM)
        return
    end
    InventorySection(content, "WEAPONS", inv.weapons, "weapon", ctx)
    InventorySection(content, "EQUIPMENT", inv.equipment, "equipment", ctx)
    InventorySection(content, "GEAR", inv.gear, "gear", ctx)
end

-- Spellcasting (casters): per-school spell attack and save DC columns; atk is
-- gold - clicking a row rolls that spell attack.
local function RenderSpellcasting(content, sheet, ctx)
    if sheet.derived.spell then
        local spell = sheet.derived.spell
        local accomplishment = ctx.accomplishment
        local modById = ctx.modById
        Header(content, "SPELLCASTING")
        local S_ATK_X, S_DC_X = PAD + 44, PAD   -- column right edges
        local sAtkHead = Acquire(content, "GameFontHighlightSmall")
        sAtkHead:SetPoint("TOPRIGHT", content, "TOPRIGHT", -S_ATK_X, content.y)
        sAtkHead:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
        sAtkHead:SetText("atk")
        local dcHead = Acquire(content, "GameFontHighlightSmall")
        dcHead:SetPoint("TOPRIGHT", content, "TOPRIGHT", -S_DC_X, content.y)
        dcHead:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])
        dcHead:SetText("DC")
        content.y = content.y - 14
        -- Hover breakdown, mirroring the weapon-attack tooltip: the effect
        -- shares fall out as differences from the structural parts (casting
        -- modifier + accomplishment, DC additionally save_dc_base). The
        -- casting source is the explicit cast attribute when one is set,
        -- else the classic primary.
        local primaryAttr = modById[sheet.derived.cast_attribute or sheet.derived.primary_attribute]
        local primaryMod = primaryAttr and primaryAttr.modifier or 0
        local primaryName = primaryAttr and primaryAttr.name or "primary"
        local dcBase = ns.DerivedConfig().save_dc_base
        local function SpellTip(label, school)
            return function(tt)
                tt:AddLine(label, C_GOLD[1], C_GOLD[2], C_GOLD[3])
                local atkFx = spell.attack - primaryMod - accomplishment
                local atkLine = "Spell attack: " .. Signed(school and school.attack or spell.attack)
                    .. " (" .. primaryName .. " modifier " .. Signed(primaryMod)
                    .. " + accomplished " .. Signed(accomplishment)
                    .. (atkFx ~= 0 and (" " .. Signed(atkFx) .. " effects") or "")
                    .. (school and school.attack ~= spell.attack
                        and (" " .. Signed(school.attack - spell.attack) .. " " .. school.name) or "")
                    .. ")"
                tt:AddLine(atkLine, 0.9, 0.9, 0.9, true)
                local dcFx = spell.dc - dcBase - primaryMod - accomplishment
                local dcLine = "Save DC: " .. (school and school.dc or spell.dc)
                    .. " (base " .. dcBase
                    .. " + " .. primaryName .. " modifier " .. Signed(primaryMod)
                    .. " + accomplished " .. Signed(accomplishment)
                    .. (dcFx ~= 0 and (" " .. Signed(dcFx) .. " effects") or "")
                    .. (school and school.dc ~= spell.dc
                        and (" " .. Signed(school.dc - spell.dc) .. " " .. school.name) or "")
                    .. ")"
                tt:AddLine(dcLine, 0.9, 0.9, 0.9, true)
            end
        end
        local function SpellRow(label, atkValue, dcValue, school)
            local rowY = content.y
            Row(content, label, "", 0, nil, SpellTip(label, school),
                ctx.rollSpec(label .. " spell attack", atkValue))
            local atk = Acquire(content, "GameFontHighlightSmall")
            atk:SetPoint("TOPRIGHT", content, "TOPRIGHT", -S_ATK_X, rowY)
            atk:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3])
            atk:SetText(Signed(atkValue))
            local dc = Acquire(content, "GameFontHighlightSmall")
            dc:SetPoint("TOPRIGHT", content, "TOPRIGHT", -S_DC_X, rowY)
            dc:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
            dc:SetText(tostring(dcValue))
        end
        if #spell.schools == 0 then
            SpellRow("Spell attack", spell.attack, spell.dc)
        else
            for _, school in ipairs(spell.schools) do
                SpellRow(school.name, school.attack, school.dc, school)
            end
        end
    end
end

-- Sends prose to group chat, chunked under the client's 255-byte message cap:
-- split on newlines, then on word boundaries. Colour escapes are stripped
-- (SendChatMessage rejects them); outside a group the text just prints locally.
-- Each sent chunk is parenthesized, the usual convention for out-of-character
-- lines in an RP channel (every chunk, so a split message stays marked).
local CHAT_MAX = 240
local function PostToChat(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if not IsInGroup() then
        ns.Print(text)
        return
    end
    local channel = IsInRaid() and "RAID" or "PARTY"
    for line in text:gmatch("[^\n]+") do
        while #line > CHAT_MAX do
            local cut = line:sub(1, CHAT_MAX):match(".*()%s")
            if not cut or cut <= 1 then cut = CHAT_MAX + 1 end
            SendChatMessage("(" .. line:sub(1, cut - 1) .. ")", channel)
            line = line:sub(cut):gsub("^%s+", "")
        end
        if line ~= "" then SendChatMessage("(" .. line .. ")", channel) end
    end
end

-- Quick-reference sections for known feats and spells: one paragraph per
-- owned feat rank / known spell, its mechanics (type, cost, range, save,
-- concentration, damage) inline as a soft-blue tag ahead of the rules text,
-- so the numbers are on the sheet without opening a picker. Entries resolve
-- against the VIEWER's active packs; ids that do not resolve (a viewed
-- character built on packs we lack, or stale picks) are summarized in one
-- dim line rather than dropped silently.
local function RenderFeatsSpells(content, sheet, ctx)
    local char = ctx.char
    if not char then return end

    -- Joins the mechanics of a feat rank or spell into one bracket tag.
    local function MetaTag(entry, extra)
        local parts = {}
        if entry.type then parts[#parts + 1] = entry.type end
        local cost = ns.FormatCost(entry.cost)
        if cost then parts[#parts + 1] = cost end
        if entry.range then parts[#parts + 1] = entry.range end
        if entry.save then parts[#parts + 1] = ns.AttrName(entry.save) .. " save" end
        if entry.concentration then parts[#parts + 1] = "Concentration" end
        if entry.damage then parts[#parts + 1] = entry.damage end
        for _, e in ipairs(extra or {}) do parts[#parts + 1] = e end
        if #parts == 0 then return "" end
        return "|cff8ec6ff[" .. table.concat(parts, " - ") .. "]|r  "
    end

    -- Feats: every owned rank of every line, in pack order.
    local featPack = ns.GetFeatPack()
    local featRows, unresolvedFeats = {}, 0
    if type(char.feats) == "table" then
        if featPack then
            for _, line in ipairs(featPack.lines or {}) do
                local owned = ns.Feats.Rank(char, line.id)
                for i = 1, math.min(owned, #(line.ranks or {})) do
                    featRows[#featRows + 1] = { line = line, rank = line.ranks[i], index = i }
                end
            end
        end
        for lineId in pairs(char.feats) do
            if not (featPack and ns.Feats.Line(featPack, lineId)) then
                unresolvedFeats = unresolvedFeats + 1
            end
        end
    end
    local homebrewFeats = (type(char.custom_feats) == "table") and char.custom_feats or {}
    if #featRows > 0 or unresolvedFeats > 0 or #homebrewFeats > 0 then
        Header(content, "FEATS", (not ctx.viewChar) and ns.FeatsUI and {
            text = "open browser", hint = "Click: open the feats browser",
            click = function() ns.FeatsUI.Open() end,
        } or nil)
        for _, r in ipairs(featRows) do
            local title = (r.rank.name or "?") .. "  |cff8ec6ff(" .. (r.line.name or r.line.id)
                .. " " .. r.index .. ")|r"
            Paragraph(content, title .. ":", MetaTag(r.rank) .. (r.rank.description or ""), C_DIM,
                ctx.postSpec((r.rank.name or "?") .. ": " .. (r.rank.description or "")))
        end
        for _, rec in ipairs(homebrewFeats) do
            if type(rec) == "table" then
                local pending = not ns.CharacterSheet.HomebrewActive(char, rec)
                local title = (rec.name or "?") .. "  |cff8ec6ff(homebrew"
                    .. (pending and (", pending until level " .. (rec.level or 1)) or "") .. ")|r"
                local body = MetaTag(rec) .. (rec.description or "")
                if pending then
                    Paragraph(content, nil, "|cff9e998c" .. title .. ":|r  " .. body, C_DIM)
                else
                    Paragraph(content, title .. ":", body, C_DIM,
                        ctx.postSpec((rec.name or "?") .. ": " .. (rec.description or "")))
                end
            end
        end
        if unresolvedFeats > 0 then
            Paragraph(content, nil, unresolvedFeats
                .. " feat line(s) not shown - no matching feats pack active.", C_DIM)
        end
    end

    -- Spells: known ids, grouped by the pack's rank-sorted order.
    local spellPack = ns.GetSpellPack()
    local spellRows, unresolvedSpells = {}, 0
    if type(char.spells) == "table" then
        if spellPack then
            for _, spell in ipairs(ns.Spells.SpellsOf(spellPack)) do
                if ns.Spells.Knows(char, spell.id) then spellRows[#spellRows + 1] = spell end
            end
        end
        for _, id in ipairs(char.spells) do
            if not (spellPack and ns.Spells.Spell(spellPack, id)) then
                unresolvedSpells = unresolvedSpells + 1
            end
        end
    end
    local homebrewSpells = (type(char.custom_spells) == "table") and char.custom_spells or {}
    if #spellRows > 0 or unresolvedSpells > 0 or #homebrewSpells > 0 then
        Header(content, "SPELLS", (not ctx.viewChar) and ns.SpellbookUI and {
            text = "open spellbook", hint = "Click: open the spellbook",
            click = function() ns.SpellbookUI.Open() end,
        } or nil)
        for _, spell in ipairs(spellRows) do
            local school = spellPack and ns.Spells.School(spellPack, spell.school)
            local title = (spell.name or "?") .. "  |cff8ec6ff("
                .. ((school and school.name) or spell.school or "?")
                .. " " .. tostring(spell.rank or "?") .. ")|r"
            Paragraph(content, title .. ":", MetaTag(spell) .. (spell.description or ""), C_DIM,
                ctx.postSpec((spell.name or "?") .. ": " .. (spell.description or "")))
        end
        for _, rec in ipairs(homebrewSpells) do
            if type(rec) == "table" then
                local pending = not ns.CharacterSheet.HomebrewActive(char, rec)
                local school = rec.school and spellPack and ns.Spells.School(spellPack, rec.school)
                local title = (rec.name or "?") .. "  |cff8ec6ff(homebrew"
                    .. (rec.school and (", " .. ((school and school.name) or rec.school)
                        .. (rec.rank and (" " .. rec.rank) or "")) or "")
                    .. (pending and (", pending until level " .. (rec.level or 1)) or "") .. ")|r"
                local body = MetaTag(rec) .. (rec.description or "")
                if pending then
                    Paragraph(content, nil, "|cff9e998c" .. title .. ":|r  " .. body, C_DIM)
                else
                    Paragraph(content, title .. ":", body, C_DIM,
                        ctx.postSpec((rec.name or "?") .. ": " .. (rec.description or "")))
                end
            end
        end
        if unresolvedSpells > 0 then
            Paragraph(content, nil, unresolvedSpells
                .. " spell(s) not shown - no matching spells pack active.", C_DIM)
        end
    end
end

-- Prose blocks: traits and notes. Traits are a titled list of wrapped
-- paragraphs, shown only when non-empty; on the own sheet they are clickable
-- to post their text to group chat (ctx.postSpec, nil on viewed sheets).
-- Notes stay private.
local function RenderProse(content, sheet, ctx)
    -- Traits.
    if #sheet.traits > 0 then
        Header(content, "TRAITS")
        for _, t in ipairs(sheet.traits) do
            Paragraph(content, t.name .. ":", t.description, C_DIM,
                ctx.postSpec(t.name .. ": " .. (t.description or "")))
        end
    end

    -- Notes.
    if sheet.notes and sheet.notes ~= "" then
        Header(content, "NOTES")
        Paragraph(content, nil, sheet.notes, C_DIM)
    end
end

-- Renders the computed sheet into the body. Called on open and after edits.
-- Builds the per-render ctx once (see the section renderers above) and draws
-- each block top to bottom; the section helpers each no-op when their data is
-- absent (no weapons, no spellcasting, no notes).
local function RenderBody(self)
    local content = self.content
    CanvasReset(content)
    local sheet = self.sheet

    local ctx = {
        viewChar = self.viewChar,
        -- The raw character record behind the sheet (the viewed one, or the
        -- roster entry): feats/spells/picks render from it, not from Compute.
        char = self.viewChar or (self.charKey and ns.GetCharacter(self.charKey)) or nil,
        accomplishment = sheet.derived.accomplishment,
        modById = {},
    }
    for _, a in ipairs(sheet.attributes) do ctx.modById[a.id] = a end
    -- Click-to-roll spec, or nil for a viewed (read-only) sheet whose modifiers
    -- are not yours to roll.
    function ctx.rollSpec(label, mod)
        if ctx.viewChar then return nil end
        return { label = label, modifier = mod or 0 }
    end
    -- Click-to-post spec (share a prose block to group chat), or nil for a
    -- viewed sheet.
    function ctx.postSpec(text)
        if ctx.viewChar then return nil end
        return { hint = "Click: post to chat", click = function() PostToChat(text) end }
    end

    RenderOverview(content, sheet, ctx)
    RenderAttributes(content, sheet, ctx)
    RenderSkills(content, sheet, ctx)
    RenderWeapons(content, sheet, ctx)
    RenderInventory(content, sheet, ctx)
    RenderSpellcasting(content, sheet, ctx)
    RenderFeatsSpells(content, sheet, ctx)
    RenderProse(content, sheet, ctx)

    CanvasFinish(content)
end

-- Pushes the current character's resource numbers into the vitals header.
-- Boxes the user is typing in are left alone so an external refresh (e.g. an
-- editor keystroke) does not stomp the in-progress value.
local function RefreshVitals(self)
    local d = self.sheet.derived
    local function setBox(box, v) if not box:HasFocus() then box:SetText(v) end end
    setBox(self.hpBox, tostring(d.hp.current or d.hp.max or 0))
    self.hpMax:SetText("/ " .. tostring(d.hp.max or "?"))
    setBox(self.manaBox, tostring(d.mana.current or d.mana.max or 0))
    self.manaMax:SetText("/ " .. tostring(d.mana.max or "?"))
    setBox(self.tempBox, tostring(d.hp.temp or 0))
    self.tempMax:SetText("")
end

-- Commits a focused, typed-but-not-entered vitals box to the character it was
-- typed FOR. Refresh leaves focused boxes alone but re-points self.charKey, so
-- without this a character switch mid-typing would land the old character's
-- typed HP on the new one when Enter finally commits. The editor's
-- CommitPending solves the same problem for its max HP/Mana boxes.
local function CommitPendingVitals(self)
    local char = self.charKey and ns.GetCharacter(self.charKey)
    if not char then return end
    local function commit(box, field)
        if not (box and box:HasFocus()) then return end
        local n = tonumber(box:GetText())
        if n then char[field] = math.max(0, math.min(99999, math.floor(n))) end
        box:ClearFocus()
    end
    commit(self.hpBox, "current_hp")
    commit(self.manaBox, "current_mana")
    commit(self.tempBox, "temp_hp")
end

-- Recomputes the sheet and redraws. Shows the active character normally, or a
-- received character (read-only) when self.viewChar is set.
local function Refresh(self)
    local viewing = self.viewChar ~= nil

    -- No system loaded: nothing renders meaningfully until one is imported.
    if not ns.HasSystem() then
        self.sheet, self.charKey = nil, nil
        self.title:SetText("Parchment")
        self.subtitle:SetText("")
        CanvasReset(self.content)
        CanvasFinish(self.content)
        if viewing then
            ns.UI.Empty(self, "No system loaded.\n\nImport the matching ruleset to view shared sheets.",
                "Import a system", function() ns.OpenModule("import") end)
        else
            ns.UI.NoSystem(self)
        end
        return
    end

    local char, key
    if viewing then char, key = self.viewChar, nil else char, key = ns.GetActiveCharacter() end
    if key ~= self.charKey then CommitPendingVitals(self) end
    self.charKey = key
    if not char then
        self.title:SetText("Parchment")
        self.subtitle:SetText("")
        self.sheet = nil
        CanvasReset(self.content)
        CanvasFinish(self.content)
        ns.UI.Empty(self, "No character yet.\n\nCreate one to get started, or import an existing one.",
            "Create a character", function() ns.OpenModule("new") end,
            "Import a character", function() ns.OpenModule("import") end)
        return
    end
    ns.UI.HideEmpty(self)
    self.sheet = ns.CharacterSheet.Compute(char, ns.GetSystem(), ns.GetItemLibrary())
    self.title:SetText((self.sheet.name or "Character")
        .. (viewing and self.viewFrom and ("  |cff8ec6ff(from " .. self.viewFrom .. ")|r") or ""))
    self.subtitle:SetText(self.sheet.quote and ('"' .. self.sheet.quote .. '"') or "")

    -- Read-only when viewing someone else's sheet: disable resource edits and
    -- hide the Edit button.
    self.hpBox:SetEnabled(not viewing)
    self.manaBox:SetEnabled(not viewing)
    self.tempBox:SetEnabled(not viewing)
    if self.editBtn then self.editBtn:SetShown(not viewing) end

    RefreshVitals(self)
    RenderBody(self)
end

-- Commits an edited resource value back to the active character.
local function CommitResource(self, field, box)
    local char = ns.GetCharacter(self.charKey)
    if not char then return end
    -- Bound the typed value: integral, non-negative, and not absurdly large.
    local n = tonumber(box:GetText())
    if n then char[field] = math.max(0, math.min(99999, math.floor(n))) end
    box:ClearFocus()
    Refresh(self)
    if ns.Party then ns.Party.OnVitalsChanged() end
end

-- Builds the window once on the shared chrome (drag, close/Escape, grip, and
-- geometry persistence under dbKey "sheet" - the same slot the sheet used
-- before it moved onto UI.CreateWindow, so saved positions carry over).
-- Returns the frame table with helper widget refs.
local function BuildFrame()
    local f = ns.UI.CreateWindow("ParchmentSheetFrame", {
        title = "Parchment", width = FRAME_W, height = FRAME_H,
        minW = MIN_W, minH = MIN_H, maxW = MAX_W, maxH = MAX_H, dbKey = "sheet",
    })

    -- The chrome's title doubles as the character-name title; the quote
    -- subtitle sits beneath it.
    f.title = f.titleFS

    f.subtitle = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.subtitle:SetPoint("TOPLEFT", PAD, -PAD - 22)
    f.subtitle:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    f.subtitle:SetJustifyH("LEFT")
    f.subtitle:SetTextColor(C_DIM[1], C_DIM[2], C_DIM[3])

    -- Vitals header: editable Current HP/Mana.
    local function MakeResource(labelText, anchorX)
        local lbl = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        lbl:SetPoint("TOPLEFT", PAD + anchorX, -PAD - 44)
        lbl:SetText(labelText)
        lbl:SetTextColor(C_HEAD[1], C_HEAD[2], C_HEAD[3])

        local box = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        box:SetSize(44, 18)
        box:SetPoint("TOPLEFT", PAD + anchorX, -PAD - 60)
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetJustifyH("CENTER")

        local maxFS = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        maxFS:SetPoint("LEFT", box, "RIGHT", 6, 0)
        maxFS:SetTextColor(C_TEXT[1], C_TEXT[2], C_TEXT[3])
        return box, maxFS
    end

    f.hpBox, f.hpMax = MakeResource("Hit Points", 0)
    f.manaBox, f.manaMax = MakeResource("Mana", 150)
    f.tempBox, f.tempMax = MakeResource("Temp HP", 290)

    local function wireResource(box, field)
        box:SetScript("OnEnterPressed", function(b) CommitResource(f, field, b) end)
        box:SetScript("OnEscapePressed", function(b) b:ClearFocus(); Refresh(f) end)
    end
    wireResource(f.hpBox, "current_hp")
    wireResource(f.manaBox, "current_mana")
    wireResource(f.tempBox, "temp_hp")

    -- Footer: Edit (opens the editor) and Save to Disk.
    f.editBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.editBtn:SetSize(60, 22)
    f.editBtn:SetText("Edit")
    f.editBtn:SetPoint("BOTTOMLEFT", PAD, 10)
    f.editBtn:SetScript("OnClick", function() ns.OpenModule("edit") end)

    local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveBtn:SetSize(96, 22)
    saveBtn:SetText("Save to Disk")
    saveBtn:SetPoint("BOTTOMLEFT", PAD + 64, 10)
    saveBtn:SetScript("OnClick", ns.SaveToDisk)
    saveBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Reloads the UI to write all Parchment changes to disk.", 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    saveBtn:SetScript("OnLeave", GameTooltip_Hide)

    -- Scrolling body.
    local scroll = CreateFrame("ScrollFrame", "ParchmentSheetScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", PAD, -PAD - 86)
    scroll:SetPoint("BOTTOMRIGHT", -PAD - 22, 38)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(FRAME_W - PAD * 2 - 22, 10)
    content.pool = {}
    content.texPool = {}
    content.btnPool = {}
    content.iconPool = {}
    scroll:SetScrollChild(content)
    f.content = content

    -- Keep the body width matched to the viewport and re-wrap on resize. The
    -- width tracks every pixel, but the (expensive) re-layout is debounced so a
    -- drag-resize only re-wraps once the size settles.
    local reflow = ns.UI.Debounce(0.1, function() if f.sheet then RenderBody(f) end end)
    scroll:SetScript("OnSizeChanged", function(_, width)
        content:SetWidth(width)
        reflow()
    end)

    return f
end

-- Returns the singleton frame, building it on first use.
local function GetFrame()
    if not CharacterSheetUI.frame then
        CharacterSheetUI.frame = BuildFrame()
    end
    return CharacterSheetUI.frame
end

-- Opens (and refreshes) the sheet showing the active character (clears any
-- received-character view).
function CharacterSheetUI.Open()
    local f = GetFrame()
    f.viewChar, f.viewFrom = nil, nil
    Refresh(f)
    f:Show()
end

-- Opens the sheet showing a received character, read-only.
function CharacterSheetUI.ShowCharacter(char, from)
    local f = GetFrame()
    f.viewChar, f.viewFrom = char, from
    Refresh(f)
    f:Show()
    f:Raise()
end

-- Toggles visibility; refreshes (own character) when opening.
function CharacterSheetUI.Toggle()
    local f = GetFrame()
    if f:IsShown() then f:Hide() else CharacterSheetUI.Open() end
end

-- Re-renders the sheet if it is currently open (e.g. after an import changed
-- the active character).
function CharacterSheetUI.RefreshIfShown()
    local f = CharacterSheetUI.frame
    if f and f:IsShown() then Refresh(f) end
end

-- Register with Core so /pmt sheet opens it.
ns.RegisterModule("sheet", CharacterSheetUI.Toggle)
