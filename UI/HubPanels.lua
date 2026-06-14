-- Parchment - Hub panels: Systems and Cached Sheets
--
-- Two hub panels that browse data owned by logic modules. The Systems panel
-- lists the system library: click an entry to make it the active system
-- (always preserving the outgoing one), X deletes via the shared confirm
-- popup, footer buttons share the system with the group or jump to Import /
-- Export. The Cached Sheets panel lists received character sheets: click to
-- view one read-only, a search box filters by character/player name, each row
-- has a refresh button (re-request a live copy) and an X (remove via the shared
-- confirm) and shows its staleness, and Clear all drops the whole cache.
--
-- Reads from: ns.UI, ns.HubUI, ns.Systems, ns.Sharing, ns.GetSystem,
--   ns.ShareSystem, ns.CharacterSheetUI, ns.OpenModule, ns.Print.
-- Exposes nothing on ns: both panels register with the hub and are reached
--   through it (ns.Systems / ns.Sharing keep the module-level entry points).

local ADDON, ns = ...

local UI = ns.UI
local ROW_H = 30

-- Shared row factory: name + meta line, hover highlight, optional X button.
local function CreateListRow(content, onDelete)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_H)

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    hl:SetColorTexture(UI.HILITE[1], UI.HILITE[2], UI.HILITE[3], UI.HILITE[4])

    row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 6, -2)
    row.name:SetJustifyH("LEFT")
    row.meta = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.meta:SetPoint("BOTTOMLEFT", 6, 2)
    row.meta:SetJustifyH("LEFT")
    row.meta:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    if onDelete then
        local del = CreateFrame("Button", nil, row)
        del:SetSize(16, 16)
        del:SetPoint("RIGHT", -6, 0)
        del:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        del:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        del:SetScript("OnClick", function() onDelete(row) end)
    end
    return row
end

-- Shared scroll-list scaffolding for both panels. When onSearch is given, a
-- debounced search box sits in the header (top-right) and the hint shrinks to
-- its left; onSearch(query) fires only when the text actually changed.
local function BuildList(panel, scrollName, hintText, onSearch)
    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 4, -4)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    hint:SetText(hintText)

    if onSearch then
        local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
        box:SetSize(120, 18)
        box:SetPoint("TOPRIGHT", -10, -4)
        box:SetAutoFocus(false)
        box:SetScript("OnEscapePressed", function(b) b:SetText(""); b:ClearFocus() end)
        box:SetScript("OnEnterPressed", function(b) b:ClearFocus() end)
        local last = ""
        local run = UI.Debounce(0.15, function() onSearch(box:GetText()) end)
        box:SetScript("OnTextChanged", function(b, user)
            if not user or b:GetText() == last then return end
            last = b:GetText()
            run()
        end)
        UI.SetPlaceholder(box, "Search")
        hint:SetPoint("RIGHT", box, "LEFT", -8, 0)
        panel.searchBox = box
    else
        hint:SetPoint("RIGHT", panel, "RIGHT", -4, 0)
    end

    local scroll = CreateFrame("ScrollFrame", scrollName, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -24)
    scroll:SetPoint("BOTTOMRIGHT", -26, 34)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    content.rows = {}
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
    panel.content = content
end

local function FooterButton(panel, text, width, x, onClick)
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetPoint("BOTTOMLEFT", x, 4)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

-- Lays out pooled rows and returns the used count.
local function PlaceRows(content, list, fill, makeRow)
    for _, r in ipairs(content.rows) do r:Hide() end
    local y = -2
    for i, entry in ipairs(list) do
        local row = content.rows[i] or makeRow(content)
        content.rows[i] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)
        fill(row, entry)
        row:Show()
        y = y - ROW_H
    end
    content:SetHeight(math.max(10, -y + 2))
    return #list
end

-- Systems panel --------------------------------------------------------------

local function MakeSystemRow(content)
    return CreateListRow(content, function(row)
        if row.sysName then ns.Systems.ConfirmDelete(row.sysName) end
    end)
end

