-- Parchment - Hub panels: Systems, Rule packs and Cached sheets
--
-- Three hub panels that browse data owned by logic modules. The Systems panel
-- lists the system library: click an entry to make it the active system
-- (always preserving the outgoing one, and asking first once characters
-- exist), X deletes via the shared confirm popup, footer buttons share the
-- system with the group or jump to Import / Export. The Rule packs panel lists
-- feat and spell packs in one list: click a pack to activate it (one active
-- slot per kind), X deletes via that module's confirm, footer buttons share a
-- pack or jump to Import / Export. The Cached sheets panel
-- lists received character sheets: click to view one read-only, right-click
-- for the same verbs as a context menu, a search box
-- filters by character/player name, each row has a refresh button (re-request
-- a live copy) and an X (remove via the shared confirm) and shows its
-- staleness, and Clear all drops the whole cache (asks first).
--
-- Reads from: ns.UI, ns.HubUI, ns.Systems, ns.Packs, ns.Sharing, ns.GetSystem,
--   ns.GetCharacters, ns.GetPackLibrary, ns.GetActivePackName, ns.ShareSystem,
--   ns.CharacterSheetUI, ns.Print.
-- Exposes nothing on ns: the panels register with the hub and are reached
--   through it (ns.Systems / ns.Packs / ns.Sharing keep the module-level
--   entry points).

local ADDON, ns = ...

local UI = ns.UI
local ROW_H = 30

-- Shared row factory: name + meta line, hover highlight, optional X button.
local function CreateListRow(content, onDelete)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_H)

    UI.RowVisuals(row)
    UI.WireRowTip(row)

    row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 6, -2)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.meta = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.meta:SetPoint("BOTTOMLEFT", 6, 2)
    row.meta:SetJustifyH("LEFT")
    row.meta:SetWordWrap(false)
    row.meta:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    -- Right edges (short of the X when present) so a long name/meta truncates
    -- instead of rendering underneath the row buttons. Rows that add more
    -- buttons (the cached-sheet refresh) re-anchor these further left.
    local inset = onDelete and -26 or -6
    row.name:SetPoint("RIGHT", row, "RIGHT", inset, 0)
    row.meta:SetPoint("RIGHT", row, "RIGHT", inset, 0)

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

-- Makes a library entry the active system (shared by the direct click and the
-- confirm below). SetActive re-renders this panel, so the [active] tag moves.
local function ActivateSystem(name)
    local entry = ns.Systems.GetLibrary()[name]
    if not entry then return end
    ns.Systems.SetActive(entry.system, entry.from)
    ns.Print("now using system '" .. name .. "'.")
end

