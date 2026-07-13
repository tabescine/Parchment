-- Codec fidelity regression suite. Originally written test-first against known
-- corruption bugs (big-int %d overflow, %.14g float loss, silent null drops,
-- unbounded nesting, NUL-injecting \u escapes); those fixes have all landed, so
-- every case here is EXPECTED TO PASS and pins the contract against regression.
--
-- Where the contract leaves a design choice open (sentinel vs. clean rejection),
-- the assertion accepts EITHER correct outcome - it only fails on silent
-- corruption. The in-comment "Today ..." notes describe the historical bug each
-- case was written against, not current behaviour.
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
local ns = {}
T.load(ns, "JSON.lua")
T.load(ns, "TOML.lua")
local JSON, TOML = ns.JSON, ns.TOML

-- Big integers (> 2^53) must survive a round-trip. Today the encoder takes the
-- string.format("%d", v) branch, which overflows the C long and emits garbage
-- (1e19 -> -9223372036854775808). Fix: %.17g past the safe-integer range.
-- (JSON.lua:53, TOML.lua:66)
local BIG = 1e19
local okJ, encJ = pcall(JSON.encode, BIG)
assert(okJ, "JSON.encode errored on a large integer: " .. tostring(encJ))
assert(JSON.decode(encJ) == BIG,
    "JSON big int did not round-trip: got " .. tostring(JSON.decode(encJ)))
local okT, encT = pcall(TOML.encode, { n = BIG })
assert(okT, "TOML.encode errored on a large integer: " .. tostring(encT))
assert(TOML.decode(encT).n == BIG,
    "TOML big int did not round-trip: got " .. tostring(TOML.decode(encT).n))

-- Inexact floats must round-trip exactly. Today the encoder falls back to
-- tostring(v), which is %.14g in Lua 5.1 and drops the low bits of 1/3. Fix:
-- emit non-integers via %.17g. (JSON.lua:56, TOML.lua:69)
local THIRD = 1 / 3
assert(JSON.decode(JSON.encode(THIRD)) == THIRD,
    "JSON float lost precision: " .. string.format("%.17g", JSON.decode(JSON.encode(THIRD))))
assert(TOML.decode(TOML.encode({ r = THIRD })).r == THIRD,
    "TOML float lost precision: "
    .. string.format("%.17g", TOML.decode(TOML.encode({ r = THIRD })).r))

-- JSON null must not be silently dropped. Today `null` decodes to nil, so it
-- vanishes from arrays (compacting them) and from objects (key disappears).
-- Fix: preserve as a sentinel OR reject with a clear error - either is correct,
-- silent loss is not. (JSON.lua:238)
local arr, arrErr = JSON.decode("[1, null, 2]")
if arr then
    assert(#arr == 3, "JSON null was silently dropped from an array (length compacted to "
        .. #arr .. ")")
else
    assert(arrErr ~= nil, "a rejected null array must carry an error message")
end
local obj, objErr = JSON.decode('{"a": null, "b": 2}')
if obj then
    assert(obj.b == 2, "decode mangled the sibling key")
    assert(obj.a ~= nil, "JSON null was silently dropped from an object (key 'a' vanished)")
else
    assert(objErr ~= nil, "a rejected null object must carry an error message")
end

-- Deeply nested input must hit a controlled depth limit, not run the parser off
-- the C stack. Today there is no limit: moderate depth parses, and extreme depth
-- raises a raw "stack overflow". Fix: a depth counter that errors cleanly.
-- (JSON.lua:224, TOML.lua:344)
local function mentionsDepth(e)
    e = tostring(e):lower()
    return e:find("deep") or e:find("nest")
end
local jDeep, jDeepErr = JSON.decode(string.rep("[", 500) .. string.rep("]", 500))
assert(jDeep == nil, "JSON accepted pathologically nested input instead of rejecting it")
assert(mentionsDepth(jDeepErr),
    "expected a controlled nesting-depth error from JSON, got: " .. tostring(jDeepErr))
local tDeep, tDeepErr = TOML.decode("x = " .. string.rep("[", 500) .. string.rep("]", 500))
assert(tDeep == nil, "TOML accepted pathologically nested input instead of rejecting it")
assert(mentionsDepth(tDeepErr),
    "expected a controlled nesting-depth error from TOML, got: " .. tostring(tDeepErr))

-- A malformed TOML \u escape must be rejected, not silently turned into a NUL
-- byte. Today tonumber(hex,16) or 0 injects "\0" for non-hex digits. Fix:
-- validate the escape length/charset and error. (TOML.lua:234-237)
local uStr, uErr = TOML.decode([[x = "\uZZZZ"]])
if uStr then
    assert(not uStr.x:find("\0"),
        "an invalid TOML \\u escape injected a NUL byte instead of erroring")
else
    assert(uErr ~= nil, "a rejected \\u escape must carry an error message")
end
