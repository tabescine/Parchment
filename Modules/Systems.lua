-- Parchment - Systems
--
-- Manages multiple system definitions so a DM-shared system never silently
-- destroys a player's own. Received systems are cached in a library and the
-- player is prompted to adopt; switching the active system preserves the
-- outgoing one. A picker (/pmt systems) chooses the active system from the
-- library. Parchment ships no system, so the library starts empty.
--
-- The library is bounded before it reaches SavedVariables (see MAX_ENTRIES /
-- MAX_SYSTEM_BYTES below), and every remote-derived name printed or shown in a
-- popup goes through ns.SafeText.
--
-- Reads from: ns.Addon.db.global (systemLibrary), ns.Comm, ns.ImportExport
--   (StripMeta), ns.JSON (size bound), ns.Print, ns.SafeText, ns.DeepCopy,
--   ns.HubUI, ns.CharacterSheetUI, ns.FeatsUI, ns.SpellbookUI, ns.ItemWizardUI.
--   Owns ParchmentSystemDB swaps. The library is browsed/managed in the
--   hub's Systems panel (UI/HubPanels.lua).
-- Exposes on ns.Systems: Store, SetActive, GetLibrary, ConfirmDelete,
--   Delete, RefreshAll.

local ADDON, ns = ...

ns.Systems = ns.Systems or {}
local Sys = ns.Systems

-- Bounds on the library, in the spirit of Modules/Sharing.lua's received-sheet
-- cache: a system over MAX_SYSTEM_BYTES (encoded) is refused before it touches
-- SavedVariables, and the library holds at most MAX_ENTRIES systems. The comm
-- path stores whatever a recognized DM sends, keyed by an attacker-chosen name,
-- so unbounded these two are permanent saved-file growth on a share flood.
-- The cap is roomier than Sharing's (a whole ruleset, not one character) and
-- the entry count tighter - nobody keeps dozens of systems.
-- Unlike a cached sheet (re-requestable), a library entry is the player's own
-- imported content, so a full library REFUSES the newcomer with a notice
-- instead of evicting anything.
local MAX_SYSTEM_BYTES = 512 * 1024
local MAX_ENTRIES = 25

-- The cache of known systems, keyed by system_name.
local function Library()
    local g = ns.Addon.db.global
    g.systemLibrary = g.systemLibrary or {}
    return g.systemLibrary
end

-- The encoded byte size of a value, or nil when it cannot be encoded. Runs
-- under pcall so a pathologically shaped payload cannot throw here.
local function EncodedSize(value)
    local ok, enc = pcall(ns.JSON.encode, value)
    if not ok or type(enc) ~= "string" then return nil end
    return #enc
end

-- How many entries a name-keyed table holds (`#` says nothing about these).
local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Refreshes any open windows that depend on the system. Also exposed as
-- Sys.RefreshAll so import flows can refresh after character-only changes.
local function RefreshAll()
    if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
    if ns.FeatsUI and ns.FeatsUI.RefreshIfShown then ns.FeatsUI.RefreshIfShown() end
    if ns.SpellbookUI and ns.SpellbookUI.RefreshIfShown then ns.SpellbookUI.RefreshIfShown() end
    if ns.CharacterEditorUI and ns.CharacterEditorUI.RefreshIfShown then ns.CharacterEditorUI.RefreshIfShown() end
    if ns.CharacterWizardUI and ns.CharacterWizardUI.RefreshIfShown then ns.CharacterWizardUI.RefreshIfShown() end
    if ns.ItemWizardUI and ns.ItemWizardUI.RefreshIfShown then ns.ItemWizardUI.RefreshIfShown() end
    if ns.HubUI then ns.HubUI.RefreshIfShown() end
end
Sys.RefreshAll = RefreshAll

-- Caches a system into the library (latest wins per name), within the bounds
-- above. Returns true when it was stored, false when it is not a system or a
-- bound refused it - a refusal prints its own notice and keeps the library as
-- it was.
function Sys.Store(system, from)
    if type(system) ~= "table" or not system.system_name then return false end
    local lib, name = Library(), system.system_name

    -- Refuse an oversized system outright, and refuse a NEW name once the
    -- library is full - an update of a name already stored always goes through,
    -- so "latest wins" still holds for systems the player already keeps.
    local size = EncodedSize(system)
    if not size or size > MAX_SYSTEM_BYTES then
        ns.Print("system '" .. ns.SafeText(name) .. "' is too large to store; ignored.")
        return false
    end
    if lib[name] == nil and Count(lib) >= MAX_ENTRIES then
        ns.Print("your system library is full (" .. MAX_ENTRIES .. "). Delete one in "
            .. "/pmt systems to make room for '" .. ns.SafeText(name) .. "'.")
        return false
    end

    lib[name] = {
        name = name, system = ns.DeepCopy(system),
        from = from, time = (time and time()) or 0,
    }
    return true
end

