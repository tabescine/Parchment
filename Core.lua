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
-- This is the only file that knows about the live SavedVariables globals. The
-- modules never touch ParchmentSystemDB / ParchmentCharDB directly; they call
-- the ns.Get* helpers here so the data source can change without touching them.
--
-- Reads from: ns.Schema.
-- Exposes on ns: the data API (GetSystem, HasSystem, GetCharacter, ...),
--   the module registry (RegisterModule, OpenModule), and ns.Addon.

local ADDON, ns = ...

-- Branding and message colours (see AGENTS code style).
local PREFIX = "|cffc8a868[Parchment]|r "
local C_GREEN = "|cff00ff00"
local C_RED = "|cffff4444"
local C_YELLOW = "|cffffcc00"
local C_GOLD = "|cffc8a868"

-- AceDB layout for addon settings (the data tables live in their own SVs).
local DB_DEFAULTS = {
    global = { activeCharacter = nil },
    profile = { minimap = { hide = false }, dm = false, publicRolls = false },
}

-- Slash subcommand -> module id (nil routing falls through to help).
local MODULE_COMMANDS = {
    init = "initiative",
    sheet = "sheet",
    perks = "perks",
    import = "import",
    edit = "edit",
    new = "new",
    config = "config",
}

local LibStub = LibStub
local Parchment = LibStub("AceAddon-3.0"):NewAddon(ADDON, "AceConsole-3.0", "AceEvent-3.0",
    "AceComm-3.0", "AceSerializer-3.0")
ns.Addon = Parchment

-- Module registry: id -> opener function, filled by RegisterModule as each
-- module loads. Empty until the module files are added (later work items).
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

-- Returns a deep copy of a value (used when seeding SavedVariables from the
-- bundled defaults so later edits don't mutate the shared default tables).
local function CopyDeep(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = CopyDeep(v) end
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

-- Returns the attribute record for an id, or nil.
function ns.GetAttribute(id)
    for _, attr in ipairs(ns.GetSystem().attributes or {}) do
        if attr.id == id then return attr end
    end
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
        mana_multiplier    = d.mana_multiplier or 2,
        movement_attribute = d.movement_attribute,       -- +per_step per positive modifier
        movement_base      = d.movement_base or 12,
        movement_per_step  = d.movement_per_step or 0.5,
        ac_base            = d.ac_base or 10,
        save_dc_base       = d.save_dc_base or 10,
        actions_base       = d.actions_base or 2,
    }
end

-- Returns the perk tree (sphere) record for an id, or nil.
function ns.GetPerkTree(id)
    for _, tree in ipairs(ns.GetSystem().perk_trees or {}) do
        if tree.id == id then return tree end
    end
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
    text = "Save all Parchment data to disk now?\n\nWoW only writes addon data on a UI reload or logout, so this will reload your interface.",
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
    Print("  " .. C_GOLD .. "/pmt sheet|r   - open the character sheet")
    Print("  " .. C_GOLD .. "/pmt init|r    - open the initiative tracker")
    Print("  " .. C_GOLD .. "/pmt perks|r   - open the perk tree viewer")
    Print("  " .. C_GOLD .. "/pmt new|r     - create a character (guided wizard)")
    Print("  " .. C_GOLD .. "/pmt edit|r    - open the character editor")
    Print("  " .. C_GOLD .. "/pmt import|r  - open the import/export dialog")
    Print("  " .. C_GOLD .. "/pmt config|r  - open settings")
    Print("  " .. C_GOLD .. "/pmt dm|r      - toggle DM mode (broadcast vs receive sync)")
    Print("  " .. C_GOLD .. "/pmt share|r   - DM: send your system to the group")
    Print("  " .. C_GOLD .. "/pmt systems|r - choose the active system (|cffc8a868/pmt systems delete|r to remove one)")
    Print("  " .. C_GOLD .. "/pmt rolls|r   - toggle public (party-visible) initiative rolls")
    Print("  " .. C_GOLD .. "/pmt view <name>|r - view another player's character sheet")
    Print("  " .. C_GOLD .. "/pmt cached|r  - browse cached sheets (|cffc8a868/pmt cached clear|r to wipe)")
    Print("  " .. C_GOLD .. "/pmt minimap|r - toggle the minimap button")
    Print("  " .. C_GOLD .. "/pmt save|r    - write all data to disk (reloads the UI)")
    Print("  " .. C_GOLD .. "/pmt who|r     - list known characters")
    Print("  " .. C_GOLD .. "/pmt validate|r- check the loaded system and characters")
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

-- Validates the loaded system and every character, printing a summary.
local function RunValidation()
    if not ns.HasSystem() then
        Print(C_YELLOW .. "no system loaded." .. "|r Import one with " .. C_GOLD .. "/pmt import|r.")
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

    for key, char in pairs(ns.GetCharacters()) do
        local cok, cissues = ns.Schema.ValidateCharacter(char, system)
        if cok then
            Print(C_GREEN .. "character '" .. (char.name or key) .. "' is valid." .. "|r")
        else
            Print(C_RED .. "character '" .. (char.name or key) .. "' has " .. #cissues .. " issue(s):" .. "|r")
            for _, issue in ipairs(cissues) do Print("  " .. C_RED .. issue .. "|r") end
        end
    end
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
        ns.Comm.SetDM(not ns.Comm.IsDM())
        Print((ns.Comm.IsDM() and C_GREEN .. "DM mode ON" or C_YELLOW .. "DM mode OFF")
            .. "|r - you " .. (ns.Comm.IsDM() and "broadcast" or "receive") .. " system and initiative sync.")
        if ns.InitiativeUI and ns.InitiativeUI.RefreshIfShown then ns.InitiativeUI.RefreshIfShown() end
        if ns.ConfigUI then ns.ConfigUI.RefreshIfShown() end
    elseif cmd == "share" then
        ns.ShareSystem()
    elseif cmd == "systems" then
        if ns.Systems then
            if arg and strtrim(arg):lower() == "delete" then ns.Systems.OpenDeletePicker()
            else ns.Systems.OpenPicker() end
        end
    elseif cmd == "rolls" then
        local p = ns.Addon.db.profile
        p.publicRolls = not p.publicRolls
        Print((p.publicRolls and C_GREEN .. "public rolls ON" or C_YELLOW .. "public rolls OFF")
            .. "|r - initiative rolls " .. (p.publicRolls and "use the in-game dice roller (party-visible)."
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

-- AceAddon lifecycle.

function Parchment:OnInitialize()
    -- Settings DB (addon options live here; the data tables are their own SVs).
    self.db = LibStub("AceDB-3.0"):New("ParchmentDB", DB_DEFAULTS, true)
    local g = self.db.global
    ParchmentCharDB = ParchmentCharDB or {}
    -- No ruleset ships with Parchment: the system stays empty until the user
    -- imports one (/pmt import) or adopts a DM-shared one.
    ParchmentSystemDB = ParchmentSystemDB or {}

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
