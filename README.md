# Parchment

A system-agnostic tabletop-RPG toolkit for World of Warcraft. Run your own
TTRPG campaign inside the game client: character sheets, an initiative
tracker, perk trees, dice rolls, and DM-to-player syncing - all driven by a
ruleset *you* import, not one the addon dictates.

Parchment ships with **no game system**. You provide one as JSON or TOML
(attributes, skills, perks, traits, modifier tables), import it in-game, and
every window - sheet math included - adapts to it.

## Features

- **Character sheet** - fully computed from your system's rules: attributes,
  modifiers, skills, saves, weapons, AC, HP/Mana, movement. Hover any total
  for a breakdown of where each bonus comes from. Editable current HP/Mana
  and Temp HP.
- **Character creation** - a guided wizard (`/pmt new`: Identity →
  Attributes → Traits → Proficiencies → Review) and a freeform point-buy
  editor (`/pmt edit`) with live warnings, plus level-up support.
- **Perk trees** - a viewer/builder for your system's perk spheres with
  prerequisites, exclusivity, ranks, perk-driven choices, and homebrew perks.
- **Initiative tracker** - sort, rounds, turn pointer, roll-or-add; the DM
  can sync the order to the group and players can submit their own rolls.
- **Party tools** - live party overview (HP/Mana/AC), view another player's
  sheet on demand, dice rolls that are either private or party-visible.
- **DM sharing with consent** - a DM can broadcast the active system to the
  group; receivers are prompted before anything replaces their own setup, and
  every received system is kept in a local library (`/pmt systems`). Sync
  requires compatible addon versions - mismatched messages are ignored with a
  chat notice saying who needs to update.
- **Import/export** - paste JSON or TOML in-game (comments and all), export
  back out the same way. No external tooling needed; an optional offline
  converter lives in `Tools/` for file-based workflows and recovery.

## Installation

1. Download or clone this repository.
2. Copy the `Parchment` folder into your AddOns directory:
   `World of Warcraft/_retail_/Interface/AddOns/`
3. Restart the client (or `/reload`), and enable Parchment in the AddOns list.

## Quick start

1. `/pmt import` - paste a system or character definition (JSON or TOML). A small
   public-domain sample lives in `Tools/examples/` if you just want to try it.
2. `/pmt new` - create a character with the guided wizard.
3. `/pmt sheet` - open your character sheet.
4. Playing with a group? The DM toggles `/pmt dm` and uses `/pmt share` to
   send the system to everyone.

Type `/pmt` (or `/parchment`) for the full command list:

| Command | Action |
|---|---|
| `/pmt sheet` | Open the character sheet |
| `/pmt init` | Open the initiative tracker |
| `/pmt perks` | Open the perk tree viewer |
| `/pmt new` | Create a character (guided wizard) |
| `/pmt edit` | Open the character editor |
| `/pmt import` | Open the import/export dialog |
| `/pmt config` | Open settings |
| `/pmt dm` | Toggle DM mode (broadcast vs receive sync) |
| `/pmt share` | DM: send your system to the group |
| `/pmt systems` | Choose the active system (`delete` to remove one) |
| `/pmt rolls` | Toggle public (party-visible) dice rolls |
| `/pmt party` | Live party overview (HP/Mana/AC) |
| `/pmt view <name>` | View another player's character sheet |
| `/pmt cached` | Browse cached sheets (`clear` to wipe) |
| `/pmt minimap` | Toggle the minimap button |
| `/pmt save` | Write all data to disk (reloads the UI) |
| `/pmt who` | List known characters |
| `/pmt validate` | Check the loaded system and characters |

## A note on saving

WoW only writes addon data to disk on logout or a UI reload. Parchment keeps
everything in memory as you play; use `/pmt save` (or just `/reload`) when you
want your characters and systems safely on disk - especially before a crash-y
raid night.

## Bring your own system

A system definition declares your ruleset as data: attributes, a modifier
table, skills, saving throws, weapons, racial/origin traits, perk trees, and
an optional `derived_stats` block that tells Parchment which attributes drive
HP, mana, AC, movement, and so on. Nothing is hard-coded - see
`Tools/examples/sample.system.toml` for the fully annotated format reference
(every feature appears once, with a comment) and `sample.character.toml` for
its character-side counterpart. Import both with `/pmt import`; `Tools/`
also holds an optional offline converter for version-controlled rulesets
and SavedVariables recovery.

## Development

Parchment keeps its rules logic free of WoW APIs, so the data layer, codecs,
schema, and the character/perk engines run - and are tested - under plain
Lua 5.1, no game client or dependencies needed:

```sh
lua5.1 Tests/run.lua
```

The suite covers the data API and migrations, schema validation, the
JSON/TOML codecs, sheet computation, the perk engine, comm version gating,
the context-menu integration, and an end-to-end import of the sample files
(whose documented numbers double as regression expectations). CI
(`.github/workflows/ci.yml`) runs a syntax check plus this suite. UI code
(frames, menus beyond their logic) is exercised in-game.

## License

Parchment is released under the [MIT License](LICENSE).

Bundled third-party libraries in `Libs/` (Ace3, LibStub, CallbackHandler,
LibDataBroker, LibDBIcon) remain under their own licenses - see each library's
directory.

The sample system and character in `Tools/examples/` are original,
public-domain demo data: use them however you like.
