-- Parchment - Initiative Tracker (UI)
--
-- The combat window (/pmt combat): a scrolling, click-to-select turn order
-- driven by InitiativeTracker, with controls to add combatants (by total or
-- by rolling d20 + modifier), add the active character, advance the turn,
-- and reset. The current turn is highlighted (and scrolled back into view when
-- it changes); the round shows in the title.
-- The DM resolves initiative ties by hand with each row's move-up arrow
-- (automatic tie-breaking uses the system's initiative_tiebreaker stat,
-- captured on add). Players may end their OWN turn: their Next button reads
-- "End turn", is enabled only on their character's turn, and sends TURNEND -
-- the DM's client verifies and advances (DM-authoritative).
--
-- Sync is DM-push (an INIT broadcast on every state change) plus two on-demand
-- paths, so a player who reloaded or joined mid-combat is not stranded on stale
-- state: opening this window PULLS the order from the recognized DM (INITREQ,
-- which the DM answers by whispering INIT back to that one asker - never a group
-- push), and the DM's "Roll call" button asks everyone to roll (INITCALL, which
-- prompts each receiver and routes the accept straight through AddSelf).
--
-- Each row also shows hit points. Player rows render the live vitals their
-- owner broadcasts (current+temp/max; respects the share-vitals opt-out and
-- updates as edits arrive). NPC rows show the DM's private HP bookkeeping:
-- the DM clicks the cell to set/adjust it, and the values are stripped from
-- the INIT broadcast (IT.WireState) - players only ever see the NPC's name.
--
-- A turn/round stopwatch sits under the title: it restarts when the active
-- combatant / round changes (also via the DM's sync), click pauses/resumes,
-- right-click restarts. Purely local; nothing crosses the wire.
--
-- Remote data is treated as hostile on the way to the screen: the list renders
-- at most MAX_ROWS rows (frames are permanent - see the constant), a truncated
-- INIT is announced in chat rather than applied quietly, and every
-- remote-derived string this file prints or shows in a popup goes through
-- Safe/ns.SafeText so "|" escape codes cannot forge a link or a texture.
--
-- Reads from: ns.InitiativeTracker, ns.Party (vitals for player rows),
--   ns.GetActiveCharacter, ns.GetSystem, ns.GetItemLibrary,
--   ns.CharacterSheet.Compute, ns.UI (shared window + palette), ns.SafeText.
-- Exposes on ns.InitiativeUI: Open, Toggle, RefreshIfShown, AddSelf (roll
--   initiative and join combat; the sheet's Initiative row uses it).
-- Registers the "initiative" module opener with Core.

local ADDON, ns = ...

local ROW_H = 20

-- Hard ceiling on the rows the list will ever build. Deliberately independent
-- of the tracker's own MAX_COMBATANTS: state also reaches us from the
-- persisted DB (a hand-edited SavedVariables file never passes through
-- SetState), and WoW cannot destroy a frame - a single oversized order would
-- brick the window for good. Rows past this are summarised in a note instead.
local MAX_ROWS = 200

local UI = ns.UI
local IT = ns.InitiativeTracker

local InitiativeUI = {}
ns.InitiativeUI = InitiativeUI

-- Forward declarations so row/button scripts can refresh the window.
local Refresh, CanEdit, Sync, RefreshIfShown

-- Makes a remote-derived string safe to print or show in a popup: Core's
-- ns.SafeText strips "|" escape codes (a name carrying |H...|h renders as a
-- clickable forged link, |T...|t as an arbitrary texture) and caps the length.
-- Core always loads first in game, and the pure-Lua tests that load this file
-- on its own install their own ns.SafeText - one sanitiser, no second copy to
-- drift out of step with it.
local function Safe(value, maxLen, fallback)
    return ns.SafeText(value, maxLen, fallback)
end

-- Creates a small text button using the standard panel button look.
local function MakeButton(parent, text, width, tooltip)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    if tooltip then
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tooltip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
    end
    return b
end

-- Creates an input box.
local function MakeEditBox(parent, width, numeric)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    if numeric then e:SetNumeric(true) end
    return e
end

-- Creates one pooled combatant row (a clickable line with a remove button).
local function CreateRow(content)
    local row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_H)

    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints(row)
    hl:SetColorTexture(UI.HILITE[1], UI.HILITE[2], UI.HILITE[3], UI.HILITE[4])
    row.hl = hl

    row.num = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.num:SetPoint("LEFT", 4, 0)
    row.num:SetWidth(20)
    row.num:SetJustifyH("RIGHT")
    row.num:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])

    row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.num, "RIGHT", 8, 0)
    row.name:SetPoint("RIGHT", row, "RIGHT", -140, 0)
    row.name:SetJustifyH("LEFT")

    -- Move-up arrow (DM/solo): manual tie-breaking - swaps with the row
    -- above; inserts never re-sort, so the new order sticks.
    local up = CreateFrame("Button", nil, row)
    up:SetSize(16, 16)
    up:SetPoint("RIGHT", -20, 0)
    up:SetNormalTexture("Interface\\Buttons\\Arrow-Up-Up")
    up:SetPushedTexture("Interface\\Buttons\\Arrow-Up-Down")
    up:SetScript("OnClick", function()
        if not CanEdit() then return end
        if IT.Move(row.index, -1) then
            Refresh(InitiativeUI.frame)
            Sync()
        end
    end)
    up:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Move up (resolve ties by hand)", 1, 1, 1)
        GameTooltip:Show()
    end)
    up:SetScript("OnLeave", GameTooltip_Hide)
    row.moveUp = up

    row.init = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.init:SetPoint("RIGHT", -40, 0)
    row.init:SetJustifyH("RIGHT")
    row.init:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])

    -- Hit points: live vitals on player rows, DM bookkeeping on NPC rows.
    -- The overlay button (DM, NPC rows only) opens the set-HP popup.
    row.hp = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    row.hp:SetPoint("RIGHT", -66, 0)
    row.hp:SetWidth(70)
    row.hp:SetJustifyH("RIGHT")
    local hpBtn = CreateFrame("Button", nil, row)
    hpBtn:SetPoint("RIGHT", -62, 0)
    hpBtn:SetSize(78, ROW_H)
    hpBtn:SetScript("OnClick", function()
        if not (CanEdit() and row.npcName) then return end
        -- The popup carries the combatant TABLE, not the row index: rows can
        -- shift while the dialog is open (e.g. a player submission inserts),
        -- and the input must land on this combatant, not this position.
        local c = IT.GetState().combatants[row.index]
        if c then StaticPopup_Show("PARCHMENT_SET_NPC_HP", Safe(row.npcName), nil, c) end
    end)
    hpBtn:SetScript("OnEnter", function(self)
        if not row.npcName then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Set hit points", 1, 1, 1)
        GameTooltip:AddLine("A number sets current HP (and max while unset), "
            .. "+N / -N adjusts, current/max sets both. Players never see NPC HP.",
            0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("In the column, a \"+N\" after current HP is temporary hit points.",
            0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    hpBtn:SetScript("OnLeave", GameTooltip_Hide)
    row.hpBtn = hpBtn

    local rm = CreateFrame("Button", nil, row)
    rm:SetSize(16, 16)
    rm:SetPoint("RIGHT", -4, 0)
    rm:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    rm:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    rm:SetScript("OnClick", function()
        if not CanEdit() then return end
        local c = IT.GetState().combatants[row.index]
        if not c then return end
        -- The displayed name is sanitised; the data copy stays raw, so the
        -- accept handler can re-check it against the combatant it came from.
        StaticPopup_Show("PARCHMENT_INIT_REMOVE", Safe(c.name), nil,
            { index = row.index, name = c.name })
    end)
    rm:SetScript("OnEnter", function(self)
        if not CanEdit() then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove " .. Safe(row.name:GetText(), 64, "combatant"), 1, 1, 1)
        GameTooltip:Show()
    end)
    rm:SetScript("OnLeave", GameTooltip_Hide)
    row.remove = rm

    row:SetScript("OnClick", function()
        if not CanEdit() then return end
        local c = IT.GetState().combatants[row.index]
        IT.SetCurrent(row.index)
        Refresh(InitiativeUI.frame)
        Sync()
        if c then ns.Print("skipped to " .. Safe(c.name) .. ".") end
    end)
    row:SetScript("OnEnter", function(self)
        if not CanEdit() then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText("Click: set as current turn", 1, 1, 1)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
end

-- Live vitals by lower-cased character name: the party roster plus our own
-- snapshot (own broadcasts echo back but are ignored, so we are never in it).
local function VitalsByName()
    local map = {}
    if not ns.Party then return map end
    for _, v in pairs(ns.Party.GetRoster()) do
        if v.name then map[v.name:lower()] = v end
    end
    local own = ns.Party.OwnSnapshot()
    if own and own.name then map[own.name:lower()] = own end
    return map
end

-- Shows/hides the centred hint that stands in for an empty list. It lives on
-- the scroll child rather than going through UI.Empty: the window-wide empty
-- state would cover the very input strip the hint points at. The FontString is
-- created on first need and then reused (frames/regions are permanent).
local function SetEmptyHint(content, show, editable)
    if not show then
        if content.hint then content.hint:Hide() end
        return
    end
    local hint = content.hint
    if not hint then
        hint = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        hint:SetPoint("TOP", content, "TOP", 0, -28)
        hint:SetJustifyH("CENTER")
        hint:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
        content.hint = hint
    end
    -- A grouped non-DM cannot add anything here; their Me button submits.
    hint:SetText(editable
        and "No combatants yet.\n\nMe rolls your character in;\nadd NPCs with the boxes below."
        or "No combatants yet.\n\nYour DM runs the tracker;\nMe still submits your roll to them.")
    hint:Show()
end

-- Shows/hides the note standing in for the rows past MAX_ROWS, anchored at the
-- offset the next row would have used. Created on first need and then reused,
-- like the empty hint. Returns the height it occupies, so the caller can size
-- the scroll child. A clipped list must say so - silently dropping combatants
-- would look like data loss.
local function SetOverflowNote(content, hidden, y)
    if hidden <= 0 then
        if content.overflow then content.overflow:Hide() end
        return 0
    end
    local note = content.overflow
    if not note then
        note = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        note:SetJustifyH("LEFT")
        note:SetTextColor(UI.RED[1], UI.RED[2], UI.RED[3])
        content.overflow = note
    end
    note:ClearAllPoints()
    note:SetPoint("TOPLEFT", content, "TOPLEFT", 6, y - 2)
    note:SetText(hidden .. (hidden == 1 and " more combatant is" or " more combatants are")
        .. " not shown (display limit " .. MAX_ROWS .. ").")
    note:Show()
    return ROW_H
end

-- "7+2/12" (temp HP rides on top of current) or "7/12" without a buffer.
local function FormatHP(cur, max, temp)
    local t = (temp and temp > 0) and ("+" .. temp) or ""
    return tostring(cur) .. t .. "/" .. tostring(max)
end

-- Rebuilds the combatant list from current state.
local function RenderList(self)
    local state = IT.GetState()
    local content = self.content
    content.rows = content.rows or {}
    for _, r in ipairs(content.rows) do r:Hide() end

    local vitals = VitalsByName()
    local editable = CanEdit()
    -- Never build more rows than the ceiling, whatever the state holds.
    local total = #state.combatants
    local shown = math.min(total, MAX_ROWS)
    local y = -2
    for i = 1, shown do
        local c = state.combatants[i]
        local row = content.rows[i] or CreateRow(content)
        content.rows[i] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 2, y)
        row:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, y)
        row.index = i
        row.num:SetText(i .. ".")
        row.name:SetText(c.name)
        local isCurrent = (i == state.current)
        if isCurrent then
            row.name:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
        elseif c.isNPC then
            row.name:SetTextColor(UI.RED[1], UI.RED[2], UI.RED[3])
        else
            row.name:SetTextColor(UI.TEXT[1], UI.TEXT[2], UI.TEXT[3])
        end
        row.init:SetText(tostring(c.init))

        -- Hit points. NPC rows: the DM's bookkeeping (absent on players'
        -- clients - WireState strips it). Player rows: live vitals, with
        -- temp HP counting toward the effective total.
        local hpText, hpColor = "", UI.DIM
        row.npcName = c.isNPC and c.name or nil
        if c.isNPC then
            if c.hp then
                local max = c.hpmax or c.hp
                hpText = FormatHP(c.hp, max)
                hpColor = (max > 0 and c.hp / max < 0.35) and UI.RED or UI.TEXT
            elseif editable then
                hpText = "set hp"
            end
        else
            local v = vitals[c.name:lower()]
            if v and (v.hpmax or 0) > 0 then
                hpText = FormatHP(v.hp or 0, v.hpmax, v.temp)
                hpColor = ((v.hp or 0) + (v.temp or 0)) / v.hpmax < 0.35 and UI.RED or UI.TEXT
            else
                hpText = "-"   -- not shared (opt-out), not in group, or unknown
            end
        end
        row.hp:SetText(hpText)
        row.hp:SetTextColor(hpColor[1], hpColor[2], hpColor[3])
        row.hpBtn:SetShown(c.isNPC and editable)
        row.moveUp:SetShown(editable and i > 1)
        -- Like moveUp/hpBtn: a non-editing player must not see a control whose
        -- click can only ever no-op in its CanEdit() guard.
        row.remove:SetShown(editable)

        row.hl:SetShown(isCurrent)
        row:Show()
        y = y - ROW_H
    end
    SetEmptyHint(content, total == 0, editable)
    y = y - SetOverflowNote(content, total - shown, y)
    content:SetHeight(math.max(10, -y + 2))
end

-- True when this client may edit the order: the DM, or anyone playing solo
-- (outside a group the tracker is purely local). Players in a group are
-- read-only and submit their initiative to the DM instead.
CanEdit = function()
    return (not ns.Comm) or ns.Comm.IsDM() or not IsInGroup()
end

-- True when the current turn belongs to this player's active character (a
-- non-NPC combatant matching its name). Lets a player end their own turn.
local function IsMyTurn()
    local state = IT.GetState()
    local c = state.combatants[state.current]
    if not c or c.isNPC then return false end
    local char = ns.GetActiveCharacter and ns.GetActiveCharacter()
    return char and char.name and char.name:lower() == c.name:lower() or false
