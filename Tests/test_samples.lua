-- End-to-end: the shipped sample files travel the REAL import pipeline
-- (ImportExport.Import -> codecs -> Schema -> Systems.SetActive / character
-- data API) and the computed sheet matches the documented numbers. Also
-- locks the JSON twins to the TOML sources and round-trips the export path.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
strtrim = function(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

local ns = {}
T.load(ns, "Schema.lua")
T.load(ns, "JSON.lua")
T.load(ns, "TOML.lua")
do  -- Core replaces ns.Addon with the real AceAddon-stub object.
    local core = T.load({}, "Core.lua")
    for k, v in pairs(core) do ns[k] = v end
end
T.load(ns, "Modules/Systems.lua")
T.load(ns, "Modules/ImportExport.lua")
T.load(ns, "Modules/Items.lua")
T.load(ns, "Modules/CharacterSheet.lua")
ParchmentCharDB, ParchmentSystemDB = {}, {}
ns.Addon:OnInitialize()

-- Mirrors ImportExport's NormalizeKeys for comparing raw decodes.
local function normalize(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do
        local key = k
        if type(k) == "string" and k:match("^%-?%d+$") then key = tonumber(k) end
        out[key] = normalize(v)
    end
    return out
end

-- Import the system, then the character, through the real dialog path.
local ok, msg = ns.ImportExport.Import(T.readfile("Tools/examples/sample.system.toml"))
assert(ok, tostring(msg))
assert(ns.HasSystem() and ns.GetSystem().system_name == "Parchment Sample")
ok, msg = ns.ImportExport.Import(T.readfile("Tools/examples/sample.character.toml"))
assert(ok, tostring(msg))
local char, key = ns.GetActiveCharacter()
assert(key == "wren" and char.name == "Wren Ashdown", tostring(key))
assert(char._key == nil, "import must strip the _key meta field")

-- The sheet must match the numbers documented in the sample's comments.
local sheet = ns.CharacterSheet.Compute(char, ns.GetSystem(), ns.GetItemLibrary())
assert(sheet, "Compute returned nil")
local attrs, skills = {}, {}
for _, a in ipairs(sheet.attributes) do attrs[a.id] = a end
for _, s in ipairs(sheet.skills) do skills[s.id] = s end
assert(attrs.wits.final == 9 and attrs.wits.modifier == 1)   -- 8 + Human's +1
assert(attrs.might.final == 5 and attrs.might.modifier == -1)
assert(skills.lore.total == 8, "lore expected +8, got " .. skills.lore.total)
assert(skills.endurance.total == 0)                          -- might -1 + Hardened +1
local d = sheet.derived
assert(d.hp.max == 32 and d.hp.current == 24 and d.hp.temp == 2)  -- 26 +2 Hardened +4 Toughness
assert(d.mana.max == 8 and d.hit_dice == "5d6")
assert(d.ac == 11 and d.initiative == 2 and d.movement == 12.5)
assert(d.actions == 3 and d.accomplishment == 3)
assert(d.save_dc == nil, "Wren is no caster - no save DC")
assert(d.init_attribute == "wits", "explicit in-list init pick must be honored")
local sphere = {}
for _, p in ipairs(sheet.sphere_perks) do sphere[p.name] = p end
assert(sphere.Toughness.rank == 2)
assert(sphere.Scholar.choices[1] == "Lore")
assert(#sheet.weapons == 1 and sheet.weapons[1].attack_total == 4)  -- Bow: wits 1 + acc 3

-- The sample's inventory survives the import as references. Nothing seeds the
-- item library, so all three resolve to the missing sentinel and land in the
-- catch-all gear group - the documented "importing this without the items costs
-- nothing but three dim rows" behaviour, and proof no dangling id can throw.
assert(#char.inventory == 3 and char.inventory[1].item_id == "itm_1")
assert(char.inventory[1].equipped == true and char.inventory[3].count == 12)
assert(sheet.inventory and #sheet.inventory.gear == 3, "dangling references must still render")
for _, row in ipairs(sheet.inventory.gear) do
    assert(row.missing and row.source == "missing", "unknown item must resolve as missing")
end
assert(sheet.derived.ac_equipment == nil, "nothing resolves, so nothing may reach AC")

-- The JSON twins must decode to exactly the TOML data (minus the _note).
local sysToml = normalize(assert(ns.TOML.decode(T.readfile("Tools/examples/sample.system.toml"))))
local sysJson = normalize(assert(ns.JSON.decode(T.readfile("Tools/examples/sample.system.json"))))
sysJson._note = nil
T.assert_deepeq(sysToml, sysJson, "system twins")
local charToml = normalize(assert(ns.TOML.decode(T.readfile("Tools/examples/sample.character.toml"))))
local charJson = normalize(assert(ns.JSON.decode(T.readfile("Tools/examples/sample.character.json"))))
charJson._note = nil
T.assert_deepeq(charToml, charJson, "character twins")

-- Export round-trips: what export produces, import's parsers reproduce.
local sysOut = ns.ImportExport.ExportSystem("toml")
T.assert_deepeq(ns.GetSystem(), normalize(assert(ns.TOML.decode(sysOut))), "system toml export")
sysOut = ns.ImportExport.ExportSystem("json")
T.assert_deepeq(ns.GetSystem(), normalize(assert(ns.JSON.decode(sysOut))), "system json export")
local charOut = assert(ns.ImportExport.ExportCharacter(nil, "json"))
local charBack = normalize(assert(ns.JSON.decode(charOut)))
assert(charBack._key == "wren", "export must tag the roster key")
charBack._key = nil
T.assert_deepeq(char, charBack, "character json export")
