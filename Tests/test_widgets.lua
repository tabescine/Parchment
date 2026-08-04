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

-- EffectSummary: one display line per effect record, targets resolved against
-- the loaded system (raw ids when it does not define them), signed values,
-- per_level and add_modifier spelled out, unknown types marked inert.
ParchmentSystemDB = {
    system_name = "W",
    attributes = { { id = "a", name = "Alpha" } },
    skills = { { id = "s1", name = "Skill One", attribute = "a" } },
    spell_schools = { { id = "ev", name = "Evocation" } },
}
assert(W.EffectSummary({ type = "save", id = "a", value = 1 }) == "Saving throw: Alpha  +1")
assert(W.EffectSummary({ type = "skill", skill = "s1", value = -2 }) == "Skill: Skill One  -2")
assert(W.EffectSummary({ type = "skill", skill = "ghost", value = 1 }) == "Skill: ghost  +1",
    "an unresolved target shows its raw id")
assert(W.EffectSummary({ type = "ac", value = 2 }) == "Armor Class  +2")
assert(W.EffectSummary({ type = "max_hp", value = 1, per_level = true })
    == "Maximum HP  +1 per level")
assert(W.EffectSummary({ type = "skill", skill = "s1", add_modifier = "a" })
    == "Skill: Skill One  +0  and Alpha modifier")
assert(W.EffectSummary({ type = "spell_attack", school = "ev", value = 1 })
    == "Spell attack: Evocation  +1")
assert(W.EffectSummary({ type = "spell_attack", value = 1 }) == "Spell attack  +1",
    "no school means every school - no target shown")
assert(W.EffectSummary({ type = "accomplish_skill", skill = "s1" })
    == "Accomplished skill: Skill One", "accomplishment is on/off, no value shown")
assert(W.EffectSummary({ type = "wild_notion", value = 3 }) == "wild_notion (not applied)")
assert(W.EffectSummary(5) == "?" and W.EffectSummary(nil) == "?")

-- An unknown type is echoed back to show what an import carried, but it is wire
-- text: a "|H...|h" in it would render a forged link (or "|T...|t" a texture) in
-- the tooltip that shows this line, so it is stripped and capped first.
local forged = W.EffectSummary({ type = "|Hitem:6948:0|h[Hearthstone]|h", value = 1 })
assert(not forged:find("|", 1, true), "no raw escape code may survive into a summary")
assert(forged:find("Hearthstone", 1, true), "the text itself should still be shown")
assert(#W.EffectSummary({ type = string.rep("x", 5000), value = 1 }) < 200,
    "an unbounded type must be capped before it reaches a tooltip")
ParchmentSystemDB = nil
