-- Feat/spell pack lifecycle: the real import pipeline (ImportExport.Import ->
-- Schema -> Packs), pairing/activation against the active system, the
-- library management seams, export round-trips, and the FEATS/SPELLS comm
-- receive path (validate -> cache -> adopt prompt, never a silent overwrite).
-- The last section covers the wire-path bounds both libraries hold (size cap,
-- entry cap that refuses instead of evicting, sanitized notices, depth cap).
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
strtrim = function(s) return (s:gsub("^%s*(.-)%s*$", "%1")) end

-- Capture popups instead of showing them.
local shown
StaticPopup_Show = function(which, arg1, arg2, data)
    shown = { which = which, arg1 = arg1, arg2 = arg2, data = data }
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

-- Wire-path bounds. A share is stored under an attacker-chosen name, so both
-- libraries cap entry count and encoded size, everything they print or put in
-- a popup is sanitized, and an over-deep payload is flattened, not thrown.

-- Capture printed notices (Core's Print writes to the chat-frame stub).
local printed = {}
local realPrint = ns.Print
ns.Print = function(line) printed[#printed + 1] = line end

-- A minimal valid feats pack under a given name, plus any extra fields.
local function featsPack(name, extra)
    local p = { kind = "feats", pack_name = name,
        lines = { { id = "l", name = "L", attribute = "might", ranks = { { name = "R" } } } } }
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Names carrying chat escapes must never reach printed text or a popup raw:
-- "|H...|h" renders as a clickable forged item link, "|T...|t" as a texture.
-- The library still keys the entry by the exact name (data, not display).
shown, printed = nil, {}
local evil = "|Hitem:6948:0:0:0|h[Hearthstone]|h|TInterface\\Icons\\INV_Misc:16|t"
handlers.FEATS(featsPack(evil), "|Hplayer:Mallory|h[Mallory]|h")
assert(#printed > 0, "an accepted share must print a notice")
for _, line in ipairs(printed) do
    assert(not line:find("|", 1, true), "printed text must carry no escapes: " .. line)
end
assert(shown and shown.which == "PARCHMENT_ADOPT_PACK")
assert(not shown.arg1:find("|", 1, true), "popup text must carry no escapes: " .. shown.arg1)
assert(ns.GetPackLibrary("feats")[evil], "the exact name must still key the entry")

-- An oversized pack is refused before it touches SavedVariables, and a refused
-- store must not prompt for adoption either (the popup is the flood's payload).
shown, printed = nil, {}
handlers.FEATS(featsPack("Huge", { note = string.rep("x", 600 * 1024) }), "Mallory")
assert(ns.GetPackLibrary("feats")["Huge"] == nil, "an oversized pack must be refused")
assert(shown == nil, "a refused pack must not prompt")
assert(#printed == 1 and printed[1]:find("too large", 1, true), tostring(printed[1]))

-- A pathologically deep payload (AceSerializer accepts thousands of levels) is
-- flattened by StripMeta's depth cap rather than overflowing the stack out of
-- the AceComm callback - and the abusive depth never reaches the library.
local function deep(levels)
    local root = {}
    local node = root
    for _ = 1, levels do node.child = {}; node = node.child end
    return root
end
local function depthOf(t)
    local n = 0
    while type(t) == "table" and t.child do n, t = n + 1, t.child end
    return n
end
assert(pcall(ns.ImportExport.StripMeta, deep(5000)), "StripMeta must not overflow")
assert(depthOf(ns.ImportExport.StripMeta(deep(5000))) < 40, "StripMeta must cap depth")
printed = {}
assert(pcall(handlers.FEATS, featsPack("Deep", { nest = deep(5000) }), "Mallory"),
    "a deeply nested share must not error out of the comm callback")
local deepEntry = ns.GetPackLibrary("feats")["Deep"]
assert(deepEntry, "the pack is otherwise valid, so it is still stored")
assert(depthOf(deepEntry.pack.nest) < 40, "over-deep nesting must never persist")

-- The library caps its entry count. Filling past the cap refuses the newcomer
-- with a notice and evicts nothing: unlike a re-requestable cached sheet, these
-- entries are the player's own imported content.
local lib = ns.GetPackLibrary("feats")
local filled
for i = count(lib) + 1, 25 do
    filled = "Fill" .. i
    assert(ns.Packs.Store("feats", featsPack(filled), "test"), "storing below the cap must work")
end
local kept = next(lib)
printed = {}
assert(ns.Packs.Store("feats", featsPack("OneTooMany"), "test") == false,
    "storing past the cap must be refused")
assert(lib["OneTooMany"] == nil, "a refused pack must not be stored")
assert(#printed == 1 and printed[1]:find("full", 1, true), tostring(printed[1]))
assert(count(lib) == 25, "the library must cap at MAX_ENTRIES, got " .. count(lib))
assert(lib[kept], "nothing may be evicted to make room")

-- At the cap, updating a name already stored still goes through (latest wins).
assert(ns.Packs.Store("feats", featsPack(filled, { version = "2" }), "test"))
assert(lib[filled].pack.version == "2", "an update of a stored name must be allowed")

-- A share arriving at a full library is refused and never prompts.
shown, printed = nil, {}
handlers.FEATS(featsPack("Flood"), "Mallory")
assert(lib["Flood"] == nil and shown == nil, "a full library must refuse and not prompt")

-- The system library holds exactly the same line (Modules/Systems.lua).
assert(handlers.SYSTEM, "system comm handler not registered")
local function system(name, extra)
    local s = { system_name = name, attributes = { { id = "x", name = "X" } } }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
end
shown, printed = nil, {}
handlers.SYSTEM(system(evil), "Mallory")
for _, line in ipairs(printed) do
    assert(not line:find("|", 1, true), "printed text must carry no escapes: " .. line)
end
assert(shown and shown.which == "PARCHMENT_ADOPT_SYSTEM")
assert(not shown.arg2:find("|", 1, true), "the popup's system name must be sanitized")
assert(ns.Systems.GetLibrary()[evil], "the exact name must still key the entry")

shown, printed = nil, {}
handlers.SYSTEM(system("Huge", { note = string.rep("x", 600 * 1024) }), "Mallory")
assert(ns.Systems.GetLibrary()["Huge"] == nil, "an oversized system must be refused")
assert(shown == nil, "a refused system must not prompt")

local sysLib = ns.Systems.GetLibrary()
for i = count(sysLib) + 1, 25 do
    assert(ns.Systems.Store(system("Sys" .. i), "test"), "storing below the cap must work")
end
local keptSys = next(sysLib)
printed = {}
assert(ns.Systems.Store(system("OneTooMany"), "test") == false,
    "storing past the cap must be refused")
assert(sysLib["OneTooMany"] == nil and sysLib[keptSys], "nothing may be evicted to make room")
assert(#printed == 1 and printed[1]:find("full", 1, true), tostring(printed[1]))
assert(count(sysLib) == 25, "the system library must cap at MAX_ENTRIES, got " .. count(sysLib))

ns.Print = realPrint

-- Leave no active packs behind: the manifest runs files in one process, and a
-- later file's Compute would silently fold this file's packs.
ParchmentPackDB = {}
