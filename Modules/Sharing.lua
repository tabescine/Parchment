-- Parchment - Sharing
--
-- Character-sheet sharing, TRP3-style: request another player's active
-- character on demand and view it read-only. A "View sheet" entry is added
-- to player right-click menus under the addon's own "Parchment" section; it
-- whispers a request, the target's addon replies with their active
-- character, and we open the sheet in view mode.
--
-- Received sheets are bounded before they reach SavedVariables: a sheet over a
-- size cap is refused, one that does not compute is refused (what we cache, we
-- can render - the cache outlives the reload that a display error does not), and
-- the cache keeps only the newest MAX_ENTRIES (oldest evicted by time). Name
-- matching goes through the shared Comm normalizer.
--
-- An inventory is a list of references into the sender's item library, which
-- the receiver does not have, so the send path enriches each entry with a small
-- `resolved` display snapshot (TRP3's exchange-payload pattern). The receiver
-- uses it only when its own library cannot resolve the id, and it survives on
-- the cached view copy alone - ns.SetCharacter strips it from stored characters.
--
-- Reads from: ns.Comm (send/normalize), ns.Addon (event registration),
--   ns.GetActiveCharacter, ns.GetSystem, ns.GetItemLibrary, ns.DeepCopy,
--   ns.Schema, ns.JSON, ns.CharacterSheet, ns.CharacterSheetUI, ns.Print.
-- Exposes on ns.Sharing: Request, GetCache, OpenCache, RemoveCached,
--   ConfirmRemoveCached, ClearCache.

local ADDON, ns = ...

ns.Sharing = ns.Sharing or {}
local S = ns.Sharing

-- Builds "Name-Realm" (or "Name" when realm is local/empty).
local function FullName(name, realm)
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- Bounds on the persistent cache: a received sheet over MAX_CHAR_BYTES (encoded)
-- is refused before it touches SavedVariables, and the cache keeps at most
-- MAX_ENTRIES, evicting the oldest by `time`. Together they stop a hostile or
-- accidental flood of large/many sheets from bloating the saved file.
local MAX_CHAR_BYTES = 256 * 1024
local MAX_ENTRIES = 50

-- The item fields a shared inventory entry carries as its display snapshot:
-- what the receiver needs to render the row and apply its bonuses (`effects`
-- included - an equipped item's modifiers are part of the sheet's totals), and
-- nothing else (no description, no version - the item itself is not being
-- transferred). ac_bonus is the retired +AC field: a migrated library never
-- carries it, but the rare item the migration could not fold still does, and
-- old senders' snapshots keep reading on our side the same way.
local RESOLVED_FIELDS = { "name", "kind", "icon", "weapon_id", "bonus", "ac_bonus", "ac_mod_cap",
    "die", "versatile_die", "category", "effects" }

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

-- Compares two names ignoring realm and case ("Bob-Realm" == "bob"). Delegates
-- to the one shared normalizer so name matching never diverges between modules.
local function SameName(a, b)
    return ns.Comm.SameName(a, b)
end

-- The encoded byte size of a received sheet, or nil when it cannot be encoded.
-- Runs under pcall so a pathologically deep payload cannot throw here.
local function EncodedSize(char)
    local ok, enc = pcall(ns.JSON.encode, char)
    if not ok or type(enc) ~= "string" then return nil end
    return #enc
end

-- True when a received sheet can actually be computed: the same
-- CharacterSheet.Compute the sheet UI runs, under pcall. A payload that passes
-- the schema but throws here must never be cached - the cache is written before
-- the sheet is displayed and read again by every later open (a re-request, the
-- Cached Sheets panel), where the render is not guarded, so it would throw on
-- every view, out of SavedVariables, until the player cleared the cache. A
-- sheet is dropped only for throwing: Compute returning nil is our state (no
-- system yet), not the sender's fault.
--
-- No item library is passed, matching how the sheet UI renders a foreign
-- character: their item ids are library-local and mean nothing here, so the
-- inventory resolves against the wire snapshot alone.
local function Computable(char)
    local Compute = ns.CharacterSheet and ns.CharacterSheet.Compute
    if not Compute then return true end
    return (pcall(Compute, char, ns.GetSystem and ns.GetSystem() or nil, nil))
end

-- Evicts the oldest entries (by `time`) until the cache is within MAX_ENTRIES.
local function EvictOldest(cache)
    local n = 0
    for _ in pairs(cache) do n = n + 1 end
    while n > MAX_ENTRIES do
        local oldestKey, oldestTime
        for key, entry in pairs(cache) do
            local t = tonumber(entry.time) or 0
            if not oldestTime or t < oldestTime then oldestKey, oldestTime = key, t end
        end
        if not oldestKey then break end
        cache[oldestKey] = nil
        n = n - 1
    end
end

-- Returns a cached entry whose key matches name (ignoring realm), or nil.
local function CachedFor(name)
    for key, entry in pairs(Cache()) do
        if SameName(key, name) then return entry, key end
    end
end

-- True when a named player is in our current party/raid (realm-tolerant).
local function InMyGroup(name)
    if not IsInGroup() then return false end
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, GetNumGroupMembers() do
        local unit = prefix .. i
        if UnitExists(unit) then
            local n, r = UnitName(unit)
            if n and SameName(FullName(n, r), name) then return true end
        end
    end
    return false
end

-- Sends an addressed message to one player. A recipient in *our* group gets the
-- party/raid broadcast (works cross-realm) tagged with their name; receivers
-- ignore messages not addressed to them. Anyone else (or oneself) is whispered
-- directly - routing by the recipient's membership, not merely our own, so a
-- reply to an outside requester is not misdirected into our group.
local function SendTo(msgType, payload, target)
    payload = payload or {}
    payload.to = target
    if InMyGroup(target) and not SameName(target, Me()) then
        return ns.Comm.Send(msgType, payload)
    end
    return ns.Comm.Whisper(msgType, payload, target)
end

-- True when an addressed message is meant for us (or is unaddressed).
local function ForMe(payload)
    return not (payload and payload.to) or SameName(payload.to, Me())
end

-- Returns a copy of a character ready to go on the wire: every inventory entry
-- carrying a `resolved` display snapshot of the library item it references, so
-- the receiver can render (and score) items it does not own. A reference we
-- cannot resolve ourselves is sent bare - the receiver shows it as missing.
-- Always a copy: the stored character must never gain wire-only fields.
local function ForWire(char)
    local copy = ns.DeepCopy(char)
    local lib = ns.GetItemLibrary and ns.GetItemLibrary() or {}
    for _, entry in ipairs(type(copy.inventory) == "table" and copy.inventory or {}) do
        if type(entry) == "table" then
            entry.resolved = nil
            local item = type(entry.item_id) == "string" and lib[entry.item_id] or nil
            if type(item) == "table" then
                local snapshot = {}
                for _, field in ipairs(RESOLVED_FIELDS) do snapshot[field] = item[field] end
                entry.resolved = snapshot
            end
        end
    end
    return copy
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
        if not (char and sender) then return end
        -- The requester resolves directly, so whisper the reply straight to them
        -- rather than broadcasting a (potentially large) sheet the whole group
        -- would decode and discard. Whispers reach party members cross-realm.
        ns.Comm.Whisper("CHAR", { char = ForWire(char), to = sender }, sender)
    end)
    ns.Comm.On("CHAR", function(payload, sender)
        if type(payload) ~= "table" or type(payload.char) ~= "table" then return end
        if not ForMe(payload) then return end

        -- Only accept replies we actually asked for, and clear just that
        -- request (others may still be in flight).
        local pendingKey
        for target in pairs(pending) do
            if SameName(target, sender) then pendingKey = target break end
        end
        if not pendingKey then return end
        pending[pendingKey] = nil

        -- Shape-check before persisting (their system may differ from ours,
        -- so shape only - no cross-reference validation). This covers the
        -- inventory's `resolved` snapshots, whose strings and bonuses are as
        -- attacker-controlled as the rest; the cache keeps them, since our own
        -- library usually cannot resolve another player's item ids.
        if not ns.Schema.ValidateCharacter(payload.char, nil) then
            ns.Print((sender or "?") .. " sent a malformed character sheet; ignored.")
            return
        end

        -- Bound the size before it reaches SavedVariables, then store and cap the
        -- entry count (oldest-out) so the cache cannot grow without limit.
        local size = EncodedSize(payload.char)
        if not size or size > MAX_CHAR_BYTES then
            ns.Print((sender or "?") .. " sent an oversized character sheet; ignored.")
            return
        end

        -- Last gate before SavedVariables: a sheet we cannot compute is dropped
        -- rather than persisted (see Computable) - what we cache, we can render.
        if not Computable(payload.char) then
            ns.Print((sender or "?") .. " sent a malformed character sheet; ignored.")
            return
        end

        local cache = Cache()
        cache[sender] = { char = payload.char, name = payload.char.name, time = (time and time()) or 0 }
        EvictOldest(cache)
        -- The name came off the wire: strip escape codes and cap it before it
        -- reaches a chat line, or a "|H...|h" in it renders as a clickable
        -- forged link (see ns.SafeText).
        ns.Print("received " .. ns.SafeText(payload.char.name, nil, "a character")
            .. " from " .. ns.SafeText(sender, nil, "?") .. ".")
        -- A refetch updates the entry's time; re-render the Cached Sheets panel
        -- so its "cached N ago" line reflects the new copy, not the stale one.
        if ns.HubUI then ns.HubUI.RefreshIfShown("cached") end
        if ns.CharacterSheetUI then
            local ok, err = pcall(ns.CharacterSheetUI.ShowCharacter, payload.char, sender)
            if not ok then ns.Print("could not display the sheet: " .. tostring(err)) end
        end
    end)