end

-- The active character's value in the system's initiative-tiebreaker stat
-- (final, post-trait), or nil when the system declares none. Captured when a
-- combatant is added; equal initiative rolls are ordered by it.
local function MyTiebreak(sheet)
    local attrId = ns.DerivedConfig().initiative_tiebreaker
    if not (attrId and sheet) then return nil end
    for _, a in ipairs(sheet.attributes or {}) do
        if a.id == attrId then return a.final end
    end
end

-- Broadcasts the current order to the group when acting as DM. WireState
-- strips the NPC hit points - they never leave this client.
--
-- DEBOUNCED, and that is load-bearing rather than tidiness. Every broadcast
-- carries the FULL state, so a receiver that misses one and catches the next
-- loses nothing - but the receiving side rate-limits INIT to one per 0.25s per
-- sender and DROPS what arrives inside that window. Sending per change is
-- therefore fine at two players and wrong at twelve: a roll call puts a popup
-- on everyone's screen at once, adjacent submissions land milliseconds apart,
-- each one made the DM re-broadcast, and whichever broadcast fell inside a
-- receiver's window was discarded. When the LAST one was the casualty - a tight
-- burst, or the DM clicking Start right after the final submission - every
-- player silently kept a short turn order with no error anywhere and no way
-- back until the DM touched the order again. Measured with 12 simulated clients
-- (Tests/test_init_scale.lua): submissions 40ms apart left all 11 players
-- holding 8 of 11 combatants.
--
-- Collapsing a burst into one trailing send fixes it at the source: the single
-- broadcast carries the settled state, and one message per burst can never
-- collide with the rate limit. SYNC_DELAY is well under a human's notice and
-- far above the gap between two clicks.
local SYNC_DELAY = 0.35
local SyncNow = function()
    if ns.Comm and ns.Comm.IsDM() then ns.Comm.Send("INIT", IT.WireState()) end
