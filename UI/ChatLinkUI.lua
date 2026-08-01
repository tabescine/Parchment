-- Parchment - Chat Link viewer (UI)
--
-- The client-side half of chat links (Modules/ChatLinks.lua): a chat-message
-- filter rewrites the plain [PMT:Name:N] tokens into clickable links at
-- display time, a SetItemRef hook catches clicks on them, and this window
-- shows the linked content - immediately for our own links, after a LINKQ ->
-- LINKA round-trip for someone else's ("Asking <sender>..." in between). An
-- answer renders only while its question is the pending one, so nobody can
-- pop this window unasked.
--
-- Mechanism modeled on Total RP 3's chat links (see Modules/ChatLinks.lua).
--
-- Reads from: ns.ChatLinks, ns.Comm (NormalizeName), ns.UI.
-- Exposes on ns.ChatLinkUI: Show, OnAnswer, and .frame.

local ADDON, ns = ...

local UI = ns.UI
local CL = ns.ChatLinks

local COLORS = {
    gold = UI.HEAD,
    text = UI.TEXT,
    dim = UI.DIM,
    blue = { 0.56, 0.78, 1 },
}

local ChatLinkUI = {}
ns.ChatLinkUI = ChatLinkUI

local function BuildFrame()
    local f = UI.CreateWindow("ParchmentChatLinkFrame", {
        title = "Link", width = 360, height = 280,
        minW = 280, minH = 160, maxW = 600, maxH = 800, dbKey = "chatLinkWindow",
    })
    local scroll = CreateFrame("ScrollFrame", "ParchmentChatLinkScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -44)
    scroll:SetPoint("BOTTOMRIGHT", -32, 14)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    content.pool, content.used = {}, 0
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w)
        content:SetWidth(w)
        if f.payload then ChatLinkUI.Render(f.payload, f.senderText) end
    end)
    f.content = content
    return f
end

local function GetFrame()
    if not ChatLinkUI.frame then ChatLinkUI.frame = BuildFrame() end
    return ChatLinkUI.frame
end

local function AcquireLine(content)
    content.used = content.used + 1
    local fs = content.pool[content.used]
    if not fs then
        fs = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        content.pool[content.used] = fs
    end
    fs:ClearAllPoints()
    fs:Show()
    return fs
end

-- Lays the payload's lines into the window (pooled FontStrings, measured
-- heights so wrapped text stacks naturally).
function ChatLinkUI.Render(payload, senderText)
    local f = GetFrame()
    f.payload, f.senderText = payload, senderText
    f.titleFS:SetText(payload.title or "Link")
    local content = f.content
    content.used = 0
    local width = content:GetWidth()
    local y = -4

    local function line(text, color, wrap)
        local fs = AcquireLine(content)
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
        fs:SetWidth(width - 8)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(wrap and true or false)
        local c = COLORS[color] or UI.TEXT
        fs:SetTextColor(c[1], c[2], c[3])
        fs:SetText(text)
        y = y - fs:GetStringHeight() - 6
    end

    for _, l in ipairs(payload.lines or {}) do
        line(l.text, l.color, l.wrap)
    end
    if senderText then
        y = y - 4
        line(senderText, "dim")
    end
    for i = content.used + 1, #content.pool do content.pool[i]:Hide() end
    content:SetHeight(math.max(10, -y + 8))
    f:Show()
end

-- Shows a payload outright (own links, placeholders).
function ChatLinkUI.Show(payload, senderText)
    ChatLinkUI.Render(payload, senderText)
end

-- The identifier we are currently waiting on, and who we asked.
local pendingId, pendingFrom

-- Renders a LINKA answer, but only the one we are waiting for.
function ChatLinkUI.OnAnswer(answer, sender)
    if not pendingId or answer.id ~= pendingId then return end
    if pendingFrom and ns.Comm and ns.Comm.NormalizeName
        and ns.Comm.NormalizeName(sender or "") ~= ns.Comm.NormalizeName(pendingFrom) then
        return
    end
    pendingId, pendingFrom = nil, nil
    if answer.unknown then
        ChatLinkUI.Render({
            title = "Link expired",
            lines = { { text = "The sender no longer has this link (links live for one session).",
                color = "dim", wrap = true } },
        })
        return
    end
    ChatLinkUI.Render(answer, "Sent by " .. (sender or "?"))
end

-- Click handling: our own links resolve locally, anyone else's are fetched.
local function OnLinkClicked(player, id)
    local me = UnitName and UnitName("player")
    local mine = me and ns.Comm and ns.Comm.SameName and ns.Comm.SameName(player, me)
    if mine then
        local payload = CL.Get(id)
        if payload then
            ChatLinkUI.Render(payload)
        else
            ChatLinkUI.Render({ title = "Link expired",
                lines = { { text = "This link is from an earlier session.", color = "dim", wrap = true } } })
        end
        return
    end
    pendingId, pendingFrom = id, player
    CL.Request(player, id)
    ChatLinkUI.Render({
        title = id:match("^(.*):%d+$") or id,
        lines = { { text = "Asking " .. player .. "...", color = "dim" } },
    })
end

-- Display-time rewrite of [PMT:...] tokens on every chat channel players
-- speak on. The wire text stays plain; only rendering changes.
local CHANNELS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE",
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_CHANNEL", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
}

local function Filter(_, _, message, playerName, ...)
    if message:find("[PMT:", 1, true) then
        message = CL.Rewrite(message, playerName)
    end
    return false, message, playerName, ...
end

local AddFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter)
    or ChatFrame_AddMessageEventFilter
if AddFilter then
    for _, channel in ipairs(CHANNELS) do
        AddFilter(channel, Filter)
    end
end

-- Clicks on rendered links land in SetItemRef; ours carry the
-- addon:parchment href (never sent over the wire, so always well-formed
-- by construction of the filter above - ParseHref still guards).
if hooksecurefunc and SetItemRef then
    hooksecurefunc("SetItemRef", function(link)
        local player, id = CL.ParseHref(link)
        if player and id then OnLinkClicked(player, id) end
    end)
end
