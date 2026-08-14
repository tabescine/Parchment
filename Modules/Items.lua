-- Parchment - Items (logic)
--
-- The rules of the item library's per-character side: how an inventory entry
-- resolves to an item, how a library item is instantiated into an inventory,
-- and the two per-character mutations (equip toggle, gear counter).
--
-- Inventory entries are thin references - { item_id, equipped, count } - and
-- everything displayed comes from the library, resolved fresh on every render.
-- That is what makes editing a library item update every character holding it;
-- the price is that a reference can dangle, which resolution answers with the
-- shared ns.MISSING_ITEM sentinel instead of an error. Between the two sits the
-- wire case: a shared sheet arrives with a `resolved` display snapshot on each
-- entry (Modules/Sharing.lua), used only when the viewer's own library cannot
-- resolve the id. Hence the precedence library -> resolved -> missing.
--
-- Pure logic: the library is passed in, never read from SavedVariables here, so
-- the whole file (and CharacterSheet.Compute through it) is testable offline.
--
-- Reads from: ns.MISSING_ITEM.
-- Exposes on ns.Items: .Resolve, .Instantiate, .ToggleEquipped, .SetCount,
--   .Remove, .ClampCount, .MigrateAC, .WieldStates, .EffectiveWield,
--   .CycleWield, .MAX_COUNT.

local ADDON, ns = ...

ns.Items = ns.Items or {}
local Items = ns.Items

