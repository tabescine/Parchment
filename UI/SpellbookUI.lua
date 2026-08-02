-- Parchment - Spellbook (UI)
--
-- The spell picker: spells rendered as cards sorted by rank, filtered by a
-- left rail of schools ("All" plus one entry per school; a school locked by
-- its opposed partner shows the lock). Each card carries name, rank, type,
-- cost, range, save, concentration and description; unknown spells offer a
-- Learn button gated by Modules/Spells.lua (school lock, cast-attribute
-- score, and a free pick in the shared ledger - enforced, not advisory).
-- Learning the FIRST spell of a school with an opposed partner confirms via
-- popup, because it locks that partner out for the character. Cards that
-- cannot be learned keep a disabled Learn button carrying the reason, and
-- every card explains its status on hover. Right-clicking a known card
-- unlearns the spell after a confirm popup. A search box filters across all
-- schools; while a query is active it bypasses the rail filter.
--
-- The rail ends in a Homebrew section: the character's custom spells
-- (char.custom_spells) as cards - "+ New spell" opens the homebrew wizard,
-- left-click edits an entry, right-click deletes it, and records gained at a
-- level above the character's render dimmed as pending.
--
-- Cards are pooled and reused (frames are permanent in WoW) and measure
-- their description text to size themselves, like the feats browser.
--
-- Reads from: ns.GetSystem, ns.GetSpellPack, ns.GetActiveCharacter,
--   ns.GetItemLibrary, ns.CharacterSheet.Compute, ns.Spells, ns.Homebrew,
--   ns.HomebrewUI, ns.Picks, ns.FormatCost, ns.AttrName, ns.UI.
-- Exposes on ns.SpellbookUI: Open, Toggle, RefreshIfShown, and .frame.
-- Registers the "spellbook" module opener with Core.

local ADDON, ns = ...

local UI = ns.UI

local LEGEND = "Learn adds a spell - right-click a known one unlearns it, shift-click puts its"
    .. " link in chat"
local SEARCH_LEGEND = "Searching all schools - the rail filter is off until the search clears."
local STATUS_COLOR = {
    known = { 0.55, 0.85, 0.55 },
    open = UI.GOLD,
    locked = { 0.55, 0.53, 0.50 },
}

-- Blizzard textures for the rail entries (the hub's flat-nav treatment;
-- Parchment ships no art). The friends-list bar is cropped past its rounded
-- left cap; the quest-title gradient marks the selected entry.
local TEX_HOVER = "Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar"
local TEX_SELECTED = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

local SpellbookUI = {}
ns.SpellbookUI = SpellbookUI

local Refresh

-- Sets the transient message line.
local function SetMsg(self, text, isError)
    local c = isError and UI.RED or UI.DIM
    self.msg:SetTextColor(c[1], c[2], c[3])
    self.msg:SetText(text or "")
end

-- The trimmed search query, or "" when not searching.
local function Query(self)
    return tostring(self.query or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Roman numerals for rank badges.
local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }
local function Roman(n)
    return ROMAN[n] or tostring(n)
end

-- Applies a validated learn, or reports why it cannot happen.
local function DoLearn(f, spell)
    local ok, reason = ns.Spells.Learn(f.char, f.sheet, f.pack, spell)
    if ok then
        SetMsg(f, "Learned " .. (spell.name or "?") .. ".", false)
        if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
        Refresh(f)
    else
        SetMsg(f, reason or "Cannot learn.", true)
    end
end

-- Applies a confirmed unlearn, or reports why it cannot happen. The spell is
-- re-checked by Modules/Spells.lua, so a state change while the popup stood
-- (another window unlearning it, a pack switch) is caught rather than trusted.
local function DoUnlearn(f, spell)
    if not (f and f.char and spell) then return end
    local ok, reason = ns.Spells.Unlearn(f.char, spell.id)
    if ok then
        SetMsg(f, "Unlearned " .. (spell.name or "?") .. ".", false)
        if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
        Refresh(f)
    else
        SetMsg(f, reason or "Cannot unlearn.", true)
    end
end

