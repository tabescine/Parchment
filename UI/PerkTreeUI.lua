-- Parchment - Perk Tree (UI)
--
-- The perk tree viewer: a node graph per ability sphere. Nodes are colour-coded
-- by status (taken / available / locked / blocked), prerequisite lines connect
-- them, hovering shows requirements and description, left-click selects (or adds
-- a rank), right-click removes. A cycler switches spheres; a counter shows
-- invested vs available points.
--
-- Reads from: ns.GetSystem, ns.GetActiveCharacter, ns.CharacterSheet.Compute,
--   ns.GetAttribute, ns.PerkTree, ns.UI.
-- Registers the "perks" module opener with Core.

local ADDON, ns = ...

local UI = ns.UI
local PT = ns.PerkTree

local NODE_W, NODE_H = 128, 36
local ROW_H, TOP_PAD = 62, 12

-- Status -> { border = {r,g,b}, bg = {r,g,b}, label = "..." }.
local STATUS = {
    taken = { border = { 0.4, 0.85, 0.4 }, bg = { 0.16, 0.34, 0.16 }, label = "Taken" },
    available = { border = UI.GOLD, bg = { 0.26, 0.22, 0.12 }, label = "Available" },
    locked = { border = { 0.4, 0.4, 0.4 }, bg = { 0.13, 0.13, 0.14 }, label = "Locked" },
    exclusive = { border = UI.RED, bg = { 0.28, 0.13, 0.13 }, label = "Blocked (exclusive)" },
}

local PerkTreeUI = {}
ns.PerkTreeUI = PerkTreeUI

local Refresh

-- Name of an attribute id.
local function AttrNameById(id)
    local a = ns.GetAttribute(id)
    return a and a.name or id
end

-- Finds a perk in a tree by id.
local function FindPerk(tree, id)
    for _, p in ipairs(tree.perks or {}) do
        if p.id == id then return p end
    end
end

-- Resolves a list of perk ids to a comma-joined list of names (any tree).
local function NamesOf(ids)
    local sys = ns.GetSystem()
    local out = {}
    for _, id in ipairs(ids or {}) do
        local found = id
        for _, tree in ipairs(sys.perk_trees or {}) do
            local p = FindPerk(tree, id)
            if p then found = p.name; break end
        end
        out[#out + 1] = found
    end
    return table.concat(out, ", ")
end

-- Sets the transient message line.
local function SetMsg(self, text, isError)
    local c = isError and UI.RED or UI.DIM
    self.msg:SetTextColor(c[1], c[2], c[3])
    self.msg:SetText(text or "")
end

-- Builds the hover tooltip for a node.
local function ShowTooltip(self, node)
    local perk, tree = node.perk, node.tree
    GameTooltip:SetOwner(node, "ANCHOR_RIGHT")
    GameTooltip:AddLine(perk.name, UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])
    local reqAttr = perk.req_attribute or tree.governing_attribute
    GameTooltip:AddLine("Requires " .. AttrNameById(reqAttr) .. " " .. (perk.attribute_req or 5), 0.9, 0.9, 0.9)
    if perk.prerequisites and #perk.prerequisites > 0 then
        GameTooltip:AddLine("Needs: " .. NamesOf(perk.prerequisites), 0.9, 0.9, 0.9)
    end
    if perk.exclusive_with and #perk.exclusive_with > 0 then
        GameTooltip:AddLine("Exclusive with: " .. NamesOf(perk.exclusive_with), UI.RED[1], UI.RED[2], UI.RED[3])
    end
    if perk.level_req then
        local levels = type(perk.level_req) == "table" and table.concat(perk.level_req, ", ") or tostring(perk.level_req)
        GameTooltip:AddLine("Level(s): " .. levels, 0.9, 0.9, 0.9)
    end
    local status = PT.Status(self.char, self.sheet, tree, perk)
    local sc = STATUS[status]
    GameTooltip:AddLine(sc.label, sc.border[1], sc.border[2], sc.border[3])
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(perk.description, 0.82, 0.80, 0.74, true)
    GameTooltip:Show()
end