-- Gear counters are player-editable, so they are bounded: a count is a whole
-- number in [0, MAX_COUNT] (mirrored by the schema's default_count check).
local MAX_COUNT = 9999
Items.MAX_COUNT = MAX_COUNT

-- The schema's bounds an ac_bonus lives within (MAX_BONUS there) and the item
-- effects list cap (MAX_ITEM_EFFECTS), mirrored for the legacy conversion.
local MAX_BONUS = 99
local MAX_EFFECTS = 10

-- Returns the inventory entry at `index`, or nil when the character has no
-- inventory or the index does not name an entry. Every mutation below goes
-- through this, so a stale index from a refreshing UI is a no-op, not an error.
local function EntryAt(char, index)
    if type(char) ~= "table" or type(char.inventory) ~= "table" then return nil end
    local entry = char.inventory[index]
    if type(entry) ~= "table" then return nil end
    return entry
end

-- Coerces a value into a valid gear count: a whole number in [0, MAX_COUNT].
-- Returns nil for anything that is not a number (NaN included), so callers can
-- fall back or refuse rather than store nonsense.
function Items.ClampCount(value)
    local n = tonumber(value)
    if not n or n ~= n then return nil end     -- not numeric, or NaN
    if n < 0 then return 0 end
    if n > MAX_COUNT then return MAX_COUNT end
    return math.floor(n)
end

-- Folds a legacy ac_bonus field into the item's effects list (an "ac" effect,
-- the shape the wizard authors since the field was retired). Mutates and
-- returns the item; idempotent, so the load-time migration re-running against
-- already-converted data is a no-op.
--
-- Only equipment ever applied the field, so only equipment converts; on any
-- other kind (where it was dormant - nothing read it) the field is simply
-- dropped, as it is when the bonus is zero or unusable. The one item that
-- keeps it is an equipment piece whose effects list is already full: the
-- sheet's legacy fold still applies the field, so nothing is lost.
function Items.MigrateAC(item)
    if type(item) ~= "table" or item.ac_bonus == nil then return item end
    local n = tonumber(item.ac_bonus)
    local bonus = 0
    if n and n == n and n ~= math.huge and n ~= -math.huge then
        bonus = math.max(-MAX_BONUS, math.min(MAX_BONUS, math.floor(n)))
    end
    if item.kind ~= "equipment" or bonus == 0 then
        item.ac_bonus = nil
        return item
    end

    local effects = type(item.effects) == "table" and item.effects or {}
    if #effects >= MAX_EFFECTS then return item end
    effects[#effects + 1] = { type = "ac", value = bonus }
    item.effects = effects
    item.ac_bonus = nil
    return item
end

-- Resolves an inventory entry to the item it displays.
--
-- Returns two values: item, source
--   item   - the library record, the entry's wire snapshot, or ns.MISSING_ITEM
--   source - "library", "wire" or "missing" (which of the three answered)
--
-- `lib` is the item library ({ [id] = item }); nil or a stale library simply
-- pushes resolution down the chain. The returned table may be the shared
-- sentinel or live library data - treat it as read-only.
function Items.Resolve(entry, lib)
    if type(entry) ~= "table" then return ns.MISSING_ITEM, "missing" end
    if type(lib) == "table" and type(entry.item_id) == "string" then
        local item = lib[entry.item_id]
        if type(item) == "table" then return item, "library" end
    end
    if type(entry.resolved) == "table" then return entry.resolved, "wire" end
    return ns.MISSING_ITEM, "missing"
end

-- Builds the inventory entry for a library item: the reference plus the state
-- that is genuinely per character - `equipped` for weapons and equipment,
-- `count` (seeded from the item's default_count) for gear. Returns nil when the
-- item is not a stored record (an id is what an inventory entry references).
function Items.Instantiate(item)
    if type(item) ~= "table" or type(item.id) ~= "string" then return nil end
    local entry = { item_id = item.id }
    if item.kind == "gear" then
        entry.count = Items.ClampCount(item.default_count) or 1
    else
        entry.equipped = false
    end
    return entry
end

-- Flips an inventory entry's equipped state. Returns the new state, or nil when
-- the index names no entry. Nothing limits how much may be equipped at once -
-- equipment AC bonuses stack across pieces by design.
function Items.ToggleEquipped(char, index)
    local entry = EntryAt(char, index)
    if not entry then return nil end
    entry.equipped = not entry.equipped
    return entry.equipped
end

-- The wield states a weapon category allows, in the order the sheet's toggle
-- cycles them. Weapons follow the tabletop convention the categories encode:
-- a light weapon can sit in either hand, a versatile one in one hand or two,
-- a two-hander only in both. No category (older items, foreign data) means a
-- plain one-hander - exactly the pre-wield behaviour.
local WIELD_ORDER = {
    light = { "main", "off" },
    one_hand = { "main" },
    versatile = { "main", "two" },
    two_hand = { "two" },
}
function Items.WieldStates(category)
    return WIELD_ORDER[category] or WIELD_ORDER.one_hand
end

-- The wield state an equipped weapon entry is effectively in: its stored state
-- when the category allows it, else the category's first state. Stored wields
-- can go stale sideways (a library edit changed the category, a shared sheet
-- said so), so this never trusts the field alone. Returns nil when the entry
-- is not equipped.
function Items.EffectiveWield(entry, category)
    if type(entry) ~= "table" or not entry.equipped then return nil end
    local states = Items.WieldStates(category)
    for _, s in ipairs(states) do
        if entry.wield == s then return s end
    end
    return states[1]
end

-- Advances a weapon entry through stashed -> each wield state -> stashed.
-- `category` decides the cycle (see WieldStates). Returns the new state as a
-- string ("stashed", "main", "off", "two"), or nil when the index names no
-- entry. The wield field is cleared when stashed so a stored character never
-- carries a stale hand.
function Items.CycleWield(char, index, category)
    local entry = EntryAt(char, index)
    if not entry then return nil end
    local states = Items.WieldStates(category)
    if not entry.equipped then
        entry.equipped = true
        entry.wield = states[1]
        return entry.wield
    end
    local current = Items.EffectiveWield(entry, category)
    for i, s in ipairs(states) do
        if s == current and states[i + 1] then
            entry.wield = states[i + 1]
            return entry.wield
        end
    end
    entry.equipped = false
    entry.wield = nil
    return "stashed"
end

-- Sets a gear entry's counter, clamped into [0, MAX_COUNT]. Returns the stored
-- count, or nil when the index names no entry or the value is not numeric (in
-- which case the entry is left untouched - a half-typed edit box must not wipe
-- a count).
function Items.SetCount(char, index, value)
    local entry = EntryAt(char, index)
    if not entry then return nil end
    local count = Items.ClampCount(value)
    if not count then return nil end
    entry.count = count
    return count
end

-- Drops the inventory entry at `index`. Returns true when one was removed,
-- false when the index names none. Removal shifts every later entry down by
-- one, so an index taken from a rendered row is only valid until the next
-- mutation: callers re-render (never reuse an index) afterwards.
function Items.Remove(char, index)
    if not EntryAt(char, index) then return false end
    table.remove(char.inventory, index)
    return true
end