-- Confirm dialog for a right-click unlearn. Data carries the window and spell
-- so nothing is captured in an upvalue that a redraw could stale out.
StaticPopupDialogs["PARCHMENT_SPELL_UNLEARN"] = {
    text = "Unlearn '%s'?\n\nThis refunds 1 pick.",
    button1 = "Unlearn", button2 = CANCEL,
    OnAccept = function(_, data)
        if data then DoUnlearn(data.window, data.spell) end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Confirm dialog for a school-locking first pick. Data carries the window and
-- spell; the learn re-validates at accept time, so a state change in between
-- (another pick, a pack switch) is caught rather than trusted.
StaticPopupDialogs["PARCHMENT_SPELL_LOCK"] = {
    text = "%s\n\nThis is permanent for this character while they know %s spells.",
    button1 = "Learn it",
    button2 = CANCEL,
    OnAccept = function(_, data)
        if data and data.window and data.spell then DoLearn(data.window, data.spell) end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- The Learn click: warn (once) when the pick locks out an opposed school.
local function LearnClicked(f, spell)
    local ok, reason = ns.Spells.CanLearn(f.char, f.sheet, f.pack, spell)
    if not ok then
        SetMsg(f, reason or "Cannot learn.", true)
        return
    end
    local wouldLock = ns.Spells.WouldLock(f.char, f.pack, spell)
    if wouldLock then
        local school = ns.Spells.School(f.pack, spell.school)
        StaticPopup_Show("PARCHMENT_SPELL_LOCK",
            "Learning \"" .. (spell.name or "?") .. "\" commits to "
            .. ((school and school.name) or spell.school) .. " and locks out "
            .. (wouldLock.name or wouldLock.id or "its opposed school") .. ".",
            (school and school.name) or spell.school,
            { window = f, spell = spell })
        return
    end
    DoLearn(f, spell)
end

local function AcquireCard(self)
    local content = self.content
    content.usedCards = content.usedCards + 1
    local card = content.cardPool[content.usedCards]
    if not card then
        card = CreateFrame("Button", nil, content)
        card:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local bg = card:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.07, 0.07, 0.08, 0.9)
        card.title = card:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        card.title:SetPoint("TOPLEFT", 10, -6)
        card.title:SetJustifyH("LEFT")
        card.learn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
        card.learn:SetSize(64, 18)
        card.learn:SetPoint("TOPRIGHT", -8, -5)
        card.learn:SetText("Learn")
        card.learn:SetScript("OnClick", function(btn)
            LearnClicked(btn.window, btn.spell)
        end)
        -- A disabled button gets no mouse events unless motion scripts are
        -- kept alive, and its tooltip is the only place the refusal shows
        -- before the click.
        card.learn:SetMotionScriptsWhileDisabled(true)
        card.learn:SetScript("OnEnter", function(btn)
            if not btn.reason then return end
            GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
            GameTooltip:SetText("Cannot learn", 1, 1, 1)
            GameTooltip:AddLine(btn.reason, UI.RED[1], UI.RED[2], UI.RED[3], true)
            GameTooltip:Show()
        end)
        card.learn:SetScript("OnLeave", GameTooltip_Hide)
        card.title:SetPoint("RIGHT", card.learn, "LEFT", -8, 0)
        card.meta = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        card.meta:SetPoint("TOPLEFT", 10, -24)
        card.meta:SetPoint("RIGHT", -10, 0)
        card.meta:SetJustifyH("LEFT")
        card.meta:SetTextColor(UI.HEAD[1], UI.HEAD[2], UI.HEAD[3])
        card.desc = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        card.desc:SetPoint("TOPLEFT", 10, -38)
        card.desc:SetPoint("RIGHT", -10, 0)
        card.desc:SetJustifyH("LEFT")
        card.desc:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
        card.desc:SetWordWrap(true)
        card:SetScript("OnClick", function(c, mouseButton)
            local f = c.window
            -- Shift-click posts the card as a chat link (pack and homebrew
            -- cards alike) instead of any other click behaviour.
            if mouseButton ~= "RightButton" and IsShiftKeyDown and IsShiftKeyDown() then
                if c.homebrewIndex then
                    local rec = ns.Homebrew.List(f.char, "spell")[c.homebrewIndex]
                    if rec then ns.ChatLinks.PostLink(ns.ChatLinks.Homebrew("spell", rec)) end
                elseif c.spell then
                    ns.ChatLinks.PostLink(ns.ChatLinks.Spell(f.pack, c.spell))
                end
                return
            end
            -- Homebrew cards edit on left-click and delete on right-click via
            -- the homebrew wizard; pack cards only forget known spells.
            if c.homebrewIndex then
                if ns.HomebrewUI then
                    if mouseButton == "RightButton" then
                        ns.HomebrewUI.Delete("spell", c.homebrewIndex)
                    else
                        ns.HomebrewUI.Open("spell", c.homebrewIndex)
                    end
                end
                return
            end
            if mouseButton ~= "RightButton" then return end
            if not ns.Spells.Knows(f.char, c.spell.id) then return end
            StaticPopup_Show("PARCHMENT_SPELL_UNLEARN", c.spell.name or "?", nil,
                { window = f, spell = c.spell })
        end)
        -- Status tooltip: the card colours say known/open/locked, this says why.
        card:SetScript("OnEnter", function(c)
            if not c.tip then return end
            GameTooltip:SetOwner(c, "ANCHOR_RIGHT")
            GameTooltip:SetText(c.tipTitle or " ", 1, 1, 1)
            GameTooltip:AddLine(c.tip, UI.TEXT[1], UI.TEXT[2], UI.TEXT[3], true)
            GameTooltip:Show()
        end)
        card:SetScript("OnLeave", GameTooltip_Hide)
        content.cardPool[content.usedCards] = card
    end
    card:Show()
    return card
end

local function AcquireRail(self)
    self.usedRail = self.usedRail + 1
    local btn = self.railPool[self.usedRail]
    if not btn then
        btn = CreateFrame("Button", nil, self)
        btn:SetSize(104, 20)
        -- The selected entry is disabled (it is "where you are", not an
        -- unavailable filter); a disabled button sees no mouse at all unless
        -- motion scripts stay alive.
        btn:SetMotionScriptsWhileDisabled(true)
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture(TEX_HOVER)
        hl:SetTexCoord(0.25, 1, 0, 1)
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.6)
        btn.sel = btn:CreateTexture(nil, "BACKGROUND")
        btn.sel:SetAllPoints()
        btn.sel:SetTexture(TEX_SELECTED)
        btn.sel:SetAlpha(0.7)
        btn.sel:Hide()
        btn.label = btn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        btn.label:SetPoint("LEFT", 6, 0)
        btn.label:SetPoint("RIGHT", -2, 0)
        btn.label:SetJustifyH("LEFT")
        btn.label:SetWordWrap(false)
        btn:SetScript("OnClick", function(b)
            local f = b.window
            f.schoolFilter = b.schoolId
            Refresh(f)
        end)
        self.railPool[self.usedRail] = btn
    end
    btn:Show()
    return btn
