-- Parchment - Core
--
-- Addon entry point and data layer. Owns SavedVariables wiring, the data-access
-- API that every module reads through, a small module registry, and the
-- /parchment (/pmt) slash commands that open each module.
--
-- Parchment is system-agnostic and ships with no ruleset: a fresh install has
-- no active system until the user imports one (/pmt import) or adopts a
-- DM-shared one. Windows that need a system show an empty state until then.
--
-- Core owns the live SavedVariables globals: modules read and write them only
-- through the ns data API (Get*/Set*) so the data source can change without
-- touching them. One sanctioned exception: Modules/Systems.lua owns
-- ParchmentSystemDB swaps (activating systems from the library).
--
-- Reads from: ns.Schema.
-- Exposes on ns: the data API (GetSystem, HasSystem, GetCharacter, the item
--   library API GetItemLibrary/GetItem/SetItem/DeleteItem/NextItemKey and the
--   shared MISSING_ITEM sentinel, the pack API GetPackLibrary/GetActivePack/
--   GetFeatPack/GetSpellPack, ...), the module registry (RegisterModule,
--   OpenModule), shared helpers (Print, DeepCopy, FindById, AttrName,
--   SaveToDisk, ShareSystem), and ns.Addon.

local ADDON, ns = ...

-- Branding and message colours.
local PREFIX = "|cffc8a868[Parchment]|r "
local C_GREEN = "|cff00ff00"
local C_RED = "|cffff4444"
local C_YELLOW = "|cffffcc00"
local C_GOLD = "|cffc8a868"

-- AceDB layout for addon settings (the data tables live in their own SVs).
local DB_DEFAULTS = {
    global = { activeCharacter = nil },
    profile = { minimap = { hide = false }, dm = false, publicRolls = false, shareVitals = true },
}

-- Data-format versioning. DB_FORMAT describes the shape of everything
-- Parchment stores: the active system, the characters, the system library,
-- and the sharing cache. When a release changes any stored shape, bump
-- DB_FORMAT and append a migration step to MIGRATIONS - users' data is then
-- upgraded in place at load, and nobody ever deletes a SavedVariables file.
-- The stamp lives in ParchmentDB.global (NOT inside the data tables, which
-- are exactly what export produces - a format key there would leak into
-- every exported file).
local DB_FORMAT = 1

-- MIGRATIONS[n] upgrades stored data from format n-1 to format n. Steps run
-- in order, so any old version passes through every intermediate shape. Each
-- step must be idempotent (WoW only flushes SavedVariables on logout/reload,
-- so a crash can re-run a step against already-migrated data) and must cover
-- every stored copy of the shape it changes: ParchmentSystemDB,
-- ParchmentCharDB.characters, db.global.systemLibrary (full system copies),
-- and db.global.sharedCache (full character copies).
local MIGRATIONS = {
    -- [2] = function(db) ... end,
}

-- The stand-in returned for an inventory reference the item library cannot
-- resolve (a deleted item, or a shared sheet naming items we do not own). One
-- shared constant table so callers can identity-test it (item == ns.MISSING_ITEM)
-- and render the row dimmed instead of erroring - nothing may mutate it.
ns.MISSING_ITEM = { missing = true, name = "Missing item", kind = "gear" }

-- Slash subcommand -> module id (nil routing falls through to help).
local MODULE_COMMANDS = {
    hub = "hub",
    characters = "characters",
    combat = "initiative",
    init = "initiative",   -- legacy alias for /pmt combat
    sheet = "sheet",
    feats = "feats",
    spellbook = "spellbook",
    spells = "spellbook",   -- alias for /pmt spellbook
    items = "items",
    import = "import",
    edit = "edit",
    new = "new",
    config = "config",
    party = "party",
}

local LibStub = LibStub
local Parchment = LibStub("AceAddon-3.0"):NewAddon(ADDON, "AceConsole-3.0", "AceEvent-3.0",
    "AceComm-3.0", "AceSerializer-3.0")
