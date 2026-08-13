-- Parchment - Item sharing (logic)
--
-- Transfers single item-library records between players, complementing the
-- whole-library export/import: a direct offer whispered to one player
-- (ITEM -> ITEMACK) and the on-demand fetch behind an importable chat link
-- (ITEMQ -> ITEMA; the link side lives in Modules/ChatLinks.lua). Both paths
-- land in the same receive seam: the record is size-capped, schema-validated
-- and then rebuilt from its known fields only (ITEM_FIELDS - junk smuggled
-- alongside never reaches SavedVariables), with escape codes scrubbed from
-- every string. The comm path holds the same validation line as the local
-- import path, plus the scrub only remote text needs.
--
-- An accepted record is stored under a FRESH local id (ns.NextItemKey):
-- sender ids are library-local ("itm_N"), so keeping one would overwrite an
-- unrelated local item. The price is that re-receiving the same item makes a
-- duplicate rather than an update - the pre-1.0 trade-off.
--
-- Direct offers are consent-gated on both sides: the receiver sees an
-- accept/decline popup (nothing is stored before "Add it"), and every offer
-- is answered with an ITEMACK whisper - offered, accepted, declined, busy or
-- invalid - so the sender is never left guessing (the INITACK pattern). A
-- missing ack times out with a version hint, because an older client drops
-- the unknown message type silently. Chat-link imports skip the receive
-- popup: clicking "Import item" was the consent.
--
-- Reads from: ns.Comm (Whisper/On/name helpers/Version), ns.Schema
--   (ValidateItem), ns.JSON (size bound), ns.Items (MigrateAC), ns.ChatLinks
--   (Get - the sent-link registry ITEMQ answers from), ns.GetItemLibrary,
--   ns.NextItemKey, ns.SetItem, ns.Print, ns.SafeText, ns.ItemWizardUI
--   (refresh, guarded), ns.ChatLinkUI (OnImportResult, guarded).
-- Exposes on ns.ItemShare: Offer, SendPrompt, RequestImport, Accept.

local ADDON, ns = ...

ns.ItemShare = ns.ItemShare or {}
local IS = ns.ItemShare

-- Cap on a wire record's encoded size. A real item (name 64, description 512,
-- ten small effects) encodes to under 2 KB; the cap bounds what a hostile
-- payload can make us validate and store.
local MAX_WIRE_BYTES = 16 * 1024

-- Seconds before a silent offer / import request is reported as unanswered.
local OFFER_TIMEOUT = 8
local IMPORT_TIMEOUT = 8

