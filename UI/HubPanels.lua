-- Parchment - Hub panels: Systems and Cached Sheets
--
-- Two hub panels that browse data owned by logic modules. The Systems panel
-- lists the system library: click an entry to make it the active system
-- (always preserving the outgoing one), X deletes via the shared confirm
-- popup, footer buttons share the system with the group or jump to Import /
-- Export. The Cached Sheets panel lists received character sheets: click to
-- view one read-only, Clear all drops the cache.
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

-- Shared scroll-list scaffolding for both panels.
local function BuildList(panel, scrollName, hintText)
    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 4, -4)
    hint:SetPoint("RIGHT", panel, "RIGHT", -4, 0)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    hint:SetText(hintText)

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

local function RefreshCached(panel)
    local list = {}
    for key, entry in pairs(ns.Sharing.GetCache()) do
        list[#list + 1] = { key = key, entry = entry }
    end
    table.sort(list, function(a, b) return (a.entry.name or a.key) < (b.entry.name or b.key) end)

    if #list == 0 then
        ns.UI.Empty(panel, "No cached sheets yet.\n\nView another player's sheet to cache it"
            .. " (right-click them, or /pmt view <name>).")
        panel.content:SetHeight(10)
        return
    end
    ns.UI.HideEmpty(panel)

    PlaceRows(panel.content, list, function(row, item)
        row.name:SetText(item.entry.name or "?")
        row.name:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
        row.meta:SetText("played by " .. item.key)
        row:SetScript("OnClick", function()
            if ns.CharacterSheetUI then
                ns.CharacterSheetUI.ShowCharacter(item.entry.char, item.key .. " (cached)")
            end
        end)
    end, function(content) return CreateListRow(content) end)
end

local function BuildCached(panel)
    BuildList(panel, "ParchmentHubCacheScroll",
        "Click a sheet to view it read-only (works offline).")
    FooterButton(panel, "Clear all", 90, 0, function()
        ns.Sharing.ClearCache()
        ns.HubUI.RefreshIfShown("cached")
    end)
end

ns.HubUI.RegisterPanel({
    id = "cached", label = "Cached Sheets", order = 70,
    Build = BuildCached, Refresh = RefreshCached,
})