ns.Addon = Parchment

-- Module registry: id -> opener function, filled by RegisterModule as each
-- module loads.
ns.modules = {}

-- Clamps n into [lo, hi].
local function Clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

-- Prints a Parchment-prefixed line to the default chat frame.
local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

-- Exposed so other modules can print prefixed chat lines.
ns.Print = Print

-- Returns a deep copy of a value (tables copied recursively; non-tables pass
-- through). Used wherever stored data must not alias a live table, e.g. the
-- system library and adopt-prompt snapshots in Modules/Systems.lua.
function ns.DeepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = ns.DeepCopy(v) end
    return out
end

-- Data API. Modules call these; they never read the SV globals directly.

-- Returns the active system definition table (ParchmentSystemDB).
function ns.GetSystem()
    return ParchmentSystemDB or {}
end

-- True when an actual system is loaded (not the empty first-run state).
function ns.HasSystem()
    return type(ParchmentSystemDB) == "table" and next(ParchmentSystemDB) ~= nil
end

-- Returns the characters table keyed by character key.
function ns.GetCharacters()
    ParchmentCharDB.characters = ParchmentCharDB.characters or {}
    return ParchmentCharDB.characters
end

-- Returns a single character by key, or nil.
function ns.GetCharacter(key)
    return ns.GetCharacters()[key]
end

-- Stores (or replaces) a character under a key.
--
-- Strips the `resolved` display snapshots from the inventory: they are wire-only
-- enrichment (Modules/Sharing.lua fills them in on the send path so a receiver
-- without our items can still render the sheet), and a stored copy would go
-- stale the moment the library item is edited. Locally the library IS the
-- source of truth, so persistence drops them.
function ns.SetCharacter(key, char)
    if type(char) == "table" and type(char.inventory) == "table" then
        for _, entry in ipairs(char.inventory) do
            if type(entry) == "table" then entry.resolved = nil end
        end
    end
    ns.GetCharacters()[key] = char
end

-- Returns the first free "<prefix>-N" character key (default prefix "Character").
function ns.NextCharacterKey(prefix)
    local chars, n, key = ns.GetCharacters(), 0
    repeat
        n = n + 1
        key = (prefix or "Character") .. "-" .. n
    until not chars[key]
    return key
end

-- Returns two values: the active character table and its key (or nil, nil).
-- Falls back to the first character present when no active key is set.
function ns.GetActiveCharacter()
    local chars = ns.GetCharacters()
    local key = Parchment.db.global.activeCharacter
    if key and chars[key] then return chars[key], key end
    local firstKey = next(chars)
    return chars[firstKey], firstKey
end

-- Sets the active character. Returns true if the key exists and was set.
function ns.SetActiveCharacter(key)
    if not ns.GetCharacter(key) then return false end
    Parchment.db.global.activeCharacter = key
    return true
end

-- Deletes a character by key, re-pointing a dangling active pointer at any
-- remaining character (or nil when none are left - a state SetActiveCharacter
-- refuses to produce, which is why deletion must live here in Core rather
-- than callers reaching into the storage layout).
function ns.DeleteCharacter(key)
    local chars = ns.GetCharacters()
    if chars[key] == nil then return end
    chars[key] = nil
    if Parchment.db.global.activeCharacter == key then
        Parchment.db.global.activeCharacter = next(chars)
    end
end

-- Item library. One global library (not per system): characters hold thin
-- references to it (char.inventory), resolved live on every Compute, so editing
-- a library item updates every character carrying it.

-- Returns the item library table keyed by item id.
function ns.GetItemLibrary()
    ParchmentItemDB = ParchmentItemDB or {}
    ParchmentItemDB.items = ParchmentItemDB.items or {}
    return ParchmentItemDB.items
end

-- Returns the item stored under an id, or the shared ns.MISSING_ITEM sentinel
-- when it does not resolve (deleted item, dangling reference). Never nil, so
-- callers render a "missing" row rather than guarding every access; the result
-- is read-only, as it may be the shared sentinel.
function ns.GetItem(id)
    local item = ns.GetItemLibrary()[id]
    if type(item) ~= "table" then return ns.MISSING_ITEM end
    return item
