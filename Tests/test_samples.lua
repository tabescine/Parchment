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
T.load(ns, "Modules/Packs.lua")
T.load(ns, "Modules/ImportExport.lua")
T.load(ns, "Modules/Items.lua")
T.load(ns, "Modules/CharacterSheet.lua")
ParchmentCharDB, ParchmentSystemDB, ParchmentPackDB = {}, {}, {}
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

-- Import the system, both packs, then the character, through the real dialog
-- path (the packs first: the sheet folds owned pack-feat effects).
local ok, msg = ns.ImportExport.Import(T.readfile("Tools/examples/sample.system.toml"))
assert(ok, tostring(msg))
assert(ns.HasSystem() and ns.GetSystem().system_name == "Parchment Sample")
ok, msg = ns.ImportExport.Import(T.readfile("Tools/examples/sample.feats.toml"))
assert(ok, tostring(msg))
ok, msg = ns.ImportExport.Import(T.readfile("Tools/examples/sample.spells.toml"))
assert(ok, tostring(msg))
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
-- Lore: wits +1 mod + accomplished +3 + the Fieldnotes feat's +1 skill
-- effect (owned pack feat ranks fold effects) + Trail Sense's add_modifier
-- copy of the Wits modifier (+1) = 6.
assert(skills.lore.total == 6, "lore expected +6, got " .. skills.lore.total)
assert(skills.endurance.total == 0)                          -- might -1 + Hardened +1
local d = sheet.derived
assert(d.hp.max == 28 and d.hp.current == 24 and d.hp.temp == 2)  -- 26 +2 Hardened
assert(d.mana.max == 8 and d.hit_dice == "5d6")
assert(d.ac == 11 and d.initiative == 2 and d.movement == 12.5)
assert(d.actions == 3 and d.accomplishment == 3)
-- Wren casts via cast_attribute (Spirit 6, modifier 0): DC 10 + 0 + acc 3.
assert(d.save_dc == 13, "cast_attribute must make Wren a caster (DC 13)")
assert(d.cast_attribute == "spirit")
assert(d.spell and d.spell.attack == 3, "spell attack = spirit mod 0 + acc 3")
assert(d.init_attribute == "wits", "explicit in-list init pick must be honored")
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

-- Now import the sample item library the same way, and the very same character
-- resolves: system + items + character is the fully-wired demo.
ok, msg = ns.ImportExport.Import(T.readfile("Tools/examples/sample.items.toml"))
assert(ok, tostring(msg))
local lib = ns.GetItemLibrary()
assert(lib.itm_1 and lib.itm_2 and lib.itm_3, "the sample library must define itm_1..itm_3")
local libOk, libIssues = ns.Schema.ValidateItemLibrary(lib)
assert(libOk, "the sample library must validate: " .. tostring(libIssues[1]))

sheet = ns.CharacterSheet.Compute(char, ns.GetSystem(), lib)
local inv = sheet.inventory
assert(#inv.weapons == 1 and #inv.equipment == 1 and #inv.gear == 1,
    "each sample item must land in its own group")
local bow = inv.weapons[1]
assert(bow.source == "library" and bow.equipped and bow.weapon_name == "Bow")
assert(bow.attack_total == 5, "bow attack 4 + the item's +1, got " .. tostring(bow.attack_total))
assert(inv.equipment[1].equipped and inv.equipment[1].ac_bonus == 1)
assert(sheet.derived.ac == 12 and sheet.derived.ac_equipment.total == 1,
    "equipped equipment must add its AC on top of the 11 above")
assert(inv.gear[1].count == 12, "the character's own count wins over the item's default_count")

-- The sample packs validate against the sample system, and Wren's feat,
-- spell and cast-attribute picks all resolve against them.
local featPack = normalize(assert(ns.TOML.decode(T.readfile("Tools/examples/sample.feats.toml"))))
local spellPack = normalize(assert(ns.TOML.decode(T.readfile("Tools/examples/sample.spells.toml"))))
local pOk, pIssues = ns.Schema.ValidateFeatPack(featPack, ns.GetSystem())
assert(pOk, "sample feats pack must validate: " .. tostring((pIssues or {})[1]))
pOk, pIssues = ns.Schema.ValidateSpellPack(spellPack, ns.GetSystem())
assert(pOk, "sample spells pack must validate: " .. tostring((pIssues or {})[1]))
pOk, pIssues = ns.Schema.ValidateCharacter(char, ns.GetSystem(),
    { feats = featPack, spells = spellPack })
assert(pOk, "Wren must validate against the packs: " .. tostring((pIssues or {})[1]))
assert(featPack.for_system == ns.GetSystem().system_name, "feat pack pairing name")
assert(spellPack.for_system == ns.GetSystem().system_name, "spell pack pairing name")

-- The JSON twins must decode to exactly the TOML data (minus the _note).
local sysToml = normalize(assert(ns.TOML.decode(T.readfile("Tools/examples/sample.system.toml"))))
local sysJson = normalize(assert(ns.JSON.decode(T.readfile("Tools/examples/sample.system.json"))))
sysJson._note = nil
T.assert_deepeq(sysToml, sysJson, "system twins")
local charToml = normalize(assert(ns.TOML.decode(T.readfile("Tools/examples/sample.character.toml"))))
local charJson = normalize(assert(ns.JSON.decode(T.readfile("Tools/examples/sample.character.json"))))
charJson._note = nil
T.assert_deepeq(charToml, charJson, "character twins")
local itemsToml = normalize(assert(ns.TOML.decode(T.readfile("Tools/examples/sample.items.toml"))))
local itemsJson = normalize(assert(ns.JSON.decode(T.readfile("Tools/examples/sample.items.json"))))
itemsJson._note = nil
T.assert_deepeq(itemsToml, itemsJson, "item twins")
local featsJson = normalize(assert(ns.JSON.decode(T.readfile("Tools/examples/sample.feats.json"))))
featsJson._note = nil
T.assert_deepeq(featPack, featsJson, "feat pack twins")
local spellsJson = normalize(assert(ns.JSON.decode(T.readfile("Tools/examples/sample.spells.json"))))
spellsJson._note = nil
T.assert_deepeq(spellPack, spellsJson, "spell pack twins")

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
for _, format in ipairs({ "json", "toml" }) do
    local itemsOut = assert(ns.ImportExport.ExportItems(format))
    local decode = (format == "toml") and ns.TOML.decode or ns.JSON.decode
    T.assert_deepeq({ items = lib }, normalize(assert(decode(itemsOut))),
        "items " .. format .. " export")
end
