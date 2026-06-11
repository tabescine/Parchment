-- Parchment - Party Overview (UI)
--
-- A live overview of the group's characters (aimed at the DM, useful to
-- anyone): one pooled row per member showing level, HP (current/max plus
-- temp), Mana, AC and initiative modifier from received VITALS snapshots.
-- Refresh asks the whole group to re-send; rows dim when their snapshot goes
-- stale. Clicking a row requests that member's full sheet via Sharing.
--
-- Reads from: ns.Party, ns.Sharing, ns.UI.
-- Exposes on ns.PartyUI: Open, Toggle, RefreshIfShown.
-- Registers the "party" module opener with Core.

local ADDON, ns = ...

local UI = ns.UI
local ROW_H = 22
local STALE_AFTER = 120 -- seconds before a snapshot renders dimmed

local PartyUI = {}
ns.PartyUI = PartyUI

local Refresh

-- Creates one pooled member row (click requests the member's full sheet).
local function CreateRow(content)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_H)

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    hl:SetColorTexture(UI.HILITE[1], UI.HILITE[2], UI.HILITE[3], UI.HILITE[4])

    local function fs(justify)
        local s = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        s:SetJustifyH(justify)
        return s
    end
    row.name = fs("LEFT")
    row.name:SetPoint("LEFT", 6, 0)
    row.name:SetPoint("RIGHT", row, "LEFT", 170, 0)
    row.level = fs("RIGHT"); row.level:SetPoint("LEFT", row, "LEFT", 172, 0); row.level:SetWidth(24)
    row.hp = fs("RIGHT");    row.hp:SetPoint("LEFT", row, "LEFT", 200, 0); row.hp:SetWidth(86)
    row.mana = fs("RIGHT");  row.mana:SetPoint("LEFT", row, "LEFT", 290, 0); row.mana:SetWidth(70)
    row.ac = fs("RIGHT");    row.ac:SetPoint("LEFT", row, "LEFT", 364, 0); row.ac:SetWidth(30)
    row.init = fs("RIGHT");  row.init:SetPoint("LEFT", row, "LEFT", 398, 0); row.init:SetWidth(34)

    row:SetScript("OnClick", function(self)
        if self.sender and ns.Sharing then ns.Sharing.Request(self.sender) end
    end)
    row:SetScript("OnEnter", function(self)
        if not self.sender then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.charName or "?", UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
        GameTooltip:AddLine("Played by " .. self.sender, 0.9, 0.9, 0.9)
        if self.age then
            GameTooltip:AddLine(string.format("Updated %ds ago", self.age), 0.62, 0.60, 0.55)
        end
        GameTooltip:AddLine("Click to view the full sheet.", 0.56, 0.78, 1)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
end

-- Renders the roster into pooled rows, sorted by character name.
local function RenderRows(self)
    local content = self.content
    content.rows = content.rows or {}
    for _, r in ipairs(content.rows) do r:Hide() end

    local list = {}
    for sender, v in pairs(ns.Party.GetRoster()) do
        list[#list + 1] = { sender = sender, v = v }
    end
    table.sort(list, function(a, b) return (a.v.name or "") < (b.v.name or "") end)

    local now = GetTime and GetTime() or 0
    local y = -2
    for i, entry in ipairs(list) do
        local row = content.rows[i] or CreateRow(content)
        content.rows[i] = row
        local v = entry.v
        row.sender, row.charName = entry.sender, v.name
        row.age = v.time and math.floor(now - v.time) or nil

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)

        row.name:SetText(v.name)
        row.level:SetText(tostring(v.level))
        row.hp:SetText(v.hp .. " / " .. v.hpmax .. (v.temp > 0 and (" |cff8ec6ff+" .. v.temp .. "|r") or ""))
        row.mana:SetText(v.manamax > 0 and (v.mana .. " / " .. v.manamax) or "-")
        row.ac:SetText(tostring(v.ac))
        row.init:SetText((v.init >= 0 and "+" or "") .. v.init)

        -- Colour: name gold, HP red when hurt, all dimmed when stale.
        local stale = row.age and row.age > STALE_AFTER
        local nameC = stale and UI.DIM or UI.GOLD
        row.name:SetTextColor(nameC[1], nameC[2], nameC[3])
        local hurtC = (v.hpmax > 0 and v.hp / v.hpmax or 1) < 0.35 and UI.RED or UI.TEXT
        local valueC = stale and UI.DIM or hurtC
        row.hp:SetTextColor(valueC[1], valueC[2], valueC[3])
        local restC = stale and UI.DIM or UI.TEXT
        row.mana:SetTextColor(restC[1], restC[2], restC[3])
        row.ac:SetTextColor(restC[1], restC[2], restC[3])
        row.init:SetTextColor(restC[1], restC[2], restC[3])

        row:Show()
        y = y - ROW_H
    end
    content:SetHeight(math.max(10, -y + 2))
    return #list
end

Refresh = function(self)
    local count = RenderRows(self)
    if count == 0 then
        ns.UI.Empty(self, "No party data yet.\n\nGroup members with Parchment answer automatically.",
            "Request vitals", function()
                local ok, err = ns.Party.RequestAll()
                if not ok then ns.Print(err or "request failed.") end
            end)
    else
        ns.UI.HideEmpty(self)
    end
end

local function BuildFrame()
    local f = UI.CreateWindow("ParchmentPartyFrame", {
        title = "Party", width = 470, height = 300,
        minW = 460, minH = 200, maxW = 700, maxH = 700, dbKey = "partyWindow",
    })

    -- Column headers.
    local function head(text, x, w, justify)
        local s = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        s:SetPoint("TOPLEFT", x, -48)
        if w then s:SetWidth(w); s:SetJustifyH(justify or "RIGHT") end
        s:SetTextColor(UI.HEAD[1], UI.HEAD[2], UI.HEAD[3])
        s:SetText(text)
    end
    head("Character", 20, 150, "LEFT")
    head("Lv", 186, 24)
    head("HP", 214, 86)
    head("Mana", 304, 70)
    head("AC", 378, 30)
    head("Init", 412, 34)

    -- Scrolling roster.
    local scroll = CreateFrame("ScrollFrame", "ParchmentPartyScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -64)
    scroll:SetPoint("BOTTOMRIGHT", -32, 44)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
    f.content = content

    -- Footer actions.
    local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refreshBtn:SetSize(70, 22); refreshBtn:SetText("Refresh"); refreshBtn:SetPoint("BOTTOMLEFT", 14, 12)
    refreshBtn:SetScript("OnClick", function()
        local ok, err = ns.Party.RequestAll()
        if not ok then ns.Print(err or "request failed.") end
    end)
    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetSize(60, 22); clearBtn:SetText("Clear"); clearBtn:SetPoint("BOTTOMLEFT", 88, 12)
    clearBtn:SetScript("OnClick", function() ns.Party.Clear(); Refresh(f) end)

    return f
end

local function GetFrame()
    if not PartyUI.frame then PartyUI.frame = BuildFrame() end
    return PartyUI.frame
end

function PartyUI.Open()
    local f = GetFrame()
    Refresh(f)
    f:Show()
    -- Opening implies wanting fresh numbers; ask the group (cheap, throttle-free
    -- pull - members each answer with one small message).
    ns.Party.RequestAll()
end

function PartyUI.Toggle()
    local f = GetFrame()
    if f:IsShown() then f:Hide() else PartyUI.Open() end
end

function PartyUI.RefreshIfShown()
    if PartyUI.frame and PartyUI.frame:IsShown() then Refresh(PartyUI.frame) end
end

ns.RegisterModule("party", PartyUI.Toggle)
