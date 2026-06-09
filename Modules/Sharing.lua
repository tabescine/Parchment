-- Parchment - Sharing
--
-- Character-sheet sharing, TRP3-style: request another player's active
-- character on demand and view it read-only. A "View Parchment Sheet" entry is
-- added to player right-click menus; it whispers a request, the target's addon
-- replies with their active character, and we open the sheet in view mode.
--
-- Reads from: ns.Comm, ns.GetActiveCharacter, ns.CharacterSheetUI, ns.Print.
-- Exposes on ns.Sharing: Request.

local ADDON, ns = ...

ns.Sharing = ns.Sharing or {}
local S = ns.Sharing

-- Builds "Name-Realm" (or "Name" when realm is local/empty).
local function FullName(name, realm)
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- Targets we are awaiting a reply from (prevents request pile-ups).
local pending = {}

-- This player's name.
local function Me()
    return (UnitName and UnitName("player")) or ""
end

-- The persistent cache of received sheets, keyed by the sender's full name:
-- { [sender] = { char = <table>, name = <charName>, time = <epoch> } }.
local function Cache()
    local g = ns.Addon.db.global
    g.sharedCache = g.sharedCache or {}
    return g.sharedCache
end

-- Compares two names ignoring realm and case ("Bob-Realm" == "bob").
local function SameName(a, b)
    if not a or not b then return false end
    a = (a:match("^[^-]+") or a):lower()
    b = (b:match("^[^-]+") or b):lower()
    return a == b
end

-- Returns a cached entry whose key matches name (ignoring realm), or nil.
local function CachedFor(name)
    for key, entry in pairs(Cache()) do
        if SameName(key, name) then return entry, key end
    end
end

-- Sends an addressed message to one player. Within a group it broadcasts on the
-- party/raid channel (works cross-realm) tagged with the recipient; receivers
-- ignore messages not addressed to them. Otherwise (or to oneself) it whispers.
local function SendTo(msgType, payload, target)
    payload = payload or {}
    payload.to = target
    if IsInGroup() and not SameName(target, Me()) then
        return ns.Comm.Send(msgType, payload)
    end
    return ns.Comm.Whisper(msgType, payload, target)
end

-- True when an addressed message is meant for us (or is unaddressed).
local function ForMe(payload)
    return not (payload and payload.to) or SameName(payload.to, Me())
end

-- Requests a player's character sheet (they must have the addon to respond).
function S.Request(target)
    if not target or target == "" then return end
    if pending[target] and GetTime and (GetTime() - pending[target]) < 8 then
        ns.Print("still waiting on " .. target .. "...")
        return
    end
    -- Show the cached copy immediately; the live reply updates it when it lands.
    local cached, key = CachedFor(target)
    if cached and ns.CharacterSheetUI then
        ns.CharacterSheetUI.ShowCharacter(cached.char, (key or target) .. " (cached)")
    end

    local ok, err = SendTo("REQ", {}, target)
    if not ok then
        ns.Print(err or "could not send request.")
        return
    end
    pending[target] = GetTime and GetTime() or 0
    ns.Print("requested " .. target .. "'s character sheet...")
    if C_Timer then
        C_Timer.After(8, function()
            if pending[target] then
                pending[target] = nil
                ns.Print("no response from " .. target
                    .. ". They need Parchment loaded and to be in your party/raid (or on your realm).")
            end
        end)
    end
end

-- Comm handlers: reply to requests addressed to us with our active character;
-- show characters we receive. ShowCharacter is wrapped so a display error is
-- reported rather than swallowed by AceComm's protected dispatch.
if ns.Comm then
    ns.Comm.On("REQ", function(payload, sender)
        if not ForMe(payload) then return end
        local char = ns.GetActiveCharacter()
        if char and sender then
            SendTo("CHAR", { char = char }, sender)
        end
    end)
    ns.Comm.On("CHAR", function(payload, sender)
        if type(payload) ~= "table" or type(payload.char) ~= "table" then return end
        if not ForMe(payload) then return end
        if wipe then wipe(pending) else for k in pairs(pending) do pending[k] = nil end end
        -- Persist to the cache, keyed by the sender.
        if sender then
            Cache()[sender] = { char = payload.char, name = payload.char.name, time = (time and time()) or 0 }
        end
        ns.Print("received " .. (payload.char.name or "a character") .. " from " .. (sender or "?") .. ".")
        if ns.CharacterSheetUI then
            local ok, err = pcall(ns.CharacterSheetUI.ShowCharacter, payload.char, sender)
            if not ok then ns.Print("could not display the sheet: " .. tostring(err)) end
        end
    end)
end

-- Opens a picker of cached sheets to view (works offline).
function S.OpenCache()
    local cache = Cache()
    local items = {}
    for key, entry in pairs(cache) do
        items[#items + 1] = { id = key, name = (entry.name or "?") .. "  |cff888888(" .. key .. ")|r" }
    end
    if #items == 0 then
        ns.Print("no cached sheets yet. View a player to cache theirs.")
        return
    end
    ns.Dialogs.Pick({
        title = "Cached Sheets", prompt = "View a cached character sheet", items = items, max = 1, selected = {},
        onConfirm = function(ids)
            local entry = ids[1] and cache[ids[1]]
            if entry and ns.CharacterSheetUI then
                ns.CharacterSheetUI.ShowCharacter(entry.char, ids[1] .. " (cached)")
            end
        end,
    })
end

-- Clears all cached sheets.
function S.ClearCache()
    local cache = Cache()
    local n = 0
    for k in pairs(cache) do cache[k] = nil; n = n + 1 end
    ns.Print("cleared " .. n .. " cached sheet(s).")
end

-- Adds "View Parchment Sheet" to player right-click menus (modern Menu API,
-- retail 11.0+). Covers self, target, focus, unit frames, chat names, and lists.
local UNIT_MENUS = {
    "MENU_UNIT_SELF", "MENU_UNIT_PLAYER", "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS",
    "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_RAID",
    "MENU_UNIT_FRIEND", "MENU_UNIT_FRIENDLY_PLAYER", "MENU_UNIT_ENEMY_PLAYER",
    "MENU_UNIT_COMMUNITIES_GUILD_MEMBER", "MENU_UNIT_BN_FRIEND",
}

-- Resolves a player name (with realm) from a menu's contextData.
local function ResolveName(contextData)
    if not contextData then return nil end
    local name, server = contextData.name, contextData.server
    local unit = contextData.unit
    if unit and UnitExists(unit) then
        if not UnitIsPlayer(unit) then return nil end
        local n, r = UnitName(unit)
        name = name or n
        server = server or r
    end
    if not name or name == "" then return nil end
    return FullName(name, server)
end

if Menu and Menu.ModifyMenu then
    for _, tag in ipairs(UNIT_MENUS) do
        Menu.ModifyMenu(tag, function(owner, root, contextData)
            local full = ResolveName(contextData)
            if not full then return end
            root:CreateButton("View Parchment Sheet", function() S.Request(full) end)
        end)
    end
end
