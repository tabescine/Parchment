-- Parchment - Sharing
--
-- Character-sheet sharing, TRP3-style: request another player's active
-- character on demand and view it read-only. A "View Parchment Sheet" entry is
-- added to player right-click menus; it whispers a request, the target's addon
-- replies with their active character, and we open the sheet in view mode.
--
-- Reads from: ns.Comm, ns.GetActiveCharacter, ns.CharacterSheetUI, ns.Print.
-- Exposes on ns.Sharing: Request.

local ADDON, ns = ...

ns.Sharing = ns.Sharing or {}
local S = ns.Sharing

-- Builds "Name-Realm" (or "Name" when realm is local/empty).
local function FullName(name, realm)
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- Requests a player's character sheet (they must have the addon to respond).
function S.Request(target)
    if not target or target == "" then return end
    local ok, err = ns.Comm.Whisper("REQ", {}, target)
    if ok then
        ns.Print("requested " .. target .. "'s character sheet...")
    else
        ns.Print(err or "could not send request.")
    end
end

-- Comm handlers: reply to requests with our active character; show characters
-- we receive.
if ns.Comm then
    ns.Comm.On("REQ", function(_, sender)
        local char = ns.GetActiveCharacter()
        if char and sender then
            ns.Comm.Whisper("CHAR", { char = char }, sender)
        end
    end)
    ns.Comm.On("CHAR", function(payload, sender)
        if type(payload) ~= "table" or type(payload.char) ~= "table" then return end
        ns.Print("received " .. (payload.char.name or "a character") .. " from " .. (sender or "?") .. ".")
        if ns.CharacterSheetUI then ns.CharacterSheetUI.ShowCharacter(payload.char, sender) end
    end)
end

-- Adds "View Parchment Sheet" to player right-click menus (modern Menu API).
local UNIT_MENUS = {
    "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER",
    "MENU_UNIT_FRIEND", "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
}

if Menu and Menu.ModifyMenu then
    for _, tag in ipairs(UNIT_MENUS) do
        Menu.ModifyMenu(tag, function(owner, root, contextData)
            local name = contextData and contextData.name
            local server = contextData and contextData.server
            if not name and contextData and contextData.unit and UnitIsPlayer(contextData.unit) then
                local n, r = UnitName(contextData.unit)
                name, server = n, r
            end
            if not name then return end
            local full = FullName(name, server)
            root:CreateButton("View Parchment Sheet", function() S.Request(full) end)
        end)
    end
end