-- Longest link identifier we accept in an ITEMQ (mirrors ChatLinks' title cap).
local MAX_ID = 120

-- The fields a wire record may carry into the library, mirroring the item
-- schema (the RESOLVED_FIELDS pattern in Modules/Sharing.lua). `version` is
-- deliberately absent - ns.SetItem stamps a local one. A field added to the
-- item schema must be added here too, or shared copies silently lose it.
local ITEM_FIELDS = { "id", "name", "kind", "description", "weapon_id", "icon",
    "bonus", "ac_bonus", "ac_mod_cap", "default_count" }
local EFFECT_FIELDS = { "type", "value", "id", "skill", "school", "add_modifier",
    "per_level" }

-- Offers we sent, awaiting their ITEMACK: [normalized target] = { name,
-- serial, acked }. `acked` marks the delivery receipt so the timeout stays
-- quiet while the receiver is still deciding.
local pendingOffers = {}
local offerSerial = 0

-- The chat-link import we are waiting on (at most one, like the link window's
-- pending question): { player, id, serial }. The serial lets an uncancellable
-- C_Timer timeout recognize itself as stale.
local pendingImport
local importSerial = 0

-- This player's own name.
local function Me()
    return (UnitName and UnitName("player")) or ""
end

-- Strips escape codes from a remote string: a "|H..." in a stored name would
-- render as a forged link everywhere the library is displayed.
local function Scrub(v)
    if type(v) == "string" then return (v:gsub("|", "")) end
    return v
end

-- Rebuilds a schema-valid wire record from its known fields only (a fresh
-- table - never a reference into the payload), scrubbing every string.
local function CleanCopy(item)
    local copy = {}
    for _, f in ipairs(ITEM_FIELDS) do copy[f] = Scrub(item[f]) end
    if type(item.effects) == "table" then
        local effects = {}
        for _, e in ipairs(item.effects) do
            if type(e) == "table" then
                local ce = {}
                for _, f in ipairs(EFFECT_FIELDS) do ce[f] = Scrub(e[f]) end
                effects[#effects + 1] = ce
            end
        end
        if #effects > 0 then copy.effects = effects end
    end
    return copy
end

-- Validates a record that arrived over the wire. Returns a clean storable
-- copy, or nil. Order matters: the size cap bounds the encode/validate cost,
-- then the schema decides (the import path's line), then the copy narrows to
-- known fields.
local function ValidWireItem(item)
    if type(item) ~= "table" then return nil end
    local ok, enc = pcall(ns.JSON.encode, item)
    if not ok or type(enc) ~= "string" or #enc > MAX_WIRE_BYTES then return nil end
    if not ns.Schema.ValidateItem(item) then return nil end
    return CleanCopy(item)
end

-- Whispers an offer's ack back to its sender (see the status list above).
local function Ack(target, status)
    ns.Comm.Whisper("ITEMACK", { status = status }, target)
end

-- Tells the chat-link window how its requested import ended (guarded - the
-- module works headless in tests, and the window may be closed).
local function NotifyLinkUI(id, ok)
    if ns.ChatLinkUI and ns.ChatLinkUI.OnImportResult then
        ns.ChatLinkUI.OnImportResult(id, ok)
    end
end

-- The current target's full name when it is a player - the natural prefill
-- for the send prompt.
local function DefaultTarget()
    if UnitExists and UnitExists("target") and UnitIsPlayer and UnitIsPlayer("target") then
        local n, r = UnitName("target")
        if n then return (r and r ~= "" and (n .. "-" .. r)) or n end
    end
    return ""
end

-- The popup's edit box across client generations (newer dialogs wrap it).
local function EditBoxOf(dialog)
    if not dialog then return nil end
    if dialog.GetEditBox then return dialog:GetEditBox() end
    return dialog.editBox
end

-- Stores an accepted wire record (a CleanCopy result) under a fresh local id
-- and reports it. Returns the new key.
function IS.Accept(item, sender)
    ns.Items.MigrateAC(item)
    local key = ns.NextItemKey()
    ns.SetItem(key, item)
    ns.Print("added '" .. ns.SafeText(item.name) .. "' from "
        .. ns.SafeText(sender, nil, "?") .. " to your item library.")
    if ns.ItemWizardUI and ns.ItemWizardUI.RefreshIfShown then
        ns.ItemWizardUI.RefreshIfShown()
    end
    return key
end

-- Whispers a library record to one player as a consent-gated offer. The
-- receiving client validates and prompts; every outcome comes back as an
-- ITEMACK, and silence (no addon, or one too old for this message) becomes a
-- timeout notice instead of a false "sent".
function IS.Offer(target, item)
    target = type(target) == "string"
        and target:gsub("^%s+", ""):gsub("%s+$", "") or ""
    if target == "" then
        ns.Print("no player name given.")
        return
    end
    if type(item) ~= "table" then return end
    if ns.Comm.SameName(target, Me()) then
        ns.Print("that is you - the item is already in your library.")
        return
    end

    local ok, err = ns.Comm.Whisper("ITEM", { item = item }, target)
    if not ok then
        ns.Print(err or "could not send the offer.")
        return
    end

    offerSerial = offerSerial + 1
    local serial = offerSerial
    local key = ns.Comm.NormalizeName(target) or target
    pendingOffers[key] = { name = item.name, serial = serial }
    ns.Print("offered '" .. ns.SafeText(item.name) .. "' to "
        .. ns.SafeText(target) .. "...")
    if C_Timer and C_Timer.After then
        C_Timer.After(OFFER_TIMEOUT, function()
            local p = pendingOffers[key]
            if p and p.serial == serial and not p.acked then
                pendingOffers[key] = nil
                ns.Print("no response from " .. ns.SafeText(target)
                    .. " - they need Parchment " .. ns.Comm.Version()
                    .. " or newer loaded (and to be online).")
            end
        end)
    end
end

-- Opens the send prompt for a library record (the item row's "Send to a
-- player" action). The popup shows the sanitized name; its data carries the
-- record itself.
function IS.SendPrompt(item)
    if type(item) ~= "table" then return end
    StaticPopup_Show("PARCHMENT_SEND_ITEM", ns.SafeText(item.name), nil, { item = item })
end

-- Asks `player` for the full record behind an importable chat link (the link
-- window's Import button). The ITEMA answer or the timeout resolves it; a
-- newer request simply replaces a stale pending one.
function IS.RequestImport(player, id)
    if type(player) ~= "string" or type(id) ~= "string" then return end
    importSerial = importSerial + 1
    local serial = importSerial
    pendingImport = { player = player, id = id, serial = serial }
    ns.Comm.Whisper("ITEMQ", { id = id }, player)
    if C_Timer and C_Timer.After then
        C_Timer.After(IMPORT_TIMEOUT, function()
            if pendingImport and pendingImport.serial == serial then
                pendingImport = nil
                ns.Print("no answer from " .. ns.SafeText(player)
                    .. " - the item could not be fetched.")
                NotifyLinkUI(id, false)
            end
        end)
    end
end

-- Prompt for an incoming direct offer. Nothing was stored yet: accepting
-- stores and acks, declining (button or Escape) just acks, and an override by
-- another popup acks nothing - the offer simply lapses.
StaticPopupDialogs["PARCHMENT_ITEM_OFFER"] = {
    text = "%s offers you the item \"%s\".\n\nAdd it to your item library?",
    button1 = "Add it",
    button2 = "No thanks",
    OnAccept = function(_, data)
        IS.Accept(data.item, data.sender)
        Ack(data.sender, "accepted")
    end,
    OnCancel = function(_, data, reason)
        if reason ~= "override" then Ack(data.sender, "declined") end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- The send prompt: a name box prefilled with the current target. Enter sends.
StaticPopupDialogs["PARCHMENT_SEND_ITEM"] = {
    text = "Send the item \"%s\" to which player?",
    button1 = "Send",
    button2 = CANCEL,
    hasEditBox = 1, maxLetters = 60,
    OnShow = function(self)
        local eb = EditBoxOf(self)
        if eb then
            eb:SetText(DefaultTarget())
            eb:HighlightText()
        end
    end,
    OnAccept = function(self, data)
        local eb = EditBoxOf(self)
        if data and eb then IS.Offer(eb:GetText(), data.item) end
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        if parent.button1 and parent.button1:IsEnabled() then parent.button1:Click() end
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Comm wiring. All four types are whisper-legal from anyone (like LINKQ/
-- LINKA): sharing with guildmates and friends outside the group is the point.
-- Their cost is bounded centrally by Comm's rate gate, and nothing here
-- touches SavedVariables without either a popup consent (ITEM) or a matching
-- pending request (ITEMA).
if ns.Comm then
    -- A direct offer: validate first (the ack tells the sender when their
    -- copy did not survive our schema), then prompt. StaticPopup_Show
    -- returning nil means an offer prompt is already up; the newcomer is
    -- refused with "busy" rather than silently replacing what the player is
    -- looking at.
    ns.Comm.On("ITEM", function(payload, sender)
        if not sender or ns.Comm.IsSelf(sender) then return end
        if type(payload) ~= "table" then return end
        local item = ValidWireItem(payload.item)
        if not item then
            Ack(sender, "invalid")
            ns.Print(ns.SafeText(sender, nil, "someone")
                .. " offered an item that failed validation; ignored.")
            return
        end
        local shown = StaticPopup_Show("PARCHMENT_ITEM_OFFER",
            ns.SafeText(sender, nil, "?"), ns.SafeText(item.name),
            { item = item, sender = sender })
        Ack(sender, shown and "offered" or "busy")
    end)

    -- The sender's verdicts on an offer we made. Only honoured while that
    -- offer is pending, so an unsolicited ack can never print.
    ns.Comm.On("ITEMACK", function(payload, sender)
        if type(payload) ~= "table" or type(payload.status) ~= "string" then return end
        local key = ns.Comm.NormalizeName(sender or "")
        local p = key and pendingOffers[key]
        if not p then return end
        local who = ns.SafeText(sender, nil, "?")
        local what = ns.SafeText(p.name, nil, "the item")
        local status = payload.status
        if status == "offered" then
            p.acked = true
            ns.Print(who .. " received the offer for '" .. what .. "'.")
        elseif status == "accepted" then
            pendingOffers[key] = nil
            ns.Print(who .. " added '" .. what .. "' to their library.")
        elseif status == "declined" then
            pendingOffers[key] = nil
            ns.Print(who .. " declined '" .. what .. "'.")
        elseif status == "busy" then
            pendingOffers[key] = nil
            ns.Print(who .. " has another item offer open - try again in a moment.")
        elseif status == "invalid" then
            pendingOffers[key] = nil
            ns.Print(who .. "'s Parchment rejected '" .. what .. "' as invalid"
                .. " - your addon versions may disagree about items.")
        end
    end)

    -- An import request against OUR sent-link registry. Only links posted as
    -- importable carry a record; an expired link (or a guessed id, which
    -- learns nothing a LINKQ would not tell it) answers unknown.
    ns.Comm.On("ITEMQ", function(payload, sender)
        if not sender or type(payload) ~= "table" or type(payload.id) ~= "string" then return end
        local id = payload.id:sub(1, MAX_ID)
        local link = ns.ChatLinks and ns.ChatLinks.Get and ns.ChatLinks.Get(id)
        local item = link and type(link.item) == "table" and link.item or nil
        if item then
            ns.Comm.Whisper("ITEMA", { id = id, item = item }, sender)
        else
            ns.Comm.Whisper("ITEMA", { id = id, unknown = true }, sender)
        end
    end)

    -- The record behind a link we asked to import. Clicking Import was the
    -- consent, so a valid answer stores without a second prompt - but only
    -- while ITS question is the pending one, from the player we asked.
    ns.Comm.On("ITEMA", function(payload, sender)
        if type(payload) ~= "table" or type(payload.id) ~= "string" then return end
        local p = pendingImport
        if not p or payload.id ~= p.id or not ns.Comm.SameName(sender, p.player) then return end
        pendingImport = nil
        if payload.unknown then
            ns.Print(ns.SafeText(sender, nil, "?")
                .. " no longer has that link (links live for one session).")
            NotifyLinkUI(p.id, false)
            return
        end
        local item = ValidWireItem(payload.item)
        if not item then
            ns.Print(ns.SafeText(sender, nil, "?") .. " sent a malformed item; ignored.")
            NotifyLinkUI(p.id, false)
            return
        end
        IS.Accept(item, sender)
        NotifyLinkUI(p.id, true)
    end)
end
