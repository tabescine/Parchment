-- Parchment - Dice
--
-- The shared d20 roller behind initiative and sheet checks. With public rolls
-- off, rolls resolve instantly from the local RNG. With them on
-- (db.profile.publicRolls), the in-game dice roller (RandomRoll) fires so the
-- whole party sees the raw die, and the result is read back off
-- CHAT_MSG_SYSTEM: requests queue FIFO and match results in order, filtered
-- to our own 1-20 rolls, with a 3s local fallback for throttled/dropped
-- roller calls - a fallback roll is flagged to the caller and tagged in chat,
-- since nobody saw it happen. Natural 20s and 1s are marked on the result
-- line. Extracted from InitiativeTracker so the character sheet's
-- click-to-roll checks share one implementation. Free-notation rolls
-- ("6d6", "2d8+3") are local-only and post as plain OOC lines.
--
-- Reads from: ns.Addon.db.profile.publicRolls, ns.Print.
-- Exposes on ns.Dice: Request, Check, Parse, Roll, RollToChat.

local ADDON, ns = ...

ns.Dice = ns.Dice or {}
local Dice = ns.Dice

-- Seed the RNG once so local d20 rolls are not identical every session.
if math.randomseed then
    local seed = (time and time() or 0) + math.floor((GetTime and GetTime() or 0) * 1000)
    math.randomseed(seed)
    math.random()
end

local rollQueue = {}

-- Turns a format string like "%s rolls %d (%d-%d)" into a capture pattern.
-- Some locales use positional specifiers (%1$s, %2$d); these are reduced to
-- plain %s/%d first so the conversion below matches them too.
local function ToPattern(fmt)
    fmt = fmt:gsub("%%(%d+)%$", "%%")
    local p = fmt:gsub("[%-%.%(%)%[%]%+%*%?%^%$%%]", "%%%0")
    p = p:gsub("%%%%s", "(.+)")
    p = p:gsub("%%%%d", "(%%d+)")
    return p
end
local ROLL_PATTERN = ToPattern(RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)")

-- True when public rolling is enabled and the in-game roller is available.
local function PublicEnabled()
    return ns.Addon and ns.Addon.db and ns.Addon.db.profile.publicRolls
        and type(RandomRoll) == "function"
end

-- Requests a d20 roll, calling onComplete(total, raw, fellBack) when it
-- resolves. With public rolls off it resolves immediately and locally; with
-- them on it fires a RandomRoll and resolves when the system message arrives
-- (3s fallback). `fellBack` is true only for that fallback roll - the group
-- never saw a system line for it, so callers must not pass it off as public.
function Dice.Request(modifier, onComplete)
    modifier = modifier or 0
    if not PublicEnabled() then
        local raw = math.random(1, 20)
        onComplete(raw + modifier, raw)
        return
    end
    local req = { modifier = modifier, onComplete = onComplete }
    rollQueue[#rollQueue + 1] = req
    if C_Timer and C_Timer.NewTimer then
        req.timer = C_Timer.NewTimer(3, function()
            for i, r in ipairs(rollQueue) do
                if r == req then
                    table.remove(rollQueue, i)
                    local raw = math.random(1, 20)
                    req.onComplete(raw + req.modifier, raw, true)
                    return
                end
            end
        end)
    end
    RandomRoll(1, 20)
end

-- Listens for our own 1-20 system rolls and resolves the oldest pending request.
local listener = CreateFrame and CreateFrame("Frame")
if listener then
    listener:RegisterEvent("CHAT_MSG_SYSTEM")
    listener:SetScript("OnEvent", function(_, _, message)
        if #rollQueue == 0 then return end
        local who, raw, low, high = message:match(ROLL_PATTERN)
        if not who then return end
        raw, low, high = tonumber(raw), tonumber(low), tonumber(high)
        if low ~= 1 or high ~= 20 then return end
        local me = UnitName and UnitName("player")
        if me and who ~= me then return end
        local req = table.remove(rollQueue, 1)
        if req.timer then req.timer:Cancel() end
        req.onComplete(raw + (req.modifier or 0), raw)
    end)
end

-- Rolls a named d20 check (e.g. "Perception", +5) and announces the result:
-- always printed locally; with public rolls on and a group, the breakdown is
-- also sent to party/raid chat, where the preceding RandomRoll system line
-- lets everyone verify the raw die. The chat copy is parenthesized, the
-- usual convention for out-of-character lines in an RP channel.
--
-- `linkToken` (optional) is a chat-link token ("[PMT:Name:N]") referencing
-- what was rolled - it REPLACES the label as the line's head ("[The
-- Lancet]: 14 (d20) + 9 = 23"), so the group can click through to the
-- ability/spell/item behind the roll. The local print is rewritten through
-- ns.ChatLinks so our own copy is clickable too (printed lines bypass the
-- chat filters that rewrite it for everyone else).
function Dice.Check(label, modifier, linkToken)
    modifier = modifier or 0
    Dice.Request(modifier, function(total, raw, fellBack)
        local line = string.format("%s: %d (d20) %s %d = %d", linkToken or label, raw,
            modifier >= 0 and "+" or "-", math.abs(modifier), total)
        local localLine = line
        if linkToken and ns.ChatLinks then
            localLine = ns.ChatLinks.Rewrite(line, (UnitName and UnitName("player")) or "?")
        end

        -- Natural 20/1 marker. SendChatMessage rejects colour escapes, so the
        -- chat copy gets a plain-text suffix instead of the coloured one.
        if raw == 20 then
            localLine = localLine .. "  |cff8cd98cNatural 20!|r"
            line = line .. " - Natural 20!"
        elseif raw == 1 then
            localLine = localLine .. "  |cffe67373Natural 1|r"
            line = line .. " - Natural 1"
        end

        -- The fallback roll was never witnessed: the group saw no system line
        -- for it, so the breakdown must not read as one.
        if fellBack then line = line .. " (local roll)" end

        ns.Print(localLine)
        if fellBack then
            ns.Print("the in-game dice roller did not answer in time - rolled locally instead.")
        end
        if PublicEnabled() and IsInGroup() then
            SendChatMessage("(" .. line .. ")", IsInRaid() and "RAID" or "PARTY")
        end
    end)