-- Confirm dialog for switching the active system. A swap rebuilds every
-- attribute-dependent frame, so it is worth a click - but only once there are
-- characters to disturb (see the row's OnClick).
StaticPopupDialogs["PARCHMENT_SWITCH_SYSTEM"] = {
    text = "Switch the active system to \"%s\"?\n\nYour characters are kept; open windows"
        .. " re-render against the new ruleset.",
    button1 = "Switch",
    button2 = CANCEL,
    OnAccept = function(_, name) ActivateSystem(name) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

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
        row.tipTitle = item.name
        row.tipLines = { { "Source", item.entry.from or "imported locally" } }
        row.tipHints = active and { "This is the active system." }
            or { "Click: make it the active system", "X: delete (asks first)" }
        row:SetScript("OnClick", function()
            if active then return end
            -- A fresh install has nothing to disturb, so the swap stays one
            -- click there; with characters around, ask before rebuilding.
            if next(ns.GetCharacters()) ~= nil then
                StaticPopup_Show("PARCHMENT_SWITCH_SYSTEM", item.name, nil, item.name)
            else
                ActivateSystem(item.name)
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
    id = "systems", label = "Systems", order = 30, icon = "inv_misc_book_09",
    count = function()
        local n = 0
        for _ in pairs(ns.Systems.GetLibrary()) do n = n + 1 end
        return n
    end,
    Build = BuildSystems, Refresh = RefreshSystems,
})

-- Rule packs panel ------------------------------------------------------------

-- One list for both kinds (feats first): a pack row activates its pack on
-- click - each kind has its own active slot - and X deletes via the shared
-- confirm. Activation is an explicit user choice, so a pack claiming another
-- system may still be activated; the pairing note in the meta line says what
-- it belongs to, and the next system switch re-resolves (Packs.SyncToSystem).

local PACK_KIND_LABEL = { feats = "Feats", spells = "Spells" }

local function MakePackRow(content)
    return CreateListRow(content, function(row)
        if row.packKind and row.packName then
            ns.Packs.ConfirmDelete(row.packKind, row.packName)
        end
    end)
end

local function RefreshPacks(panel)
    local list = {}
    for kind in pairs(PACK_KIND_LABEL) do
        for name, entry in pairs(ns.GetPackLibrary(kind)) do
            list[#list + 1] = { kind = kind, name = name, entry = entry }
        end
    end
    table.sort(list, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.name < b.name
    end)

    if #list == 0 then
        ns.UI.Empty(panel, "No feat or spell packs yet.\n\nImport one, or adopt one your DM shares.",
            "Import a pack", function() ns.HubUI.Open("import") end)
        panel.content:SetHeight(10)
        return
    end
    ns.UI.HideEmpty(panel)

    PlaceRows(panel.content, list, function(row, item)
        row.packKind, row.packName = item.kind, item.name
        local active = ns.GetActivePackName(item.kind) == item.name
        row.name:SetText("|cff8ec6ff[" .. PACK_KIND_LABEL[item.kind] .. "]|r " .. item.name
            .. (active and "  |cff66d966[active]|r" or ""))
        local c = active and UI.GOLD or UI.TEXT
        row.name:SetTextColor(c[1], c[2], c[3])
        local pack = item.entry.pack or {}
        row.meta:SetText((pack.for_system and ("for " .. pack.for_system) or "any system")
            .. (item.entry.from and ("  -  from " .. item.entry.from) or ""))
        row.tipTitle = item.name
        local lines = {
            { "Kind", PACK_KIND_LABEL[item.kind] },
            { "For system", pack.for_system or "any" },
        }
        if item.entry.from then lines[#lines + 1] = { "From", item.entry.from } end
        if pack.version then lines[#lines + 1] = { "Version", pack.version } end
        row.tipLines = lines
        row.tipHints = active and { "This is the active " .. item.kind .. " pack." }
            or { "Click: activate it (one active per kind)", "X: delete (asks first)" }
        row:SetScript("OnClick", function()
            if ns.Packs.Activate(item.kind, item.name) then
                ns.Print("now using " .. ns.Packs.Label(item.kind) .. " '" .. item.name .. "'.")
                ns.HubUI.RefreshIfShown("packs")
            end
        end)
    end, MakePackRow)
end

local function BuildPacks(panel)
    BuildList(panel, "ParchmentHubPackScroll",
        "Click a pack to activate it (one active per kind). X deletes (asks first).")
    FooterButton(panel, "Share feats", 100, 0, function() ns.Packs.Share("feats") end)
    FooterButton(panel, "Share spells", 100, 104, function() ns.Packs.Share("spells") end)
    FooterButton(panel, "Import / Export", 110, 208, function() ns.HubUI.Open("import") end)
end

ns.HubUI.RegisterPanel({
    id = "packs", label = "Rule packs", order = 35, icon = "inv_misc_book_11",
    count = function()
        local n = 0
        for _ in pairs(ns.GetPackLibrary("feats")) do n = n + 1 end
        for _ in pairs(ns.GetPackLibrary("spells")) do n = n + 1 end
        return n
    end,
    Build = BuildPacks, Refresh = RefreshPacks,
})

-- Cached sheets panel ---------------------------------------------------------

-- Confirm dialog for dropping the whole cache. The per-row X asks too (via
-- ns.Sharing), and this one throws away every sheet at once.
StaticPopupDialogs["PARCHMENT_CLEAR_CACHE"] = {
    text = "Clear all %d cached sheet(s)?\n\nYou can view them again by requesting them.",
    button1 = DELETE or "Clear",
    button2 = CANCEL,
    OnAccept = function()
        ns.Sharing.ClearCache()
        ns.HubUI.RefreshIfShown("cached")
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

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
-- the delete X) that re-requests a live copy. Unlike the system/pack rows this
-- one also answers to right-click (the manage menu in RefreshCached), so it
-- registers both buttons.
local function MakeCacheRow(content)
    local row = CreateListRow(content, function(r)
        if r.cacheKey then ns.Sharing.ConfirmRemoveCached(r.cacheKey, r.cacheName) end
    end)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local refresh = CreateFrame("Button", nil, row)
    refresh:SetSize(16, 16)
    refresh:SetPoint("RIGHT", -28, 0)
    refresh:SetNormalTexture("Interface\\Buttons\\UI-RefreshButton")
    refresh:SetHighlightTexture("Interface\\Buttons\\UI-RefreshButton")
    refresh:SetScript("OnClick", function()
        if row.cacheKey then ns.Sharing.Request(row.cacheKey) end
    end)
    -- This row has a second button; pull the text edges left of it.
    row.name:SetPoint("RIGHT", row, "RIGHT", -48, 0)
    row.meta:SetPoint("RIGHT", row, "RIGHT", -48, 0)
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
        row.tipTitle = item.entry.name or "?"
        local lines = { { "Player", item.key } }
        local lvl = type(item.entry.char) == "table" and item.entry.char.level
        if lvl then lines[#lines + 1] = { "Level", lvl } end
        lines[#lines + 1] = { "Cached", age ~= "" and age:gsub("^cached ", "") or "unknown" }
        row.tipLines = lines
        row.tipHints = { "Click: view (read-only)", "Right-click: actions",
            "Refresh: re-request a live copy", "X: remove (asks first)" }

        local name = item.entry.name or "?"
        local function View()
            if ns.CharacterSheetUI then
                ns.CharacterSheetUI.ShowCharacter(item.entry.char, item.key .. " (cached)")
            end
        end
        -- Left-click views; right-click gathers the row's buttons as a context
        -- menu (modern Menu API; without it right-click just views too).
        row:SetScript("OnClick", function(self, mouseButton)
            if mouseButton == "RightButton" and MenuUtil then
                MenuUtil.CreateContextMenu(self, function(_, root)
                    root:CreateTitle(name)
                    local tip = MenuUtil.SetElementTooltip
                    local e = root:CreateButton("View", View)
                    if tip then tip(e, "Opens this cached copy, read-only.") end
                    e = root:CreateButton("Request a live copy", function()
                        ns.Sharing.Request(item.key)
                    end)
                    if tip then tip(e, "Asks " .. item.key .. " for a fresh sheet.") end
                    e = root:CreateButton("Remove", function()
                        ns.Sharing.ConfirmRemoveCached(item.key, item.entry.name)
                    end)
                    if tip then tip(e, "Drops the cached copy. Asks first.") end
                end)
                return
            end
            View()
        end)
    end, MakeCacheRow)
end

local function BuildCached(panel)
    BuildList(panel, "ParchmentHubCacheScroll",
        "Click to view (offline). Refresh re-requests a live copy; X removes.",
        function(query) panel.cacheQuery = query; RefreshCached(panel) end)
    FooterButton(panel, "Clear all", 90, 0, function()
        local n = 0
        for _ in pairs(ns.Sharing.GetCache()) do n = n + 1 end
        if n > 0 then StaticPopup_Show("PARCHMENT_CLEAR_CACHE", n) end
    end)
end

ns.HubUI.RegisterPanel({
    id = "cached", label = "Cached sheets", order = 70, icon = "inv_scroll_03",
    count = function()
        local n = 0
        for _ in pairs(ns.Sharing.GetCache()) do n = n + 1 end
        return n
    end,
    Build = BuildCached, Refresh = RefreshCached,
})