-- Handles a click on a node: select on left, deselect on right.
local function OnNodeClick(self, node, button)
    local perk, tree = node.perk, node.tree
    local ok, reason
    if button == "RightButton" then
        ok, reason = PT.Deselect(self.char, tree, perk)
        SetMsg(self, ok and ("Removed " .. perk.name .. ".") or reason, not ok)
    else
        ok, reason = PT.Select(self.char, self.sheet, tree, perk)
        SetMsg(self, ok and ("Selected " .. perk.name .. ".") or reason, not ok)
    end
    if ok then Refresh(self) end
end

-- Creates one pooled node button (scripts read node.perk / node.tree).
local function CreateNode(self)
    local node = CreateFrame("Button", nil, self.content, "BackdropTemplate")
    node:SetSize(NODE_W, NODE_H)
    node:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    node:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    node.label = node:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    node.label:SetPoint("CENTER")
    node.label:SetWidth(NODE_W - 10)
    node.label:SetJustifyH("CENTER")
    node.rank = node:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    node.rank:SetPoint("BOTTOMRIGHT", -3, 2)
    node:SetScript("OnEnter", function(n) ShowTooltip(self, n) end)
    node:SetScript("OnLeave", GameTooltip_Hide)
    node:SetScript("OnClick", function(n, button) OnNodeClick(self, n, button) end)
    return node
end

local function AcquireNode(self)
    local content = self.content
    content.usedNodes = content.usedNodes + 1
    local node = content.nodePool[content.usedNodes]
    if not node then
        node = CreateNode(self)
        content.nodePool[content.usedNodes] = node
    end
    node:Show()
    return node
end

local function AcquireLine(self)
    local content = self.content
    content.usedLines = content.usedLines + 1
    local line = content.linePool[content.usedLines]
    if not line then
        line = content:CreateLine(nil, "ARTWORK")
        line:SetThickness(2)
        line:SetColorTexture(0.5, 0.45, 0.3, 0.7)
        content.linePool[content.usedLines] = line
    end
    line:Show()
    return line
end

