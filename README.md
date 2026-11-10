# OptiMFG 1.0.79

Signed OptiMFG runtime package for the OptiShade launcher. The launcher reads [`channel.json`](channel.json), checks its signature, then downloads and verifies `packages/OptiShade.OptiMFG-1.0.79.tar.gz` and every file in it before installing.

Changes in 1.0.79:
- RTX 40: restores the previous frame-generation backend. The 1.0.78 backend could stop DLSS Frame Generation from starting, so X2/X3/X4 had no effect.
- OptiMFG Live: keeps the fix for a crash after Enable FPS capture (administrator).

The runtime keeps its required upstream licences and notices. The launcher and installer are not included here.
