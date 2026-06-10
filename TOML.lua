-- Parchment - TOML
--
-- A focused, dependency-free TOML encoder/decoder covering the subset the
-- Parchment schema needs: scalars, arrays (incl. multi-line and arrays of
-- inline tables), inline tables, [table] and [[array.of.tables]] headers,
-- dotted keys, comments, and basic/literal strings. It is not a full TOML 1.0
-- implementation (no dates, no multi-line literal strings on encode), but it
-- round-trips the system and character data exactly.
--
-- Decode keeps object keys as strings (the import layer normalizes integer-like
-- keys to numbers, matching the JSON path). Encode emits arrays of tables as
-- readable [[...]] blocks and leaf maps as inline tables.
--
-- Reads from: nothing.
-- Exposes on ns.TOML: .encode(value) -> string, .decode(str) -> value | nil,err

local ADDON, ns = ...

ns.TOML = ns.TOML or {}
local TOML = ns.TOML

-- Shared helpers.

-- True (and length) when t is a 1..n sequence.
local function IsSeq(t)
    if type(t) ~= "table" then return false end
    local count = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        count = count + 1
    end
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return true, count
end

-- True when v is a sequence whose every element is a (non-sequence) table.
local function IsArrayOfTables(v)
    local seq, n = IsSeq(v)
    if not seq or n == 0 then return false end
    for i = 1, n do
        local e = v[i]
        if type(e) ~= "table" or IsSeq(e) then return false end
    end
    return true
end

-- Encoding.

local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
    ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
}