end

-- The cache of received sheets, keyed by sender (read-only for the hub's
-- Cached Sheets panel).
function S.GetCache()
    return Cache()
end

-- Opens the cached-sheets browser (the hub's Cached Sheets panel).
function S.OpenCache()
    if ns.HubUI then ns.HubUI.Open("cached") end
end

-- Removes one cached sheet by its exact key. Returns true when one was removed.
function S.RemoveCached(key)
    local cache = Cache()
    if cache[key] == nil then return false end
    cache[key] = nil
    return true
end

-- Confirm dialog for removing a single cached sheet. Light by design: a cached
-- sheet is just a copy and can be re-requested, so this only guards a misclick.
StaticPopupDialogs["PARCHMENT_REMOVE_CACHED"] = {
    text = "Remove the cached sheet for %s?\n\nYou can view it again by requesting it.",
    button1 = DELETE or "Remove",
    button2 = CANCEL,
    OnAccept = function(_, data)
        if data and S.RemoveCached(data.key) and ns.HubUI then
            ns.HubUI.RefreshIfShown("cached")
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Prompts to remove a cached sheet; removal is keyed by the exact `key`, while
-- `name` (the character name) is what the prompt shows.
function S.ConfirmRemoveCached(key, name)
    -- Display text is sanitized; the popup's data keeps the raw key so the
    -- accept handler still removes the right entry.
    StaticPopup_Show("PARCHMENT_REMOVE_CACHED", ns.SafeText(name or key), nil, { key = key })
end

-- Clears all cached sheets.
function S.ClearCache()
    local cache = Cache()
    local n = 0
    for k in pairs(cache) do cache[k] = nil; n = n + 1 end
    ns.Print("cleared " .. n .. " cached sheet(s).")
end

-- Adds a "View sheet" entry to player right-click menus (modern Menu API,
-- retail 11.0+), under the addon's own "Parchment" section. Covers self,
-- target, focus, unit frames, chat names, and lists.
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

-- Appends our entries under their own "Parchment" section (Menu-API menus
-- are flat; a divider + title opens a section that runs until the next one).
-- Deliberately NOT merged into TRP3's "Roleplay options" section: that
-- placement depends on callback registration order, breaks silently when a
-- TRP3 user disables its menu entries, and makes our button look like a
-- TRP3 feature. An own section behaves identically with or without TRP3.
local function AddMenuEntry(root, contextData)
    local full = ResolveName(contextData)
    if not full then return end
    root:CreateDivider()
    root:CreateTitle("Parchment")
    root:CreateButton("View sheet", function() S.Request(full) end)
end

-- Registration is deferred to PLAYER_ENTERING_WORLD purely for stable menu
-- ordering: ModifyMenu callbacks run in registration order, and registering
-- after other addons' login-time hooks keeps the Parchment section at the
-- bottom (after e.g. TRP3's "Roleplay options") instead of moving around
-- with addon load order. Nothing breaks if another addon registers later.
if Menu and Menu.ModifyMenu then
    ns.Addon:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        ns.Addon:UnregisterEvent("PLAYER_ENTERING_WORLD")
        for _, tag in ipairs(UNIT_MENUS) do
            -- The closure must be fresh per registration: ModifyMenu keys
            -- its registry on it, so a shared one would replace earlier
            -- registrations.
            Menu.ModifyMenu(tag, function(owner, root, contextData)
                AddMenuEntry(root, contextData)
            end)
        end
    end)
end
