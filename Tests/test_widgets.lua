-- ns.Widgets item builders and the editor's race-list logic - the
-- system-agnostic races rules (allowed/disallowed, no assumed names).
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
local ns = T.load({}, "Core.lua")
T.load(ns, "UI/Window.lua")
T.load(ns, "UI/Widgets.lua")
T.load(ns, "Modules/CharacterSheet.lua")
T.load(ns, "Modules/Picks.lua")
T.load(ns, "Modules/CharacterEditor.lua")
local W = ns.Widgets

local sys = {
    attributes = { { id = "a", name = "Alpha" }, { id = "b", name = "Beta" } },
    racial_traits = {
        { id = "h", name = "H", allowed_races = { "human" }, description = "dh" },
        { id = "open", name = "Open" },                               -- no lists: everyone
        { id = "noorc", name = "NoOrc", disallowed_races = { "orc" } },
        { id = "o", name = "O", allowed_races = { "orc" } },
    },
}

local function ids(items)
    local out = {}
    for _, item in ipairs(items) do out[#out + 1] = item.id end
    return table.concat(out, ",")
end

-- RacialItems: allowed limits, omitted opens to all, disallowed excludes.
assert(ids(W.RacialItems(sys, "human")) == "__none,h,open,noorc")
assert(ids(W.RacialItems(sys, "orc")) == "__none,open,o")
assert(ids(W.RacialItems(sys, "sylvan")) == "__none,open,noorc")
assert(ids(W.RacialItems(sys, "")) == "__none,open,noorc", "unset race gets only unrestricted traits")
assert(W.RacialItems(sys, "human")[2].tooltip == "dh", "description must become the tooltip")

-- CE.Races: explicit list wins (declaration order kept); otherwise the
-- sorted union of trait race lists; nothing is ever assumed.
local CE = ns.CharacterEditor
assert(table.concat(CE.Races(sys), ",") == "human,orc")
assert(table.concat(CE.Races({ races = { "zeta", "alpha" } }), ",") == "zeta,alpha")
assert(#CE.Races({}) == 0, "empty system must yield no races")

-- ListItems / AttrItems / TraitItems / SaveItems / TraitName.
assert(ids(W.ListItems(sys.attributes)) == "a,b")
assert(#W.AttrItems(sys) == 2)
assert(ids(W.AttrItems(sys, { b = true })) == "b")
local traits = W.TraitItems(sys.racial_traits)
assert(#traits == 4 and traits[1].tooltip == "dh")
local saves = W.SaveItems(sys, "a")
assert(saves[1].name == "Alpha  (primary)" and saves[1].tooltip ~= nil)
assert(saves[2].name == "Beta" and saves[2].tooltip == nil)
assert(W.TraitName(sys, "racial_traits", "h") == "H")
assert(W.TraitName(sys, "racial_traits", "nope") == "nope")