local function EncodeString(s)
    return '"' .. s:gsub('[%z\1-\31"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function EncodeScalar(v)
    local t = type(v)
    if t == "string" then return EncodeString(v) end
    if t == "boolean" then return tostring(v) end
    if v == math.floor(v) and v == v and v ~= math.huge and v ~= -math.huge then
        return string.format("%d", v)
    end
    return tostring(v)
end

-- Renders a bare key, or a quoted key when it contains anything unusual.
local function EncodeKey(k)
    k = tostring(k)
    if k:match("^[%w_%-]+$") then return k end
    return EncodeString(k)
end

-- Renders any value inline (used in arrays, inline tables, and leaf maps).
local function EncodeInline(v)
    if type(v) ~= "table" then return EncodeScalar(v) end
    if next(v) == nil then return "[]" end
    local seq, n = IsSeq(v)
    if seq then
        local parts = {}
        for i = 1, n do parts[i] = EncodeInline(v[i]) end
        return "[ " .. table.concat(parts, ", ") .. " ]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = EncodeKey(k) .. " = " .. EncodeInline(v[k])
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

-- True when a map value should be promoted to its own [section]: it contains an
-- array of tables, or a nested map that itself needs a section.
local function NeedsSection(v)
    if type(v) ~= "table" or IsSeq(v) then return false end
    for _, val in pairs(v) do
        if IsArrayOfTables(val) then return true end
        if type(val) == "table" and not IsSeq(val) and NeedsSection(val) then return true end
    end
    return false
end

local function JoinPath(path, key)
    local k = EncodeKey(key)
    return path == "" and k or (path .. "." .. k)
end

-- Recursively writes a table as TOML lines into out, under the section `path`.
local function EncodeTable(out, tbl, path)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    -- Inline values: scalars, scalar/array arrays, and leaf maps.
    for _, k in ipairs(keys) do
        local v = tbl[k]
        local isSectionMap = type(v) == "table" and not IsSeq(v) and NeedsSection(v)
        if not IsArrayOfTables(v) and not isSectionMap then
            out[#out + 1] = EncodeKey(k) .. " = " .. EncodeInline(v)
        end
    end

    -- Nested maps that warrant their own section.
    for _, k in ipairs(keys) do
        local v = tbl[k]
        if type(v) == "table" and not IsSeq(v) and NeedsSection(v) then
            out[#out + 1] = ""
            out[#out + 1] = "[" .. JoinPath(path, k) .. "]"
            EncodeTable(out, v, JoinPath(path, k))
        end
    end

    -- Arrays of tables as [[...]] blocks.
    for _, k in ipairs(keys) do
        local v = tbl[k]
        if IsArrayOfTables(v) then
            for _, elem in ipairs(v) do
                out[#out + 1] = ""
                out[#out + 1] = "[[" .. JoinPath(path, k) .. "]]"
                EncodeTable(out, elem, JoinPath(path, k))
            end
        end
    end
end

-- Encodes a Lua table as a TOML document string.
function TOML.encode(value)
    if type(value) ~= "table" then return EncodeScalar(value) end
    local out = {}
    EncodeTable(out, value, "")
    return table.concat(out, "\n") .. "\n"
end

-- Decoding.

local UNESCAPE = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
    f = "\f", n = "\n", r = "\r", t = "\t",
}

-- Encodes a Unicode code point as UTF-8 (Lua 5.1 has no utf8 library).
local function Utf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    else
        return string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
end

-- Decodes a TOML document into a Lua table.
--
-- Returns the table on success, or nil plus an error message on failure.
function TOML.decode(str)
    local s = str
    local pos = 1
    local n = #s
    local root = {}
    local current = root
    local parseValue

    -- Errors report line:column - a byte offset is useless in a long paste.
    local function err(msg)
        local before = s:sub(1, math.max(pos - 1, 0))
        local _, lines = before:gsub("\n", "")
        local col = pos - (before:match("()\n[^\n]*$") or 0)
        error(msg .. " (line " .. (lines + 1) .. ", column " .. col .. ")", 0)
    end
    local function peek(o) return s:sub(pos + (o or 0), pos + (o or 0)) end
    local function isWS(c) return c == " " or c == "\t" end

    local function skipInlineWS()
        while pos <= n and isWS(peek()) do pos = pos + 1 end
    end

    -- Skips whitespace, newlines and comments (between statements).
    local function skipBlank()
        while pos <= n do
            local c = peek()
            if isWS(c) or c == "\n" or c == "\r" then
                pos = pos + 1
            elseif c == "#" then
                while pos <= n and peek() ~= "\n" do pos = pos + 1 end
            else
                break
            end
        end
    end

    local function parseBasicString()
        local triple = s:sub(pos, pos + 2) == '"""'
        pos = pos + (triple and 3 or 1)
        if triple and peek() == "\n" then pos = pos + 1 end
        local buf = {}
        while true do
            if pos > n then err("unterminated string") end
            if triple and s:sub(pos, pos + 2) == '"""' then pos = pos + 3; break end
            local c = peek()
            if not triple and c == '"' then pos = pos + 1; break
            elseif not triple and c == "\n" then err("unterminated string")
            elseif c == "\\" then
                local e = peek(1)
                if UNESCAPE[e] then
                    buf[#buf + 1] = UNESCAPE[e]; pos = pos + 2
                elseif e == "u" or e == "U" then
                    local len = (e == "u") and 4 or 8
                    local hex = s:sub(pos + 2, pos + 1 + len)
                    buf[#buf + 1] = Utf8(tonumber(hex, 16) or 0)
                    pos = pos + 2 + len
                elseif triple and (e == "\n" or e == " " or e == "\t" or e == "\r") then
                    -- line-ending backslash: trim following whitespace
                    pos = pos + 1
                    while pos <= n and peek():match("%s") do pos = pos + 1 end
                else
                    err("invalid escape")
                end
            else
                buf[#buf + 1] = c; pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    local function parseLiteralString()
        local triple = s:sub(pos, pos + 2) == "'''"
        pos = pos + (triple and 3 or 1)
        if triple and peek() == "\n" then pos = pos + 1 end
        local start = pos
        while true do
            if pos > n then err("unterminated literal string") end
            if triple then
                if s:sub(pos, pos + 2) == "'''" then break end
            elseif peek() == "'" then
                break
            elseif peek() == "\n" then
                err("unterminated literal string")
            end
            pos = pos + 1
        end
        local out = s:sub(start, pos - 1)
        pos = pos + (triple and 3 or 1)
        return out
    end

    local function parseNumber()
        local numstr = s:match("^[%+%-]?[%d_]+%.?[%d_]*[eE][%+%-]?[%d_]+", pos)
            or s:match("^[%+%-]?[%d_]+%.?[%d_]*", pos)
        if not numstr or numstr == "" then err("invalid value") end
        pos = pos + #numstr
        return tonumber((numstr:gsub("_", "")))
    end

    local function parseKey()
        skipInlineWS()
        local c = peek()
        if c == '"' then return parseBasicString() end
        if c == "'" then return parseLiteralString() end
        local start = pos
        while pos <= n and peek():match("[%w_%-]") do pos = pos + 1 end
        if pos == start then err("expected key") end
        return s:sub(start, pos - 1)
    end

    local function parseKeyPath()
        local path = {}
        while true do
            path[#path + 1] = parseKey()
            skipInlineWS()
            if peek() == "." then pos = pos + 1 else break end
        end
        return path
    end

    local function parseArray()
        pos = pos + 1
        local arr = {}
        while true do
            skipBlank()
            if peek() == "]" then pos = pos + 1; break end
            arr[#arr + 1] = parseValue()
            skipBlank()
            local c = peek()
            if c == "," then pos = pos + 1
            elseif c == "]" then pos = pos + 1; break
            else err("expected ',' or ']' in array") end
        end
        return arr
    end

    local function parseInlineTable()
        pos = pos + 1
        local t = {}
        skipInlineWS()
        if peek() == "}" then pos = pos + 1; return t end
        while true do
            local path = parseKeyPath()
            skipInlineWS()
            if peek() ~= "=" then err("expected '=' in inline table") end
            pos = pos + 1
            local node = t
            for i = 1, #path - 1 do
                node[path[i]] = node[path[i]] or {}
                node = node[path[i]]
            end
            node[path[#path]] = parseValue()
            skipInlineWS()
            local c = peek()
            if c == "," then pos = pos + 1; skipInlineWS()
            elseif c == "}" then pos = pos + 1; break
            else err("expected ',' or '}' in inline table") end
        end
        return t
    end

    parseValue = function()
        skipInlineWS()
        local c = peek()
        if c == '"' then return parseBasicString()
        elseif c == "'" then return parseLiteralString()
        elseif c == "[" then return parseArray()
        elseif c == "{" then return parseInlineTable()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        else return parseNumber() end
    end

    -- Descends one path segment for header navigation: into the last element of
    -- an array of tables, into an existing map, or a freshly created map.
    local function descend(tbl, key)
        local v = tbl[key]
        if v == nil then
            v = {}
            tbl[key] = v
            return v
        end
        if type(v) == "table" then
            local seq = IsSeq(v)
            if seq and #v > 0 and type(v[#v]) == "table" then return v[#v] end
            return v
        end
        err("key '" .. tostring(key) .. "' is not a table")
    end

    local function navParent(path)
        local t = root
        for i = 1, #path - 1 do t = descend(t, path[i]) end
        return t
    end

    -- Main statement loop.
    local function step()
        local c = peek()
        if c == "[" then
            if peek(1) == "[" then
                pos = pos + 2
                local path = parseKeyPath()
                skipInlineWS()
                if s:sub(pos, pos + 1) ~= "]]" then err("expected ']]'") end
                pos = pos + 2
                local parent = navParent(path)
                local key = path[#path]
                parent[key] = parent[key] or {}
                local elem = {}
                local arr = parent[key]
                arr[#arr + 1] = elem
                current = elem
            else
                pos = pos + 1
                local path = parseKeyPath()
                skipInlineWS()
                if peek() ~= "]" then err("expected ']'") end
                pos = pos + 1
                local parent = navParent(path)
                local key = path[#path]
                parent[key] = parent[key] or {}
                current = parent[key]
            end
        else
            local path = parseKeyPath()
            skipInlineWS()
            if peek() ~= "=" then err("expected '='") end
            pos = pos + 1
            local value = parseValue()
            local node = current
            for i = 1, #path - 1 do
                node[path[i]] = node[path[i]] or {}
                node = node[path[i]]
            end
            node[path[#path]] = value
        end

        -- Consume to end of line (allow a trailing comment).
        skipInlineWS()
        if pos <= n and peek() == "#" then
            while pos <= n and peek() ~= "\n" do pos = pos + 1 end
        end
    end

    local ok, parseErr = pcall(function()
        skipBlank()
        while pos <= n do
            step()
            skipBlank()
        end
    end)
    if not ok then return nil, tostring(parseErr) end
    return root
end
