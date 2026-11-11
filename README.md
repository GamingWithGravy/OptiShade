# OptiShade Core 1.0.99

Signed OptiShade Core package for the OptiShade launcher. The launcher reads [`channel.json`](channel.json), checks its signature, then downloads and verifies `packages/OptiShade.Core-1.0.99.tar.gz` and every file in it before installing.

Changes in 1.0.99:
- Glass Cockpit: the in-game controls work with the official add-on 1.1.0. Before, the in-game menu said the add-on's interface was not compatible with this OptiShade build.
- Fixes MSFS 2024 crashing at start on some PCs in the image-effects depth add-on.
- Automatic diagnostic reports use Troubleshooter 0.2.36.

Includes every change from 1.0.78, 1.0.93, 1.0.94, 1.0.95, 1.0.96, 1.0.97 and 1.0.98.

`packages/OptiShade.Core-source.tar.gz` is the corresponding source for the GPL-covered OptiScaler-derived portions. The launcher and installer are not included here.