-- Positions and colours every node, then draws prerequisite lines.
local function RenderGraph(self)
    local content = self.content
    for _, n in ipairs(content.nodePool) do n:Hide() end
    for _, l in ipairs(content.linePool) do l:Hide() end
    content.usedNodes, content.usedLines = 0, 0
    content.nodeMap = {}

    local tree = ns.GetSystem().perk_trees[self.treeIndex]
    if not tree then return end
    local rows = (tree.layout and tree.layout.rows) or {}
    local width = content:GetWidth()

    for ri, row in ipairs(rows) do
        local count = #row.perks
        for ci, pid in ipairs(row.perks) do
            local perk = FindPerk(tree, pid)
            if perk then
                local node = AcquireNode(self)
                node.perk, node.tree = perk, tree
                node.label:SetText(perk.name)

                local status = PT.Status(self.char, self.sheet, tree, perk)
                local sc = STATUS[status]
                node:SetBackdropColor(sc.bg[1], sc.bg[2], sc.bg[3], 0.9)
                node:SetBackdropBorderColor(sc.border[1], sc.border[2], sc.border[3], 1)
                node.label:SetTextColor(0.95, 0.93, 0.88)

                if perk.max_ranks and perk.max_ranks > 1 then
                    node.rank:SetText(PT.Rank(self.char, perk) .. "/" .. perk.max_ranks)
                    node.rank:Show()
                else
                    node.rank:Hide()
                end

                local x = width * ci / (count + 1) - NODE_W / 2
                local y = -TOP_PAD - (ri - 1) * ROW_H
                node:ClearAllPoints()
                node:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
                content.nodeMap[pid] = node
            end
        end
    end

    content:SetHeight(TOP_PAD + #rows * ROW_H + 16)

    -- Prerequisite lines (only between nodes shown in this tree).
    for _, perk in ipairs(tree.perks) do
        local toNode = content.nodeMap[perk.id]
        if toNode then
            for _, pr in ipairs(perk.prerequisites or {}) do
                local fromNode = content.nodeMap[pr]
                if fromNode then
                    local line = AcquireLine(self)
                    line:SetStartPoint("CENTER", fromNode)
                    line:SetEndPoint("CENTER", toNode)
                end
            end
        end
    end
end

-- Recomputes the active character and redraws the current sphere.
Refresh = function(self)
    local char = ns.GetActiveCharacter()
    self.char = char
    if not char then
        self.sphereLabel:SetText("No character")
        self.points:SetText("")
        for _, n in ipairs(self.content.nodePool) do n:Hide() end
        for _, l in ipairs(self.content.linePool) do l:Hide() end
        return
    end
    self.sheet = ns.CharacterSheet.Compute(char, ns.GetSystem())

    local trees = ns.GetSystem().perk_trees or {}
    if self.treeIndex > #trees then self.treeIndex = 1 end
    local tree = trees[self.treeIndex]
    self.sphereLabel:SetText(tree and tree.name or "No spheres")

    local invested, available = PT.Points(char)
    self.points:SetText("Points: " .. invested .. " / " .. available)
    RenderGraph(self)
end

-- Switches spheres by delta (wraps).
local function Cycle(self, delta)
    local trees = ns.GetSystem().perk_trees or {}
    if #trees == 0 then return end
    self.treeIndex = (self.treeIndex - 1 + delta) % #trees + 1
    SetMsg(self, "", false)
    Refresh(self)
end

local function MakeArrow(parent, text, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(26, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function BuildFrame()
    local f = UI.CreateWindow("ParchmentPerkFrame", {
        title = "Perks", width = 470, height = 520,
        minW = 380, minH = 360, maxW = 820, maxH = 1000, dbKey = "perkWindow",
    })
    f.treeIndex = 1

    -- Sphere cycler.
    f.prevBtn = MakeArrow(f, "<", function() Cycle(f, -1) end)
    f.prevBtn:SetPoint("TOPLEFT", 16, -44)
    f.nextBtn = MakeArrow(f, ">", function() Cycle(f, 1) end)
    f.nextBtn:SetPoint("TOPLEFT", 228, -44)
    f.sphereLabel = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.sphereLabel:SetPoint("LEFT", f.prevBtn, "RIGHT", 6, 0)
    f.sphereLabel:SetPoint("RIGHT", f.nextBtn, "LEFT", -6, 0)
    f.sphereLabel:SetJustifyH("CENTER")
    f.sphereLabel:SetTextColor(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3])

    f.points = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.points:SetPoint("TOPRIGHT", -16, -48)
    f.points:SetTextColor(UI.HEAD[1], UI.HEAD[2], UI.HEAD[3])

    -- Legend and message line.
    local legend = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    legend:SetPoint("TOPLEFT", 16, -72)
    legend:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    legend:SetJustifyH("LEFT")
    legend:SetTextColor(UI.DIM[1], UI.DIM[2], UI.DIM[3])
    legend:SetText("|cff66d966Taken|r  |cffc8a868Available|r  |cff999999Locked|r  |cffe67272Blocked|r"
        .. "   -   left-click select, right-click remove")

    f.msg = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.msg:SetPoint("TOPLEFT", 16, -90)
    f.msg:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.msg:SetJustifyH("LEFT")
    f.msg:SetWordWrap(false)

    -- Scrolling graph canvas.
    local scroll = CreateFrame("ScrollFrame", "ParchmentPerkScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -108)
    scroll:SetPoint("BOTTOMRIGHT", -32, 14)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    content.nodePool, content.linePool = {}, {}
    content.usedNodes, content.usedLines = 0, 0
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, w)
        content:SetWidth(w)
        if f.char then RenderGraph(f) end
    end)
    f.content = content

    return f
end

local function GetFrame()
    if not PerkTreeUI.frame then PerkTreeUI.frame = BuildFrame() end
    return PerkTreeUI.frame
end

function PerkTreeUI.Open()
    local f = GetFrame()
    SetMsg(f, "", false)
    Refresh(f)
    f:Show()
end

function PerkTreeUI.Toggle()
    local f = GetFrame()
    if f:IsShown() then f:Hide() else PerkTreeUI.Open() end
end

ns.RegisterModule("perks", PerkTreeUI.Toggle)
