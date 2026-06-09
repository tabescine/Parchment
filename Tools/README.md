# Parchment Tools

Companion tooling for the Parchment addon. These files live inside the addon
folder for convenience; WoW ignores everything not listed in the `.toc`, so they
ship harmlessly alongside the Lua.

## parchment_converter.py

Converts a JSON or TOML system definition or character into a Lua
SavedVariables file you can drop straight into your WoW account:

```
WTF/Account/<ACCOUNT>/SavedVariables/ParchmentSystemDB.lua
WTF/Account/<ACCOUNT>/SavedVariables/ParchmentCharDB.lua
```

Requires Python 3 (TOML input needs Python 3.11+ for the built-in `tomllib`, or
`pip install toml`). JSON input needs nothing extra.

### Usage

```sh
# System definition -> ParchmentSystemDB.lua
python parchment_converter.py examples/sample.system.json

# Character (single) -> ParchmentCharDB.lua, keyed by its "_key" field
python parchment_converter.py examples/tabescine.character.json
python parchment_converter.py examples/tabescine.character.toml

# Override output path / key / variable name
python parchment_converter.py examples/tabescine.character.json -o ParchmentCharDB.lua -k "Tabescine-Stormrage"
```

Type is auto-detected (a file with `system_name`/`perk_trees` is a system; one
with `name`/`attributes` is a character). Force it with `-t system|character`.

### How the formats map

- A JSON/TOML **array** becomes a Lua sequence.
- A JSON/TOML **object/table** becomes a Lua table. Keys that look like integers
  (e.g. a `level_bonuses` map keyed `"3"`, `"9"`) become Lua **numeric** keys so
  the addon's numeric lookups (modifier tables, level bonuses) keep working.
- Top-level keys starting with `_` (like `_key`) are converter metadata and are
  stripped from the output. `_key` sets the character's SavedVariables key.

### Workflow

1. Edit a file under `examples/` (or copy one as a starting point).
2. Run the converter to produce the `.lua` file.
3. Quit WoW (SavedVariables are only read at launch), drop the `.lua` into the
   `SavedVariables/` folder above, and start the game.
4. In game, `/pmt validate` confirms the data loaded and references resolve.

## examples/

- `sample.system.json` - the full "a homebrew system" system definition,
  generated from the addon's bundled default so it always matches what ships.
- `tabescine.character.json` - the example character, JSON form.
- `tabescine.character.toml` - the same character, TOML form (hand-editable,
  with comments). Demonstrates the homebrew ability-path `effects` that make
  example skill bonuses compute automatically.