end

-- Stores (or replaces) an item under a key, stamping the key onto its `id` and
-- bumping `version` past the stored item's. The version is what a future item
-- transfer compares to decide whose copy is newer; every save moves it forward.
-- Returns the stored item, or nil when the arguments are not an id and a table.
function ns.SetItem(id, item)
    if type(id) ~= "string" or type(item) ~= "table" then return nil end
    local lib = ns.GetItemLibrary()
    local previous = lib[id]
    item.id = id
    item.version = (tonumber(type(previous) == "table" and previous.version) or 0) + 1
    lib[id] = item
    return item
end

-- Deletes an item by id. Characters holding it keep the reference and render a
-- missing-item row (see ns.GetItem) - nothing rewrites their inventories.
function ns.DeleteItem(id)
    ns.GetItemLibrary()[id] = nil
end

-- Returns the first free "itm_N" item key.
function ns.NextItemKey()
    local lib, n, key = ns.GetItemLibrary(), 0
    repeat
        n = n + 1
        key = "itm_" .. n
    until not lib[key]
    return key
end

-- Feat / spell packs. Packs are standalone importable rule collections (see
-- Schema.ValidateFeatPack / ValidateSpellPack) in their own SavedVariables
-- global: one library per kind, keyed by pack_name, plus an active-pack
-- pointer per kind. Modules/Packs.lua manages the libraries and activation;
-- everything else reads the active pack through GetFeatPack / GetSpellPack.
-- All ParchmentPackDB access stays here, like the other SV globals.

local PACK_KINDS = { feats = true, spells = true }

-- Returns the library for a pack kind ({ [name] = { name, pack, from, time } }).
function ns.GetPackLibrary(kind)
    if not PACK_KINDS[kind] then return {} end
    ParchmentPackDB = ParchmentPackDB or {}
    ParchmentPackDB[kind] = ParchmentPackDB[kind] or {}
    return ParchmentPackDB[kind]
end

-- Returns the active pack NAME for a kind, or nil. A pointer left dangling at
-- a deleted library entry reads as "no active pack" rather than erroring.
function ns.GetActivePackName(kind)
    if not PACK_KINDS[kind] or type(ParchmentPackDB) ~= "table" then return nil end
    local name = ParchmentPackDB["active_" .. kind]
    if name ~= nil and ns.GetPackLibrary(kind)[name] then return name end
    return nil
end

-- Sets (or, with nil, clears) the active pack pointer for a kind. Refuses a
-- name the library does not hold. Returns true when the pointer was written.
function ns.SetActivePackName(kind, name)
    if not PACK_KINDS[kind] then return false end
    if name ~= nil and not ns.GetPackLibrary(kind)[name] then return false end
    ParchmentPackDB = ParchmentPackDB or {}
    ParchmentPackDB["active_" .. kind] = name
    return true
end

-- Returns the active pack definition table for a kind, or nil.
function ns.GetActivePack(kind)
    local name = ns.GetActivePackName(kind)
    local entry = name and ns.GetPackLibrary(kind)[name]
    return type(entry) == "table" and entry.pack or nil
end

-- The active feats pack definition, or nil when none is active.
function ns.GetFeatPack()
    return ns.GetActivePack("feats")
end

-- The active spells pack definition, or nil when none is active.
function ns.GetSpellPack()
    return ns.GetActivePack("spells")
end

-- Finds a record by its `id` field in a list of records. Returns nil when
-- absent. The system data is full of such lists (attributes, skills,
-- traits); modules share this instead of re-rolling the loop.
function ns.FindById(list, id)
    for _, record in ipairs(list or {}) do
        if record.id == id then return record end
    end
end

-- Returns the attribute record for an id, or nil.
function ns.GetAttribute(id)
    return ns.FindById(ns.GetSystem().attributes, id)
end

