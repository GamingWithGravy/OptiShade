# OptiShade Core 1.0.95

Signed OptiShade Core package for the OptiShade launcher. The launcher reads [`channel.json`](channel.json), checks its signature, then downloads and verifies `packages/OptiShade.Core-1.0.95.tar.gz` and every file in it before installing.

Changes in 1.0.95:
- Automatic diagnostic reports, sent when the game stops responding, now use the same Troubleshooter (0.2.35) as the launcher, so they no longer include out-of-date findings.
- The in-game OptiShade menu shows version 1.0.95.

Includes every change from 1.0.78, 1.0.93 and 1.0.94.

`packages/OptiShade.Core-source.tar.gz` is the corresponding source for the GPL-covered OptiScaler-derived portions. The launcher and installer are not included here.
