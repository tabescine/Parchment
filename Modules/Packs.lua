-- Parchment - Packs
--
-- Manages feat and spell pack libraries so a DM-shared pack never silently
-- destroys a player's own, mirroring Modules/Systems.lua: received packs are
-- cached and the player is prompted to adopt. A pack pairs with a system via
-- its `for_system` name (advisory - a pack imports fine without its system);
-- switching the active system re-resolves which pack of each kind is active.
--
-- Pack libraries are bounded before they reach SavedVariables (see MAX_ENTRIES
-- / MAX_PACK_BYTES below, the same line Modules/Systems.lua holds), and every
-- remote-derived name printed or shown in a popup goes through ns.SafeText.
--
-- Reads from: the ns pack data API (GetPackLibrary, GetActivePackName,
--   SetActivePackName, GetActivePack - Core.lua owns the ParchmentPackDB
--   global), ns.Comm, ns.Schema, ns.ImportExport (StripMeta), ns.JSON (size
--   bound), ns.Print, ns.SafeText, ns.DeepCopy, ns.Systems (RefreshAll).
-- Exposes on ns.Packs: Store, Activate, Deactivate, Import, Delete,
--   ConfirmDelete, SyncToSystem, Share, PairedSystem, Label.

local ADDON, ns = ...

ns.Packs = ns.Packs or {}
local Packs = ns.Packs

-- Bounds on each kind's library, mirroring Modules/Systems.lua: a pack over
-- MAX_PACK_BYTES (encoded) never lands, and a library holds at most
-- MAX_ENTRIES packs. The comm path stores whatever a recognized DM sends,
-- keyed by an attacker-chosen pack_name, so unbounded these are permanent
-- saved-file growth on a share flood. A full library refuses the newcomer with
-- a notice rather than evicting: the entries are the player's own imported
-- content, not a re-fetchable cache.
local MAX_PACK_BYTES = 512 * 1024
local MAX_ENTRIES = 25

local KINDS = { "feats", "spells" }
local KIND_LABEL = { feats = "feats pack", spells = "spells pack" }
local KIND_MSG = { feats = "FEATS", spells = "SPELLS" }

-- Human label for a pack kind ("feats pack" / "spells pack").
function Packs.Label(kind)
    return KIND_LABEL[kind] or "pack"
end

local function Validator(kind)
    return kind == "feats" and ns.Schema.ValidateFeatPack or ns.Schema.ValidateSpellPack
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

-- Refreshes every window that renders system or pack data. Pack contents feed
-- the same sheets and pickers a system switch invalidates, so the system-level
-- refresh is the right (single) hammer.
local function RefreshAll()
    if ns.Systems then ns.Systems.RefreshAll() end
end