-- Makes a system the active one, preserving the outgoing system in the library
-- (if not already there) so nothing is lost. Preservation is best-effort: a
-- library already at MAX_ENTRIES refuses the outgoing system, and Sys.Store
-- says so - the swap still happens, so the user is told rather than silently
-- losing it.
function Sys.SetActive(system, from)
    if type(system) ~= "table" then return end
    if type(ParchmentSystemDB) == "table" and ParchmentSystemDB.system_name
        and not Library()[ParchmentSystemDB.system_name] then
        Sys.Store(ParchmentSystemDB, "yours")
    end
    ParchmentSystemDB = ns.DeepCopy(system)
    Sys.Store(ParchmentSystemDB, from)
    -- The active system changed, so re-resolve which feat/spell packs pair
    -- with it (Modules/Packs.lua; loads after this file, hence the guard).
    if ns.Packs then ns.Packs.SyncToSystem() end
    RefreshAll()
end

-- True when name matches the active system's name.
local function IsActiveName(name)
    return type(ParchmentSystemDB) == "table" and ParchmentSystemDB.system_name == name
end

-- The system library, keyed by system_name: { name, system, from, time }.
-- Read-only for callers (the hub's Systems panel renders it).
function Sys.GetLibrary()
    return Library()
end

-- Deletes a system from the library. Deleting the active system also clears
-- it (otherwise the next switch-away would resurrect the library entry),
-- returning the addon to the no-system state. Characters are untouched.
function Sys.Delete(name)
    if not Library()[name] then return end
    Library()[name] = nil
    if IsActiveName(name) then
        ParchmentSystemDB = {}
        ns.Print("deleted system '" .. ns.SafeText(name)
            .. "'. It was active - no system is loaded now.")
    else
        ns.Print("deleted system '" .. ns.SafeText(name) .. "' from your library.")
    end
    RefreshAll()
end

-- Opens the delete confirmation for a library entry (the hub's Systems
-- panel calls this from its per-row delete button). The name is sanitized for
-- display only; the popup's data keeps the exact key deletion looks up.
function Sys.ConfirmDelete(name)
    if not Library()[name] then return end
    local note = IsActiveName(name)
        and "It is your ACTIVE system - Parchment returns to the no-system state."
        or "Your characters are not affected."
    StaticPopup_Show("PARCHMENT_DELETE_SYSTEM", ns.SafeText(name), note, name)
end

-- Confirm dialog for deleting a system (destructive once saved to disk).
StaticPopupDialogs["PARCHMENT_DELETE_SYSTEM"] = {
    text = "Delete system \"%s\"?\n\n%s",
    button1 = DELETE or "Delete",
    button2 = CANCEL,
    OnAccept = function(_, name)
        Sys.Delete(name)
        if ns.HubUI then ns.HubUI.RefreshIfShown("systems") end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Prompt to adopt a DM-shared system (cached regardless of the choice). The
-- popup's data is the exact received entry, so a same-name share arriving
-- between the prompt and the click cannot swap what "Use it" applies.
StaticPopupDialogs["PARCHMENT_ADOPT_SYSTEM"] = {
    text = "%s shared the system \"%s\". Use it now?\n\nIt is saved to your systems (/pmt systems) either way.",
    button1 = "Use it",
    button2 = "Not now",
    OnAccept = function(_, entry)
        if entry and entry.system then
            Sys.SetActive(entry.system, entry.from)
            ns.Print("now using system '" .. ns.SafeText(entry.name) .. "'.")
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Receive handler: cache the shared system and prompt, rather than overwriting.
-- Remote data is schema-validated first - the local import path validates, and
-- the comm path must hold the same line or a bad share breaks every window.
-- Everything the handler shows the player (sender, system name) is remote text,
-- so it goes through ns.SafeText: a raw "|" escape would render as a forged
-- item link, and an unbounded name would hang the chat frame.
if ns.Comm then
    ns.Comm.On("SYSTEM", function(system, sender)
        -- Our own broadcast echoes back; a DM must not be prompted to adopt
        -- the system they just shared.
        if ns.Comm.IsSelf(sender) then return end
        if type(system) ~= "table" or type(system.system_name) ~= "string" then return end
        -- Same line as the local import path: strip '_'-prefixed metadata
        -- before validating and storing, so remote metadata never persists into
        -- the library / ParchmentSystemDB or round-trips into local exports.
        if ns.ImportExport and ns.ImportExport.StripMeta then
            system = ns.ImportExport.StripMeta(system)
        end
        local ok = ns.Schema.ValidateSystem(system)
        if not ok then
            ns.Print(ns.SafeText(sender, nil, "someone") .. " shared system '"
                .. ns.SafeText(system.system_name) .. "' but it failed validation; ignored.")
            return
        end
        -- A refused store (oversized, or a full library) already said why; do
        -- not follow it with a "shared" line and an adopt prompt for something
        -- we did not keep - that popup is exactly what a flood would spam.
        if not Sys.Store(system, sender) then return end
        ns.Print(ns.SafeText(sender, nil, "a DM") .. " shared system '"
            .. ns.SafeText(system.system_name) .. "'.")
        StaticPopup_Show("PARCHMENT_ADOPT_SYSTEM", ns.SafeText(sender, nil, "someone"),
            ns.SafeText(system.system_name),
            { system = ns.DeepCopy(system), from = sender, name = system.system_name })
    end)
end
