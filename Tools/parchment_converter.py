#!/usr/bin/env python3
"""Parchment converter.

Reads a JSON or TOML file describing a Parchment *system definition*, a
*character* or an *item library* and emits a Lua SavedVariables file that can
be dropped straight into:

    WTF/Account/<ACCOUNT>/SavedVariables/ParchmentSystemDB.lua
    WTF/Account/<ACCOUNT>/SavedVariables/ParchmentCharDB.lua
    WTF/Account/<ACCOUNT>/SavedVariables/ParchmentItemDB.lua

The schema is the same one the addon uses (see Tools/examples/). The converter
is deliberately generic: it does not hardcode any ruleset's attributes or
skills, it just transcodes the structure. The one piece of schema knowledge it
applies is that object keys which look like integers (e.g. a level_bonuses map
keyed "3", "9") become Lua numeric keys, so the addon's numeric lookups work.

Usage:
    python parchment_converter.py INPUT [-o OUTPUT] [-t system|character|items|auto]
                                        [-k KEY] [--var VARNAME]

Examples:
    python parchment_converter.py examples/sample.system.json
    python parchment_converter.py examples/sample.character.json -o ParchmentCharDB.lua
    python parchment_converter.py examples/sample.items.json
"""

import argparse
import json
import os
import re
import sys

INT_KEY = re.compile(r"^-?\d+$")
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
LUA_RESERVED = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
    "then", "true", "until", "while",
}


def load_input(path):
    """Loads JSON or TOML based on file extension; returns a Python object."""
    ext = os.path.splitext(path)[1].lower()
    with open(path, "rb") as fh:
        raw = fh.read()
    if ext == ".toml":
        try:
            import tomllib  # Python 3.11+
            return tomllib.loads(raw.decode("utf-8"))
        except ModuleNotFoundError:
            try:
                import toml  # third-party fallback
            except ModuleNotFoundError:
                sys.exit("TOML input needs Python 3.11+ or the 'toml' package "
                         "(pip install toml).")
            return toml.loads(raw.decode("utf-8"))
    return json.loads(raw.decode("utf-8"))


def lua_string(s):
    """Escapes a Python string into a double-quoted Lua string literal."""
    out = (s.replace("\\", "\\\\").replace('"', '\\"')
            .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t"))
    return '"' + out + '"'


def lua_key(key):
    """Renders a dict key as a Lua table key prefix, e.g. `name = ` or `[3] = `.

    Integer-looking string keys become numeric keys so numeric lookups work.
    """
    k = str(key)
    if INT_KEY.match(k):
        return "[%s] = " % k
    if IDENTIFIER.match(k) and k not in LUA_RESERVED:
        return "%s = " % k
    return "[%s] = " % lua_string(k)


def is_array(value):
    """True for a Python list (rendered as a Lua sequence)."""
    return isinstance(value, list)


def serialize(value, indent=0):
    """Recursively renders a Python value as pretty-printed Lua."""
    pad = "    " * indent
    inner = "    " * (indent + 1)

    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "nil"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return ("%d" % value) if value.is_integer() else repr(value)
    if isinstance(value, str):
        return lua_string(value)

    if is_array(value):
        if not value:
            return "{}"
        items = [inner + serialize(v, indent + 1) for v in value]
        return "{\n" + ",\n".join(items) + ",\n" + pad + "}"

    if isinstance(value, dict):
        if not value:
            return "{}"
        # Stable order: numeric keys first (numerically), then the rest sorted.
        keys = list(value.keys())
        keys.sort(key=lambda k: (0, int(k)) if INT_KEY.match(str(k)) else (1, str(k)))
        items = [inner + lua_key(k) + serialize(value[k], indent + 1) for k in keys]
        return "{\n" + ",\n".join(items) + ",\n" + pad + "}"

    sys.exit("cannot serialize value of type %s" % type(value).__name__)


def strip_meta(data):
    """Returns a shallow copy of a dict without keys starting with '_'."""
    return {k: v for k, v in data.items() if not str(k).startswith("_")}


def detect_type(data):
    """Guesses 'system', 'character' or 'items' from the structure.

    Mirrors the addon's own detection order (Modules/ImportExport.lua): `items`
    is checked last, so it only marks a library on a file that is nothing else.
    """
    if "characters" in data:
        return "character"
    if "system_name" in data or "perk_trees" in data or "modifier_table" in data:
        return "system"
    if "name" in data and ("attributes" in data or "level" in data):
        return "character"
    if "items" in data:
        return "items"
    sys.exit("could not auto-detect type; pass -t system, -t character or -t items.")


def build_system(data):
    """Returns (varname, lua_table_value) for a system definition."""
    return "ParchmentSystemDB", strip_meta(data)


def build_character(data, key_override):
    """Returns (varname, lua_table_value) for a character file.

    Accepts either a full DB ({"characters": {...}}) or a single character
    object carrying a "_key" (or supplied via -k / the input filename).
    """
    if "characters" in data:
        return "ParchmentCharDB", strip_meta(data)
    key = key_override or data.get("_key")
    if not key:
        sys.exit("character has no key; add a \"_key\" field or pass -k KEY.")
    return "ParchmentCharDB", {"characters": {key: strip_meta(data)}}


def build_items(data):
    """Returns (varname, lua_table_value) for an item library.

    The library is stored under an `items` key ({"items": {id: item}}), the
    same wrapper the in-game export writes, so a file round-trips between the
    converter and /pmt import unchanged.
    """
    return "ParchmentItemDB", strip_meta(data)


def main():
    parser = argparse.ArgumentParser(description="Convert JSON/TOML to Parchment SavedVariables Lua.")
    parser.add_argument("input", help="input .json or .toml file")
    parser.add_argument("-o", "--output", help="output .lua file (default: <VARNAME>.lua)")
    parser.add_argument("-t", "--type", choices=["system", "character", "items", "auto"],
                        default="auto")
    parser.add_argument("-k", "--key", help="SavedVariables key for a single character")
    parser.add_argument("--var", help="override the global variable name")
    args = parser.parse_args()

    data = load_input(args.input)
    if not isinstance(data, dict):
        sys.exit("top-level value must be an object/table.")

    kind = args.type if args.type != "auto" else detect_type(data)
    if kind == "system":
        varname, table = build_system(data)
    elif kind == "items":
        varname, table = build_items(data)
    else:
        varname, table = build_character(data, args.key)
    if args.var:
        varname = args.var

    body = "%s = %s\n" % (varname, serialize(table, 0))
    header = ("-- Generated by parchment_converter.py from %s\n"
              "-- Drop into WTF/Account/<ACCOUNT>/SavedVariables/%s.lua\n"
              % (os.path.basename(args.input), varname))
    output = header + body

    out_path = args.output or (varname + ".lua")
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(output)
    print("wrote %s (%s, %d bytes)" % (out_path, varname, len(output)))


if __name__ == "__main__":
    main()
