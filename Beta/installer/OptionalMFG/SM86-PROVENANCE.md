# RTX 20/30 MFG provider provenance

## Upstream component

- Project: [sdli1995/dlssg_for_sm86](https://github.com/sdli1995/dlssg_for_sm86). Its current README identifies the project source as GPLv3; the bundled NVIDIA runtime and kernel resources remain third-party material and are not relicensed under GPL. Review the release's notices and distribution terms before copying source or redistributing any bundled assets.
- Release: v0.4.0, official asset `dlssg-release-0.4.0-x64.zip`.
- Download: `https://github.com/sdli1995/dlssg_for_sm86/releases/download/v0.4.0/dlssg-release-0.4.0-x64.zip`.
- Pinned archive SHA-256: `5865360C3295038F0FF979D303BB7EB9437EEC09FBC08686967D3B5D41D9C019`.
- Exact selected files and SHA-256 pins are in `Beta/installer/sm86-mfg.ps1`. The installer verifies the archive before reading it and verifies every extracted file before changing the game folder.
- Upstream manual and installation limits: [English manual](https://github.com/sdli1995/dlssg_for_sm86/blob/main/MANUAL.en.html), [installation reference](https://github.com/sdli1995/dlssg_for_sm86/blob/main/docs/INSTALL.en.md), [source README](https://github.com/sdli1995/dlssg_for_sm86/blob/main/README.en.md).

The upstream package supports RTX 20 Turing (SM75) and RTX 30 Ampere (SM86) on Windows x64 / Direct3D 12. OptiShade currently offers the component for supported MSFS 2020/2024 DX12 installations. The installer takes one proxy DLL matching an imported, unoccupied game loader name, the upstream INI, the backend/runtime files, and the upstream licence/notices. It does not install the optional SR files. It does not build or modify the upstream binaries.

## UI and provider behavior

The local installer experiment places the upstream `version.dll` payload under `OptiShadeData/Engine/dlssg_sm86/dlssg_sm86.dll` and enables OptiScaler's existing `AmpereMfgLoader` sideload path. It does not place a second loader proxy in the game root. The current OptiShade MFG UI code observes the game's Streamline `slDLSSGGetState` maximum and can send a requested Off/Follow/fixed mode through the existing external `slDLSSGSetOptions` hook. The available tiles remain governed by the current game/provider report. The upstream factory ceiling remains `MaxGeneratedFrames=3` (up to 4x); the game chooses the actual request, and its own plugin can report a lower maximum.

**Compatibility warning:** the upstream [installation manual](https://github.com/sdli1995/dlssg_for_sm86/blob/main/MANUAL.en.html) explicitly tells users to remove OptiScaler and other DLSS/frame-generation mods before installing its game-folder proxy. This experiment avoids installing that second game-folder proxy and uses OptiScaler's existing post-attach loader, but upstream has not documented or endorsed this combined setup. The OptiScaler maintainers also marked a request for this integration as not planned, citing reverse-engineering and takedown risk ([discussion](https://github.com/optiscaler/OptiScaler/discussions/1146)). Source inspection and fixture tests cannot establish that the proxy's hooks coexist safely with OptiScaler or produce MFG output. Keep the route marked experimental and do not claim it works until actual RTX 20 and RTX 30 MSFS DX12 tests verify loading, toggling and distinct generated output.

RTX 40 stays on the existing channel-selected provider. RTX 50 stays on game-native frame generation. The old RTX 20/30 source receipt is migrated to this component only after the new package and loader have been verified; the installer retains rollback data until the provider receipt commits. Uninstall restores the pre-provider OptiScaler settings and removes only unchanged, receipt-owned files. User-edited upstream INI files and foreign loader DLLs are preserved.

## Evidence limits

Offline fixture tests verify routing, recorded hash checks, one-proxy selection, install/remove ownership, migration, user-edited INI retention and transaction rollback. They do not verify a fresh download's hashes, run the upstream DLL, a simulator or a GPU. Upstream's published RTX 20/30 implementation and reported device tests are useful provenance, not proof that this OptiShade + OptiScaler integration works in any MSFS build, driver, GPU or runtime. The upstream manual's OptiScaler warning is a blocker to qualification.

Before any release claim, test an RTX 20 and RTX 30 independently in MSFS 2020/2024 DX12. Record the exact game/plugin/driver, confirm loader and upstream logs, exercise the OptiShade Off/Follow/multiplier controls, observe the game's accepted state and capture distinct generated output while monitoring base FPS, GPU load, latency and mode-switch/restart behavior. Preserve the reports and leave output acceptance pending until those tests pass.
