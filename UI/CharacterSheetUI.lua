-- Parchment - Character Sheet (UI)
--
-- Builds and drives the character sheet window. Owns one reusable frame: a
-- draggable, Escape-closable panel with a fixed vitals header (editable current
-- HP/Mana) and a scrolling body that renders the computed sheet - attributes,
-- derived stats, skills and saves, weapons, traits, the homebrew ability path
-- and notes.
--
-- All layout is data-driven from ns.CharacterSheet.Compute; nothing here knows
-- any specific ruleset, so whatever system the user imports renders too.
--
-- Reads from: ns.GetActiveCharacter, ns.GetSystem, ns.CharacterSheet.Compute.
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

local CharacterSheetUI = {}
ns.CharacterSheetUI = CharacterSheetUI

-- Formats a number with an explicit sign (+3, -2, +0).
local Signed = ns.UI.Signed

-- Trims trailing ".0" off a number formatted for display (13.0 -> 13).
local function Num(n)
    if n == math.floor(n) then return tostring(math.floor(n)) end
    return tostring(n)
end

-- Soft-blue inline tag naming the trait/perk(s) that modified a stat, so it is
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
    content.rowIndex = 0
end

-- Returns the next pooled hover button (transparent, spans a row) used to show
-- a breakdown tooltip and/or roll a check. Scripts read btn.tip(GameTooltip)
-- and btn.roll = { label, modifier, who } (set fresh on every render).
local function AcquireBtn(content)
    content.btnUsed = content.btnUsed + 1
    local b = content.btnPool[content.btnUsed]
    if not b then
        b = CreateFrame("Button", nil, content)
        b:SetScript("OnEnter", function(self)
            if not (self.tip or self.roll) then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.tip then self.tip(GameTooltip) end
            if self.roll then
                GameTooltip:AddLine("Click: roll d20 " .. Signed(self.roll.modifier), 0.56, 0.78, 1)
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        b:SetScript("OnClick", function(self)
            if self.roll then
                ns.Dice.Check(self.roll.label, self.roll.modifier, self.roll.who)
            end
        end)
        content.btnPool[content.btnUsed] = b
    end
    b:ClearAllPoints()
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

-- Hides pooled regions left over from a previous, longer render.
local function CanvasFinish(content)
    for i = content.used + 1, #content.pool do content.pool[i]:Hide() end
    for i = content.texUsed + 1, #content.texPool do content.texPool[i]:Hide() end
    for i = content.btnUsed + 1, #content.btnPool do content.btnPool[i]:Hide() end
    content:SetHeight(-content.y + PAD)
end

-- Adds a gold section header followed by a thin divider rule. Resets the row
-- stripe parity so each section starts its banding fresh.
local function Header(content, text)
    content.y = content.y - 12
    local fs = Acquire(content, "GameFontNormal")
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, content.y)
    fs:SetTextColor(C_GOLD[1], C_GOLD[2], C_GOLD[3])
    fs:SetText(text)
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
-- ({ label, modifier, who }) is given, clicking the row rolls that check.
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
-- gold inline; body wraps beneath the available width.
local function Paragraph(content, title, body, color)
    local width = content:GetWidth() - PAD * 2
    local fs = Acquire(content, "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, content.y)
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    local c = color or C_DIM
    fs:SetTextColor(c[1], c[2], c[3])
    local text = title and ("|cffc8a868" .. title .. "|r  " .. (body or "")) or (body or "")
    fs:SetText(text)
    content.y = content.y - fs:GetStringHeight() - 6
end

-- Renders the computed sheet into the body. Called on open and after edits.
local function RenderBody(self)
    local content = self.content
    CanvasReset(content)
    local sheet = self.sheet

    -- Click-to-roll specs. Only for the own character - a viewed (received)
    -- sheet is read-only and its modifiers are not yours to roll.
    local function rollSpec(label, mod)
        if self.viewChar then return nil end
        return { label = label, modifier = mod or 0, who = sheet.name }
    end

    -- Derived stats, two readable rows of pairs.
    Header(content, "OVERVIEW")
    Row(content, "Level", tostring(sheet.level))
    Row(content, "Hit Dice", sheet.derived.hit_dice)
    Row(content, "Armor Class", tostring(sheet.derived.ac), 0, C_GOLD)
    Row(content, "Initiative", Signed(sheet.derived.initiative), 0, nil, nil,
        rollSpec("Initiative", sheet.derived.initiative))
    Row(content, "Movement", Num(sheet.derived.movement) .. "m")
    Row(content, "Actions", tostring(sheet.derived.actions))
    Row(content, "Save DC", tostring(sheet.derived.save_dc), 0, C_GOLD)
    Row(content, "Accomplishment Bonus", Signed(sheet.derived.accomplishment))
    Row(content, "Primary Attribute", sheet.derived.primary_attribute or "-")
    if sheet.derived.attack_modifier ~= 0 then
        Row(content, "Global Attack Modifier", Signed(sheet.derived.attack_modifier), 0, C_DIM)
    end

    -- Attributes.
    Header(content, "ATTRIBUTES")
    for _, a in ipairs(sheet.attributes) do
        local value
        if a.bonus ~= 0 then
            value = string.format("%d %s = %d    %s", a.base, Signed(a.bonus), a.final, Signed(a.modifier))
        else
            value = string.format("%d    %s", a.final, Signed(a.modifier))
        end
        Row(content, a.name, value, 0, nil, nil, rollSpec(a.name .. " check", a.modifier))
        if #a.sources > 0 then
            Row(content, "", table.concat(a.sources, ", "), INDENT, C_DIM)
        end
    end

    -- Attacks (as recorded on the sheet).
    if #sheet.attack_lines > 0 then
        Header(content, "ATTACKS")
        for _, al in ipairs(sheet.attack_lines) do
            Row(content, al.name, (al.die or "") .. " " .. Signed(al.modifier or 0))
        end
    end

    -- Skills and saves, grouped under each attribute's saving throw. Each row
    -- carries a hover tooltip breaking down how its total is reached.
    Header(content, "SKILLS & SAVING THROWS")
    local saveByAttr, modById = {}, {}
    for _, s in ipairs(sheet.saves) do saveByAttr[s.id] = s end
    for _, a in ipairs(sheet.attributes) do modById[a.id] = a end
    local accomplishment = sheet.derived.accomplishment
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
            save and rollSpec(a.name .. " save", save.total))
        for _, sk in ipairs(skillsByAttr[a.id] or {}) do
            local name = (sk.accomplished and "* " or "") .. sk.name .. SourceTag(sk.sources)
            Row(content, name, Signed(sk.total), INDENT, sk.accomplished and C_STAR or C_TEXT,
                breakdownTip(sk.name, a, sk.accomplished, sk.sources, sk.total),
                rollSpec(sk.name, sk.total))
        end
    end

    -- Weapon proficiencies (hover for damage and properties).
    if #sheet.weapons > 0 then
        Header(content, "WEAPON SKILLS (accomplished)")
        for _, w in ipairs(sheet.weapons) do
            local props = #w.properties > 0 and ("  [" .. table.concat(w.properties, ", ") .. "]") or ""
            local weapon = w
            local value = w.damage or ""
            if w.attack_total then
                value = Signed(w.attack_total) .. (w.damage and ("    " .. w.damage) or "")
            end
            Row(content, w.name .. props, value, 0, nil, function(tt)
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
            end, w.attack_total and rollSpec(w.name .. " attack", w.attack_total) or nil)
        end
    end

    -- Traits.
    if #sheet.traits > 0 then
        Header(content, "TRAITS")
        for _, t in ipairs(sheet.traits) do
            Paragraph(content, t.name .. ":", t.description, C_DIM)
        end
    end

    -- Selected sphere perks.
    if #sheet.sphere_perks > 0 then
        Header(content, "PERKS")
        for _, p in ipairs(sheet.sphere_perks) do
            local title = p.name .. (p.rank > 1 and (" x" .. p.rank) or "")
                .. (p.choices and #p.choices > 0 and ("  |cff8ec6ff[" .. table.concat(p.choices, ", ") .. "]|r") or "")
                .. (p.sphere and ("  |cff8ec6ff(" .. p.sphere .. ")|r") or "")
            Paragraph(content, title .. ":", p.description, C_DIM)
        end
    end

    -- Homebrew ability path.
    if #sheet.custom_perks > 0 then
        Header(content, "ABILITY PATH")
        for _, p in ipairs(sheet.custom_perks) do
            Paragraph(content, "Lv" .. (p.level or "?") .. " " .. p.name .. ":", p.description, C_DIM)
        end
    end

    -- Notes.
    if sheet.notes and sheet.notes ~= "" then
        Header(content, "NOTES")
        Paragraph(content, nil, sheet.notes, C_DIM)
    end

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
    self.sheet = ns.CharacterSheet.Compute(char, ns.GetSystem())
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
    local n = tonumber(box:GetText())
    if n then char[field] = n end
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
    scroll:SetScrollChild(content)
    f.content = content

    -- Keep the body width matched to the viewport and re-wrap on resize.
    scroll:SetScript("OnSizeChanged", function(self, width)
        content:SetWidth(width)
        if f.sheet then RenderBody(f) end
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
