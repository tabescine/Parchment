-- Schema.lua: feat pack and spell pack validation, plus the character-side
-- feats/spells/cast_attribute checks against active packs.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
local ns = T.load({}, "Schema.lua")
local Schema = ns.Schema

local function findIssue(issues, pattern)
    for _, issue in ipairs(issues or {}) do
        if issue:find(pattern, 1, true) then return issue end
    end
end

-- A minimal system for cross-reference checks.
local function System()
    return {
        system_name = "T",
        attributes = { { id = "pow", name = "Power" }, { id = "wit", name = "Wits" } },
    }
end

-- A minimal valid feats pack.
local function FeatPack()
    return {
        kind = "feats",
        pack_name = "Test Feats",
        for_system = "T",
        version = "1.0",
        rank_attribute_req = { 6, 7, 8 },
        lines = {
            {
                id = "grip", name = "Grip", attribute = "pow",
                ranks = {
                    { name = "Hold", type = "active", cost = { ap = 1 }, range = "melee" },
                    { name = "Clinch", type = "passive", save = "pow" },
                    { name = "Throw", cost = { ap = 2, mana = 1 }, effects = { { type = "ac", value = 1 } } },
                },
            },
            { id = "study", name = "Study", attribute = "wit", ranks = { { name = "Read" } } },
        },
    }
end

-- Feat pack: happy path, with and without a system.
assert(Schema.ValidateFeatPack(FeatPack()))
assert(Schema.ValidateFeatPack(FeatPack(), System()))

-- Not-a-table, wrong kind, missing required fields.
local ok, issues = Schema.ValidateFeatPack("nope")
assert(not ok and issues[1])
local pack = FeatPack()
pack.kind = "spells"
ok, issues = Schema.ValidateFeatPack(pack)
assert(not ok and findIssue(issues, "'kind'"), "wrong kind not reported")
ok, issues = Schema.ValidateFeatPack({ lines = {} })
assert(not ok and findIssue(issues, "pack_name"), "missing pack_name not reported")

-- Duplicate line ids, unknown attributes (only with a system), empty ranks.
pack = FeatPack()
pack.lines[2].id = "grip"
ok, issues = Schema.ValidateFeatPack(pack)
assert(not ok and findIssue(issues, "duplicate id 'grip'"))
pack = FeatPack()
pack.lines[1].attribute = "ghost"
assert(Schema.ValidateFeatPack(pack), "attributes must not resolve without a system")
ok, issues = Schema.ValidateFeatPack(pack, System())
assert(not ok and findIssue(issues, "unknown attribute 'ghost'"))
pack = FeatPack()
pack.lines[1].ranks[2].save = "ghost"
ok, issues = Schema.ValidateFeatPack(pack, System())
assert(not ok and findIssue(issues, "unknown save attribute 'ghost'"))
pack = FeatPack()
pack.lines[1].ranks = {}
ok, issues = Schema.ValidateFeatPack(pack)
assert(not ok and findIssue(issues, "has no ranks"))

-- Rank shape: missing name, bad cost, negative cost, bad effects.
pack = FeatPack()
pack.lines[1].ranks[1] = { type = "active" }
ok, issues = Schema.ValidateFeatPack(pack)
assert(not ok and findIssue(issues, "'name'"))
pack = FeatPack()
pack.lines[1].ranks[1].cost = "1 AP"
ok, issues = Schema.ValidateFeatPack(pack)
assert(not ok and findIssue(issues, "'cost' should be a table"))
pack = FeatPack()
pack.lines[1].ranks[1].cost = { ap = -1 }
ok, issues = Schema.ValidateFeatPack(pack)
assert(not ok and findIssue(issues, "must not be negative"))
pack = FeatPack()
pack.lines[1].ranks[3].effects = { "ac" }
ok, issues = Schema.ValidateFeatPack(pack)
assert(not ok and findIssue(issues, "effects[1]"))

