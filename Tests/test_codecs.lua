-- JSON.lua and TOML.lua: decoding features the import path relies on, and
-- encode/decode round-trips (the export path).
local T = dofile((TEST_ROOT or "") .. "Tests/wow_stubs.lua")
local ns = {}
T.load(ns, "JSON.lua")
T.load(ns, "TOML.lua")

-- TOML decoding: comments, scalars, arrays, inline tables, [table],
-- [[array-of-tables]], nested dotted headers - everything the samples use.
-- ([==[ ]==] because plain [[ ]] cannot contain the [[records]] headers)
local toml = [==[
# full-line comment
name = "Demo"            # trailing comment
count = 3
ratio = 0.5
flag = true
list = ["a", "b"]
mixed = { base = 2, attribute = "wits" }

[section]
key = "value"

[[records]]
id = "r1"
nums = [1, 2, 3]

[[records]]
id = "r2"
[records.choice]
kind = "skill"

[[records.effects]]
type = "skill"
value = -1
]==]
local data, err = ns.TOML.decode(toml)
assert(data, tostring(err))
T.assert_deepeq(data, {
    name = "Demo", count = 3, ratio = 0.5, flag = true,
    list = { "a", "b" },
    mixed = { base = 2, attribute = "wits" },
    section = { key = "value" },
    records = {
        { id = "r1", nums = { 1, 2, 3 } },
        { id = "r2", choice = { kind = "skill" }, effects = { { type = "skill", value = -1 } } },
    },
}, "toml")

-- A parse error reports rather than throws.
local bad, badErr = ns.TOML.decode("= broken")
assert(bad == nil and badErr ~= nil)

-- A malformed number (the digit class matches a bare "_") must REJECT, not parse
-- to nil and silently drop the key / compact the array. Same contract as JSON null.
local numBad, numErr = ns.TOML.decode("x = _\ny = 2")
assert(numBad == nil and numErr ~= nil, "bare-underscore number must be rejected")
local arrBad = ns.TOML.decode("a = [ _, 1 ]")
assert(arrBad == nil, "bare-underscore array element must be rejected, not compacted")
-- Well-formed underscore separators still parse.
local numOk = ns.TOML.decode("x = 1_000")
assert(numOk and numOk.x == 1000, "underscore digit separators must still work")

-- JSON decoding, including escapes and nesting. The codec's null contract is
-- now REJECT (not silently drop) - dropping would corrupt arrays/objects, and
-- Parchment data never contains null. See test_codec_fidelity for the full set.
local jdata, jerr = ns.JSON.decode([[{"a": [1, 2.5, true, "x\"y"], "n": {"k": -3}}]])
assert(jdata, tostring(jerr))
assert(jdata.a[1] == 1 and jdata.a[2] == 2.5 and jdata.a[3] == true)
assert(jdata.a[4] == 'x"y' and #jdata.a == 4)
assert(jdata.n.k == -3)
local jnull, jnullErr = ns.JSON.decode('[1, null, 2]')
assert(jnull == nil and jnullErr ~= nil, "null must be rejected, not dropped")
local jbad, jbadErr = ns.JSON.decode("{nope")
assert(jbad == nil and jbadErr ~= nil)

-- Round-trips: decode(encode(x)) must reproduce x for export-shaped data.
local sample = {
    system_name = "RT", version = "1.0",
    attributes = { { id = "a", name = "Alpha" } },
    modifier_table = { -1, 0, 1 },
    point_buy = { total = 15, base = 1 },
    nested = { deep = { list = { "x", "y" }, flag = false, num = 2.5 } },
}
local viaJson = ns.JSON.decode(ns.JSON.encode(sample, true))
T.assert_deepeq(sample, viaJson, "json roundtrip")
local viaToml = ns.TOML.decode(ns.TOML.encode(sample))
T.assert_deepeq(sample, viaToml, "toml roundtrip")

-- UTF-16 surrogate pairs in \u escapes combine into ONE UTF-8 character
-- (Python's json.dumps escapes every emoji/astral char this way); a lone or
-- misordered half is rejected. TOML reaches astral chars via 8-digit \U, and
-- refuses surrogate halves / out-of-range escapes outright.
local EMOJI = "\240\159\152\128"  -- U+1F600 as UTF-8
local surr = ns.JSON.decode('["\\ud83d\\ude00"]')
assert(surr and surr[1] == EMOJI, "surrogate pair must decode to one UTF-8 char, not CESU-8")
local lone, loneErr = ns.JSON.decode('["\\ud83d"]')
assert(lone == nil and tostring(loneErr):find("surrogate"), "a lone high surrogate must be rejected")
local swap = ns.JSON.decode('["\\ude00\\ud83d"]')
assert(swap == nil, "a low-first surrogate pair must be rejected")
assert(ns.JSON.decode(ns.JSON.encode({ EMOJI }))[1] == EMOJI, "raw UTF-8 must round-trip")
local astral = ns.TOML.decode([[x = "\U0001F600"]])
assert(astral and astral.x == EMOJI, "TOML \\U astral escape must produce 4-byte UTF-8")
local tsurr = ns.TOML.decode([[x = "\ud800"]])
assert(tsurr == nil, "TOML must reject surrogate-half escapes (not Unicode scalar values)")
local trange = ns.TOML.decode([[x = "\U00110000"]])
assert(trange == nil, "TOML must reject escapes beyond U+10FFFF")

-- Non-finite numbers: encode refuses them loudly (they have no valid document
-- representation), and decode rejects literals that overflow to inf.
assert(not pcall(ns.JSON.encode, 0 / 0), "JSON.encode must error on NaN")
assert(not pcall(ns.JSON.encode, math.huge), "JSON.encode must error on inf")
assert(not pcall(ns.TOML.encode, { x = 1 / 0 }), "TOML.encode must error on inf")
local jinf, jinfErr = ns.JSON.decode("[1e999]")
assert(jinf == nil and tostring(jinfErr):find("range"), "JSON must reject overflowing literals")
local tinf = ns.TOML.decode("x = 1e999")
assert(tinf == nil, "TOML must reject overflowing literals")

-- Integers keep printing as plain digits (no decimal point, no %d - whose
-- C-long cast is 32-bit on Windows) across the whole exact-double range.
assert(ns.JSON.encode(3) == "3")
assert(ns.JSON.encode(2 ^ 40 + 1) == "1099511627777", "past-2^31 integers must print exactly")
assert(ns.TOML.encode({ n = 2 ^ 40 + 1 }):find("1099511627777", 1, true))
