-- Parchment - Feats (UI)
--
-- The feats browser: ability lines rendered as expandable rank ladders, not a
-- graph - a feats pack needs no hand-authored layout. A left rail filters by
-- governing attribute ("All" plus one entry per attribute that owns lines);
-- the list shows one row per line with its rank pips, and clicking a row
-- unfolds the line's rank cards (name, type, cost, range, save, description).
-- The next rank's card carries a Learn button, gated by Modules/Feats.lua
-- (previous rank via ladder order, attribute score, and a free pick in the
-- shared ledger - learning is enforced, not advisory). Cards that cannot be
-- learned keep a disabled Learn button carrying the reason, and every card
-- explains its status on hover. Right-clicking the highest taken card unlearns
-- that rank after a confirm popup. A search box filters lines across all
-- attributes by name and rank text; while a query is active it bypasses the
-- rail filter.
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
-- The file also registers the hub's Feats panel: a read-only list of what the
-- active character has picked (owned ranks then homebrew records, in the
-- sheet's quick-ref order) with the shared pick budget and a button into the
-- browser. A row reads its record in the link viewer on click and links it in
-- chat on shift-click; picks are made in the browser, which the footer button
-- opens.
--
-- Reads from: ns.GetSystem, ns.GetFeatPack, ns.GetActiveCharacter,
--   ns.GetItemLibrary, ns.CharacterSheet.Compute, ns.Feats, ns.Homebrew,
--   ns.HomebrewUI, ns.HubUI, ns.Picks, ns.FormatCost, ns.AttrName, ns.UI,
--   ns.ChatLinks, ns.ChatLinkUI.
-- Exposes on ns.FeatsUI: Open, Toggle, RefreshIfShown, and .frame.
-- Registers the "feats" module opener with Core and the "feats" hub panel.

local ADDON, ns = ...

local UI = ns.UI

local ROW_H = 30
local LEGEND = "Click a line to unfold it, a card to read it big - Learn takes the next rank,"
    .. " right-click the top rank unlearns it, shift-click links it in chat"
local SEARCH_LEGEND = "Searching all attributes - the rail filter is off until the search clears."
local STATUS_COLOR = {
    taken = { 0.55, 0.85, 0.55 },
    next = UI.GOLD,
    locked = { 0.55, 0.53, 0.50 },
}

-- Blizzard textures for the rail entries (the hub's flat-nav treatment;
-- Parchment ships no art). The friends-list bar is cropped past its rounded
-- left cap; the quest-title gradient marks the selected entry.
local TEX_HOVER = "Interface\\FriendsFrame\\UI-FriendsFrame-HighlightBar"
local TEX_SELECTED = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

local FeatsUI = {}
ns.FeatsUI = FeatsUI

local Refresh

-- Repaints the hub's Feats panel after a pick changes here. The learn/unlearn
-- paths redraw this window directly rather than through ns.Systems.RefreshAll
-- (which covers the hub), so they say it themselves; the panel's Refresh only
-- reads state, so nothing calls back.
local function HubRefresh()
    if ns.HubUI then ns.HubUI.RefreshIfShown("feats") end
end

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

-- Applies a confirmed unlearn of a line's top rank, or reports why it cannot
-- happen. The ladder position is re-checked here: another pick between the
-- popup opening and its accept would move the top rank.
local function DoUnlearn(f, line, rankIndex, rankName)
    if not (f and f.char and line) then return end
    if ns.Feats.Rank(f.char, line.id) ~= rankIndex then
        SetMsg(f, "That is no longer the highest rank taken.", true)
        return
    end
    local ok, reason = ns.Feats.Unlearn(f.char, line)
    if ok then
        SetMsg(f, "Unlearned " .. (rankName or "?") .. ".", false)
        if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
        HubRefresh()
        Refresh(f)
    else
        SetMsg(f, reason or "Cannot unlearn.", true)
    end
end

-- Confirm dialog for a right-click unlearn. Data carries the window, line and
-- rank so nothing is captured in an upvalue that a redraw could stale out.
StaticPopupDialogs["PARCHMENT_FEAT_UNLEARN"] = {
    text = "Unlearn '%s'?\n\nThis refunds 1 pick.",
    button1 = "Unlearn", button2 = CANCEL,
    OnAccept = function(_, data)
        if data then DoUnlearn(data.window, data.line, data.rankIndex, data.rankName) end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Pool helpers: acquire the nth widget of a pool, creating it on first use.
local function AcquireRow(self)
    local content = self.content
    content.usedRows = content.usedRows + 1
    local row = content.rowPool[content.usedRows]
    if not row then
        row = CreateFrame("Button", nil, content)
        row:SetHeight(ROW_H)
        row:RegisterForClicks("LeftButtonUp")
        UI.RowVisuals(row)
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
                HubRefresh()
                Refresh(f)
            else
                SetMsg(f, reason or "Cannot learn.", true)
            end
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
            if mouseButton ~= "RightButton" then
                -- Plain click: open the rank in the link viewer - a pop-out
                -- reader for text that makes heavy going as a card in the
                -- scroll (same rendering a clicked chat link gets).
                if c.line and ns.ChatLinkUI then
                    ns.ChatLinkUI.Show(ns.ChatLinks.FeatRank(
                        c.line, c.line.ranks[c.rankIndex], c.rankIndex))
                end
                return
            end
            -- Only the highest taken rank can come off (ladder order).
            if ns.Feats.Rank(f.char, c.line.id) ~= c.rankIndex then return end
            StaticPopup_Show("PARCHMENT_FEAT_UNLEARN", c.rankName or "?", nil,
                { window = f, line = c.line, rankIndex = c.rankIndex, rankName = c.rankName })
        end)
        -- Status tooltip: the card colours say taken/next/locked, this says why.
        card:SetScript("OnEnter", function(c)
            if not c.tip then return end
            GameTooltip:SetOwner(c, "ANCHOR_RIGHT")
            GameTooltip:SetText(c.tipTitle or " ", 1, 1, 1)
            GameTooltip:AddLine(c.tip, UI.TEXT[1], UI.TEXT[2], UI.TEXT[3], true)
            if c.line then
                GameTooltip:AddLine("Click: read it in its own window",
                    UI.GREEN[1], UI.GREEN[2], UI.GREEN[3])
            end
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

-- The tooltip for a rank card: its status plus the cause. Takes the refusal
-- reason CanLearn already produced for the next rank (nil when it is
-- learnable). Returns title, body.
local function RankTip(self, line, rankIndex, status, reason)
    if status == "taken" then
        local top = ns.Feats.Rank(self.char, line.id) == rankIndex
        return "Learned", top and "Right-click to unlearn it and refund its pick."
            or "Unlearn the ranks above it first."
    end
    if status == "locked" then
        local prev = (line.ranks or {})[rankIndex - 1]
        local req = ns.Feats.RankReq(self.pack, line, rankIndex)
        return "Locked", "Learn " .. ((prev and prev.name) or "the rank below") .. " first."
            .. (req and ("\nNeeds " .. ns.AttrName(line.attribute) .. " " .. req .. ".") or "")
    end
    if reason then return "Cannot learn", reason end
    return "Next rank", "Learn takes it for 1 pick."
end

-- Lays out the left rail: "All" plus one button per attribute owning lines,
-- and the character's Homebrew section at the bottom.
local function RenderRail(self)
    self.usedRail = 0
    local pack = self.pack
    local y = -70
    -- A search spans every attribute, so no rail entry is the active filter
    -- while a query stands - drop the band rather than lie about it.
    local searching = Query(self) ~= ""
    local function add(label, attrId, count)
        local btn = AcquireRail(self)
        btn.window, btn.attrId = self, attrId
        local selected = self.attrFilter == attrId and not searching
        btn.label:SetText(label .. (count and (" (" .. count .. ")") or ""))
        -- Rail buttons are pooled: band, font and enabled state are set on
        -- every entry every render, or a reused button keeps the selection it
        -- carried under the previous filter.
        btn.label:SetFontObject(selected and _G.GameFontNormal or _G.GameFontHighlight)
        btn.sel:SetShown(selected)
        btn:SetEnabled(not selected)
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
        and "No homebrew feats yet - write one with '+ New feat'."
        or "Click a homebrew feat to edit it, right-click to delete it.", false)
end

-- Lays out the list: line rows, and rank cards under expanded lines.
local function RenderList(self)
    local content = self.content
    local query = Query(self)
    self.newBtn:Hide()
    -- The legend doubles as the search's status line: it is the one text that
    -- transient feedback in self.msg never overwrites.
    self.legend:SetText((query ~= "") and SEARCH_LEGEND or LEGEND)
    if self.attrFilter == "__homebrew" and query == "" then
        RenderHomebrew(self)
        return
    end
    content.usedRows, content.usedCards = 0, 0
    local width = content:GetWidth()
    local y = -4

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
                -- Affordability shows before the click, not after it: an
                -- unlearnable next rank keeps a disabled button plus reason.
                local reason
                if status == "next" then
                    local canLearn, why = ns.Feats.CanLearn(self.char, self.sheet, self.pack, line)
                    reason = (not canLearn) and (why or "Cannot learn.") or nil
                    card.learn:SetEnabled(canLearn)
                end
                card.learn.reason = reason
                card.tipTitle, card.tip = RankTip(self, line, i, status, reason)
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
    -- The shared budget reads as what is left to spend, green until it is gone.
    local spent, budget = ns.Picks.Points(char)
    local left = budget - spent
    self.points:SetText(left .. ((left == 1) and " pick left" or " picks left"))
    local pc = (left > 0) and UI.GREEN or UI.RED
    self.points:SetTextColor(pc[1], pc[2], pc[3])
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

    -- The picks budget is the number that decides every Learn click, so it
    -- carries the full-size font; Refresh colours it green/red.
    f.points = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.points:SetPoint("TOPRIGHT", -16, -46)

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

-- Feats hub panel -------------------------------------------------------------

-- The hub's read-only twin of the browser: one row per owned rank, then the
-- homebrew records, in the order the sheet's quick-ref uses. Rows are pooled
-- and reused here too (frames are permanent in WoW).

local PANEL_ROW_H = 30
local TIP_DESC_MAX = 150
-- The soft blue the sheet and the other hub lists tag a row's origin with.
local TAG_BLUE = "|cff8ec6ff"

-- The picks the panel lists: every owned rank in pack order, then the
-- character's homebrew feats - the sheet's collection, entry for entry.
-- Returns the list ({ rec, line, index } / { rec, homebrew, pending }) and how
-- many recorded lines no active pack resolves.
local function PickedFeats(char)
    local pack = ns.GetFeatPack()
    local list, unresolved = {}, 0
    if type(char.feats) == "table" then
        if pack then
            for _, line in ipairs(pack.lines or {}) do
                local owned = ns.Feats.Rank(char, line.id)
                for i = 1, math.min(owned, #(line.ranks or {})) do
                    list[#list + 1] = { rec = line.ranks[i], line = line, index = i }
                end
            end
        end
        for lineId in pairs(char.feats) do
            if not (pack and ns.Feats.Line(pack, lineId)) then unresolved = unresolved + 1 end
        end
    end
    for _, rec in ipairs(ns.Homebrew.List(char, "feat")) do
        if type(rec) == "table" then
            list[#list + 1] = { rec = rec, homebrew = true,
                pending = not ns.Homebrew.Active(char, rec) }
        end
    end
    return list, unresolved
end

-- A picked entry's mechanics as one line (the row truncates what still runs
-- past its width).
local function PickMeta(rec)
    local parts = {}
    if rec.type then parts[#parts + 1] = rec.type end
    local cost = ns.FormatCost(rec.cost)
    if cost then parts[#parts + 1] = cost end
    if rec.range then parts[#parts + 1] = "Range: " .. rec.range end
    if rec.save then parts[#parts + 1] = ns.AttrName(rec.save) .. " save" end
    return table.concat(parts, "  -  ")
end

-- A one-paragraph excerpt of rules text for a tooltip: whitespace collapsed
-- and cut at a word boundary past TIP_DESC_MAX. Returns nil for empty text.
local function Excerpt(text)
    local s = tostring(text or ""):gsub("%s+", " ")
    s = s:gsub("^ ", ""):gsub(" $", "")
    if s == "" then return nil end
    if #s > TIP_DESC_MAX then
        s = s:sub(1, TIP_DESC_MAX):gsub("%s+%S*$", "") .. "..."
    end
    return s
end

-- Fills a row's tooltip: the mechanics as label/value pairs, then the rules
-- text as wrapped prose. Set fresh every render (pooled rows keep old data).
local function FillRowTip(row, entry)
    local rec = entry.rec
    row.tipTitle = rec.name or "?"
    local lines = {}
    if rec.type then lines[#lines + 1] = { "Type", rec.type } end
    local cost = ns.FormatCost(rec.cost)
    if cost then lines[#lines + 1] = { "Cost", cost } end
    if rec.range then lines[#lines + 1] = { "Range", rec.range } end
    if rec.save then lines[#lines + 1] = { "Save", ns.AttrName(rec.save) } end
    if entry.line then
        lines[#lines + 1] = { "Rank",
            Roman(entry.index) .. " of " .. (entry.line.name or entry.line.id) }
    else
        lines[#lines + 1] = { "Homebrew", "gained at level " .. (rec.level or 1) }
    end
    local excerpt = Excerpt(rec.description)
    if excerpt then lines[#lines + 1] = excerpt end
    row.tipLines = lines
    row.tipHints = { "Click: read it in its own window", "Shift-click: link it in chat" }
end

-- The chat-link payload for the record a row carries, built at click time so
-- it reflects the current data. Returns nil for a row with no record yet.
local function RowPayload(row)
    if not row.rec then return nil end
    if row.line then return ns.ChatLinks.FeatRank(row.line, row.rec, row.index) end
    return ns.ChatLinks.Homebrew("feat", row.rec)
end

local function CreatePanelRow(content)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(PANEL_ROW_H)

    UI.RowVisuals(row)
    UI.WireRowTip(row)

    row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 6, -2)
    row.name:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.meta = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.meta:SetPoint("BOTTOMLEFT", 6, 2)
    row.meta:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.meta:SetJustifyH("LEFT")
    row.meta:SetWordWrap(false)
    row.meta:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    -- Left reads the record in the link viewer, shift links it in chat; the
    -- footer button is the way into the browser where picks are made.
    row:SetScript("OnClick", function(self)
        local payload = RowPayload(self)
        if not payload then return end
        if IsShiftKeyDown and IsShiftKeyDown() then
            ns.ChatLinks.PostLink(payload)
            return
        end
        if ns.ChatLinkUI then ns.ChatLinkUI.Show(payload) end
    end)
    return row
end

-- Fills one row: the rank (or record) name with its line/homebrew tag, the
-- compressed mechanics line, and the tooltip. Pending records render dim.
-- The link context is set on every fill - a pooled row must never carry the
-- previous render's record.
local function FillPanelRow(row, entry)
    local rec = entry.rec
    row.rec, row.line, row.index = rec, entry.line, entry.index
    local tag
    if entry.line then
        tag = TAG_BLUE .. "(" .. (entry.line.name or entry.line.id) .. " " .. entry.index .. ")|r"
    else
        tag = TAG_BLUE .. "(homebrew"
            .. (entry.pending and (", pending until level " .. (rec.level or 1)) or "") .. ")|r"
    end
    row.name:SetText((rec.name or "?") .. "  " .. tag)
    local c = entry.pending and UI.DIM or UI.TEXT
    row.name:SetTextColor(c[1], c[2], c[3])
    row.meta:SetText(PickMeta(rec))
    FillRowTip(row, entry)
end

local function RefreshPanel(panel)
    local content = panel.content
    for _, r in ipairs(content.rows) do r:Hide() end
    content.note:Hide()
    content:SetHeight(10)

    -- The empty state masks the body but neither the header line nor the
    -- footer button, so both go with it - HideEmpty only drops the overlay.
    local function headerless()
        panel.hint:SetText("")
        panel.points:SetText("")
        panel.openBtn:Hide()
    end

    if not ns.HasSystem() then
        headerless()
        ns.UI.NoSystem(panel)
        return
    end
    local char = ns.GetActiveCharacter()
    if not char then
        headerless()
        ns.UI.Empty(panel,
            "No character yet.\n\nCreate one to pick feats, or import an existing one.",
            "Create a character", function() ns.OpenModule("new") end,
            "Import a character", function() ns.OpenModule("import") end)
        return
    end

    -- Header: whose picks these are, and the budget both pickers spend from -
    -- seeing it here saves opening a browser to read one number.
    panel.hint:SetText("What " .. (char.name or "this character") .. " has picked."
        .. " The browser is where picks are made.")
    local spent, budget = ns.Picks.Points(char)
    local left = budget - spent
    panel.points:SetText(left .. ((left == 1) and " pick left" or " picks left"))
    local pc = (left > 0) and UI.GREEN or UI.RED
    panel.points:SetTextColor(pc[1], pc[2], pc[3])

    local list, unresolved = PickedFeats(char)
    if #list == 0 and unresolved == 0 then
        panel.openBtn:Hide()
        ns.UI.Empty(panel, "No feats picked yet.\n\nThe browser unfolds every ability line into"
            .. " its ranks; Learn takes the next one.",
            "Open the feats browser", function() FeatsUI.Open() end)
        return
    end
    ns.UI.HideEmpty(panel)
    panel.openBtn:Show()

    local y = -2
    for i, entry in ipairs(list) do
        local row = content.rows[i] or CreatePanelRow(content)
        content.rows[i] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)
        FillPanelRow(row, entry)
        row:Show()
        y = y - PANEL_ROW_H
    end

    -- Picks recorded against a pack that is not active are unreachable here;
    -- the sheet says so in the same words rather than dropping them silently.
    if unresolved > 0 then
        content.note:ClearAllPoints()
        content.note:SetPoint("TOPLEFT", content, "TOPLEFT", 8, y - 4)
        content.note:SetPoint("RIGHT", content, "RIGHT", -6, 0)
        content.note:SetText(unresolved
            .. " feat line(s) not shown - no matching feats pack active.")
        content.note:Show()
        y = y - 22
    end
    content:SetHeight(math.max(10, -y + 2))
end

local function BuildPanel(panel)
    panel.hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    panel.hint:SetPoint("TOPLEFT", 4, -4)
    panel.hint:SetJustifyH("LEFT")
    -- One header line: a long character name truncates rather than wrapping
    -- down over the list.
    panel.hint:SetWordWrap(false)
    panel.hint:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    panel.points = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    panel.points:SetPoint("TOPRIGHT", -10, -2)
    panel.hint:SetPoint("RIGHT", panel.points, "LEFT", -8, 0)

    local scroll = CreateFrame("ScrollFrame", "ParchmentHubFeatsScroll", panel,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -24)
    scroll:SetPoint("BOTTOMRIGHT", -26, 34)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    content.rows = {}
    content.note = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    content.note:SetJustifyH("LEFT")
    content.note:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    content.note:Hide()
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
    panel.content = content

    panel.openBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.openBtn:SetSize(160, 22)
    panel.openBtn:SetPoint("BOTTOMLEFT", 0, 4)
    panel.openBtn:SetText("Open the feats browser")
    panel.openBtn:SetScript("OnClick", function() FeatsUI.Open() end)
end

ns.HubUI.RegisterPanel({
    id = "feats", label = "Feats", order = 42, icon = "ability_warrior_battleshout",
    count = function()
        local char = ns.GetActiveCharacter()
        if not char then return 0 end
        local list = PickedFeats(char)
        return #list
    end,
    Build = BuildPanel, Refresh = RefreshPanel,
})

ns.RegisterModule("feats", FeatsUI.Toggle)