-- rank_attribute_req must be a list of numbers.
pack = FeatPack()
pack.rank_attribute_req = { 6, "seven" }
ok, issues = Schema.ValidateFeatPack(pack)
assert(not ok and findIssue(issues, "rank_attribute_req[2]"))

-- A minimal valid spells pack.
local function SpellPack()
    return {
        kind = "spells",
        pack_name = "Test Spells",
        for_system = "T",
        rank_cast_req = { 8, 9 },
        cast_attributes = { "wit" },
        schools = {
            { id = "ember", name = "Ember", opposed = "frost" },
            { id = "frost", name = "Frost", opposed = "ember" },
            { id = "hearth", name = "Hearth" },
        },
        spells = {
            { id = "bolt", name = "Bolt", school = "ember", rank = 1, type = "attack",
                cost = { mana = 1 }, range = "20m", damage = "1d8 fire" },
            { id = "veil", name = "Veil", school = "frost", rank = 1, type = "reaction",
                cost = { mana = 2 }, range = "self", concentration = false },
            { id = "mend", name = "Mend", school = "hearth", rank = 2, save = "pow",
                concentration = true },
        },
    }
end

-- Spell pack: happy path, with and without a system.
assert(Schema.ValidateSpellPack(SpellPack()))
assert(Schema.ValidateSpellPack(SpellPack(), System()))

-- Wrong kind and missing required spell fields.
pack = SpellPack()
pack.kind = "feats"
ok, issues = Schema.ValidateSpellPack(pack)
assert(not ok and findIssue(issues, "'kind'"))
pack = SpellPack()
pack.spells[1].school = nil
ok, issues = Schema.ValidateSpellPack(pack)
assert(not ok and findIssue(issues, "'school'"))
pack = SpellPack()
pack.spells[1].rank = 0
ok, issues = Schema.ValidateSpellPack(pack)
assert(not ok and findIssue(issues, "rank must be at least 1"))

-- Duplicate ids, unknown school, unresolvable/asymmetric/self opposition.
pack = SpellPack()
pack.spells[2].id = "bolt"
ok, issues = Schema.ValidateSpellPack(pack)
assert(not ok and findIssue(issues, "duplicate id 'bolt'"))
pack = SpellPack()
pack.spells[1].school = "void"
ok, issues = Schema.ValidateSpellPack(pack)
assert(not ok and findIssue(issues, "unknown school 'void'"))
pack = SpellPack()
pack.schools[1].opposed = "ghost"
ok, issues = Schema.ValidateSpellPack(pack)
assert(not ok and findIssue(issues, "opposed school 'ghost' not found"))
pack = SpellPack()
pack.schools[2].opposed = nil
ok, issues = Schema.ValidateSpellPack(pack)
assert(not ok and findIssue(issues, "does not oppose it back"))
pack = SpellPack()
pack.schools[3].opposed = "hearth"
ok, issues = Schema.ValidateSpellPack(pack)
assert(not ok and findIssue(issues, "opposes itself"))

-- Cast attributes resolve only against a system.
pack = SpellPack()
pack.cast_attributes = { "ghost" }
assert(Schema.ValidateSpellPack(pack))
ok, issues = Schema.ValidateSpellPack(pack, System())
assert(not ok and findIssue(issues, "unknown attribute 'ghost' in cast_attributes"))

-- Character-side checks. A minimal character; packs passed as the third arg.
local function Char()
    return {
        name = "N", level = 3, attributes = { pow = 6, wit = 8 },
        cast_attribute = "wit",
        feats = { grip = 2 },
        spells = { "bolt", "mend" },
    }
end
local packs = { feats = FeatPack(), spells = SpellPack() }
assert(Schema.ValidateCharacter(Char(), System(), packs))
-- Shape-only when no packs/system are supplied.
assert(Schema.ValidateCharacter(Char()))

