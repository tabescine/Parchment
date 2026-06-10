-- Parchment - Systems
--
-- Manages multiple system definitions so a DM-shared system never silently
-- destroys a player's own. Received systems are cached in a library and the
-- player is prompted to adopt; switching the active system preserves the
-- outgoing one. A picker (/pmt systems) chooses the active system from the
-- library. Parchment ships no system, so the library starts empty.
--
-- Reads from: ns.Addon.db.global (systemLibrary, systemSource), ns.Comm,
--   ns.Dialogs, ns.Print, ns.CharacterSheetUI, ns.PerkTreeUI. Owns
--   ParchmentSystemDB swaps.
-- Exposes on ns.Systems: Store, SetActive, OpenPicker.

local ADDON, ns = ...

ns.Systems = ns.Systems or {}
local Sys = ns.Systems

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deepcopy(v) end
    return o
end

-- The cache of known systems, keyed by system_name.
local function Library()
    local g = ns.Addon.db.global
    g.systemLibrary = g.systemLibrary or {}
    return g.systemLibrary
end

-- Refreshes any open windows that depend on the system. Also exposed as
-- Sys.RefreshAll so import flows can refresh after character-only changes.
local function RefreshAll()
    if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
    if ns.PerkTreeUI and ns.PerkTreeUI.frame and ns.PerkTreeUI.frame:IsShown() then ns.PerkTreeUI.Open() end
    if ns.CharacterEditorUI and ns.CharacterEditorUI.RefreshIfShown then ns.CharacterEditorUI.RefreshIfShown() end
    if ns.CharacterWizardUI and ns.CharacterWizardUI.RefreshIfShown then ns.CharacterWizardUI.RefreshIfShown() end
end
Sys.RefreshAll = RefreshAll

-- Caches a system into the library (latest wins per name).
function Sys.Store(system, from)
    if type(system) ~= "table" or not system.system_name then return end
    Library()[system.system_name] = {
        name = system.system_name, system = deepcopy(system),
        from = from, time = (time and time()) or 0,
    }
end

-- Makes a system the active one, preserving the outgoing system in the library
-- (if not already there) so nothing is lost.
function Sys.SetActive(system, from)
    if type(system) ~= "table" then return end
    local g = ns.Addon.db.global
    if type(ParchmentSystemDB) == "table" and ParchmentSystemDB.system_name
        and not Library()[ParchmentSystemDB.system_name] then
        Sys.Store(ParchmentSystemDB, "yours")
    end
    ParchmentSystemDB = deepcopy(system)
    g.systemSource = "imported"
    Sys.Store(ParchmentSystemDB, from)
    RefreshAll()
end

-- True when name matches the active system's name.
local function IsActiveName(name)
    return type(ParchmentSystemDB) == "table" and ParchmentSystemDB.system_name == name
end

-- The library as sorted picker items, the active system marked.
local function LibraryItems()
    local items = {}
    for name, entry in pairs(Library()) do
        items[#items + 1] = {
            id = name,
            name = name .. (entry.from and ("  |cff888888(from " .. entry.from .. ")|r") or "")
                .. (IsActiveName(name) and "  |cff66d966[active]|r" or ""),
        }
    end
    table.sort(items, function(a, b) return a.id < b.id end)
    return items
end

-- Opens the system picker over the cached system library.
function Sys.OpenPicker()
    local items = LibraryItems()
    if #items == 0 then
        ns.Print("your system library is empty. Import one with /pmt import.")
        return
    end

    ns.Dialogs.Pick({
        title = "Systems", prompt = "Choose the active system", items = items, max = 1, selected = {},
        onConfirm = function(ids)
            local id = ids[1]
            local entry = id and Library()[id]
            if entry then
                Sys.SetActive(entry.system, entry.from)
                ns.Print("now using system '" .. id .. "'.")
            end
        end,
    })
end

-- Deletes a system from the library. Deleting the active system also clears
-- it (otherwise the next switch-away would resurrect the library entry),
-- returning the addon to the no-system state. Characters are untouched.
function Sys.Delete(name)
    if not Library()[name] then return end
    Library()[name] = nil
    if IsActiveName(name) then
        ParchmentSystemDB = {}
        ns.Addon.db.global.systemSource = nil
        ns.Print("deleted system '" .. name .. "'. It was active - no system is loaded now.")
    else
        ns.Print("deleted system '" .. name .. "' from your library.")
    end
    RefreshAll()
end

-- Opens a picker to delete a system from the library (confirmed via popup).
function Sys.OpenDeletePicker()
    local items = LibraryItems()
    if #items == 0 then
        ns.Print("your system library is empty - nothing to delete.")
        return
    end

    ns.Dialogs.Pick({
        title = "Delete System", prompt = "Choose a system to delete", items = items, max = 1, selected = {},
        onConfirm = function(ids)
            local name = ids[1]
            if not (name and Library()[name]) then return end
            local note = IsActiveName(name)
                and "It is your ACTIVE system - Parchment returns to the no-system state."
                or "Your characters are not affected."
            StaticPopup_Show("PARCHMENT_DELETE_SYSTEM", name, note, name)
        end,
    })
end

-- Confirm dialog for deleting a system (destructive once saved to disk).
StaticPopupDialogs["PARCHMENT_DELETE_SYSTEM"] = {
    text = "Delete system \"%s\"?\n\n%s",
    button1 = DELETE or "Delete",
    button2 = CANCEL,
    OnAccept = function(_, name) Sys.Delete(name) end,
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
            ns.Print("now using system '" .. entry.name .. "'.")
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Receive handler: cache the shared system and prompt, rather than overwriting.
-- Remote data is schema-validated first - the local import path validates, and
-- the comm path must hold the same line or a bad share breaks every window.
if ns.Comm then
    ns.Comm.On("SYSTEM", function(system, sender)
        if type(system) ~= "table" or type(system.system_name) ~= "string" then return end
        local ok = ns.Schema.ValidateSystem(system)
        if not ok then
            ns.Print((sender or "someone") .. " shared system '" .. system.system_name
                .. "' but it failed validation; ignored.")
            return
        end
        Sys.Store(system, sender)
        ns.Print((sender or "a DM") .. " shared system '" .. system.system_name .. "'.")
        StaticPopup_Show("PARCHMENT_ADOPT_SYSTEM", tostring(sender), system.system_name,
            { system = deepcopy(system), from = sender, name = system.system_name })
    end)
end
