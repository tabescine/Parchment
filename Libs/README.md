# Libs

Vendored libraries, loaded via `embeds.xml` before any Parchment Lua runs. Do
not edit these by hand; update them from upstream.

## Bundled now

- **Ace3** (`Ace3/`) - includes LibStub and CallbackHandler-1.0. Parchment uses
  AceAddon, AceConsole, AceEvent, AceTimer, AceDB, AceComm and AceSerializer.
  Source: https://github.com/WoWUIDev/Ace3
- **LibDataBroker-1.1** (`LibDataBroker-1.1/`) - data broker object for the
  minimap/launcher button. Source: https://github.com/tekkub/libdatabroker-1-1

## Deferred (polish phase)

These back the minimap button and custom fonts/textures (priority 8). They live
on WoWAce/CurseForge rather than under a stable GitHub name, so drop them in when
that work item starts and add them to `embeds.xml`:

- **LibDBIcon-1.0** - minimap button, sits on top of the LibDataBroker object.
- **LibSharedMedia-3.0** - shared font/texture registry (only if custom media is
  added).
