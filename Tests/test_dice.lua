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

-- With a token: it rides the line, and the local print is rewritten.
ns.Dice.Check("Bolt attack", 3, "[PMT:Bolt:1]")
assert(printed[2] == "RW<Me>Bolt attack: 7 (d20) + 3 = 10 [PMT:Bolt:1]", tostring(printed[2]))
assert(#sent == 0, "public rolls off must never reach chat")