local function RefreshSystems(panel)
    local list = {}
    for name, entry in pairs(ns.Systems.GetLibrary()) do
        list[#list + 1] = { name = name, entry = entry }
    end
    table.sort(list, function(a, b) return a.name < b.name end)

    if #list == 0 then
        ns.UI.Empty(panel, "Your system library is empty.\n\nImport a ruleset to get started.",
            "Import a system", function() ns.HubUI.Open("import") end)
        panel.content:SetHeight(10)
        return
    end
    ns.UI.HideEmpty(panel)

    local activeName = ns.GetSystem().system_name
    PlaceRows(panel.content, list, function(row, item)
        row.sysName = item.name
        local active = item.name == activeName
        row.name:SetText(item.name .. (active and "  |cff66d966[active]|r" or ""))
        local c = active and UI.GOLD or UI.TEXT
        row.name:SetTextColor(c[1], c[2], c[3])
        row.meta:SetText(item.entry.from and ("from " .. item.entry.from) or "imported")
        row:SetScript("OnClick", function()
            local entry = ns.Systems.GetLibrary()[item.name]
            if entry then
                ns.Systems.SetActive(entry.system, entry.from)
                ns.Print("now using system '" .. item.name .. "'.")
            end
        end)
    end, MakeSystemRow)
end

local function BuildSystems(panel)
    BuildList(panel, "ParchmentHubSysScroll",
        "Click a system to make it active (the outgoing one is kept). X deletes (asks first).")
    FooterButton(panel, "Share with group", 120, 0, ns.ShareSystem)
    FooterButton(panel, "Import / Export", 110, 124, function() ns.HubUI.Open("import") end)
end

ns.HubUI.RegisterPanel({
    id = "systems", label = "Systems", order = 30,
    Build = BuildSystems, Refresh = RefreshSystems,
})

-- Cached Sheets panel ---------------------------------------------------------

-- Human-readable staleness from an entry's stored epoch time ("just now",
-- "5m ago", "2h ago", "3d ago"); empty when no timestamp was recorded.
local function AgeText(t)
    t = tonumber(t)
    if not t or t == 0 then return "" end
    local secs = ((time and time()) or 0) - t
    if secs < 60 then return "cached just now" end
    if secs < 3600 then return "cached " .. math.floor(secs / 60) .. "m ago" end
    if secs < 86400 then return "cached " .. math.floor(secs / 3600) .. "h ago" end
    return "cached " .. math.floor(secs / 86400) .. "d ago"
end

-- A cached-sheet row: the shared list row plus a per-row refresh button (left of
-- the delete X) that re-requests a live copy.
local function MakeCacheRow(content)
    local row = CreateListRow(content, function(r)
        if r.cacheKey then ns.Sharing.ConfirmRemoveCached(r.cacheKey, r.cacheName) end
    end)
    local refresh = CreateFrame("Button", nil, row)
    refresh:SetSize(16, 16)
    refresh:SetPoint("RIGHT", -28, 0)
    refresh:SetNormalTexture("Interface\\Buttons\\UI-RefreshButton")
    refresh:SetHighlightTexture("Interface\\Buttons\\UI-RefreshButton")
    refresh:SetScript("OnClick", function()
        if row.cacheKey then ns.Sharing.Request(row.cacheKey) end
    end)
    return row
end

local function RefreshCached(panel)
    local query = (panel.cacheQuery or ""):lower()
    local cache = ns.Sharing.GetCache()
    local total, list = 0, {}
    for key, entry in pairs(cache) do
        total = total + 1
        local hay = ((entry.name or "") .. " " .. key):lower()
        if query == "" or hay:find(query, 1, true) then
            list[#list + 1] = { key = key, entry = entry }
        end
    end
    table.sort(list, function(a, b) return (a.entry.name or a.key) < (b.entry.name or b.key) end)

    if #list == 0 then
        local msg = total == 0
            and "No cached sheets yet.\n\nView another player's sheet to cache it"
                .. " (right-click them, or /pmt view <name>)."
            or ("No cached sheets match \"" .. (panel.cacheQuery or "") .. "\".")
        ns.UI.Empty(panel, msg)
        panel.content:SetHeight(10)
        return
    end
    ns.UI.HideEmpty(panel)

    PlaceRows(panel.content, list, function(row, item)
        row.cacheKey, row.cacheName = item.key, item.entry.name
        row.name:SetText(item.entry.name or "?")
        row.name:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
        local age = AgeText(item.entry.time)
        local suffix = age ~= "" and ("   |cff8a857a" .. age .. "|r") or ""
        row.meta:SetText("played by " .. item.key .. suffix)
        row:SetScript("OnClick", function()
            if ns.CharacterSheetUI then
                ns.CharacterSheetUI.ShowCharacter(item.entry.char, item.key .. " (cached)")
            end
        end)
    end, MakeCacheRow)
end

local function BuildCached(panel)
    BuildList(panel, "ParchmentHubCacheScroll",
        "Click to view (offline). Refresh re-requests a live copy; X removes.",
        function(query) panel.cacheQuery = query; RefreshCached(panel) end)
    FooterButton(panel, "Clear all", 90, 0, function()
        ns.Sharing.ClearCache()
        ns.HubUI.RefreshIfShown("cached")
    end)
end

ns.HubUI.RegisterPanel({
    id = "cached", label = "Cached Sheets", order = 70,
    Build = BuildCached, Refresh = RefreshCached,
})
