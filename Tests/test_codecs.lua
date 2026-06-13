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
