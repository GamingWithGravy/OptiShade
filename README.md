# OptiMFG 1.0.100

Signed OptiMFG runtime package for the OptiShade launcher. The launcher reads [`channel.json`](channel.json), checks its signature, then downloads and verifies `packages/OptiShade.OptiMFG-1.0.100.tar.gz` and every file in it before installing.

Changes in 1.0.100:
- RTX 20, 30 and 40 cards and AMD Radeon cards now use MFG Unlocker 1.7.0 (MIT licence, by dashdogy). On AMD it runs XeMFG with Intel XeSS frame generation. This package does not contain either: the launcher downloads them from their official GitHub releases on your PC and checks every file against pinned digests before installing.
- MFG Unlocker's own menu, startup message and input hooks are switched off. OptiShade's Performance page is the only frame-generation control.
- RTX 50 keeps the game's native frame generation.
- The previously bundled RTX backend is no longer included.
- The AMD route is new and experimental.

`packages/OptiShade.OptiMFG-source.tar.gz` holds the corresponding source, including the desktop controller. The runtime keeps its required upstream licences and notices. The launcher and installer are not included here.
