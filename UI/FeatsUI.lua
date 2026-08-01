-- Parchment - Feats (UI)
--
-- The feats browser: ability lines rendered as expandable rank ladders, not a
-- graph - a feats pack needs no hand-authored layout. A left rail filters by
-- governing attribute ("All" plus one entry per attribute that owns lines);
-- the list shows one row per line with its rank pips, and clicking a row
-- unfolds the line's rank cards (name, type, cost, range, save, description).
-- The next rank's card carries a Learn button, gated by Modules/Feats.lua
-- (previous rank via ladder order, attribute score, and a free pick in the
-- shared ledger - learning is enforced, not advisory). Right-clicking the
-- highest taken card removes that rank. A search box filters lines across all
-- attributes by name and rank text.
--
-- The rail ends in a Homebrew section: the character's custom feats
-- (char.custom_feats) as cards - "+ New feat" opens the homebrew wizard,
-- left-click edits an entry, right-click deletes it, and records gained at a
-- level above the character's render dimmed as pending.
--
-- Rows and cards are pooled and reused (frames are permanent in WoW); only
-- the visible filter's rows exist at once. Cards measure their description
-- text and size themselves, so ladders stack at their natural heights.
--
-- Reads from: ns.GetSystem, ns.GetFeatPack, ns.GetActiveCharacter,
--   ns.GetItemLibrary, ns.CharacterSheet.Compute, ns.Feats, ns.Homebrew,
--   ns.HomebrewUI, ns.Picks, ns.FormatCost, ns.AttrName, ns.UI.
-- Exposes on ns.FeatsUI: Open, Toggle, RefreshIfShown, and .frame.
-- Registers the "feats" module opener with Core.

local ADDON, ns = ...

local UI = ns.UI

local ROW_H = 30
local STATUS_COLOR = {
    taken = { 0.55, 0.85, 0.55 },
    next = UI.GOLD,
    locked = { 0.55, 0.53, 0.50 },
}

local FeatsUI = {}
ns.FeatsUI = FeatsUI

local Refresh

-- Sets the transient message line.
local function SetMsg(self, text, isError)
    local c = isError and UI.RED or UI.DIM
    self.msg:SetTextColor(c[1], c[2], c[3])
    self.msg:SetText(text or "")
end

-- Rank pips for a line: filled for taken ranks, hollow for the rest.
local function Pips(owned, total)
    local taken = string.rep("*", owned)
    local rest = string.rep("·", math.max(0, total - owned))
    return "|cff8cd98c" .. taken .. "|r|cff777777" .. rest .. "|r  " .. owned .. "/" .. total
end

-- The trimmed search query, or "" when not searching.
local function Query(self)
    return tostring(self.query or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Pool helpers: acquire the nth widget of a pool, creating it on first use.
local function AcquireRow(self)
    local content = self.content
    content.usedRows = content.usedRows + 1
    local row = content.rowPool[content.usedRows]
    if not row then
        row = CreateFrame("Button", nil, content)
        row:SetHeight(ROW_H)
        row:RegisterForClicks("LeftButtonUp")
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.12, 0.11, 0.09, 0.9)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(UI.HILITE[1], UI.HILITE[2], UI.HILITE[3], UI.HILITE[4])
        row.name = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        row.name:SetPoint("LEFT", 8, 0)
        row.name:SetJustifyH("LEFT")
        row.pips = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.pips:SetPoint("RIGHT", -8, 0)
        row.name:SetPoint("RIGHT", row.pips, "LEFT", -8, 0)
        row:SetScript("OnClick", function(r)
            local f = r.window
            f.expanded[r.lineId] = not f.expanded[r.lineId] or nil
            Refresh(f)
        end)
        content.rowPool[content.usedRows] = row
    end
    row:Show()
    return row
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
        card.title:SetPoint("TOPLEFT", 14, -6)
        card.title:SetJustifyH("LEFT")
        card.learn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
        card.learn:SetSize(64, 18)
        card.learn:SetPoint("TOPRIGHT", -8, -5)
        card.learn:SetText("Learn")
        card.learn:SetScript("OnClick", function(btn)
            local f = btn.window
            local ok, reason = ns.Feats.Learn(f.char, f.sheet, f.pack, btn.line)
            if ok then
                SetMsg(f, "Learned " .. (btn.line.ranks[ns.Feats.Rank(f.char, btn.line.id)].name or "?") .. ".", false)
                if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
                Refresh(f)
            else
                SetMsg(f, reason or "Cannot learn.", true)
            end
        end)
        card.title:SetPoint("RIGHT", card.learn, "LEFT", -8, 0)
        card.meta = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        card.meta:SetPoint("TOPLEFT", 14, -24)
        card.meta:SetPoint("RIGHT", -10, 0)
        card.meta:SetJustifyH("LEFT")
        card.meta:SetTextColor(UI.HEAD[1], UI.HEAD[2], UI.HEAD[3])
        card.desc = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        card.desc:SetPoint("TOPLEFT", 14, -38)
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
                    local rec = ns.Homebrew.List(f.char, "feat")[c.homebrewIndex]
                    if rec then ns.ChatLinks.PostLink(ns.ChatLinks.Homebrew("feat", rec)) end
                elseif c.line then
                    ns.ChatLinks.PostLink(ns.ChatLinks.FeatRank(
                        c.line, c.line.ranks[c.rankIndex], c.rankIndex))
                end
                return
            end
            -- Homebrew cards edit on left-click and delete on right-click via
            -- the homebrew wizard; pack cards only remove ranks.
            if c.homebrewIndex then
                if ns.HomebrewUI then
                    if mouseButton == "RightButton" then
                        ns.HomebrewUI.Delete("feat", c.homebrewIndex)
                    else
                        ns.HomebrewUI.Open("feat", c.homebrewIndex)
                    end
                end
                return
            end
            if mouseButton ~= "RightButton" then return end
            -- Only the highest taken rank can come off (ladder order).
            if ns.Feats.Rank(f.char, c.line.id) ~= c.rankIndex then return end
            local ok, reason = ns.Feats.Unlearn(f.char, c.line)
            if ok then
                SetMsg(f, "Removed " .. (c.rankName or "?") .. ".", false)
                if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
                Refresh(f)
            else
                SetMsg(f, reason or "Cannot remove.", true)
            end
        end)
        content.cardPool[content.usedCards] = card
    end
    card:Show()
    return card
