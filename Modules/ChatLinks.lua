-- Parchment - Chat Links (logic)
--
-- TRP3-style clickable chat links for feats, spells, homebrew and items. The
-- WIRE carries plain text - "[PMT:Name:1]" - so vanilla chat rules are never
-- violated and clients without Parchment just see that token. Each Parchment
-- client rewrites the token at DISPLAY time (a chat-message filter) into a
-- clickable |Haddon:parchment:...|h link. Clicking asks the original sender
-- for the link's content over comm (LINKQ -> LINKA whispers) and shows it in
-- the link window (UI/ChatLinkUI.lua) - the content itself is never in the
-- chat message, so a link is as big as its name regardless of its text.
--
-- Sent links live in a session registry (never persisted): a link outlives
-- neither the session nor a /reload, matching TRP3's behaviour - askers get
-- an "expired" answer then.
--
-- Received LINKA payloads are attacker-controlled: they are shape-checked,
-- size-capped and stripped of escape codes here before any UI sees them, and
-- an answer is only honoured while ITS question is the pending one (an
-- unsolicited LINKA can never pop a window).
--
-- The link mechanism (plain token + display-time rewrite + SetItemRef +
-- on-demand comm fetch) is modeled on Total RP 3's chat links
-- (https://github.com/Total-RP/Total-RP-3, Apache-2.0); this is an
-- independent implementation, no code is copied.
--
-- PostLink INSERTS the token into the chat input rather than sending
-- anywhere itself: the user finishes the message and picks the channel,
-- exactly like linking a regular item.
--
-- Reads from: ns.Comm (On/Whisper), ns.Print, ns.FormatCost, ns.AttrName,
--   ns.Spells (school names), ns.ChatLinkUI (render, guarded - loads later).
-- Exposes on ns.ChatLinks: Store, Get, MakeToken, Rewrite, ParseHref,
--   PostLink, Request, SanitizeAnswer, the payload builders (FeatRank,
--   Spell, Homebrew, Item) and the LINK_TYPE/FIND_PATTERN constants.

local ADDON, ns = ...

ns.ChatLinks = ns.ChatLinks or {}
local CL = ns.ChatLinks

-- The href type our display-time links carry. "addon:" links are client-legal
-- in rendered text (never sent), and SetItemRef fires for them on click.
CL.LINK_TYPE = "addon:parchment"
-- The plain-text token as it travels in a chat message.
CL.FIND_PATTERN = "%[PMT:([^%]]+)%]"

local LINK_COLOR = "|cffc8a868"

-- Caps on a received answer (attacker-controlled).
local MAX_TITLE = 120
local MAX_LINES = 40
local MAX_LINE = 600

-- Session registry of links WE sent: identifier -> { title, lines }.
local sent = {}

-- Strips characters that would break the token or smuggle escape codes into
-- rendered text: pipes, brackets and colons (the token's own delimiters).
local function CleanName(name)
    name = tostring(name or "?"):gsub("[|%[%]:]", "")
    if name == "" then name = "?" end
    return name
end

-- Strips escape codes from received text before it reaches a FontString.
local function CleanText(text)
    return tostring(text):gsub("|", "")
end

-- Stores a payload ({ title, lines }) under a fresh "<Name>:<n>" identifier
-- and returns that identifier.
function CL.Store(payload)
    local stem = CleanName(payload.title)
    local n = 0
    local id
    repeat
        n = n + 1
        id = stem .. ":" .. n
    until not sent[id]
    sent[id] = payload
    return id
end

-- The stored payload for an identifier we sent, or nil (expired/unknown).
function CL.Get(id)
    return sent[id]
end

-- Stores the payload and returns the chat-ready token ("[PMT:Name:1]").
function CL.MakeToken(payload)
    return "[PMT:" .. CL.Store(payload) .. "]"
end

-- Rewrites every [PMT:...] token in a displayed message into a clickable
-- link carrying the author's name (so the click knows whom to ask). Pure -
-- the chat filter in UI/ChatLinkUI.lua feeds it each message.
function CL.Rewrite(message, playerName)
    return (message:gsub(CL.FIND_PATTERN, function(content)
        local display = content:match("^(.*):%d+$") or content
        return LINK_COLOR .. "|H" .. CL.LINK_TYPE .. ":" .. (playerName or "?") .. ":" .. content
            .. "|h[" .. display .. "]|h|r"
    end))
end

-- Splits a clicked href ("addon:parchment:Player-Realm:Name:1") into the
-- sender's name and the link identifier, or nil when it is not ours.
function CL.ParseHref(link)
    if link:sub(1, #CL.LINK_TYPE) ~= CL.LINK_TYPE then return nil end
    local content = link:sub(#CL.LINK_TYPE + 2)
    local sep = content:find(":", 1, true)
    if not sep then return nil end
    return content:sub(1, sep - 1), content:sub(sep + 1)
end

-- The chat edit box currently open for typing, unwrapped across API
-- generations (older ChatEdit_GetActiveWindow returns the edit box itself;
-- newer wrappers may nest it), or nil when none is open.
local function ActiveEditBox()
    local win = (ChatFrameUtil and ChatFrameUtil.GetActiveWindow and ChatFrameUtil.GetActiveWindow())
        or (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow())
    if not win then return nil end
    if win.Insert then return win end
    if win.editBox and win.editBox.Insert then return win.editBox end
    if win.chatFrame and win.chatFrame.editBox and win.chatFrame.editBox.Insert then
        return win.chatFrame.editBox
    end
    return nil
end

-- Puts a payload's link token into the chat input, like shift-clicking a
-- regular item: into the actively open edit box when there is one (the user
-- finishes the message and picks the channel), else a fresh input pre-filled
-- with the token. The message is the user's to send - no channel is chosen
-- and nothing is auto-sent, which is also why the token goes in bare (their
-- sentence, their parentheses).
function CL.PostLink(payload)
    local token = CL.MakeToken(payload)
    local editBox = ActiveEditBox()
    if editBox then
        editBox:Insert(token)
        return true
    end
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if open then
        open(token)
        return true
    end
    ns.Print("no chat input to put the link into.")
    return false
end

-- Payload builders: each returns { title, lines }, lines being
-- { text, color = "gold"|"text"|"dim"|"blue", wrap = true|nil }. Colors stay
-- symbolic on the wire; the UI maps them to the palette.

local function MetaParts(rec)
    local parts = {}
    if rec.type then parts[#parts + 1] = rec.type end
    local cost = ns.FormatCost(rec.cost)
    if cost then parts[#parts + 1] = cost end
    if rec.range then parts[#parts + 1] = "Range: " .. rec.range end
    if rec.save then parts[#parts + 1] = ns.AttrName(rec.save) .. " save" end
    if rec.concentration then parts[#parts + 1] = "Concentration" end
    if rec.damage then parts[#parts + 1] = rec.damage end
    return parts
end

local function Build(title, context, rec)
    local lines = {}
    if context then lines[#lines + 1] = { text = context, color = "blue" } end
    local meta = table.concat(MetaParts(rec), "  -  ")
    if meta ~= "" then lines[#lines + 1] = { text = meta, color = "gold" } end
    if rec.description and rec.description ~= "" then
        lines[#lines + 1] = { text = rec.description, color = "text", wrap = true }
    end
    return { title = title, lines = lines }
end

-- A pack feat rank ("Keen Senses", context "Watcher's Instinct I").
local ROMAN = { "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }
function CL.FeatRank(line, rank, rankIndex)
    return Build(rank.name or "?",
        (line.name or line.id or "?") .. " " .. (ROMAN[rankIndex] or tostring(rankIndex)), rank)
end

-- A pack spell ("Arcane Dart", context "Arcane - Rank 1").
function CL.Spell(pack, spell)
    local school = ns.Spells and ns.Spells.School(pack, spell.school)
    local context = ((school and school.name) or spell.school or "?")
        .. " - Rank " .. tostring(spell.rank or "?")
    return Build(spell.name or "?", context, spell)
end

-- A homebrew record of either kind.
function CL.Homebrew(kind, rec)
    local context = "Homebrew " .. (kind == "spell" and "spell" or "feat")
    if kind == "spell" and rec.school then
        local pack = ns.GetSpellPack and ns.GetSpellPack()
        local school = pack and ns.Spells and ns.Spells.School(pack, rec.school)
        context = context .. " - " .. ((school and school.name) or rec.school)
            .. (rec.rank and (" Rank " .. rec.rank) or "")
    end
    return Build(rec.name or "?", context, rec)
end

-- A library item (resolved display entry or raw record).
function CL.Item(item)
    local lines = {}
    local kind = item.kind and (item.kind:gsub("^%l", string.upper)) or nil
    local bits = {}
    if kind then bits[#bits + 1] = kind end
    if item.weapon_name then bits[#bits + 1] = "for " .. item.weapon_name end
    if type(item.bonus) == "number" and item.bonus ~= 0 then
        bits[#bits + 1] = (item.bonus > 0 and "+" or "") .. item.bonus .. " attack"
    end
    if type(item.ac_bonus) == "number" and item.ac_bonus ~= 0 then
        bits[#bits + 1] = (item.ac_bonus > 0 and "+" or "") .. item.ac_bonus .. " AC"
    end
    if #bits > 0 then lines[#lines + 1] = { text = table.concat(bits, "  -  "), color = "gold" } end
    if item.description and item.description ~= "" then
        lines[#lines + 1] = { text = item.description, color = "text", wrap = true }
    end
    return { title = item.name or "?", lines = lines }
end

-- Bounds and cleans a received LINKA payload. Returns a safe copy, or nil
-- when the shape is beyond saving.
function CL.SanitizeAnswer(data)
    if type(data) ~= "table" or type(data.id) ~= "string" then return nil end
    local out = { id = CleanText(data.id):sub(1, MAX_TITLE) }
    if data.unknown then
        out.unknown = true
        return out
    end
    if type(data.title) ~= "string" then return nil end
    out.title = CleanText(data.title):sub(1, MAX_TITLE)
    out.lines = {}
    for i, line in ipairs(type(data.lines) == "table" and data.lines or {}) do
        if i > MAX_LINES then break end
        if type(line) == "table" and type(line.text) == "string" then
            out.lines[#out.lines + 1] = {
                text = CleanText(line.text):sub(1, MAX_LINE),
                color = (line.color == "gold" or line.color == "dim" or line.color == "blue")
                    and line.color or "text",
                wrap = line.wrap and true or nil,
            }
        end
    end
    return out
end

-- Asks `player` for the content behind a link identifier. The UI shows a
-- placeholder and renders the LINKA when it lands (or an expiry notice).
function CL.Request(player, id)
    if not ns.Comm then return end
    ns.Comm.Whisper("LINKQ", { id = id }, player)
end

-- Comm wiring. LINKQ answers from OUR registry; LINKA renders only while its
-- question is still pending (the UI tracks what it asked for).
if ns.Comm then
    ns.Comm.On("LINKQ", function(payload, sender)
        if type(payload) ~= "table" or type(payload.id) ~= "string" then return end
        local id = payload.id:sub(1, MAX_TITLE)
        local link = sent[id]
        if not link then
            ns.Comm.Whisper("LINKA", { id = id, unknown = true }, sender)
            return
        end
        ns.Comm.Whisper("LINKA", { id = id, title = link.title, lines = link.lines }, sender)
    end)
    ns.Comm.On("LINKA", function(payload, sender)
        local answer = CL.SanitizeAnswer(payload)
        if not answer then return end
        if ns.ChatLinkUI and ns.ChatLinkUI.OnAnswer then
            ns.ChatLinkUI.OnAnswer(answer, sender)
        end
    end)
end