end
Sync = UI.Debounce(SYNC_DELAY, SyncNow)

-- Asks the DM for the current order (the pull that balances Sync's push). The
-- tracker is otherwise only ever pushed, so a player who reloaded or joined
-- mid-combat would sit on stale state until the DM next changed something.
-- Silent unless there is actually a DM to ask: as the DM, solo, or before any
-- DM is recognized this sends nothing. How often it may be asked is bounded on
-- the DM's side, by Comm's per-sender rate gate.
local function RequestSync()
    if not ns.Comm then return end
    if ns.Comm.IsDM() or not IsInGroup() or not ns.Comm.RecognizedDM() then return end
    ns.Comm.Send("INITREQ", {})
end

-- Scrolls the current turn back into view after a re-render. Only when the
-- turn actually changed (a manual scroll must not be yanked back on every
-- refresh) and only far enough to bring the row inside the visible band,
-- clamped to the scroll range. Rows start 2px below the content top.
local function ScrollToCurrent(self, current)
    if current == self.scrolledTo then return end
    self.scrolledTo = current
    local scroll = self.scroll
    if not (scroll and current and current >= 1) then return end
    local view = scroll:GetHeight()
    local range = self.content:GetHeight() - view
    if range <= 0 then return end
    local top = 2 + (current - 1) * ROW_H
    local offset = scroll:GetVerticalScroll()
    if top < offset then
        offset = top
    elseif top + ROW_H > offset + view then
        offset = top + ROW_H - view
    end
    scroll:SetVerticalScroll(math.max(0, math.min(range, offset)))
end

-- Turn/round stopwatch -------------------------------------------------------

-- "m:ss" for a number of elapsed seconds.
local function Clock(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function UpdateTimerText(self)
    if not (self.timerBtn and self.timerBtn:IsShown()) then return end
    local now = self.timerPausedAt or GetTime()
    local text = "Turn " .. Clock(now - (self.turnStart or now))
        .. "    Round " .. Clock(now - (self.roundStart or now))
    if self.timerPausedAt then text = text .. "  |cffffcc00(paused)|r" end
    self.timerText:SetText(text)
end

-- Restarts the stopwatches when the active combatant / round changes (which
-- also happens when a player applies the DM's sync). A turn change resumes a
-- paused timer - the pause was about the previous turn.
local function TickoverTimers(self, state)
    local sig = (state.round or 0) .. ":" .. (state.current or 0)
    if sig ~= self.timerSig then
        self.timerSig = sig
        local now = GetTime()
        self.turnStart = now
        if (state.round or 0) ~= self.timerRound then
            self.timerRound = state.round or 0
            self.roundStart = now
        end
        self.timerPausedAt = nil
    end
    self.timerBtn:SetShown((state.current or 0) > 0)
    UpdateTimerText(self)
end

-- Updates the title (round) and the list, and reflects the current role on the
-- editing controls.
function Refresh(self)
    local state = IT.GetState()
    local round = state.round or 0
    local title = round > 0 and ("Combat  -  Round " .. round) or "Combat"
    if ns.Comm and ns.Comm.IsDM() then title = title .. "  |cff8ec6ff(DM)|r" end
    self.titleFS:SetText(title)

    local editable = CanEdit()
    self.addBtn:SetEnabled(editable)
    self.rollBtn:SetEnabled(editable)
    self.npcCheck:SetEnabled(editable)
    self.startBtn:SetEnabled(editable and #state.combatants > 0)
    self.nextBtn:SetEnabled(editable or IsMyTurn())
    self.nextBtn:SetText(editable and "Next" or "End turn")
    self.resetBtn:SetEnabled(editable)
    self.meBtn:SetText(editable and "Me" or "Submit")
    -- The roll call is a DM control, so it stays hidden for a player in a group
    -- (only the DM may put a prompt on everyone's screen). It does NOT hide
    -- when there is simply nobody to call: a control that vanishes teaches the
    -- user nothing, and its neighbours (Start, Reset) grey out rather than
    -- disappear. Solo, it shows disabled and the tooltip says why.
    self.callBtn:SetShown(editable and true or false)
    self.callBtn:SetEnabled(editable and IsInGroup() and true or false)
    if self.publicCheck and ns.Addon and ns.Addon.db then
        self.publicCheck:SetChecked(ns.Addon.db.profile.publicRolls)
    end
    TickoverTimers(self, state)
    RenderList(self)
    ScrollToCurrent(self, state.current or 0)
end

-- Commits the name/value inputs as a combatant. rolled=true treats the value as
-- a d20 modifier; otherwise it is the initiative total. The NPC checkbox
-- decides the kind: NPCs get DM-tracked HP, unticked adds a player row (for
-- group members without the addon) whose HP comes from their vitals.
local function CommitInput(self, rolled)
    if not CanEdit() then return end
    local name = self.nameBox:GetText()
    local value = tonumber(self.modBox:GetText()) or 0
    local isNPC = self.npcCheck:GetChecked() and true or false
    self.nameBox:SetText("")
    self.modBox:SetText("")
    self.nameBox:ClearFocus()
    self.modBox:ClearFocus()
    if rolled then
        -- May resolve asynchronously (public rolls); refresh in the callback.
        IT.AddRolled(name, value, isNPC, nil, function(combatant, _, _, err)
            -- A public roll resolves async: the window may have closed, and
            -- IT.Add re-checks duplicates, so honour both before touching the UI.
            if err then ns.Print(err) end
            if self:IsShown() then Refresh(self) end
            if combatant then Sync() end
        end)
    else
        local combatant, err = IT.Add(name, value, isNPC)
        if err then ns.Print(err) end
        Refresh(self)
        if combatant then Sync() end
    end
end

-- Rolls the active character's initiative and joins combat: as DM/solo the
-- combatant is added locally (and synced); as a player in a group the roll
-- is submitted to the DM. Public - the sheet's Initiative row uses it too.
function InitiativeUI.AddSelf()
    if not ns.HasSystem() then
        ns.Print("no system loaded - import one with /pmt import to add your character.")
        return
    end
    local char = ns.GetActiveCharacter()
    if not char then return end
    local sheet = ns.CharacterSheet.Compute(char, ns.GetSystem(), ns.GetItemLibrary())
    if not sheet then return end
    -- One entry per character: re-rolling means asking the DM to remove the
    -- old entry first. The local state mirrors the DM's last sync, so this
    -- also stops a player double-submitting; the DM-side INITSUBMIT guard
    -- stays authoritative for the race window before the sync lands.
    if IT.HasPlayer(sheet.name) then
        ns.Print(sheet.name .. " is already in the turn order.")
        return
    end
    local tb = MyTiebreak(sheet)
    if CanEdit() then
        IT.AddRolled(sheet.name, sheet.derived.initiative, false, tb, function(combatant, _, _, err)
            if err then ns.Print(err) end
            RefreshIfShown()
            if combatant then Sync() end
        end)
    else
        IT.RequestRoll(sheet.derived.initiative, function(total)
            local ok, err = ns.Comm.Send("INITSUBMIT", { name = sheet.name, init = total, tb = tb })
            ns.Print(ok and ("submitted initiative " .. total .. " to the DM.") or (err or "submit failed."))
        end)
    end
end

-- Builds the window and its controls once.
local function BuildFrame()
    local f = UI.CreateWindow("ParchmentInitFrame", {
        title = "Combat", width = 380, height = 440,
        minW = 380, minH = 260, maxW = 560, maxH = 900, dbKey = "initiativeWindow",
    })
    -- Restored geometry may predate the wider action row (Roll call), which
    -- would otherwise run under the public-roll checkbox in the corner.
    if f:GetWidth() < 380 then f:SetWidth(380) end

    -- Turn/round stopwatch (shown once combat has a current turn).
    local timerBtn = CreateFrame("Button", nil, f)
    timerBtn:SetPoint("TOPLEFT", 16, -28)
    timerBtn:SetSize(190, 14)
    timerBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f.timerText = timerBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.timerText:SetPoint("LEFT")
    f.timerText:SetJustifyH("LEFT")
    f.timerText:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    timerBtn:SetScript("OnClick", function(_, button)
        local now = GetTime()
        if button == "RightButton" then
            f.turnStart, f.roundStart, f.timerPausedAt = now, now, nil
        elseif f.timerPausedAt then
            local shift = now - f.timerPausedAt
            f.turnStart = (f.turnStart or now) + shift
            f.roundStart = (f.roundStart or now) + shift
            f.timerPausedAt = nil
        else
            f.timerPausedAt = now
        end
        UpdateTimerText(f)
    end)
    timerBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText("Turn & round stopwatch", 1, 1, 1)
        GameTooltip:AddLine("Restarts on turn/round changes. Click to pause or "
            .. "resume, right-click to restart. Local only.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    timerBtn:SetScript("OnLeave", GameTooltip_Hide)
    f.timerBtn = timerBtn

    -- Tick the stopwatch display (~4x/s; OnUpdate stops while hidden).
    f.timerAccum = 0
    f:SetScript("OnUpdate", function(self, dt)
        self.timerAccum = self.timerAccum + dt
        if self.timerAccum < 0.25 then return end
        self.timerAccum = 0
        UpdateTimerText(self)
    end)

    -- Column headers for the two numeric columns. Right-anchored to the frame
    -- at the same insets the row cells use (rows sit 2px inside the scroll
    -- child, which itself ends 32px from the frame's right edge).
    local function head(text, rightInset, width)
        local s = f:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        s:SetPoint("TOPRIGHT", f, "TOPRIGHT", -rightInset, -46)
        s:SetWidth(width)
        s:SetJustifyH("RIGHT")
        s:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
        s:SetText(text)
    end
    head("HP", 100, 70)
    head("Init", 74, 30)

    -- Scrolling combatant list.
    local scroll = CreateFrame("ScrollFrame", "ParchmentInitScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -62)
    scroll:SetPoint("BOTTOMRIGHT", -32, 72)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    content.rows = {}
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
    f.content = content
    f.scroll = scroll

    -- Input row: name, value, Add, Roll.
    f.nameBox = MakeEditBox(f, 104, false)
    f.nameBox:SetPoint("BOTTOMLEFT", 18, 42)
    f.modBox = MakeEditBox(f, 30, true)
    f.modBox:SetPoint("BOTTOMLEFT", 134, 42)
    f.addBtn = MakeButton(f, "Add", 42, "Add a combatant using the value as their initiative total.")
    f.addBtn:SetPoint("BOTTOMLEFT", 170, 41)
    f.rollBtn = MakeButton(f, "Roll", 42, "Add a combatant, rolling d20 + the value as a modifier.")
    f.rollBtn:SetPoint("BOTTOMLEFT", 214, 41)

    -- Typed combatants default to NPCs (red name, DM-tracked HP). Untick to
    -- hand-add a player - e.g. a group member without the addon - whose HP
    -- cell reads from vitals instead.
    f.npcCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.npcCheck:SetSize(22, 22)
    f.npcCheck:SetPoint("BOTTOMLEFT", 256, 41)
    f.npcCheck:SetChecked(true)
    f.npcLabel = f.npcCheck:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.npcLabel:SetPoint("LEFT", f.npcCheck, "RIGHT", 0, 0)
    f.npcLabel:SetText("NPC")
    f.npcCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Add as NPC", 1, 1, 1)
        GameTooltip:AddLine("NPCs get DM-tracked hit points (click their HP cell; "
            .. "players never see the numbers). Untick to add a player by name - "
            .. "their HP cell shows their shared vitals instead.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    f.npcCheck:SetScript("OnLeave", GameTooltip_Hide)

    -- Action row: Me/Submit, Start, Next, Reset, Roll call. Widths are tuned to
    -- leave the public-roll checkbox its corner at the window's minimum width.
    f.meBtn = MakeButton(f, "Me", 42,
        "DM/solo: add your active character (rolled). Player: submit your initiative to the DM.")
    f.meBtn:SetPoint("BOTTOMLEFT", 18, 14)
    f.startBtn = MakeButton(f, "Start", 46,
        "Start combat: round 1 begins at the top of the order. Add everyone "
        .. "first - nothing runs (no round, no timers) until combat starts.")
    f.startBtn:SetPoint("BOTTOMLEFT", 64, 14)
    f.nextBtn = MakeButton(f, "Next", 54,
        "DM/solo: advance to the next turn. Player: end your own turn "
        .. "(enabled only while it is your character's turn).")
    f.nextBtn:SetPoint("BOTTOMLEFT", 114, 14)
    f.resetBtn = MakeButton(f, "Reset", 50,
        "Reset the tracker: removes all combatants and ends combat (asks for confirmation).")
    f.resetBtn:SetPoint("BOTTOMLEFT", 172, 14)
    -- DM only (shown in Refresh); disabled with no group to call.
    f.callBtn = MakeButton(f, "Roll call", 58,
        "Ask everyone in the group to roll initiative: each of them gets a "
        .. "prompt that rolls their active character in.\n\n"
        .. "Needs a party or raid - there is nobody to ask when solo.")
    f.callBtn:SetPoint("BOTTOMLEFT", 226, 14)

    -- Public-roll toggle: route Roll/Me through the in-game dice roller so the
    -- whole party sees the result, instead of a hidden local d20.
    f.publicCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.publicCheck:SetSize(22, 22)
    f.publicCheck:SetPoint("BOTTOMRIGHT", -8, 12)
    f.publicLabel = f.publicCheck:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.publicLabel:SetPoint("RIGHT", f.publicCheck, "LEFT", -1, 0)
    f.publicLabel:SetText("Public roll")
    f.publicCheck:SetScript("OnClick", function(self)
        if ns.Addon and ns.Addon.db then
            ns.Addon.db.profile.publicRolls = self:GetChecked() and true or false
        end
        if ns.ConfigUI then ns.ConfigUI.RefreshIfShown() end
    end)
    f.publicCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Public rolls", 1, 1, 1)
        GameTooltip:AddLine("Roll with the in-game dice roller so the whole party "
            .. "sees it, instead of a hidden local d20.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    f.publicCheck:SetScript("OnLeave", GameTooltip_Hide)

    -- Wire actions.
    f.addBtn:SetScript("OnClick", function() CommitInput(f, false) end)
    f.rollBtn:SetScript("OnClick", function() CommitInput(f, true) end)
    f.meBtn:SetScript("OnClick", InitiativeUI.AddSelf)
    f.startBtn:SetScript("OnClick", function() if CanEdit() then IT.Start(); Refresh(f); Sync() end end)
    f.nextBtn:SetScript("OnClick", function()
        if CanEdit() then
            IT.Next()
            Refresh(f)
            Sync()
        elseif IsMyTurn() then
            -- DM-authoritative: ask to end our turn; the DM verifies it is
            -- actually ours, advances, and rebroadcasts the new order.
            local state = IT.GetState()
            local c = state.combatants[state.current]
            local ok, err = ns.Comm.Send("TURNEND", { name = c and c.name })
            ns.Print(ok and "ending your turn..." or (err or "could not reach the DM."))
        end
    end)
    f.callBtn:SetScript("OnClick", function()
        if not (CanEdit() and ns.Comm) then return end
        local ok, err = ns.Comm.Send("INITCALL", {})
        ns.Print(ok and "asked the group to roll initiative."
            or (err or "could not reach the group."))
    end)
    f.resetBtn:SetScript("OnClick", function()
        if not CanEdit() then return end
        local n = #IT.GetState().combatants
        if n == 0 then return end
        StaticPopup_Show("PARCHMENT_RESET_COMBAT", n .. (n == 1 and " combatant" or " combatants"))
    end)
    f.nameBox:SetScript("OnEnterPressed", function() CommitInput(f, false) end)
    f.modBox:SetScript("OnEnterPressed", function() CommitInput(f, false) end)
    -- Tab cycles the two inputs: name -> value -> name.
    f.nameBox:SetScript("OnTabPressed", function() f.modBox:SetFocus() end)
    f.modBox:SetScript("OnTabPressed", function() f.nameBox:SetFocus() end)

    -- Input hints. The value's meaning depends on the button, so both boxes
    -- also explain themselves on hover. (Placeholders last: they HookScript.)
    local function InputTooltip(box, title, body)
        box:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(title, 1, 1, 1)
            GameTooltip:AddLine(body, 0.9, 0.9, 0.9, true)
            GameTooltip:Show()
        end)
        box:SetScript("OnLeave", GameTooltip_Hide)
    end
    InputTooltip(f.nameBox, "Combatant name",
        "Who joins the order; the NPC checkbox decides the kind.")
    InputTooltip(f.modBox, "Initiative value",
        "Add uses it as the initiative TOTAL. Roll uses it as the d20 MODIFIER "
        .. "and rolls d20 + value.")
    UI.SetPlaceholder(f.nameBox, "name")
    UI.SetPlaceholder(f.modBox, "init")

    -- Debounced, like the sheet body and the pickers: OnResize fires per
    -- pixel of a drag-resize, and the scroll's OnSizeChanged fires too.
    local relayout = UI.Debounce(0.1, function() if f:IsShown() then RenderList(f) end end)
    f.OnResize = relayout
    return f
end

-- Returns the singleton frame, building it on first use.
local function GetFrame()
    if not InitiativeUI.frame then InitiativeUI.frame = BuildFrame() end
    return InitiativeUI.frame
end

function InitiativeUI.Open()
    local f = GetFrame()
    Refresh(f)
    f:Show()
    RequestSync()
end

function InitiativeUI.Toggle()
    local f = GetFrame()
    if f:IsShown() then f:Hide() else InitiativeUI.Open() end
end

ns.RegisterModule("initiative", InitiativeUI.Toggle)

-- Refreshes the tracker window if it is open.
RefreshIfShown = function()
    if InitiativeUI.frame and InitiativeUI.frame:IsShown() then Refresh(InitiativeUI.frame) end
end
InitiativeUI.RefreshIfShown = RefreshIfShown

-- The popup's edit box: "EditBox" since the 12.x GameDialog rework,
-- "editBox" on older clients - accept either.
local function PopupEditBox(popup)
    return popup.EditBox or popup.editBox
end

-- Applies set-HP input to a combatant by resolving its CURRENT index - the
-- order may have shifted while the dialog was open.
local function ApplyHPInput(combatant, text)
    for i, c in ipairs(IT.GetState().combatants) do
        if c == combatant then return IT.AdjustHP(i, text) end
    end
    return false, "that combatant is no longer in the order."
end

-- Set-HP popup for NPC rows (DM only; opened from a row's HP cell). The
-- combatant table travels as popup data; AdjustHP validates and parses.
StaticPopupDialogs["PARCHMENT_SET_NPC_HP"] = {
    text = "Hit points for %s\n|cff888888number = set current (and max while unset),\n"
        .. "+N / -N = adjust, current/max = set both|r",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    OnAccept = function(self, combatant)
        local ok, err = ApplyHPInput(combatant, PopupEditBox(self):GetText())
        if not ok then ns.Print(err) end
        RefreshIfShown()
    end,
    EditBoxOnEnterPressed = function(self, combatant)
        local popup = self:GetParent()
        local ok, err = ApplyHPInput(combatant, PopupEditBox(popup):GetText())
        if not ok then ns.Print(err) end
        RefreshIfShown()
        popup:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Remove confirmation: the X sits 4px from the move-up arrow, and a deleted
-- combatant's place in the order is not recoverable. The index is re-checked
-- against the name on accept - a sync while the dialog stood may have moved
-- the rows under it.
StaticPopupDialogs["PARCHMENT_INIT_REMOVE"] = {
    text = "Remove %s from the combat?",
    button1 = "Remove",
    button2 = CANCEL,
    OnAccept = function(_, data)
        if not CanEdit() then return end
        local c = IT.GetState().combatants[data.index]
        if not (c and c.name == data.name) then return end
        IT.Remove(data.index)
        RefreshIfShown()
        Sync()
        ns.Print("removed " .. Safe(c.name) .. " (initiative " .. tostring(c.init) .. ").")
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Reset confirmation: the button sits next to Next, and a mid-fight misclick
-- must not wipe a painstakingly assembled order.
StaticPopupDialogs["PARCHMENT_RESET_COMBAT"] = {
    text = "Reset the combat tracker?\n\nThis removes %s and ends combat.",
    button1 = "Reset",
    button2 = CANCEL,
    OnAccept = function()
        -- Re-checked: the role may have changed while the dialog was open.
        if not CanEdit() then return end
        IT.Reset()
        RefreshIfShown()
        Sync()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- The DM's roll call, as it lands on a player's screen. Only the recognized DM
-- can reach it (Comm gates INITCALL as authoritative), and rolling is entirely
-- AddSelf's job: it owns the no-system / no-character / already-entered checks
-- and the DM-vs-player submit split, so there is nothing to duplicate here.
StaticPopupDialogs["PARCHMENT_INIT_CALL"] = {
    text = "%s is asking everyone to roll initiative.%s",
    button1 = "Roll",
    button2 = "Ignore",
    OnAccept = function() InitiativeUI.AddSelf() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Announces an order that did not fit the tracker's combatant cap (the count
-- IT.SetState returns). A DM whose legitimate encounter got clipped has to find
-- out, and a peer flooding the order should be loud rather than silent.
local function NotifyTruncated(dropped, sender)
    if not dropped or dropped <= 0 then return end
    ns.Print("|cffffcc00combat order from " .. Safe(sender, 32, "the DM")
        .. " was too long -|r " .. dropped
        .. (dropped == 1 and " combatant was" or " combatants were") .. " dropped.")
end

-- Adopt prompt for an INIT arriving before any DM is recognized (the bootstrap
-- window, where Comm's central gate accepts anyone). Accepting applies the
-- order AND recognizes the sender as this session's DM, so their later syncs
-- flow normally; declining ignores that sender's pushes until reload.
StaticPopupDialogs["PARCHMENT_ADOPT_INIT"] = {
    text = "%s is sharing a combat order but is not your recognized DM yet."
        .. "\n\nApply it and recognize them as your DM for this session?",
    button1 = ACCEPT,
    button2 = "Ignore",
    OnAccept = function(_, data)
        ns.Comm.SetRecognizedDM(data.sender)
        NotifyTruncated(IT.SetState(data.state), data.sender)
        RefreshIfShown()
    end,
    OnCancel = function(_, data)
        if data.ignored then data.ignored[data.key] = true end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Sync handlers: players adopt the DM's broadcast order; the DM accepts player
-- initiative submissions, adds them, and rebroadcasts.
if ns.Comm then
    -- Senders whose pre-recognition INIT pushes were declined (session memory;
    -- keyed by canonical name). They can still become DM via a DMROLE claim.
    local ignoredInit = {}
    ns.Comm.On("INIT", function(state, sender)
        -- Only the recognized DM's INIT reaches here (Comm gates it centrally);
        -- an active DM still ignores the echo of its own broadcast.
        if ns.Comm.IsDM() then return end
        if type(state) ~= "table" then return end
        -- Bootstrap gate: while no DM is recognized, Comm.IsAuthoritative lets
        -- any group member through, and INIT overwrites the PERSISTED order -
        -- so it must not apply silently. Hold the same trust posture as SYSTEM
        -- (Modules/Systems.lua): prompt, and lock recognition in on accept.
        if not ns.Comm.RecognizedDM() then
            local key = ns.Comm.NormalizeName(sender) or "?"
            if ignoredInit[key] then return end
            StaticPopup_Show("PARCHMENT_ADOPT_INIT", Safe(sender, 32, "someone"), nil,
                { sender = sender, state = state, key = key, ignored = ignoredInit })
            return
        end
        NotifyTruncated(IT.SetState(state), sender)
        RefreshIfShown()
    end)
    -- A player submitted their own initiative. SubmitFor binds the entry to the
    -- sender (so only they can later end its turn), refuses a second entry from
    -- the same player, and clamps the wire values - the DM-side notice is the
    -- only feedback on a refused resubmit.
    ns.Comm.On("INITSUBMIT", function(payload, sender)
        if not ns.Comm.IsDM() then return end
        if type(payload) ~= "table" or type(payload.name) ~= "string" then return end
        local combatant, err = IT.SubmitFor(sender, payload.name, payload.init, payload.tb)
        if combatant then
            -- Both names: the submitter picks the combatant name freely, so the
            -- DM should see WHO claimed it (a player squatting a teammate's
            -- name is otherwise invisible until the teammate is refused).
            ns.Print(Safe(sender, 32, "a player") .. " submitted " .. Safe(combatant.name)
                .. " at initiative " .. combatant.init .. ".")
            RefreshIfShown()
            Sync()
        elseif err then
            ns.Print(Safe(sender, 32, "a player") .. " re-submitted initiative; ignored - "
                .. Safe(err, 128))
        end
    end)
    -- A player pulled the order (their combat window just opened). Only the DM
    -- answers, and only to the asker: a WHISPER, never Send - one window opening
    -- must not push a full state at the whole group. No payload is read, so
    -- there is nothing to validate; Comm's rate gate (per sender + type) is what
    -- stops a peer making us serialize the order over and over.
    -- A pull is answered by whisper so one player opening their window does not
    -- push a full state at the whole group. But at a full table everyone opens
    -- it within the same few seconds, and eleven whispers of the same state cost
    -- eleven times the bytes of one broadcast on a channel that moves about
    -- 690 bytes a second. So a second asker arriving while an answer is still
    -- pending upgrades the reply to a single group broadcast, and the rest of
    -- the burst rides along on it. Mirrors Party's VITREQ coalescing.
    local pullTo, pullPending = nil, false
    local function AnswerPull()
        pullPending = false
        if not ns.Comm.IsDM() then return end
        if pullTo then
            ns.Comm.Whisper("INIT", IT.WireState(), pullTo)
        else
            ns.Comm.Send("INIT", IT.WireState())
        end
        pullTo = nil
    end
    ns.Comm.On("INITREQ", function(_, sender)
        if not ns.Comm.IsDM() then return end
        if pullPending then
            -- More than one asker in the window: answer the group once instead.
            if pullTo and not ns.Comm.SameName(pullTo, sender) then pullTo = nil end
            return
        end
        pullPending, pullTo = true, sender
        if C_Timer and C_Timer.After then
            C_Timer.After(SYNC_DELAY, AnswerPull)
        else
            AnswerPull()
        end
    end)
    -- The DM called for initiative. Comm has already established that this is
    -- the recognized DM and a group member, and our own broadcast never echoes
    -- back to us (the central self-echo filter on group distributions), so the
    -- calling DM is never prompted by their own call.
    ns.Comm.On("INITCALL", function(_, sender)
        local char = ns.GetActiveCharacter and ns.GetActiveCharacter()
        local who = (char and char.name) and ("\n\nRolling for " .. Safe(char.name) .. ".") or ""
        StaticPopup_Show("PARCHMENT_INIT_CALL", Safe(sender, 32, "your DM"), who)
    end)
    -- A player ended their own turn: EndTurnFor advances only when the active
    -- combatant is the one this sender submitted (a stale, duplicate, or
    -- someone-else's request is ignored), then we rebroadcast.
    ns.Comm.On("TURNEND", function(payload, sender)
        if not ns.Comm.IsDM() then return end
        if type(payload) ~= "table" or type(payload.name) ~= "string" then return end
        local c = IT.EndTurnFor(sender, payload.name)
        if not c then return end
        ns.Print(Safe(sender, 32, "a player") .. " ended " .. Safe(c.name) .. "'s turn.")
        RefreshIfShown()
        Sync()
    end)
end
