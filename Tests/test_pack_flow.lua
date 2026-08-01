-- Feat/spell pack lifecycle: the real import pipeline (ImportExport.Import ->
-- Schema -> Packs), pairing/activation against the active system, the
-- library management seams, export round-trips, and the FEATS/SPELLS comm
-- receive path (validate -> cache -> adopt prompt, never a silent overwrite).
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
strtrim = function(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

-- Capture popups instead of showing them.
local shown
StaticPopup_Show = function(which, arg1, arg2, data)
    shown = { which = which, arg1 = arg1, data = data }
end

local ns = {}
T.load(ns, "Schema.lua")
T.load(ns, "JSON.lua")
T.load(ns, "TOML.lua")
do
    local core = T.load({}, "Core.lua")
    for k, v in pairs(core) do ns[k] = v end
end

-- Comm stub: registered handlers are invoked directly below.
local handlers = {}
local sent = {}
ns.Comm = {
    On = function(t, fn) handlers[t] = fn end,
    IsSelf = function() return false end,
    IsDM = function() return true end,
    Send = function(t, v) sent[#sent + 1] = { t = t, v = v }; return true end,
}

T.load(ns, "Modules/Systems.lua")
T.load(ns, "Modules/Packs.lua")
T.load(ns, "Modules/ImportExport.lua")
ParchmentCharDB, ParchmentSystemDB, ParchmentPackDB = {}, {}, {}
ns.Addon:OnInitialize()

assert(handlers.FEATS and handlers.SPELLS, "pack comm handlers not registered")

-- Mirrors ImportExport's NormalizeKeys for comparing decodes.
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

-- System first; no packs exist yet, so nothing activates.
local ok, msg = ns.ImportExport.Import(T.readfile("Tools/examples/sample.system.toml"))
assert(ok, tostring(msg))
assert(ns.GetFeatPack() == nil and ns.GetSpellPack() == nil)

-- Importing the sample packs stores AND activates them (for_system matches).
ok, msg = ns.ImportExport.Import(T.readfile("Tools/examples/sample.feats.toml"))
assert(ok and msg:find("now active", 1, true), tostring(msg))
assert(ns.GetFeatPack() and ns.GetFeatPack().pack_name == "Parchment Sample Feats")
ok, msg = ns.ImportExport.Import(T.readfile("Tools/examples/sample.spells.toml"))
assert(ok and msg:find("now active", 1, true), tostring(msg))
assert(ns.GetSpellPack() and ns.GetSpellPack().pack_name == "Parchment Sample Spells")

-- A pack claiming a DIFFERENT system is stored but not activated.
local foreign = {
    kind = "feats", pack_name = "Foreign Feats", for_system = "Somewhere Else",
    lines = { { id = "l", name = "L", attribute = "might", ranks = { { name = "R" } } } },
}
ok, msg = ns.ImportExport.Import(ns.JSON.encode(foreign))
assert(ok and msg:find("stored", 1, true), tostring(msg))
assert(ns.GetFeatPack().pack_name == "Parchment Sample Feats", "foreign pack must not displace the active one")
assert(ns.GetPackLibrary("feats")["Foreign Feats"], "foreign pack must still be cached")

-- A pack claiming NO system is universal: it activates anywhere.
local universal = {
    kind = "spells", pack_name = "Universal Spells",
    spells = { { id = "s", name = "S", school = "any", rank = 1 } },
}
ok, msg = ns.ImportExport.Import(ns.JSON.encode(universal))
assert(ok and msg:find("now active", 1, true), tostring(msg))
assert(ns.GetSpellPack().pack_name == "Universal Spells")
assert(ns.Packs.Activate("spells", "Parchment Sample Spells"))

-- An invalid pack is refused outright (nothing stored).
local bad = { kind = "feats", pack_name = "Bad", lines = { { id = "l", name = "L" } } }
ok, msg = ns.ImportExport.Import(ns.JSON.encode(bad))
assert(not ok and msg:find("attribute", 1, true), tostring(msg))
assert(ns.GetPackLibrary("feats")["Bad"] == nil, "an invalid pack must not be cached")

-- A pack whose cross-references fail against ITS OWN system is refused too.
local crossbad = {
    kind = "feats", pack_name = "Crossbad", for_system = "Parchment Sample",
    lines = { { id = "l", name = "L", attribute = "ghost", ranks = { { name = "R" } } } },
}
ok, msg = ns.ImportExport.Import(ns.JSON.encode(crossbad))
assert(not ok and msg:find("unknown attribute 'ghost'", 1, true), tostring(msg))

-- Character import validates against the active packs.
ok, msg = ns.ImportExport.Import(T.readfile("Tools/examples/sample.character.toml"))
assert(ok, tostring(msg))
local badChar = ns.JSON.decode(ns.ImportExport.ExportCharacter(nil, "json"))
badChar.feats = { keen_study = 99 }
ok, msg = ns.ImportExport.Import(ns.JSON.encode(badChar))
assert(not ok and msg:find("exceeds", 1, true), "over-ranked feat must be refused: " .. tostring(msg))

-- Export round-trips for both kinds and formats.
for kind, exporter in pairs({ feats = "ExportFeatPack", spells = "ExportSpellPack" }) do
    for _, format in ipairs({ "json", "toml" }) do
        local out = assert(ns.ImportExport[exporter](format))
        local decode = (format == "toml") and ns.TOML.decode or ns.JSON.decode
        T.assert_deepeq(ns.GetActivePack(kind), normalize(assert(decode(out))),
            kind .. " " .. format .. " export")
    end
end

-- Share sends the active pack under the kind's message type.
ns.Packs.Share("feats")
assert(sent[#sent].t == "FEATS" and sent[#sent].v.pack_name == "Parchment Sample Feats")

-- Switching to a system the packs do not claim deactivates them; switching
-- back re-activates by for_system match.
ns.Systems.SetActive({ system_name = "Blank", attributes = { { id = "x", name = "X" } } }, "test")
assert(ns.GetFeatPack() == nil, "feat pack must deactivate with its system")
assert(ns.GetSpellPack() == nil, "spell pack must deactivate with its system")
assert(ns.GetPackLibrary("feats")["Parchment Sample Feats"], "deactivation must not delete")
local entry = ns.Systems.GetLibrary()["Parchment Sample"]
ns.Systems.SetActive(entry.system, "test")
assert(ns.GetFeatPack() and ns.GetFeatPack().pack_name == "Parchment Sample Feats",
    "feat pack must re-activate with its system")
assert(ns.GetSpellPack() and ns.GetSpellPack().pack_name == "Parchment Sample Spells")

-- Delete: removing the active pack deactivates it; the pointer self-heals.
ns.Packs.Delete("feats", "Foreign Feats")
assert(ns.GetFeatPack().pack_name == "Parchment Sample Feats",
    "deleting an inactive pack must not touch the active one")
ns.Packs.Delete("feats", "Parchment Sample Feats")
assert(ns.GetFeatPack() == nil)
assert(not ns.Packs.Activate("feats", "Parchment Sample Feats"), "activating a deleted pack must fail")

-- Comm receive: a valid share is cached and prompts, never applied silently.
shown = nil
local sharedPack = normalize(assert(ns.TOML.decode(T.readfile("Tools/examples/sample.feats.toml"))))
handlers.FEATS(sharedPack, "Alice")
assert(shown and shown.which == "PARCHMENT_ADOPT_PACK", "a shared pack must prompt")
assert(ns.GetFeatPack() == nil, "a shared pack must not activate before acceptance")
assert(ns.GetPackLibrary("feats")["Parchment Sample Feats"], "a shared pack must be cached")
StaticPopupDialogs["PARCHMENT_ADOPT_PACK"].OnAccept(nil, shown.data)
assert(ns.GetFeatPack() and ns.GetFeatPack().pack_name == "Parchment Sample Feats",
    "accepting must activate the shared pack")

-- Comm receive: an invalid share is ignored entirely.
shown = nil
handlers.SPELLS({ pack_name = "Evil", spells = { { id = 5 } } }, "Mallory")
assert(shown == nil, "an invalid share must not prompt")
assert(ns.GetPackLibrary("spells")["Evil"] == nil, "an invalid share must not be cached")

-- Comm receive: remote '_'-metadata is stripped before storing.
handlers.FEATS({ _smuggled = true, kind = "feats", pack_name = "Meta",
    lines = { { id = "l", name = "L", attribute = "might", ranks = { { name = "R" } } } } }, "Alice")
local stored = ns.GetPackLibrary("feats")["Meta"]
assert(stored and stored.pack._smuggled == nil, "wire metadata must be stripped")

-- Leave no active packs behind: the manifest runs files in one process, and a
-- later file's Compute would silently fold this file's packs.
ParchmentPackDB = {}