-- Feats: bad shapes, unknown line, rank beyond the ladder.
local char = Char()
char.feats = "grip"
ok, issues = Schema.ValidateCharacter(char, nil, packs)
assert(not ok and findIssue(issues, "'feats' should be a table"))
char = Char()
char.feats = { grip = 0 }
ok, issues = Schema.ValidateCharacter(char, nil, packs)
assert(not ok and findIssue(issues, "at least 1"))
char = Char()
char.feats = { ghost = 1 }
ok, issues = Schema.ValidateCharacter(char, nil, packs)
assert(not ok and findIssue(issues, "unknown feat line"))
char = Char()
char.feats = { grip = 4 }
ok, issues = Schema.ValidateCharacter(char, nil, packs)
assert(not ok and findIssue(issues, "exceeds the line's 3 rank(s)"))
-- Without the pack, any string key with a sane rank passes (shape only).
char = Char()
char.feats = { ghost = 1 }
assert(Schema.ValidateCharacter(char))

-- Spells: unknown ids, opposed-school violations (reported once per pair).
char = Char()
char.spells = { "ghost" }
ok, issues = Schema.ValidateCharacter(char, nil, packs)
assert(not ok and findIssue(issues, "unknown spell 'ghost'"))
char = Char()
char.spells = { "bolt", "veil" }
ok, issues = Schema.ValidateCharacter(char, nil, packs)
assert(not ok and findIssue(issues, "opposed schools 'ember' and 'frost'"))
local count = 0
for _, issue in ipairs(issues) do
    if issue:find("opposed schools", 1, true) then count = count + 1 end
end
assert(count == 1, "opposed pair must be reported once, got " .. count)

-- Cast attribute: outside the pack's candidates, and unknown in the system.
char = Char()
char.cast_attribute = "pow"
ok, issues = Schema.ValidateCharacter(char, nil, packs)
assert(not ok and findIssue(issues, "not one of the spell pack's cast_attributes"))
char = Char()
char.cast_attribute = "ghost"
ok, issues = Schema.ValidateCharacter(char, System())
assert(not ok and findIssue(issues, "unknown cast_attribute 'ghost'"))

-- Click-to-roll checks ({ attribute } or { skill }) on feat ranks and spells:
-- shape-only without a system, resolved against it when given.
local function CheckSystem()
    local s = System()
    s.skills = { { id = "sneak", name = "Sneak", attribute = "wit" } }
    return s
end
pack = FeatPack()
pack.lines[1].ranks[1].check = { attribute = "pow" }
pack.lines[1].ranks[2].check = { skill = "sneak" }
assert(Schema.ValidateFeatPack(pack), "valid checks must pass without a system")
assert(Schema.ValidateFeatPack(pack, CheckSystem()), "valid checks must pass with a system")
pack.lines[1].ranks[1].check = { attribute = "ghost" }
assert(Schema.ValidateFeatPack(pack), "check attributes must not resolve without a system")
ok, issues = Schema.ValidateFeatPack(pack, CheckSystem())
assert(not ok and findIssue(issues, "unknown check attribute 'ghost'"))
pack = FeatPack()
pack.lines[1].ranks[1].check = { skill = "ghost" }
ok, issues = Schema.ValidateFeatPack(pack, CheckSystem())
assert(not ok and findIssue(issues, "unknown check skill 'ghost'"))
pack = FeatPack()
pack.lines[1].ranks[1].check = "pow"
ok, issues = Schema.ValidateFeatPack(pack)
assert(not ok and findIssue(issues, "'check' should be a table"))
pack = FeatPack()
pack.lines[1].ranks[1].check = { attribute = "pow", skill = "sneak" }
ok, issues = Schema.ValidateFeatPack(pack)
assert(not ok and findIssue(issues, "exactly one of 'attribute' or 'skill'"))
pack = FeatPack()
pack.lines[1].ranks[1].check = {}
ok, issues = Schema.ValidateFeatPack(pack)
assert(not ok and findIssue(issues, "exactly one of 'attribute' or 'skill'"))

