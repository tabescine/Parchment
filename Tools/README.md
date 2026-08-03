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
  (Might/Wits/Spirit), modifier table, point-buy, the `progression` pick
  budget feats/spells/homebrew spend from, accomplish targets (all three
  spec forms), a full `derived_stats` block, accomplishment table, level
  bonuses, hit-dice bands, skills, weapons (incl. a finesse-style attribute
  list), spell schools, and traits with bonuses *and* penalties. The shared
  effect vocabulary (traits, pack feats/spells, homebrew) is documented in
  the file's footer.
- `sample.feats.toml` - **the annotated feats-pack reference.** A feats pack
  is a standalone import paired to a system via `for_system`: ability lines,
  each a ladder of ranks where rank position is the prerequisite chain.
  Demonstrates rank effects, kinds, and the display metadata.
- `sample.spells.toml` - **the annotated spells-pack reference**: schools
  plus a flat spell list, each spell rank-gated against the character's
  casting attribute (`rank_cast_req`) rather than by other spells.
- `sample.character.toml` - **the annotated character reference** (Wren
  Ashdown, level 5): trait selections, feat picks (`line id = rank`), known
  spells and `cast_attribute`, accomplished skills/weapons/saves, a homebrew
  feat demonstrating `effects`, `add_modifier` and informational effect
  types, plus the `_key` field a single-character in-game import requires.
- `sample.items.toml` - **the annotated item-library reference**: the three
  items Wren's inventory references - a weapon linked to the system's "bow"
  with a `+1` attack bonus, a piece of equipment worth `+1` AC while worn, and
  a gear item with a counter. The library is global (one per install, shared by
  every character) and characters only reference it, so importing this makes
  Wren's three inventory rows resolve.
- `sample.*.json` - the same data in JSON (generated from the TOML; JSON
  allows no comments, so the TOML files are the documented ones). Both
  formats import identically.

**Getting data into the game: use `/pmt import`.** Paste the whole file -
comments included - system first, then the packs, then the items, then the
character. The
dialog auto-detects JSON/TOML/Lua and what the paste holds, validates against
the schema, and only commits on success; the same dialog's Export buttons
produce the formats back. No external tooling is needed. Item and character
imports MERGE by key, so a paste never wipes what it does not mention.

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

It converts a JSON or TOML system definition, character, item library or
feats/spells pack into a Lua SavedVariables file you drop into your WoW
account:

```
WTF/Account/<ACCOUNT>/SavedVariables/ParchmentSystemDB.lua
WTF/Account/<ACCOUNT>/SavedVariables/ParchmentCharDB.lua
WTF/Account/<ACCOUNT>/SavedVariables/ParchmentItemDB.lua
WTF/Account/<ACCOUNT>/SavedVariables/ParchmentPackDB.lua
```

Note that feats and spells packs share `ParchmentPackDB`: converting one pack
kind writes a file without the other. Prefer `/pmt import` when you need both,
or convert both and combine the `feats` and `spells` tables by hand.

Requires Python 3 (TOML input needs Python 3.11+ for the built-in `tomllib`,
or `pip install toml`). JSON input needs nothing extra.

### Usage

```sh
# System definition -> ParchmentSystemDB.lua
python parchment_converter.py examples/sample.system.json

# Character (single) -> ParchmentCharDB.lua, keyed by its "_key" field
python parchment_converter.py examples/sample.character.json
python parchment_converter.py examples/sample.character.toml

# Item library -> ParchmentItemDB.lua
python parchment_converter.py examples/sample.items.toml

# Feats or spells pack -> ParchmentPackDB.lua (one kind per file - see above)
python parchment_converter.py examples/sample.feats.json
python parchment_converter.py examples/sample.spells.toml

# Override output path / key / variable name
python parchment_converter.py examples/sample.character.json -o ParchmentCharDB.lua -k "Wren-Stormrage"

# --var overrides the Lua variable name in the output (rarely needed)
python parchment_converter.py examples/sample.system.json --var MySystemDB
```

Type is auto-detected, mirroring the addon's own sniffing: an explicit `kind`
field wins; a file with `system_name`/`modifier_table` is a system; one with
`pack_name` plus `lines` or `spells` is a feats or spells pack; one with
`name`/`attributes` is a character; one whose only marker is `items` is an
item library. Force it with `-t system|character|items|feats|spells`.

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
