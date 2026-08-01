-- Parchment - Spells (logic)
--
-- The rules engine behind the spellbook: which spells a character knows,
-- school exclusivity locks, cast-attribute rank gates, and validated
-- learn/unlearn. Spells do not chain like feat ranks; the gates are the
-- school lock (knowing a spell from a school's `opposed` partner), the cast
-- attribute's score against the pack's per-rank requirement, and a free pick
-- in the shared ledger (Modules/Picks.lua). Learning is enforced here, not
-- advisory.
--
-- A character's known spells live in char.spells as a flat id list, and the
-- chosen casting attribute in char.cast_attribute.
--
-- Reads from: ns.GetSpellPack, ns.Picks, ns.AttrName, ns.FindById.
--   The caller passes the computed sheet so attribute requirements check
--   final (post-trait) values, matching the other pickers.
-- Exposes on ns.Spells: Knows, Spell, School, SpellsOf, SchoolsKnown,
--   LockedBy, CastReq, WouldLock, CanLearn, Learn, Unlearn, Search.

local ADDON, ns = ...

ns.Spells = ns.Spells or {}
local Spells = ns.Spells

-- Returns the final (post-trait) value of an attribute from a computed sheet.
local function AttrFinal(sheet, attrId)
    for _, a in ipairs(sheet and sheet.attributes or {}) do
        if a.id == attrId then return a.final end
    end
    return 0
end

-- True when the character knows a spell id.
function Spells.Knows(char, spellId)
    for _, id in ipairs(type(char) == "table" and char.spells or {}) do
        if id == spellId then return true end
    end
    return false
end

-- Finds a spell record by id in a pack, or nil.
function Spells.Spell(pack, spellId)
    return ns.FindById(type(pack) == "table" and pack.spells or nil, spellId)
end

-- Finds a school record by id in a pack, or nil.
function Spells.School(pack, schoolId)
    return ns.FindById(type(pack) == "table" and pack.schools or nil, schoolId)
end

-- Returns the pack's spells for a school (all when schoolId is nil), sorted
-- by rank then pack order. Always a fresh list.
function Spells.SpellsOf(pack, schoolId)
    local out = {}
    for _, spell in ipairs(type(pack) == "table" and pack.spells or {}) do
        if type(spell) == "table" and (schoolId == nil or spell.school == schoolId) then
            out[#out + 1] = spell
        end
    end
    -- Stable sort: rank ascending, original position breaking ties.
    local pos = {}
    for i, s in ipairs(out) do pos[s] = i end
    table.sort(out, function(a, b)
        local ra, rb = tonumber(a.rank) or 0, tonumber(b.rank) or 0
        if ra ~= rb then return ra < rb end
        return pos[a] < pos[b]
    end)
    return out
end

-- The set of school ids the character knows at least one spell from.
function Spells.SchoolsKnown(char, pack)
    local known = {}
    for _, id in ipairs(type(char) == "table" and char.spells or {}) do
        local spell = Spells.Spell(pack, id)
        if spell and type(spell.school) == "string" then known[spell.school] = true end
    end
    return known
end

-- The school id LOCKING a school for this character (its `opposed` partner,
-- when the character knows spells from it), or nil when the school is open.
function Spells.LockedBy(char, pack, schoolId)
    local school = Spells.School(pack, schoolId)
    local opposed = type(school) == "table" and school.opposed
    if type(opposed) ~= "string" then return nil end
    if Spells.SchoolsKnown(char, pack)[opposed] then return opposed end
    return nil
end

-- The cast attribute score a spell rank requires (pack.rank_cast_req), or nil.
function Spells.CastReq(pack, rank)
    local reqs = type(pack) == "table" and pack.rank_cast_req
    local v = type(reqs) == "table" and reqs[tonumber(rank) or 0]
    if type(v) == "number" then return v end
    return nil
end

-- The school record that learning this spell would lock OUT (the school's
-- opposed partner, when this is the character's first spell of the school and
-- the partner is still open). The pickers confirm before this happens.
function Spells.WouldLock(char, pack, spell)
    local school = Spells.School(pack, spell.school)
    local opposed = type(school) == "table" and school.opposed
    if type(opposed) ~= "string" then return nil end
    if Spells.SchoolsKnown(char, pack)[spell.school] then return nil end
    return Spells.School(pack, opposed)
end

-- Checks whether a spell may be learned. Returns ok, reason.
function Spells.CanLearn(char, sheet, pack, spell)
    if Spells.Knows(char, spell.id) then return false, "Already known." end
    local lockedBy = Spells.LockedBy(char, pack, spell.school)
    if lockedBy then
        local locker = Spells.School(pack, lockedBy)
        return false, "School locked - you know " .. ((locker and locker.name) or lockedBy) .. " spells."
    end
    local req = Spells.CastReq(pack, spell.rank)
    if req then
        local candidates = type(pack.cast_attributes) == "table" and pack.cast_attributes or {}
        local castAttr = char.cast_attribute
        if not castAttr and #candidates > 0 then
            return false, "Choose a cast attribute first (character editor)."
        end
        if castAttr and AttrFinal(sheet, castAttr) < req then
            return false, "Requires " .. ns.AttrName(castAttr) .. " " .. req .. "."
        end
    end
    local spent, budget = ns.Picks.Points(char)
    if spent >= budget then
        return false, "No picks left (" .. spent .. " of " .. budget .. " spent)."
    end
    return true
end

-- Learns a spell. Returns ok, reason.
function Spells.Learn(char, sheet, pack, spell)
    local ok, reason = Spells.CanLearn(char, sheet, pack, spell)
    if not ok then return false, reason end
    char.spells = char.spells or {}
    char.spells[#char.spells + 1] = spell.id
    return true
end

-- Forgets a known spell (spells have no dependents, so any known one may
-- go). Returns ok, reason.
function Spells.Unlearn(char, spellId)
    for i, id in ipairs(type(char) == "table" and char.spells or {}) do
        if id == spellId then
            table.remove(char.spells, i)
            return true
        end
    end
    return false, "Not known."
end

-- Searches a pack's spells for a query (case-insensitive plain text over
-- name, description and school name, whitespace-trimmed). Returns a list of
-- spell records in rank-sorted order; an empty query matches none.
function Spells.Search(pack, query)
    query = tostring(query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local out = {}
    if query == "" then return out end
    for _, spell in ipairs(Spells.SpellsOf(pack)) do
        local school = Spells.School(pack, spell.school)
        local hay = ((spell.name or "") .. "\n" .. (spell.description or "")
            .. "\n" .. ((school and school.name) or spell.school or "")):lower()
        if hay:find(query, 1, true) then out[#out + 1] = spell end
    end
    return out
end