end

-- Free-notation rolls ("/pmt roll 6d6", the sheet's Roll dice button). These
-- are LOCAL rolls: RandomRoll is d20-shaped, so arbitrary dice have no
-- witnessed system path - the result posts as a plain OOC line the table
-- takes on trust, like any hand-typed number.

-- Caps on parsed notation: a typo must not hang the client rolling.
local MAX_DICE, MAX_SIDES, MAX_MOD = 100, 1000, 999

-- Parses "XdY" with an optional "+Z"/"-Z" ("6d6", "d20", "2d8+3", "4d6-1").
-- Returns count, sides, modifier - or nil for anything else (including
-- notation past the caps).
function Dice.Parse(notation)
    -- Trim the ends only: collapsing interior whitespace would quietly turn
    -- "1d6 7" into 1d67 - dice the user never asked for.
    local s = tostring(notation or ""):lower():match("^%s*(.-)%s*$")
    local count, sides, rest = s:match("^(%d*)d(%d+)(.-)$")
    if not sides then return nil end
    local mod = 0
    if rest ~= "" then
        mod = tonumber(rest:match("^([%+%-]%d+)$"))
        if not mod then return nil end
    end
    count = (count == "") and 1 or tonumber(count)
    sides = tonumber(sides)
    if count < 1 or count > MAX_DICE then return nil end
    if sides < 2 or sides > MAX_SIDES then return nil end
    if mod < -MAX_MOD or mod > MAX_MOD then return nil end
    return count, sides, mod
end

-- Rolls parsed notation. Returns total and the canonical notation ("2d8+3"),
-- or nil when the notation does not parse.
function Dice.Roll(notation)
    local count, sides, mod = Dice.Parse(notation)
    if not count then return nil end
    local total = mod
    for _ = 1, count do total = total + math.random(1, sides) end
    local canon = count .. "d" .. sides
        .. (mod > 0 and ("+" .. mod) or (mod < 0 and tostring(mod)) or "")
    return total, canon
end

-- Rolls and announces: "(rolled 6d6: 23)" to the group channel, the same
-- line as a plain print when solo. Returns false (with a usage note) when
-- the notation does not parse, so callers can keep an input box open.
function Dice.RollToChat(notation)
    local total, canon = Dice.Roll(notation)
    if not total then
        ns.Print("usage: roll XdY with an optional +Z/-Z - e.g. 6d6 or 2d8+3.")
        return false
    end
    local line = "rolled " .. canon .. ": " .. total
    if IsInGroup and IsInGroup() then
        SendChatMessage("(" .. line .. ")", (IsInRaid and IsInRaid()) and "RAID" or "PARTY")
    else
        ns.Print(line)
    end
    return true
end