-- The active system, when the pack explicitly claims it by name; nil
-- otherwise. This is what pack validation resolves attributes against: a pack
-- claiming no system (or somebody else's) must not fail cross-reference
-- checks against whatever happens to be loaded here.
function Packs.PairedSystem(pack)
    if type(pack) == "table" and pack.for_system ~= nil and ns.HasSystem()
        and ns.GetSystem().system_name == pack.for_system then
        return ns.GetSystem()
    end
    return nil
end

-- True when a pack may activate alongside the ACTIVE system: it claims no
-- system at all (universal), or it claims the active one by name.
local function PairsWithActive(pack)
    if type(pack) ~= "table" then return false end
    if pack.for_system == nil then return true end
    return ns.HasSystem() and ns.GetSystem().system_name == pack.for_system
end

-- Caches a pack into its kind's library (latest wins per pack_name), within
-- the bounds above. Returns true when it was stored, false when it is not a
-- pack or a bound refused it - a refusal prints its own notice and leaves the
-- library exactly as it was.
function Packs.Store(kind, pack, from)
    if type(pack) ~= "table" or type(pack.pack_name) ~= "string" then return false end
    local lib, name = ns.GetPackLibrary(kind), pack.pack_name

    -- Refuse an oversized pack outright, and refuse a NEW name once the library
    -- is full - an update of a name already stored always goes through, so
    -- "latest wins" still holds for packs the player already keeps.
    local size = EncodedSize(pack)
    if not size or size > MAX_PACK_BYTES then
        ns.Print(Packs.Label(kind) .. " '" .. ns.SafeText(name)
            .. "' is too large to store; ignored.")
        return false
    end
    if lib[name] == nil and Count(lib) >= MAX_ENTRIES then
        ns.Print("your " .. Packs.Label(kind) .. " library is full (" .. MAX_ENTRIES
            .. "). Delete one in /pmt systems to make room for '" .. ns.SafeText(name) .. "'.")
        return false
    end

    lib[name] = {
        name = name, pack = ns.DeepCopy(pack),
        from = from, time = (time and time()) or 0,
    }
    return true
end

-- Makes a stored pack the active one of its kind. Returns ok, err.
function Packs.Activate(kind, name)
    if not ns.SetActivePackName(kind, name) then
        return false, "no " .. Packs.Label(kind) .. " named '" .. ns.SafeText(name)
            .. "' in your library."
    end
    RefreshAll()
    return true
end

-- Clears the active pack of a kind (back to the empty state).
function Packs.Deactivate(kind)
    ns.SetActivePackName(kind, nil)
    RefreshAll()
end

-- The import seam (local paste and converter alike): stores the pack, then
-- activates it when it pairs with the active system. Returns activated, stored:
-- `stored` is false when a library bound refused the pack (Store printed why),
-- in which case nothing was activated either.
function Packs.Import(kind, pack, from)
    if not Packs.Store(kind, pack, from) then return false, false end
    local activated = false
    if PairsWithActive(pack) then
        activated = ns.SetActivePackName(kind, pack.pack_name)
    end
    RefreshAll()
    return activated, true
end

-- Deletes a pack from its library. Deleting the active pack deactivates it
-- (the pointer self-heals to nil); characters are untouched - their picks
-- simply stop resolving until it returns.
function Packs.Delete(kind, name)
    local lib = ns.GetPackLibrary(kind)
    if not lib[name] then return end
    local wasActive = ns.GetActivePackName(kind) == name
    lib[name] = nil
    if wasActive then ns.SetActivePackName(kind, nil) end
    ns.Print("deleted " .. Packs.Label(kind) .. " '" .. ns.SafeText(name) .. "'"
        .. (wasActive and ". It was active - none is now." or " from your library."))
    RefreshAll()
end

-- Confirm dialog for deleting a pack (destructive once saved to disk).
StaticPopupDialogs["PARCHMENT_DELETE_PACK"] = {
    text = "Delete %s \"%s\"?\n\nCharacters are not affected; their picks stop resolving until it returns.",
    button1 = DELETE or "Delete",
    button2 = CANCEL,
    OnAccept = function(_, data)
        Packs.Delete(data.kind, data.name)
        if ns.HubUI then ns.HubUI.RefreshIfShown("systems") end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Opens the delete confirmation for a library entry. The name is sanitized for
-- display only; the popup's data keeps the exact key deletion looks up.
function Packs.ConfirmDelete(kind, name)
    if not ns.GetPackLibrary(kind)[name] then return end
    StaticPopup_Show("PARCHMENT_DELETE_PACK", Packs.Label(kind), ns.SafeText(name),
        { kind = kind, name = name })
end

-- Re-resolves one kind's active pack against the active system: a still-
-- pairing active pack stays; otherwise the library pack claiming the system
-- by name activates (alphabetically first when several do); otherwise the
-- pointer clears - the empty state, never an error.
local function SyncKind(kind)
    local lib = ns.GetPackLibrary(kind)
    local activeName = ns.GetActivePackName(kind)
    local active = activeName and lib[activeName]
    if active and PairsWithActive(active.pack) then return end

    local pick
    if ns.HasSystem() then
        local sysName = ns.GetSystem().system_name
        for name, entry in pairs(lib) do
            if type(entry) == "table" and type(entry.pack) == "table"
                and entry.pack.for_system == sysName
                and (not pick or name < pick) then
                pick = name
            end
        end
    end
    if pick then
        ns.SetActivePackName(kind, pick)
        ns.Print("now using " .. Packs.Label(kind) .. " '" .. ns.SafeText(pick)
            .. "' with this system.")
    elseif activeName then
        ns.SetActivePackName(kind, nil)
        ns.Print(Packs.Label(kind) .. " '" .. ns.SafeText(activeName)
            .. "' does not pair with this system; deactivated.")
    end
end

-- Re-resolves both kinds. Modules/Systems.lua calls this after every active-
-- system swap (import, adoption, library switch).
function Packs.SyncToSystem()
    for _, kind in ipairs(KINDS) do SyncKind(kind) end
end

-- Broadcasts the active pack of a kind to the group (DM only), like
-- ns.ShareSystem. Sharing is always this explicit action.
function Packs.Share(kind)
    if not ns.Comm.IsDM() then
        ns.Print("only the DM shares packs. Use /pmt dm first.")
        return
    end
    local pack = ns.GetActivePack(kind)
    if not pack then
        ns.Print("no active " .. Packs.Label(kind) .. " to share. Import one with /pmt import first.")
        return
    end
    local ok, err = ns.Comm.Send(KIND_MSG[kind], pack)
    ns.Print(ok and ("shared the " .. Packs.Label(kind) .. " with your group.")
        or (err or "share failed"))
end

-- Prompt to adopt a DM-shared pack (cached regardless of the choice). The
-- popup's data carries kind + name only; activation resolves from the library
-- at click time, so a same-name share arriving in between simply updates what
-- "Use it" activates - latest wins, matching Store.
StaticPopupDialogs["PARCHMENT_ADOPT_PACK"] = {
    text = "%s\n\nIt is saved to your pack library either way.",
    button1 = "Use it",
    button2 = "Not now",
    OnAccept = function(_, data)
        if data and Packs.Activate(data.kind, data.name) then
            ns.Print("now using " .. Packs.Label(data.kind) .. " '"
                .. ns.SafeText(data.name) .. "'.")
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Receive handler factory: cache the shared pack and prompt, never overwrite
-- silently. Remote data is schema-validated first - the same line as the
-- local import path, or a bad share breaks every window that renders packs.
-- Sender and pack name are remote text, so everything shown goes through
-- ns.SafeText: a raw "|" escape would render as a forged item link, and an
-- unbounded name would hang the chat frame.
local function OnPackShared(kind)
    return function(pack, sender)
        if ns.Comm.IsSelf(sender) then return end
        if type(pack) ~= "table" or type(pack.pack_name) ~= "string" then return end
        if ns.ImportExport and ns.ImportExport.StripMeta then
            pack = ns.ImportExport.StripMeta(pack)
        end
        local ok = Validator(kind)(pack, Packs.PairedSystem(pack))
        if not ok then
            ns.Print(ns.SafeText(sender, nil, "someone") .. " shared " .. Packs.Label(kind)
                .. " '" .. ns.SafeText(pack.pack_name) .. "' but it failed validation; ignored.")
            return
        end
        -- A refused store (oversized, or a full library) already said why; do
        -- not follow it with a "shared" line and an adopt prompt for something
        -- we did not keep - that popup is exactly what a flood would spam.
        if not Packs.Store(kind, pack, sender) then return end
        ns.Print(ns.SafeText(sender, nil, "a DM") .. " shared " .. Packs.Label(kind)
            .. " '" .. ns.SafeText(pack.pack_name) .. "'.")
        StaticPopup_Show("PARCHMENT_ADOPT_PACK",
            ns.SafeText(sender, nil, "someone") .. " shared the " .. Packs.Label(kind)
                .. " \"" .. ns.SafeText(pack.pack_name) .. "\". Use it now?",
            nil, { kind = kind, name = pack.pack_name })
    end
end

if ns.Comm then
    ns.Comm.On("FEATS", OnPackShared("feats"))
    ns.Comm.On("SPELLS", OnPackShared("spells"))
end
