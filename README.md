# OptiMFG 1.0.78

Signed OptiMFG runtime package for the OptiShade launcher. The launcher reads [`channel.json`](channel.json), checks its signature, then downloads and verifies `packages/OptiShade.OptiMFG-1.0.78.tar.gz` and every file in it before installing.

Changes in 1.0.78:
- RTX 40: fixes a crash when a game restarts Streamline (the frame-generation plugin was kept loaded and used a plugin that had been unloaded).
- OptiMFG Live: fixes a crash after Enable FPS capture (administrator).

The runtime keeps its required upstream licences and notices. The launcher and installer are not included here.