end

local function AcquireRail(self)
    self.usedRail = self.usedRail + 1
    local btn = self.railPool[self.usedRail]
    if not btn then
        btn = CreateFrame("Button", nil, self, "UIPanelButtonTemplate")
        btn:SetSize(104, 20)
        btn:SetScript("OnClick", function(b)
            local f = b.window
            f.attrFilter = b.attrId
            Refresh(f)
        end)
        self.railPool[self.usedRail] = btn
    end
    btn:Show()
    return btn
end

-- Roman numerals for rank badges (ladders are short; past X, numbers do).
local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }
local function Roman(n)
    return ROMAN[n] or tostring(n)
end

-- One line's meta text: type, cost, range, save and the attribute gate.
local function MetaText(pack, line, rank, rankIndex)
    local parts = {}
    if rank.type then parts[#parts + 1] = rank.type end
    local cost = ns.FormatCost(rank.cost)
    if cost then parts[#parts + 1] = cost end
    if rank.range then parts[#parts + 1] = "Range: " .. rank.range end
    if rank.save then parts[#parts + 1] = ns.AttrName(rank.save) .. " save" end
    local req = ns.Feats.RankReq(pack, line, rankIndex)
    if req then parts[#parts + 1] = "needs " .. ns.AttrName(line.attribute) .. " " .. req end
    return table.concat(parts, "  -  ")
end

-- Lays out the left rail: "All" plus one button per attribute owning lines,
-- and the character's Homebrew section at the bottom.
local function RenderRail(self)
    self.usedRail = 0
    local pack = self.pack
    local y = -70
    local function add(label, attrId, count)
        local btn = AcquireRail(self)
        btn.window, btn.attrId = self, attrId
        local selected = self.attrFilter == attrId
        btn:SetText((selected and "|cffc8a868> |r" or "") .. label
            .. (count and (" (" .. count .. ")") or ""))
        btn:SetPoint("TOPLEFT", 14, y)
        y = y - 22
    end
    add("All", nil, #ns.Feats.Lines(pack))
    for _, attr in ipairs(ns.GetSystem().attributes or {}) do
        local n = #ns.Feats.Lines(pack, attr.id)
        if n > 0 then add(attr.name, attr.id, n) end
    end
    add("Homebrew", "__homebrew", #ns.Homebrew.List(self.char, "feat"))
    for i = self.usedRail + 1, #self.railPool do self.railPool[i]:Hide() end
end

-- One homebrew record's meta text: gained level plus its quick-ref fields.
local function HomebrewMeta(rec)
    local parts = { "gained at level " .. (rec.level or 1) }
    if rec.type then parts[#parts + 1] = rec.type end
    local cost = ns.FormatCost(rec.cost)
    if cost then parts[#parts + 1] = cost end
    if rec.range then parts[#parts + 1] = "Range: " .. rec.range end
    if rec.save then parts[#parts + 1] = ns.AttrName(rec.save) .. " save" end
    return table.concat(parts, "  -  ")
end

-- Lays out the Homebrew view: a "+ New" button, then one card per record
-- (left-click edits in the wizard, right-click deletes; pending ones dim).
local function RenderHomebrew(self)
    local content = self.content
    content.usedRows, content.usedCards = 0, 0
    -- No line rows in this view: hide the whole row pool, or the previous
    -- attribute filter's rows keep rendering under the homebrew cards.
    for i = 1, #content.rowPool do content.rowPool[i]:Hide() end
    local width = content:GetWidth()
    self.newBtn:Show()
    self.newBtn:ClearAllPoints()
    self.newBtn:SetPoint("TOPLEFT", 0, -4)
    local y = -30

    local list = ns.Homebrew.List(self.char, "feat")
    for i, rec in ipairs(list) do
        if type(rec) == "table" then
            local card = AcquireCard(self)
            card.window, card.homebrewIndex = self, i
            card.line, card.rankIndex, card.rankName = nil, nil, rec.name
            card:SetPoint("TOPLEFT", 0, y)
            card:SetWidth(width)
            local active = ns.Homebrew.Active(self.char, rec)
            local sc = active and STATUS_COLOR.taken or STATUS_COLOR.locked
            card.title:SetText((rec.name or "?") .. (active and "" or "  (pending)"))
            card.title:SetTextColor(sc[1], sc[2], sc[3])
            card.meta:SetText(HomebrewMeta(rec))
            card.desc:SetText(rec.description or "")
            card.learn:Hide()
            local descH = (rec.description and rec.description ~= "")
                and (card.desc:GetStringHeight() + 6) or 0
            card:SetHeight(24 + 14 + descH + 6)
            y = y - card:GetHeight() - 4
        end
    end
    for i = content.usedCards + 1, #content.cardPool do content.cardPool[i]:Hide() end
    content:SetHeight(math.max(10, -y + 8))
    SetMsg(self, #list == 0
        and "No homebrew feats yet - write one with '+ New feat'."
        or "Click a homebrew feat to edit it, right-click to delete it.", false)
end

-- Lays out the list: line rows, and rank cards under expanded lines.
local function RenderList(self)
    local content = self.content
    self.newBtn:Hide()
    if self.attrFilter == "__homebrew" and Query(self) == "" then
        RenderHomebrew(self)
        return
    end
    content.usedRows, content.usedCards = 0, 0
    local width = content:GetWidth()
    local y = -4

    local query = Query(self)
    local lines = (query ~= "") and ns.Feats.Search(self.pack, query)
        or ns.Feats.Lines(self.pack, self.attrFilter)

    for _, line in ipairs(lines) do
        local owned = ns.Feats.Rank(self.char, line.id)
        local total = #(line.ranks or {})
        local row = AcquireRow(self)
        row.window, row.lineId = self, line.id
        row.homebrewIndex = nil
        row:SetPoint("TOPLEFT", 0, y)
        row:SetWidth(width)
        local c = owned > 0 and STATUS_COLOR.taken or UI.TEXT
        row.name:SetText((self.expanded[line.id] and "- " or "+ ") .. (line.name or line.id))
        row.name:SetTextColor(c[1], c[2], c[3])
        row.pips:SetText(Pips(owned, total))
        y = y - ROW_H - 2

        if self.expanded[line.id] then
            for i, rank in ipairs(line.ranks or {}) do
                local card = AcquireCard(self)
                card.window, card.line, card.rankIndex = self, line, i
                card.homebrewIndex = nil
                card.rankName = rank.name
                card:SetPoint("TOPLEFT", 12, y)
                card:SetWidth(width - 12)
                local status = ns.Feats.Status(self.char, line, i)
                local sc = STATUS_COLOR[status]
                card.title:SetText(Roman(i) .. ".  " .. (rank.name or "?"))
                card.title:SetTextColor(sc[1], sc[2], sc[3])
                card.meta:SetText(MetaText(self.pack, line, rank, i))
                card.desc:SetText(rank.description or "")
                card.learn:SetShown(status == "next")
                card.learn.window, card.learn.line = self, line
                -- Natural height: title (24) + meta line (14) + measured
                -- description + bottom padding.
                local descH = (rank.description and rank.description ~= "")
                    and (card.desc:GetStringHeight() + 6) or 0
                card:SetHeight(24 + 14 + descH + 6)
                y = y - card:GetHeight() - 2
            end
            y = y - 4
        end
    end

    for i = content.usedRows + 1, #content.rowPool do content.rowPool[i]:Hide() end
    for i = content.usedCards + 1, #content.cardPool do content.cardPool[i]:Hide() end
    content:SetHeight(math.max(10, -y + 8))

    if #lines == 0 then
        SetMsg(self, (query ~= "") and ("No feats match \"" .. query .. "\".")
            or "This pack has no lines here.", false)
    end
end

-- Recomputes the active character, packs and sheet, then redraws.
Refresh = function(self)
    local function blank()
        for _, r in ipairs(self.content.rowPool) do r:Hide() end
        for _, c in ipairs(self.content.cardPool) do c:Hide() end
        for _, b in ipairs(self.railPool) do b:Hide() end
        self.newBtn:Hide()
        self.points:SetText("")
        self.packLabel:SetText("")
    end

    if not ns.HasSystem() then
        blank()
        ns.UI.NoSystem(self)
        return
    end
    local pack = ns.GetFeatPack()
    self.pack = pack
    if not pack then
        blank()
        ns.UI.Empty(self, "No feats pack active.\n\nImport one, or adopt one your DM shares.",
            "Import a feats pack", function() ns.OpenModule("import") end)
        return
    end
    local char = ns.GetActiveCharacter()
    self.char = char
    if not char then
        blank()
        ns.UI.Empty(self, "No character yet.\n\nCreate one to learn feats, or import an existing one.",
            "Create a character", function() ns.OpenModule("new") end,
            "Import a character", function() ns.OpenModule("import") end)
        return
    end
    ns.UI.HideEmpty(self)

    self.sheet = ns.CharacterSheet.Compute(char, ns.GetSystem(), ns.GetItemLibrary())
    self.packLabel:SetText(pack.pack_name or "")
    local spent, budget = ns.Picks.Points(char)
    self.points:SetText("Picks: " .. spent .. " / " .. budget)
    RenderRail(self)
    RenderList(self)
end

local function BuildFrame()
    local f = UI.CreateWindow("ParchmentFeatsFrame", {
        title = "Feats", width = 560, height = 560,
        minW = 460, minH = 380, maxW = 900, maxH = 1000, dbKey = "featsWindow",
    })
    f.expanded = {}
    f.railPool, f.usedRail = {}, 0

    f.packLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.packLabel:SetPoint("TOPLEFT", 16, -44)
    f.packLabel:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])

    f.points = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.points:SetPoint("TOPRIGHT", -16, -46)
    f.points:SetTextColor(UI.HEAD[1], UI.HEAD[2], UI.HEAD[3])

    -- Search box: filters lines across every attribute (name + rank text).
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
    UI.SetPlaceholder(f.searchBox, "Search feats")

    f.legend = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.legend:SetPoint("TOPLEFT", 130, -50)
    f.legend:SetPoint("RIGHT", f.points, "LEFT", -12, 0)
    f.legend:SetJustifyH("LEFT")
    f.legend:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    f.legend:SetText("Click a line to unfold it - Learn takes the next rank, right-click the top rank"
        .. " removes it, shift-click a card puts its link in chat")

    f.msg = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.msg:SetPoint("TOPLEFT", 130, -72)
    f.msg:SetPoint("RIGHT", f.searchBox, "LEFT", -12, 0)
    f.msg:SetJustifyH("LEFT")
    f.msg:SetWordWrap(false)

    -- Scrolling ladder list, right of the attribute rail.
    local scroll = CreateFrame("ScrollFrame", "ParchmentFeatsScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 126, -92)
    scroll:SetPoint("BOTTOMRIGHT", -32, 14)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    content.rowPool, content.cardPool = {}, {}
    content.usedRows, content.usedCards = 0, 0
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
    f.newBtn:SetText("+ New feat")
    f.newBtn:SetScript("OnClick", function()
        if ns.HomebrewUI then ns.HomebrewUI.Open("feat") end
    end)
    f.newBtn:Hide()

    return f
end

local function GetFrame()
    if not FeatsUI.frame then FeatsUI.frame = BuildFrame() end
    return FeatsUI.frame
end

function FeatsUI.Open()
    local f = GetFrame()
    SetMsg(f, "", false)
    Refresh(f)
    f:Show()
end

function FeatsUI.Toggle()
    local f = GetFrame()
    if f:IsShown() then f:Hide() else FeatsUI.Open() end
end

-- Redraws the browser when it is open (system/pack/character changes).
function FeatsUI.RefreshIfShown()
    local f = FeatsUI.frame
    if f and f:IsShown() then Refresh(f) end
end

ns.RegisterModule("feats", FeatsUI.Toggle)
