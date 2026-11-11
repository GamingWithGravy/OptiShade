# OptiMFG 1.0.101

Signed OptiMFG runtime package for the OptiShade launcher. The launcher reads [`channel.json`](channel.json), checks its signature, then downloads and verifies `packages/OptiShade.OptiMFG-1.0.101.tar.gz` and every file in it before installing.

Changes in 1.0.101:
- Fixes OptiMFG failing to install or update with "OptiMFG backend payload verification failed: version.dll" on launchers older than 1.0.100. Update the launcher to get the new frame-generation backend.

Changes in 1.0.100:
- New frame-generation backend, downloaded by the launcher from its official release and checked file by file before installing. Its own menu and on-screen messages are switched off; OptiShade's Performance page is the only frame-generation control.
- AMD Radeon cards are supported (experimental).

`packages/OptiShade.OptiMFG-source.tar.gz` holds the corresponding source, including the desktop controller. The runtime keeps its required upstream licences and notices. The launcher and installer are not included here.
