-- Parchment - Systems
--
-- Manages multiple system definitions so a DM-shared system never silently
-- destroys a player's own. Received systems are cached in a library and the
-- player is prompted to adopt; switching the active system preserves the
-- outgoing one. A picker (/pmt systems) chooses the active system, including the
-- bundled default.
--
-- Reads from: ns.Addon.db.global (systemLibrary, systemSource), ns.ReseedSystem,
--   ns.defaultSystem, ns.Comm, ns.Dialogs, ns.Print, ns.CharacterSheetUI,
--   ns.PerkTreeUI. Owns ParchmentSystemDB swaps.
-- Exposes on ns.Systems: Store, SetActive, UseBundled, OpenPicker.

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

-- Refreshes any open windows that depend on the system.
local function RefreshAll()
    if ns.CharacterSheetUI then ns.CharacterSheetUI.RefreshIfShown() end
    if ns.PerkTreeUI and ns.PerkTreeUI.frame and ns.PerkTreeUI.frame:IsShown() then ns.PerkTreeUI.Open() end
end

-- Caches a system into the library (latest wins per name).
function Sys.Store(system, from)
    if type(system) ~= "table" or not system.system_name then return end
    Library()[system.system_name] = {
        name = system.system_name, system = deepcopy(system),
        from = from, time = (time and time()) or 0,
    }
end

-- Makes a system the active one, preserving the outgoing (non-bundled) system
-- in the library so nothing is lost.
function Sys.SetActive(system, from)
    if type(system) ~= "table" then return end
    local g = ns.Addon.db.global
    if g.systemSource ~= "bundled" and type(ParchmentSystemDB) == "table" and ParchmentSystemDB.system_name then
        Sys.Store(ParchmentSystemDB, "yours")
    end
    ParchmentSystemDB = deepcopy(system)
    g.systemSource = "imported"
    Sys.Store(ParchmentSystemDB, from)
    RefreshAll()
end

-- Switches to the bundled default, preserving any non-bundled current system.
function Sys.UseBundled()
    local g = ns.Addon.db.global
    if g.systemSource ~= "bundled" and type(ParchmentSystemDB) == "table" and ParchmentSystemDB.system_name then
        Sys.Store(ParchmentSystemDB, "yours")
    end
    ns.ReseedSystem()
    RefreshAll()
end

-- Opens the system picker (bundled default + cached systems).
function Sys.OpenPicker()
    local g = ns.Addon.db.global
    local activeName = type(ParchmentSystemDB) == "table" and ParchmentSystemDB.system_name or nil
    local bundledName = ns.defaultSystem.system_name
    local function activeTag(isActive) return isActive and "  |cff66d966[active]|r" or "" end

    local items = {
        { id = "__bundled", name = bundledName .. " (bundled)" .. activeTag(g.systemSource == "bundled") },
    }
    for name, entry in pairs(Library()) do
        items[#items + 1] = {
            id = name,
            name = name .. (entry.from and ("  |cff888888(from " .. entry.from .. ")|r") or "")
                .. activeTag(g.systemSource ~= "bundled" and name == activeName),
        }
    end

    ns.Dialogs.Pick({
        title = "Systems", prompt = "Choose the active system", items = items, max = 1, selected = {},
        onConfirm = function(ids)
            local id = ids[1]
            if id == "__bundled" then
                Sys.UseBundled()
                ns.Print("now using the bundled system.")
            elseif id then
                local entry = Library()[id]
                if entry then
                    Sys.SetActive(entry.system, entry.from)
                    ns.Print("now using system '" .. id .. "'.")
                end
            end
        end,
    })
end

-- Prompt to adopt a DM-shared system (cached regardless of the choice).
StaticPopupDialogs["PARCHMENT_ADOPT_SYSTEM"] = {
    text = "%s shared the system \"%s\". Use it now?\n\nIt is saved to your systems (/pmt systems) either way.",
    button1 = "Use it",
    button2 = "Not now",
    OnAccept = function(_, name)
        local entry = Library()[name]
        if entry then
            Sys.SetActive(entry.system, entry.from)
            ns.Print("now using system '" .. name .. "'.")
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Receive handler: cache the shared system and prompt, rather than overwriting.
if ns.Comm then
    ns.Comm.On("SYSTEM", function(system, sender)
        if type(system) ~= "table" or not system.system_name then return end
        Sys.Store(system, sender)
        ns.Print((sender or "a DM") .. " shared system '" .. system.system_name .. "'.")
        StaticPopup_Show("PARCHMENT_ADOPT_SYSTEM", tostring(sender), system.system_name, system.system_name)
    end)
end
