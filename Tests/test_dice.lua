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
assert(select("#", ns.Dice.Parse("6d6")) == 3)
local c, s, m = ns.Dice.Parse("6d6")
assert(c == 6 and s == 6 and m == 0)
c, s, m = ns.Dice.Parse("d20")
assert(c == 1 and s == 20 and m == 0, "bare dY defaults to one die")
c, s, m = ns.Dice.Parse(" 2D8+3 ")
assert(c == 2 and s == 8 and m == 3, "case and spaces are forgiven")
c, s, m = ns.Dice.Parse("4d6-1")
assert(c == 4 and s == 6 and m == -1)
for _, bad in ipairs({ "", "6d", "d", "2x6", "6d6+", "6d6+2+3", "0d6", "6d1",
    "101d6", "6d1001", "1d6+1000", "1d6 7" }) do
    assert(ns.Dice.Parse(bad) == nil, "must reject '" .. bad .. "'")
end

-- math.random is still the deterministic 7 from above.
local total, canon = ns.Dice.Roll("3d10+2")
assert(total == 23 and canon == "3d10+2", "got " .. tostring(total) .. " " .. tostring(canon))
total, canon = ns.Dice.Roll("d20")
assert(total == 7 and canon == "1d20", "canonical form spells out the count")
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