-- Display name for an attribute id: its name, the raw id when it does not
-- resolve, or "(none)" for an unset (nil) selection.
function ns.AttrName(id)
    if not id then return "(none)" end
    local attr = ns.GetAttribute(id)
    return attr and attr.name or id
end

-- Display text for a cost record ({ ap = n, mana = n }): "1 AP, 2 Mana".
-- Returns nil when there is nothing to show, so callers can hide the field.
-- Shared by the feat/spell pickers and the sheet's quick-reference rows.
function ns.FormatCost(cost)
    if type(cost) ~= "table" then return nil end
    local parts = {}
    if type(cost.ap) == "number" and cost.ap > 0 then
        parts[#parts + 1] = cost.ap .. " AP"
    end
    if type(cost.mana) == "number" and cost.mana > 0 then
        parts[#parts + 1] = cost.mana .. " Mana"
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ")
end

-- Maps an attribute value to its modifier via the system's modifier table,
-- clamping the value into the table's 1..max range first.
function ns.GetModifier(value)
    local table_ = ns.GetSystem().modifier_table or {}
    local clamped = Clamp(value or 0, 1, #table_)
    return table_[clamped] or 0
end

-- Returns the hit die string ("d10") for a given Vitality modifier, using the
-- system's ordered hit-dice bands.
function ns.GetHitDie(vitModifier)
    for _, band in ipairs(ns.GetSystem().hit_dice_bands or {}) do
        if vitModifier <= band.max_mod then return band.die end
    end
    return "d4"
end

-- Returns the accomplishment bonus for a character level.
function ns.GetAccomplishmentBonus(level)
    local table_ = ns.GetSystem().accomplishment_table or {}
    return table_[Clamp(level or 1, 1, #table_)] or 0
end

-- Resolved derived-stat configuration for the active system. A system may
-- declare which attributes drive its derived stats via a `derived_stats` block;
-- any field left unset means that coupling does not apply, so the engine never
-- assumes a particular attribute exists (keeping it system-agnostic). Numeric
-- bases default to common conventions but can be overridden too.
function ns.DerivedConfig()
    local d = ns.GetSystem().derived_stats or {}
    return {
        hit_die_attribute  = d.hit_die_attribute,        -- modifier picks the hit-die band
        hp_attribute       = d.hp_attribute,             -- modifier added to HP rolls
        retroactive_hp     = d.retroactive_hp and true or false, -- changing hp_attribute re-grants HP for past levels
        spell_attributes   = d.spell_attributes or {},   -- primary among these => spellcaster
        mana_attribute     = d.mana_attribute,           -- mana source for non-casters
        initiative_tiebreaker = d.initiative_tiebreaker, -- attr deciding equal initiative rolls
        mana_multiplier    = d.mana_multiplier or 2,
        mana_base          = d.mana_base or 0,           -- flat mana floor
        mana_per_level     = d.mana_per_level or 0,      -- x level, rounded up
        movement_attribute = d.movement_attribute,       -- +per_step per positive modifier
        ac_attributes      = d.ac_attributes,            -- candidate attrs for AC (pick or best)
        init_attributes    = d.init_attributes,          -- candidate attrs for initiative
        movement_base      = d.movement_base or 12,
        movement_per_step  = d.movement_per_step or 0.5,
        ac_base            = d.ac_base or 10,
        save_dc_base       = d.save_dc_base or 10,
        actions_base       = d.actions_base or 2,
    }
end

-- Module registry.

-- Registers a module's opener under an id. opener is called (with no args)
-- when the matching slash command runs.
function ns.RegisterModule(id, opener)
    ns.modules[id] = opener
end

-- Opens a registered module by id, or reports that it is not yet available.
function ns.OpenModule(id)
    local opener = ns.modules[id]
    if opener then
        opener()
    else
        Print(C_YELLOW .. "the '" .. id .. "' module is not available yet." .. "|r")
    end
end

-- Persistence. WoW only writes SavedVariables to disk on a UI reload or logout,
-- so "save to disk" is a confirmed ReloadUI (which flushes the data).
StaticPopupDialogs["PARCHMENT_SAVE_RELOAD"] = {
    text = "Save all Parchment data to disk now?\n\n"
        .. "WoW only writes addon data on a UI reload or logout, so this will reload your interface.",
    button1 = "Save & Reload",
    button2 = CANCEL,
    OnAccept = function() ReloadUI() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Prompts to persist all data to disk via a confirmed UI reload.
function ns.SaveToDisk()
    StaticPopup_Show("PARCHMENT_SAVE_RELOAD")
end

-- Broadcasts the active system to the group (DM only) and prints the outcome.
-- Sharing is always this explicit action - toggling DM mode never auto-sends.
-- Used by /pmt share and the settings window.
function ns.ShareSystem()
    if not ns.Comm.IsDM() then
        Print(C_RED .. "only the DM shares the system. Use /pmt dm first." .. "|r")
    elseif not ns.HasSystem() then
        Print(C_RED .. "no system loaded to share. Import one with /pmt import first." .. "|r")
    else
        local ok, err = ns.Comm.Send("SYSTEM", ns.GetSystem())
        Print(ok and (C_GREEN .. "shared the system with your group." .. "|r")
            or (C_RED .. (err or "share failed") .. "|r"))
    end
end

-- Slash command handling.

local function PrintHelp()
    Print(C_GOLD .. "Adventures await. Commands:|r")
    Print("  " .. C_GOLD .. "/pmt hub|r     - the Parchment menu (characters, settings, ...)")
    Print("  " .. C_GOLD .. "/pmt characters|r - manage characters (select / delete)")
    Print("  " .. C_GOLD .. "/pmt sheet|r   - open the character sheet")
    Print("  " .. C_GOLD .. "/pmt combat|r  - open the combat tracker (initiative, HP, timer)")
    Print("  " .. C_GOLD .. "/pmt feats|r   - browse and learn feats (ability lines)")
    Print("  " .. C_GOLD .. "/pmt spellbook|r - browse and learn spells")
    Print("  " .. C_GOLD .. "/pmt items|r   - browse your item library (create, edit, hand out items)")
    Print("  " .. C_GOLD .. "/pmt new|r     - create a character (guided wizard)")
    Print("  " .. C_GOLD .. "/pmt edit|r    - open the character editor")
    Print("  " .. C_GOLD .. "/pmt import|r  - open the import/export dialog")
    Print("  " .. C_GOLD .. "/pmt config|r  - open settings")
    Print("  " .. C_GOLD .. "/pmt dm|r      - toggle DM mode; |r" .. C_GOLD .. "dm who|r / |r"
        .. C_GOLD .. "dm accept <name>|r query or set who you recognize")
    Print("  " .. C_GOLD .. "/pmt share|r   - DM: send your system to the group; |r" .. C_GOLD
        .. "share feats|r / |r" .. C_GOLD .. "share spells|r / |r" .. C_GOLD
        .. "share all|r for the active packs")
    Print("  " .. C_GOLD .. "/pmt systems|r - manage your system library (activate / delete)")
    Print("  " .. C_GOLD .. "/pmt rolls|r   - toggle public (party-visible) dice rolls")
    Print("  " .. C_GOLD .. "/pmt party|r   - live party overview (HP/Mana/AC of group members)")
    Print("  " .. C_GOLD .. "/pmt view <name>|r - view another player's character sheet")
    Print("  " .. C_GOLD .. "/pmt cached|r  - browse cached sheets (|cffc8a868/pmt cached clear|r to wipe)")
    Print("  " .. C_GOLD .. "/pmt minimap|r - toggle the minimap button")
    Print("  " .. C_GOLD .. "/pmt save|r    - write all data to disk (reloads the UI)")
    Print("  " .. C_GOLD .. "/pmt who|r     - list known characters")
    Print("  " .. C_GOLD .. "/pmt validate|r- check the loaded system, characters and item library")
end

-- Prints the known characters and marks the active one.
local function PrintRoster()
    local _, activeKey = ns.GetActiveCharacter()
    local found = false
    for key, char in pairs(ns.GetCharacters()) do
        found = true
        local marker = (key == activeKey) and (C_GREEN .. " (active)|r") or ""
        Print(string.format("  %s%s|r  [%s]%s", C_GOLD, char.name or "?", key, marker))
    end
    if not found then Print(C_YELLOW .. "no characters loaded." .. "|r") end
end

-- Sweeps the item library: shape issues, plus the two cross-references that
-- only degrade a row rather than breaking it - a weapon_id naming no weapon in
-- the active system (the item stays a display-only item) and a character
-- inventory entry naming an item we no longer own (it renders as missing).
-- `system` is nil when none is loaded; the weapon links are skipped then.
local function ValidateItems(system)
    local lib = ns.GetItemLibrary()
    if next(lib) == nil then return end

    local ok, issues = ns.Schema.ValidateItemLibrary(lib)
    if ok then
        Print(C_GREEN .. "item library is valid." .. "|r")
    else
        Print(C_RED .. "item library has " .. #issues .. " issue(s):" .. "|r")
        for _, issue in ipairs(issues) do Print("  " .. C_RED .. issue .. "|r") end
    end

    if system then
        local weaponIds = {}
        for _, weapon in ipairs(system.weapons or {}) do
            if type(weapon) == "table" and weapon.id then weaponIds[weapon.id] = true end
        end
        for id, item in pairs(lib) do
            if type(item) == "table" and item.weapon_id and not weaponIds[item.weapon_id] then
                Print("  " .. C_YELLOW .. "item '" .. tostring(id) .. "' links unknown weapon '"
                    .. tostring(item.weapon_id) .. "' (shown as a plain item)." .. "|r")
            end
        end
    end

    for key, char in pairs(ns.GetCharacters()) do
        for i, entry in ipairs(type(char.inventory) == "table" and char.inventory or {}) do
            if type(entry) == "table" and lib[entry.item_id] == nil then
                Print("  " .. C_YELLOW .. "character '" .. (char.name or key) .. "' inventory[" .. i
                    .. "] references unknown item '" .. tostring(entry.item_id) .. "'." .. "|r")
            end
        end
    end
end

-- Validates the loaded system, every character and the item library, printing
-- a summary.
local function RunValidation()
    if not ns.HasSystem() then
        Print(C_YELLOW .. "no system loaded." .. "|r Import one with " .. C_GOLD .. "/pmt import|r.")
        ValidateItems(nil)
        return
    end
    local system = ns.GetSystem()
    local ok, issues = ns.Schema.ValidateSystem(system)
    if ok then
        Print(C_GREEN .. "system '" .. (system.system_name or "?") .. "' is valid." .. "|r")
    else
        Print(C_RED .. "system has " .. #issues .. " issue(s):" .. "|r")
        for _, issue in ipairs(issues) do Print("  " .. C_RED .. issue .. "|r") end
    end

    -- Active packs, validated against the system they claim (Packs.PairedSystem
    -- keeps a foreign pack from failing cross-references against this one).
    local packs = { feats = ns.GetFeatPack(), spells = ns.GetSpellPack() }
    for kind, pack in pairs(packs) do
        local validate = (kind == "feats") and ns.Schema.ValidateFeatPack
            or ns.Schema.ValidateSpellPack
        local pok, pissues = validate(pack, ns.Packs.PairedSystem(pack))
        local label = ns.Packs.Label(kind) .. " '" .. tostring(pack.pack_name) .. "'"
        if pok then
            Print(C_GREEN .. label .. " is valid." .. "|r")
        else
            Print(C_RED .. label .. " has " .. #pissues .. " issue(s):" .. "|r")
            for _, issue in ipairs(pissues) do Print("  " .. C_RED .. issue .. "|r") end
        end
    end

    for key, char in pairs(ns.GetCharacters()) do
        local cok, cissues = ns.Schema.ValidateCharacter(char, system, packs)
        if cok then
            Print(C_GREEN .. "character '" .. (char.name or key) .. "' is valid." .. "|r")
        else
            Print(C_RED .. "character '" .. (char.name or key) .. "' has " .. #cissues .. " issue(s):" .. "|r")
            for _, issue in ipairs(cissues) do Print("  " .. C_RED .. issue .. "|r") end
        end
    end

    ValidateItems(system)
end

-- Prints the DM-role toggle result and refreshes the windows that show it.
local function AnnounceDMRole()
    Print((ns.Comm.IsDM() and C_GREEN .. "DM mode ON" or C_YELLOW .. "DM mode OFF")
        .. "|r - you " .. (ns.Comm.IsDM() and "broadcast" or "receive") .. " system and initiative sync.")
    if ns.InitiativeUI and ns.InitiativeUI.RefreshIfShown then ns.InitiativeUI.RefreshIfShown() end
    if ns.ConfigUI then ns.ConfigUI.RefreshIfShown() end
end

-- Handles /pmt dm [who | accept <name>]: toggle our own role (claim, with a
-- take-over confirm when we already recognize someone else; or step down), query
-- the recognized DM, or manually recognize a player (recovery).
local function HandleDMRole(arg)
    arg = strtrim(arg or "")
    local sub = arg:lower():match("^(%S*)")

    if sub == "who" then
        local rec = ns.Comm.RecognizedDM()
        if rec then Print("you recognize " .. C_GOLD .. rec .. "|r as DM.")
        else Print(C_YELLOW .. "no DM recognized yet." .. "|r") end
        return
    end
    if sub == "accept" then
        local name = strtrim(arg:match("^%S+%s+(.*)$") or "")
        if name == "" then Print(C_YELLOW .. "usage: /pmt dm accept <player name>" .. "|r"); return end
        ns.Comm.SetRecognizedDM(name)
        Print("now recognizing " .. C_GOLD .. name .. "|r as DM.")
        if ns.InitiativeUI and ns.InitiativeUI.RefreshIfShown then ns.InitiativeUI.RefreshIfShown() end
        return
    end

    -- No subcommand: step down if we are the DM, otherwise claim.
    if ns.Comm.IsDM() then
        ns.Comm.SetDM(false)
        AnnounceDMRole()
        return
    end
    -- Claiming while we already recognize a different DM is a take-over: confirm
    -- first so a stray /pmt dm cannot silently fight an existing DM. Escape keeps
    -- the current DM (non-destructive default).
    local rec = ns.Comm.RecognizedDM()
    if rec and not ns.Comm.SameName(rec, UnitName("player"))
        and ns.Dialogs and ns.Dialogs.ConfirmDMTakeover then
        ns.Dialogs.ConfirmDMTakeover(rec, function() ns.Comm.SetDM(true); AnnounceDMRole() end)
        return
    end
    ns.Comm.SetDM(true)
    AnnounceDMRole()
end

-- Dispatches a slash command line to the matching action.
local function HandleSlash(input)
    input = strtrim(input or "")
    local cmd = input:lower():match("^(%S*)")
    local arg = input:match("^%S*%s+(.*)$")

    if cmd == "" or cmd == "help" then
        PrintHelp()
    elseif cmd == "view" then
        if arg and arg ~= "" then ns.Sharing.Request(strtrim(arg))
        else Print(C_YELLOW .. "usage: /pmt view <player name>" .. "|r") end
    elseif cmd == "cached" then
        if arg and strtrim(arg):lower() == "clear" then ns.Sharing.ClearCache()
        else ns.Sharing.OpenCache() end
    elseif cmd == "who" then
        PrintRoster()
    elseif cmd == "validate" then
        RunValidation()
    elseif cmd == "dm" then
        HandleDMRole(arg)
    elseif cmd == "share" then
        local what = strtrim(arg or ""):lower()
        if what == "feats" or what == "spells" then
            ns.Packs.Share(what)
        elseif what == "all" then
            ns.ShareSystem()
            ns.Packs.Share("feats")
            ns.Packs.Share("spells")
        else
            ns.ShareSystem()
        end
    elseif cmd == "systems" then
        -- The system library lives in the hub (activate / delete per row).
        if ns.HubUI then ns.HubUI.Open("systems") end
    elseif cmd == "rolls" then
        local p = ns.Addon.db.profile
        p.publicRolls = not p.publicRolls
        Print((p.publicRolls and C_GREEN .. "public rolls ON" or C_YELLOW .. "public rolls OFF")
            .. "|r - initiative and sheet checks " .. (p.publicRolls and "use the in-game dice roller (party-visible)."
                or "use a hidden local d20."))
        if ns.InitiativeUI and ns.InitiativeUI.RefreshIfShown then ns.InitiativeUI.RefreshIfShown() end
        if ns.ConfigUI then ns.ConfigUI.RefreshIfShown() end
    elseif cmd == "minimap" then
        if ns.Minimap then
            local shown = ns.Minimap.Toggle()
            Print((shown and C_GREEN .. "minimap button shown" or C_YELLOW .. "minimap button hidden") .. "|r")
            if ns.ConfigUI then ns.ConfigUI.RefreshIfShown() end
        end
    elseif cmd == "save" then
        ns.SaveToDisk()
    elseif MODULE_COMMANDS[cmd] then
        ns.OpenModule(MODULE_COMMANDS[cmd])
    else
        Print(C_RED .. "unknown command '" .. cmd .. "'." .. "|r")
        PrintHelp()
    end
end

-- Runs pending data-format migrations, then stamps the current format. Data
-- from a NEWER Parchment (downgrade) is left untouched with a warning - we
-- cannot know how to read it, and wiping would destroy good data.
local function MigrateData(db)
    local from = db.global.dataFormat or 1
    if from > DB_FORMAT then
        Print(C_YELLOW .. "your saved data is from a newer Parchment (data format " .. from
            .. ", this addon reads " .. DB_FORMAT .. "). Update the addon; the data is untouched." .. "|r")
        return
    end
    for v = from + 1, DB_FORMAT do
        if MIGRATIONS[v] then MIGRATIONS[v](db) end
    end
    db.global.dataFormat = DB_FORMAT
end

-- AceAddon lifecycle.

function Parchment:OnInitialize()
    -- Settings DB (addon options live here; the data tables are their own SVs).
    self.db = LibStub("AceDB-3.0"):New("ParchmentDB", DB_DEFAULTS, true)
    local g = self.db.global
    ParchmentCharDB = ParchmentCharDB or {}
    ParchmentItemDB = ParchmentItemDB or {}
    ParchmentPackDB = ParchmentPackDB or {}
    -- No ruleset ships with Parchment: the system stays empty until the user
    -- imports one (/pmt import) or adopts a DM-shared one.
    ParchmentSystemDB = ParchmentSystemDB or {}

    -- Upgrade stored data written by older releases (see MIGRATIONS above).
    MigrateData(self.db)

    if not g.activeCharacter then
        g.activeCharacter = next(ns.GetCharacters())
    end

    -- Slash commands.
    self:RegisterChatCommand("parchment", HandleSlash)
    self:RegisterChatCommand("pmt", HandleSlash)

    -- One-line load summary; nudge first-time users to import a system.
    local note = ns.HasSystem() and ""
        or (C_YELLOW .. " No system loaded - import one with /pmt import." .. "|r")
    Print(C_GOLD .. "loaded." .. "|r" .. note .. " Type " .. C_GOLD .. "/pmt|r for commands.")
end

function Parchment:OnEnable()
    if ns.Minimap then ns.Minimap.Init() end
    if not ns.Comm then return end
    ns.Comm.Init()
    -- A DM-shared system is handled by Modules/Systems.lua: it is cached to the
    -- system library and the player is prompted to adopt it, never overwriting
    -- their active system without consent.
end
