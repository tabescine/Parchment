-- Dice.Check: local roll formatting, the optional chat-link token riding the
-- roll line, and the local copy being rewritten to a clickable link.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
T.InstallLifecycleStubs({})
UnitName = function() return "Me" end
IsInGroup = function() return false end

local printed, sent = {}, {}
SendChatMessage = function(msg, channel) sent[#sent + 1] = { msg = msg, channel = channel } end

local ns = {
    Print = function(m) printed[#printed + 1] = m end,
    Addon = { db = { profile = { publicRolls = false } } },
    -- Rewrite stub: proves the LOCAL copy goes through the chat-link
    -- rewriter with our own name (printed lines bypass the chat filters).
    ChatLinks = { Rewrite = function(line, name) return "RW<" .. name .. ">" .. line end },
}
T.load(ns, "Modules/Dice.lua")

-- Deterministic die.
-- luacheck: ignore 122 (test-only stub of the global RNG)
math.random = function() return 7 end

-- A plain check: no token, no rewrite, nothing sent (public rolls off).
ns.Dice.Check("Perception", -1)
assert(printed[1] == "Perception: 7 (d20) - 1 = 6", tostring(printed[1]))
assert(#sent == 0)

-- With a token: it replaces the label as the line's head, and the local
-- print is rewritten.
ns.Dice.Check("Bolt attack", 3, "[PMT:Bolt:1]")
assert(printed[2] == "RW<Me>[PMT:Bolt:1]: 7 (d20) + 3 = 10", tostring(printed[2]))
assert(#sent == 0, "public rolls off must never reach chat")

-- Free-notation rolls: Parse accepts XdY with an optional +/-Z and rejects
-- everything else (including notation past the caps); Roll sums count dice
-- plus the modifier and echoes canonical notation; RollToChat routes to the
-- group channel parenthesized, or a plain local print when solo.
local terms = ns.Dice.Parse("6d6")
assert(type(terms) == "table" and #terms == 1)
assert(terms[1].count == 6 and terms[1].sides == 6 and terms[1].sign == 1)
terms = ns.Dice.Parse("1d10+1d6-2")
assert(#terms == 3, "riders parse as separate terms")
assert(terms[2].sides == 6 and terms[3].flat == 2 and terms[3].sign == -1)
for _, bad in ipairs({ "", "6d", "d", "2x6", "6d6+", "0d6", "6d1",
    "101d6", "51d3+50d3", "6d1001", "1d6+1000", "1d6 7", "2+3",
    "1d6+1d6+1d6+1d6+1d6+1d6+1d6+1d6+1d6+1d6+1d6" }) do
    assert(ns.Dice.Parse(bad) == nil, "must reject '" .. bad .. "'")
end

-- math.random is still the deterministic 7 from above.
local total, canon = ns.Dice.Roll("3d10+2")
assert(total == 23 and canon == "3d10+2", "got " .. tostring(total) .. " " .. tostring(canon))
total, canon = ns.Dice.Roll("d20")
assert(total == 7 and canon == "1d20", "canonical form spells out the count")
total, canon = ns.Dice.Roll(" 2D8+3 ")
assert(total == 17 and canon == "2d8+3", "case and edge spaces are forgiven")
total, canon = ns.Dice.Roll("1d10+1d6")
assert(total == 14 and canon == "1d10+1d6", "damage riders sum per-term")
total, canon = ns.Dice.Roll("1d8+1d6-2")
assert(total == 12 and canon == "1d8+1d6-2", "got " .. tostring(total) .. " " .. tostring(canon))
total, canon = ns.Dice.Roll("6d6+2+3")
assert(total == 47 and canon == "6d6+2+3", "multiple flats sum")
assert(ns.Dice.Roll("nope") == nil)

-- Solo: plain local print, nothing sent.
printed, sent = {}, {}
ns.Print = function(msg) printed[#printed + 1] = msg end
assert(ns.Dice.RollToChat("2d6") == true)
assert(#sent == 0)
assert(printed[#printed] == "rolled 2d6: 14", "got '" .. tostring(printed[#printed]) .. "'")

-- Grouped: the parenthesized OOC line to the party channel.
IsInGroup = function() return true end
IsInRaid = function() return false end
assert(ns.Dice.RollToChat("2d6+1") == true)
assert(#sent == 1 and sent[1].msg == "(rolled 2d6+1: 15)" and sent[1].channel == "PARTY",
    "got '" .. tostring(sent[1] and sent[1].msg) .. "'")
IsInGroup = function() return false end

-- Bad notation reports usage and returns false (the popup keeps its box open).
printed = {}
assert(ns.Dice.RollToChat("garbage") == false)
assert(printed[1] and printed[1]:find("usage", 1, true), "usage line expected")

-- NotationCheck: a labelled free-notation roll (the sheet's weapon damage
-- click). Local print always; the parenthesized OOC copy only in a group; the
-- optional link token replaces the label and is rewritten locally.
printed, sent = {}, {}
ns.Print = function(msg) printed[#printed + 1] = msg end
assert(ns.Dice.NotationCheck("Cudgel damage", "1d8+3") == true)
local line = printed[#printed]
assert(line and line:find("^Cudgel damage: 1d8%+3 = %d+$"), "got '" .. tostring(line) .. "'")
assert(#sent == 0, "solo rolls stay local")

IsInGroup = function() return true end
assert(ns.Dice.NotationCheck("Cudgel damage", "1d8") == true)
assert(#sent == 1 and sent[1].channel == "PARTY"
    and sent[1].msg:find("^%(Cudgel damage: 1d8 = %d+%)$"),
    "got '" .. tostring(sent[1] and sent[1].msg) .. "'")
IsInGroup = function() return false end

assert(ns.Dice.NotationCheck("X", "garbage") == false, "bad notation must refuse")

printed = {}
assert(ns.Dice.NotationCheck("Cudgel damage", "1d8", "[PMT:Cudgel:1]") == true)
assert(printed[1]:find("^RW<Me>%[PMT:Cudgel:1%]: 1d8 = %d+$"),
    "the link token must head the line, rewritten: got '" .. tostring(printed[1]) .. "'")

print("test_dice: NotationCheck OK")

-- An extra term (the sheet's armed Aim): named separately in the breakdown
-- and added to the total; absent = the classic line, byte for byte.
printed, sent = {}, {}
ns.Print = function(msg) printed[#printed + 1] = msg end
ns.Dice.Check("Club attack", 5, nil, { label = "Aim", value = 2 })
assert(printed[1] == "Club attack: 7 (d20) + 5 + 2 (Aim) = 14", tostring(printed[1]))
ns.Dice.Check("Club attack", 5, nil, { label = "Aim", value = -1 })
assert(printed[2] == "Club attack: 7 (d20) + 5 - 1 (Aim) = 11", tostring(printed[2]))
ns.Dice.Check("Club attack", 5, nil, { label = "Aim", value = 0 })
assert(printed[3] == "Club attack: 7 (d20) + 5 = 12", "a zero extra must not clutter the line")
ns.Dice.Check("Club attack", 5)
assert(printed[4] == "Club attack: 7 (d20) + 5 = 12", "no extra = the classic line")

print("test_dice: extra term OK")
