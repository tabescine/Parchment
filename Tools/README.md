# Parchment Tools

Companion files for the Parchment addon. They live inside the addon folder
for convenience; WoW ignores everything not listed in the `.toc`, so they
ship harmlessly alongside the Lua.

## examples/

Parchment ships with **no ruleset** - it is a system-agnostic toolkit, and any
real ruleset belongs to its own author. These files are a small, original,
public-domain demo system ("Parchment Sample") that exists to document the
import format and let you try the UI. They are not a playable game.

The examples are deliberately exhaustive: **every feature of the system and
character formats appears at least once**, and the TOML files annotate each
one with a comment. To adopt your own ruleset, copy `sample.system.toml`, read
it top to bottom, and replace the contents.

- `sample.system.toml` - **the annotated format reference.** 3 attributes
  (Might/Wits/Spirit), modifier table, point-buy, accomplish targets (all
  three spec forms), a full `derived_stats` block, accomplishment table,
  level bonuses, hit-dice bands, skills, weapons (incl. a finesse-style
  attribute list), traits with bonuses *and* penalties, and two perk trees
  exercising every perk feature: effects, requirements (attribute / level /
  prerequisites / any-of / cross-tree exclusivity), multi-rank perks, every
  `choice` variant, tier colours, and a lattice layout. The effect vocabulary
  is documented in the file's footer.
- `sample.character.toml` - **the annotated character reference** (Wren
  Ashdown, level 5): trait/perk selections, perk choices, accomplished
  skills/weapons/saves, a homebrew perk demonstrating `effects`,
  `add_modifier`, `replaces`, and informational effect types, plus
  `attack_lines` and the `_key` field a single-character in-game import
  requires.
- `sample.system.json` / `sample.character.json` - the same data in JSON
  (generated from the TOML; JSON allows no comments, so the TOML files are
  the documented ones). Both formats import identically.

**Getting data into the game: use `/pmt import`.** Paste the whole file -
comments included - system first, then the character. The dialog
auto-detects JSON/TOML/Lua, validates against the schema, and only commits
on success; the same dialog's Export buttons produce the formats back. No
external tooling is needed.

## parchment_converter.py (optional)

You probably don't need this: `/pmt import` covers the normal workflow
entirely. The converter writes Lua SavedVariables files directly, which is
useful in exactly two situations:

- **File-based workflows** - you keep your ruleset in version control and
  want to deploy edits straight into the game's data files without an
  in-game paste each iteration.
- **Recovery** - a SavedVariables file is corrupted badly enough that the
  addon (and so its import dialog) cannot help; the converter rebuilds a
  clean one offline from your JSON/TOML source.

It converts a JSON or TOML system definition or character into a Lua
SavedVariables file you drop into your WoW account:

```
WTF/Account/<ACCOUNT>/SavedVariables/ParchmentSystemDB.lua
WTF/Account/<ACCOUNT>/SavedVariables/ParchmentCharDB.lua
```

Requires Python 3 (TOML input needs Python 3.11+ for the built-in `tomllib`,
or `pip install toml`). JSON input needs nothing extra.

### Usage

```sh
# System definition -> ParchmentSystemDB.lua
python parchment_converter.py examples/sample.system.json

# Character (single) -> ParchmentCharDB.lua, keyed by its "_key" field
python parchment_converter.py examples/sample.character.json
python parchment_converter.py examples/sample.character.toml

# Override output path / key / variable name
python parchment_converter.py examples/sample.character.json -o ParchmentCharDB.lua -k "Wren-Stormrage"

# --var overrides the Lua variable name in the output (rarely needed)
python parchment_converter.py examples/sample.system.json --var MySystemDB
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
3. Quit WoW first (SavedVariables are read at launch and written on logout -
   the game would overwrite your file), drop the `.lua` into the
   `SavedVariables/` folder above, and start the game.
4. In game, `/pmt validate` confirms the data loaded and references resolve.
