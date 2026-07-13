# Libs

Vendored libraries, loaded via `embeds.xml` before any Parchment Lua runs. Do
not edit these by hand; update them from upstream.

These libraries are **not** covered by Parchment's MIT license; each remains
under its own terms, noted below.

- **Ace3** (`Ace3/`) - includes LibStub and CallbackHandler-1.0. Parchment uses
  AceAddon, AceConsole, AceEvent, AceTimer, AceDB, AceComm and AceSerializer.
  Source: https://github.com/WoWUIDev/Ace3
  License: Ace3 Development Team BSD-style license (`Ace3/LICENSE.txt`).
- **LibDataBroker-1.1** (`LibDataBroker-1.1/`) - data broker object for the
  minimap/launcher button. Source: https://github.com/tekkub/libdatabroker-1-1
  License: none published upstream (no license file or header exists). It was
  released in 2008 expressly as an embeddable interface standard and is
  vendored verbatim by a large share of public WoW addons; bundled here
  unmodified on that basis.
- **LibDBIcon-1.0** (`LibDBIcon-1.0/`) - the minimap button itself, on top of the
  LibDataBroker object. Single file pulled from WoWAce
  (https://repos.wowace.com/wow/libdbicon-1-0/trunk).
  License: Ace3 Development Team BSD-style license, as declared on
  https://www.wowace.com/projects/libdbicon-1-0 (`LibDBIcon-1.0/LICENSE.txt`).
- **LibDeflate** (`LibDeflate/`) - DEFLATE compression for the comm wire format.
  Source: https://github.com/SafeteeWoW/LibDeflate
  License: zlib license (`LibDeflate/LICENSE.txt`).
