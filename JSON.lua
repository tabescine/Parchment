-- Parchment - JSON
--
-- A small, dependency-free JSON encoder/decoder for in-game import/export. WoW
-- addons cannot pull in external libraries, so this is self-contained Lua 5.1.
--
-- Conventions chosen to match the converter tool and the Parchment schema:
--   * A Lua sequence (1..n) encodes to a JSON array; any other table encodes to
--     a JSON object. An empty table encodes to [] (lists are the common case).
--   * decode returns JSON arrays as sequences and JSON objects with string keys.
--     Integer-looking keys are normalized to numbers by the import layer, not
--     here, so this stays a faithful generic JSON codec.
--
-- Reads from: nothing.
-- Exposes on ns.JSON: .encode(value, pretty), .decode(str) -> value | nil, err

local ADDON, ns = ...

ns.JSON = ns.JSON or {}
local JSON = ns.JSON

-- Encoding.

local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
    ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f',
}

-- Returns true (and the length) when t is a 1..n sequence.
local function IsArray(t)
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

-- Escapes a Lua string into a quoted JSON string.
local function EncodeString(s)
    return '"' .. s:gsub('[%z\1-\31"\\]', function(c)
        return ESCAPES[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function EncodeValue(v, indent, pretty)
    local t = type(v)
    if t == "string" then
        return EncodeString(v)
    elseif t == "number" then
        if v == math.floor(v) and v == v and v ~= math.huge and v ~= -math.huge then
            return string.format("%d", v)
        end
        return tostring(v)
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        if next(v) == nil then return "[]" end
        local nl, pad, padIn, sp = "", "", "", ""
        if pretty then
            nl, pad, padIn, sp = "\n", string.rep("  ", indent), string.rep("  ", indent + 1), " "
        end
        local isArr, n = IsArray(v)
        if isArr then
            local parts = {}
            for i = 1, n do parts[i] = padIn .. EncodeValue(v[i], indent + 1, pretty) end
            return "[" .. nl .. table.concat(parts, "," .. nl) .. nl .. pad .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = padIn .. EncodeString(tostring(k)) .. ":" .. sp
                .. EncodeValue(v[k], indent + 1, pretty)
        end
        return "{" .. nl .. table.concat(parts, "," .. nl) .. nl .. pad .. "}"
    end
    return "null"
end

-- Encodes a Lua value as JSON. pretty adds newlines and indentation.
function JSON.encode(value, pretty)
    return EncodeValue(value, 0, pretty)
end

-- Decoding.

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

-- Decodes a JSON string into a Lua value.
--
-- Returns the value on success, or nil plus an error message on failure.
function JSON.decode(str)
    local s = str
    local pos = 1
    local parseValue

    -- Errors report line:column - a byte offset is useless in a long paste.
    local function err(msg)
        local before = s:sub(1, math.max(pos - 1, 0))
        local _, lines = before:gsub("\n", "")
        local col = pos - (before:match("()\n[^\n]*$") or 0)
        error(msg .. " at line " .. (lines + 1) .. ", column " .. col, 0)
    end

    local function skip()
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then
                pos = pos + 1
            else
                break
            end
        end
    end

    local function parseString()
        pos = pos + 1
        local buf = {}
        while true do
            if pos > #s then err("unterminated string") end
            local c = s:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                break
            elseif c == "\\" then
                local e = s:sub(pos + 1, pos + 1)
                if e == '"' then buf[#buf + 1] = '"'
                elseif e == "\\" then buf[#buf + 1] = "\\"
                elseif e == "/" then buf[#buf + 1] = "/"
                elseif e == "b" then buf[#buf + 1] = "\b"
                elseif e == "f" then buf[#buf + 1] = "\f"
                elseif e == "n" then buf[#buf + 1] = "\n"
                elseif e == "r" then buf[#buf + 1] = "\r"
                elseif e == "t" then buf[#buf + 1] = "\t"
                elseif e == "u" then
                    local hex = s:sub(pos + 2, pos + 5)
                    if not hex:match("^%x%x%x%x$") then err("invalid \\u escape") end
                    buf[#buf + 1] = Utf8(tonumber(hex, 16))
                    pos = pos + 4
                else
                    err("invalid escape '\\" .. e .. "'")
                end
                pos = pos + 2
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    local function parseNumber()
        local numstr = s:match("^%-?%d+%.?%d*[eE][+%-]?%d+", pos)
            or s:match("^%-?%d+%.?%d*", pos)
        if not numstr or numstr == "" then err("invalid number") end
        pos = pos + #numstr
        return tonumber(numstr)
    end

    local function parseArray()
        pos = pos + 1
        local arr = {}
        skip()
        if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while true do
            arr[#arr + 1] = parseValue()
            skip()
            local c = s:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "]" then
                pos = pos + 1
                break
            else
                err("expected ',' or ']'")
            end
        end
        return arr
    end

    local function parseObject()
        pos = pos + 1
        local obj = {}
        skip()
        if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while true do
            skip()
            if s:sub(pos, pos) ~= '"' then err("expected string key") end
            local key = parseString()
            skip()
            if s:sub(pos, pos) ~= ":" then err("expected ':'") end
            pos = pos + 1
            obj[key] = parseValue()
            skip()
            local c = s:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "}" then
                pos = pos + 1
                break
            else
                err("expected ',' or '}'")
            end
        end
        return obj
    end

    parseValue = function()
        skip()
        if pos > #s then err("unexpected end of input") end
        local c = s:sub(pos, pos)
        if c == "{" then return parseObject()
        elseif c == "[" then return parseArray()
        elseif c == '"' then return parseString()
        elseif c == "t" then
            if s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true end
            err("invalid literal")
        elseif c == "f" then
            if s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
            err("invalid literal")
        elseif c == "n" then
            if s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil end
            err("invalid literal")
        else
            return parseNumber()
        end
    end

    local ok, result = pcall(parseValue)
    if not ok then return nil, tostring(result) end
    skip()
    if pos <= #s then return nil, "trailing characters at position " .. pos end
    return result
end