end

-- One spell's meta text: school (when unfiltered), type, cost, range, save,
-- concentration, damage and the cast gate.
local function MetaText(self, spell)
    local parts = { "Rank " .. Roman(tonumber(spell.rank) or 0) }
    if self.schoolFilter == nil then
        local school = ns.Spells.School(self.pack, spell.school)
        parts[#parts + 1] = (school and school.name) or spell.school
    end
    if spell.type then parts[#parts + 1] = spell.type end
    local cost = ns.FormatCost(spell.cost)
    if cost then parts[#parts + 1] = cost end
    if spell.range then parts[#parts + 1] = "Range: " .. spell.range end
    if spell.save then parts[#parts + 1] = ns.AttrName(spell.save) .. " save" end
    if spell.concentration then parts[#parts + 1] = "Concentration" end
    if spell.damage then parts[#parts + 1] = spell.damage end
    local req = ns.Spells.CastReq(self.pack, spell.rank)
    if req then
        local attr = self.char.cast_attribute
        parts[#parts + 1] = "needs " .. (attr and ns.AttrName(attr) or "cast attribute") .. " " .. req
    end
    return table.concat(parts, "  -  ")
end

-- The tooltip for a spell card: its status plus the cause. Takes the refusal
-- reason CanLearn already produced (nil when learnable). Returns title, body.
local function SpellTip(self, spell, status, reason)
    if status == "known" then
        return "Known", "Right-click to unlearn it and refund its pick."
    end
    if status == "locked" then
        local lockedBy = ns.Spells.LockedBy(self.char, self.pack, spell.school)
        local locker = lockedBy and ns.Spells.School(self.pack, lockedBy)
        local school = ns.Spells.School(self.pack, spell.school)
        return "School locked", "You know " .. ((locker and locker.name) or lockedBy or "opposed")
            .. " spells, which closes "
            .. ((school and school.name) or spell.school or "this school") .. "."
    end
    if reason then return "Cannot learn", reason end
    local wouldLock = ns.Spells.WouldLock(self.char, self.pack, spell)
    return "Open", wouldLock
        and ("Learn takes it for 1 pick and locks out "
            .. (wouldLock.name or wouldLock.id or "its opposed school") .. ".")
        or "Learn takes it for 1 pick."
end

-- Lays out the left rail: "All" plus one button per school, with lock marks.
local function RenderRail(self)
    self.usedRail = 0
    local y = -70
    -- A search spans every school, so no rail entry is the active filter while
    -- a query stands - drop the band rather than lie about it.
    local searching = Query(self) ~= ""
    local function add(label, schoolId, count, locked)
        local btn = AcquireRail(self)
        btn.window, btn.schoolId = self, schoolId
        local selected = self.schoolFilter == schoolId and not searching
        btn.label:SetText((locked and "|cff999999" or "") .. label
            .. (count and (" (" .. count .. ")") or "") .. (locked and " x|r" or ""))
        -- Rail buttons are pooled: band, font and enabled state are set on
        -- every entry every render, or a reused button keeps the selection it
        -- carried under the previous filter.
        btn.label:SetFontObject(selected and _G.GameFontNormal or _G.GameFontHighlight)
        btn.sel:SetShown(selected)
        btn:SetEnabled(not selected)
        btn:SetPoint("TOPLEFT", 14, y)
        y = y - 22
    end
    add("All", nil, #ns.Spells.SpellsOf(self.pack))
    for _, school in ipairs(self.pack.schools or {}) do
        if type(school) == "table" and school.id then
            add(school.name or school.id, school.id, #ns.Spells.SpellsOf(self.pack, school.id),
                ns.Spells.LockedBy(self.char, self.pack, school.id) ~= nil)
        end
    end
    add("Homebrew", "__homebrew", #ns.Homebrew.List(self.char, "spell"))
    for i = self.usedRail + 1, #self.railPool do self.railPool[i]:Hide() end
end

-- One homebrew spell's meta text: gained level plus its quick-ref fields.
local function HomebrewMeta(self, rec)
    local parts = { "gained at level " .. (rec.level or 1) }
    if rec.school then
        local school = ns.Spells.School(self.pack, rec.school)
        parts[#parts + 1] = ((school and school.name) or rec.school)
            .. (rec.rank and (" rank " .. rec.rank) or "")
    end
    if rec.type then parts[#parts + 1] = rec.type end
    local cost = ns.FormatCost(rec.cost)
    if cost then parts[#parts + 1] = cost end
    if rec.range then parts[#parts + 1] = "Range: " .. rec.range end
    if rec.save then parts[#parts + 1] = ns.AttrName(rec.save) .. " save" end
    if rec.concentration then parts[#parts + 1] = "Concentration" end
    if rec.damage then parts[#parts + 1] = rec.damage end
    return table.concat(parts, "  -  ")
end

-- Lays out the Homebrew view: a "+ New" button, then one card per record
-- (left-click edits in the wizard, right-click deletes; pending ones dim).
local function RenderHomebrew(self)
    local content = self.content
    content.usedCards = 0
    local width = content:GetWidth()
    self.newBtn:Show()
    self.newBtn:ClearAllPoints()
    self.newBtn:SetPoint("TOPLEFT", 0, -4)
    local y = -30

    local list = ns.Homebrew.List(self.char, "spell")
    for i, rec in ipairs(list) do
        if type(rec) == "table" then
            local card = AcquireCard(self)
            card.window, card.homebrewIndex = self, i
            card.spell = nil
            card:SetPoint("TOPLEFT", 0, y)
            card:SetWidth(width)
            local active = ns.Homebrew.Active(self.char, rec)
            local sc = active and STATUS_COLOR.known or STATUS_COLOR.locked
            card.title:SetText((rec.name or "?") .. (active and "" or "  (pending)"))
            card.title:SetTextColor(sc[1], sc[2], sc[3])
            card.meta:SetText(HomebrewMeta(self, rec))
            card.desc:SetText(rec.description or "")
            card.learn:Hide()
            card.learn.reason = nil
            -- Pending records render dimmed; the tooltip says what they wait on.
            card.tipTitle = (not active) and "Pending" or nil
            card.tip = (not active)
                and ("Gained at level " .. (rec.level or 1) .. "; this character is not there yet.")
                or nil
            local descH = (rec.description and rec.description ~= "")
                and (card.desc:GetStringHeight() + 6) or 0
            card:SetHeight(24 + 14 + descH + 6)
            y = y - card:GetHeight() - 4
        end
    end
    for i = content.usedCards + 1, #content.cardPool do content.cardPool[i]:Hide() end
    content:SetHeight(math.max(10, -y + 8))
    SetMsg(self, #list == 0
        and "No homebrew spells yet - write one with '+ New spell'."
        or "Click a homebrew spell to edit it, right-click to delete it.", false)
end

-- Lays out the spell cards for the current filter or search.
local function RenderList(self)
    local content = self.content
    local query = Query(self)
    self.newBtn:Hide()
    -- The legend doubles as the search's status line: it is the one text that
    -- transient feedback in self.msg never overwrites.
    self.legend:SetText((query ~= "") and SEARCH_LEGEND or LEGEND)
    if self.schoolFilter == "__homebrew" and query == "" then
        RenderHomebrew(self)
        return
    end
    content.usedCards = 0
    local width = content:GetWidth()
    local y = -4

    local spells = (query ~= "") and ns.Spells.Search(self.pack, query)
        or ns.Spells.SpellsOf(self.pack, self.schoolFilter)

    for _, spell in ipairs(spells) do
        local card = AcquireCard(self)
        card.window, card.spell = self, spell
        card.homebrewIndex = nil
        card:SetPoint("TOPLEFT", 0, y)
        card:SetWidth(width)
        local known = ns.Spells.Knows(self.char, spell.id)
        local locked = ns.Spells.LockedBy(self.char, self.pack, spell.school) ~= nil
        local status = known and "known" or (locked and "locked" or "open")
        local sc = STATUS_COLOR[status]
        card.title:SetText((spell.name or "?") .. (known and "  |cff8cd98c(known)|r" or ""))
        card.title:SetTextColor(sc[1], sc[2], sc[3])
        card.meta:SetText(MetaText(self, spell))
        card.desc:SetText(spell.description or "")
        card.learn:SetShown(not known and not locked)
        card.learn.window, card.learn.spell = self, spell
        -- Affordability shows before the click, not after it: an unlearnable
        -- open spell keeps a disabled button plus reason.
        local reason
        if status == "open" then
            local canLearn, why = ns.Spells.CanLearn(self.char, self.sheet, self.pack, spell)
            reason = (not canLearn) and (why or "Cannot learn.") or nil
            card.learn:SetEnabled(canLearn)
        end
        card.learn.reason = reason
        card.tipTitle, card.tip = SpellTip(self, spell, status, reason)
        local descH = (spell.description and spell.description ~= "")
            and (card.desc:GetStringHeight() + 6) or 0
        card:SetHeight(24 + 14 + descH + 6)
        y = y - card:GetHeight() - 4
    end

    for i = content.usedCards + 1, #content.cardPool do content.cardPool[i]:Hide() end
    content:SetHeight(math.max(10, -y + 8))

    if #spells == 0 then
        SetMsg(self, (query ~= "") and ("No spells match \"" .. query .. "\".")
            or "No spells here.", false)
    end
end

-- Recomputes the active character, pack and sheet, then redraws.
Refresh = function(self)
    local function blank()
        for _, c in ipairs(self.content.cardPool) do c:Hide() end
        for _, b in ipairs(self.railPool) do b:Hide() end
        self.newBtn:Hide()
        self.points:SetText("")
        self.castInfo:SetText("")
        self.packLabel:SetText("")
    end

    if not ns.HasSystem() then
        blank()
        ns.UI.NoSystem(self)
        return
    end
    local pack = ns.GetSpellPack()
    self.pack = pack
    if not pack then
        blank()
        ns.UI.Empty(self, "No spells pack active.\n\nImport one, or adopt one your DM shares.",
            "Import a spells pack", function() ns.OpenModule("import") end)
        return
    end
    local char = ns.GetActiveCharacter()
    self.char = char
    if not char then
        blank()
        ns.UI.Empty(self, "No character yet.\n\nCreate one to learn spells, or import an existing one.",
            "Create a character", function() ns.OpenModule("new") end,
            "Import a character", function() ns.OpenModule("import") end)
        return
    end
    ns.UI.HideEmpty(self)

    self.sheet = ns.CharacterSheet.Compute(char, ns.GetSystem(), ns.GetItemLibrary())
    self.packLabel:SetText(pack.pack_name or "")
    -- The shared budget reads as what is left to spend, green until it is gone;
    -- the cast attribute is reference, so it keeps its own dim string.
    local spent, budget = ns.Picks.Points(char)
    local left = budget - spent
    self.points:SetText(left .. ((left == 1) and " pick left" or " picks left"))
    local pc = (left > 0) and UI.GREEN or UI.RED
    self.points:SetTextColor(pc[1], pc[2], pc[3])
    self.castInfo:SetText(char.cast_attribute
        and ("Casts with " .. ns.AttrName(char.cast_attribute)) or "")
    RenderRail(self)
    RenderList(self)
end

local function BuildFrame()
    local f = UI.CreateWindow("ParchmentSpellbookFrame", {
        title = "Spellbook", width = 560, height = 560,
        minW = 460, minH = 380, maxW = 900, maxH = 1000, dbKey = "spellbookWindow",
    })
    f.railPool, f.usedRail = {}, 0

    f.packLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.packLabel:SetPoint("TOPLEFT", 16, -44)
    f.packLabel:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])

    -- The picks budget is the number that decides every Learn click, so it
    -- carries the full-size font; Refresh colours it green/red.
    f.points = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.points:SetPoint("TOPRIGHT", -16, -46)

    -- The cast attribute sits on the same header row, dim and small, so the
    -- budget reads as the only number that changes with a pick.
    f.castInfo = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.castInfo:SetPoint("RIGHT", f.points, "LEFT", -10, 0)
    f.castInfo:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    f.searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.searchBox:SetSize(140, 18)
    f.searchBox:SetPoint("TOPRIGHT", -18, -68)
    f.searchBox:SetAutoFocus(false)
    f.searchBox:SetScript("OnEscapePressed", function(box)
        box:SetText("")
        box:ClearFocus()
    end)
    f.searchBox:SetScript("OnEnterPressed", function(box) box:ClearFocus() end)
    local runSearch = UI.Debounce(0.15, function() Refresh(f) end)
    f.searchBox:SetScript("OnTextChanged", function(box)
        local q = box:GetText()
        if q == f.query then return end
        f.query = q
        runSearch()
    end)
    UI.SetPlaceholder(f.searchBox, "Search spells")

    f.legend = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.legend:SetPoint("TOPLEFT", 130, -50)
    f.legend:SetPoint("RIGHT", f.castInfo, "LEFT", -12, 0)
    f.legend:SetJustifyH("LEFT")
    f.legend:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    f.legend:SetText(LEGEND)

    -- Both anchors fix the same top edge, so the explicit height stands: two
    -- wrapped lines, enough for a refusal reason at the narrowest window.
    f.msg = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.msg:SetPoint("TOPLEFT", 130, -72)
    f.msg:SetPoint("TOPRIGHT", f.searchBox, "TOPLEFT", -12, -4)
    f.msg:SetHeight(24)
    f.msg:SetJustifyH("LEFT")
    f.msg:SetJustifyV("TOP")
    f.msg:SetWordWrap(true)

    local scroll = CreateFrame("ScrollFrame", "ParchmentSpellbookScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 126, -92)
    scroll:SetPoint("BOTTOMRIGHT", -32, 14)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    content.cardPool = {}
    content.usedCards = 0
    scroll:SetScrollChild(content)
    local relayout = UI.Debounce(0.1, function() if f.char and f.pack then Refresh(f) end end)
    scroll:SetScript("OnSizeChanged", function(_, w)
        content:SetWidth(w)
        relayout()
    end)
    f.content = content

    -- The Homebrew view's authoring entry point (shown only in that view).
    f.newBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    f.newBtn:SetSize(120, 20)
    f.newBtn:SetText("+ New spell")
    f.newBtn:SetScript("OnClick", function()
        if ns.HomebrewUI then ns.HomebrewUI.Open("spell") end
    end)
    f.newBtn:Hide()

    return f
end

local function GetFrame()
    if not SpellbookUI.frame then SpellbookUI.frame = BuildFrame() end
    return SpellbookUI.frame
end

function SpellbookUI.Open()
    local f = GetFrame()
    SetMsg(f, "", false)
    Refresh(f)
    f:Show()
end

function SpellbookUI.Toggle()
    local f = GetFrame()
    if f:IsShown() then f:Hide() else SpellbookUI.Open() end
end

-- Redraws the spellbook when it is open (system/pack/character changes).
function SpellbookUI.RefreshIfShown()
    local f = SpellbookUI.frame
    if f and f:IsShown() then Refresh(f) end
end

ns.RegisterModule("spellbook", SpellbookUI.Toggle)
