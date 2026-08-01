-- CharacterEditor.LevelUp/LevelDown: the level-scaled resources. HP moves by
-- the caller's rolled gain; mana moves by the system formula's per-level share
-- (mana_base + ceil(level x mana_per_level) + multiplier x cast modifier - only
-- the middle term depends on level). The stored max_mana MUST move on level
-- change: InitResources persists the creation-level base and Compute prefers a
-- stored max, so a static store means mana never scales (the Nele bug).
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallWowStubs()

local ns = {}
T.load(ns, "Schema.lua")
do
    local core = T.load({}, "Core.lua")
    for k, v in pairs(core) do ns[k] = v end
end
T.load(ns, "Modules/CharacterSheet.lua")
T.load(ns, "Modules/Picks.lua")
T.load(ns, "Modules/CharacterEditor.lua")
local CE = ns.CharacterEditor

-- An AIAS-shaped system: mana 3 + ceil(level/2) + cast modifier.
local system = {
    system_name = "T",
    attributes = { { id = "int", name = "Intellect" } },
    modifier_table = { -1, 0, 1, 2 },
    derived_stats = {
        mana_base = 3, mana_per_level = 0.5, mana_multiplier = 1,
        hit_die_attribute = "int",
    },
}
-- Core's helpers (GetSystem, GetModifier, DerivedConfig, ...) all read the
-- SavedVariables global; setting it makes them coherent without stubs.
ParchmentSystemDB = system
ns.GetItemLibrary = function() return {} end
ns.GetFeatPack = function() return nil end
ns.GetSpellPack = function() return nil end

local char = {
    name = "Manabearer", level = 1,
    attributes = { int = 4 },   -- modifier +2
    cast_attribute = "int",
}

-- Creation: level 1 stores base 3 + ceil(0.5) + 2 = 6.
CE.InitResources(char, system)
assert(char.max_mana == 6, "creation mana: expected 6, got " .. tostring(char.max_mana))
assert(char.current_mana == 6)

-- Level 2: ceil(1.0) is still 1, no gain. Level 3: ceil(1.5) = 2, +1 mana.
assert(CE.LevelUp(char, 4, system))
assert(char.max_mana == 6, "level 2 adds no mana share, got " .. tostring(char.max_mana))
local ok, notes = CE.LevelUp(char, 4, system)
assert(ok)
assert(char.max_mana == 7, "level 3 mana: expected 7, got " .. tostring(char.max_mana))
assert(char.current_mana == 7, "current mana rises with the max")
local found = false
for _, n in ipairs(notes) do if n == "+1 mana" then found = true end end
assert(found, "the level-up notes must announce the mana gain")

-- Ten more levels: at 13 the share is ceil(6.5) = 7, so max = 3 + 7 + 2 = 12.
for _ = 1, 10 do assert(CE.LevelUp(char, 1, system)) end
assert(char.level == 13)
assert(char.max_mana == 12, "level 13 mana: expected 12, got " .. tostring(char.max_mana))

-- Down is a true undo of up: back at 3, mana returns to 7; spent mana is
-- clamped to the shrunk max rather than refunded past it.
char.current_mana = 12
for _ = 1, 10 do assert(CE.LevelDown(char, system)) end
assert(char.level == 3)
assert(char.max_mana == 7, "level-down mana: expected 7, got " .. tostring(char.max_mana))
assert(char.current_mana <= char.max_mana, "current must not exceed the shrunk max")

-- A manual override still scales from wherever the user set it (the delta is
-- applied to the stored value, not recomputed from scratch).
char.max_mana = 20
assert(CE.LevelUp(char, 1, system))   -- level 4: share unchanged (ceil(2) = 2)
assert(char.max_mana == 20)
assert(CE.LevelUp(char, 1, system))   -- level 5: share 3, +1
assert(char.max_mana == 21, "override + delta: expected 21, got " .. tostring(char.max_mana))

-- A character imported WITHOUT stored resources runs on the live formula,
-- which scales by itself: level up/down must leave the nil store alone -
-- materializing 0 + delta would freeze the formula at a wrong value.
local imported = { name = "Storeless", level = 15,
    attributes = { int = 4 }, cast_attribute = "int" }
local before = ns.CharacterSheet.Compute(imported, system, {}).derived.mana.base
assert(before == 3 + 8 + 2, "level-15 formula mana: got " .. tostring(before))
assert(CE.LevelUp(imported, 5, system))       -- 16: share unchanged
assert(CE.LevelUp(imported, 5, system))       -- 17: share +1
assert(imported.max_mana == nil, "a nil mana store must stay nil across level up")
local after = ns.CharacterSheet.Compute(imported, system, {}).derived.mana.base
assert(after == before + 1, "formula mana must keep scaling: got " .. tostring(after))
assert(CE.LevelDown(imported, system))
assert(imported.max_mana == nil, "a nil mana store must stay nil across level down")
