# Libs

Vendored libraries, loaded via `embeds.xml` before any Parchment Lua runs. Do
not edit these by hand; update them from upstream.

## Bundled now

- **Ace3** (`Ace3/`) - includes LibStub and CallbackHandler-1.0. Parchment uses
  AceAddon, AceConsole, AceEvent, AceTimer, AceDB, AceComm and AceSerializer.
  Source: https://github.com/WoWUIDev/Ace3
- **LibDataBroker-1.1** (`LibDataBroker-1.1/`) - data broker object for the
  minimap/launcher button. Source: https://github.com/tekkub/libdatabroker-1-1
- **LibDBIcon-1.0** (`LibDBIcon-1.0/`) - the minimap button itself, on top of the
  LibDataBroker object. Single file pulled from WoWAce
  (https://repos.wowace.com/wow/libdbicon-1-0/trunk).

## Not used

- **LibSharedMedia-3.0** - shared font/texture registry. Not needed: Parchment
  uses standard WoW fonts and textures.
