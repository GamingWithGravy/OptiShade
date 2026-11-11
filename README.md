# OptiShade Core 1.0.100

Signed OptiShade Core package for the OptiShade launcher. The launcher reads [`channel.json`](channel.json), checks its signature, then downloads and verifies `packages/OptiShade.Core-1.0.100.tar.gz` and every file in it before installing.

Changes in 1.0.100:
- Fixes MSFS 2024 closing straight away on start when another tool's nvngx.dll is in the game folder.
- AMD frame generation: XeFG accepts up to 6x for the new OptiMFG 1.0.100 route.
- Automatic diagnostic reports use Troubleshooter 0.2.37. It names another tool's graphics DLL in the game folder (dxgi.dll, d3d11.dll, d3d12.dll, dinput8.dll or nvngx.dll) and no longer shows a routine NR rebuild wait as a problem.

Includes every change from 1.0.78, 1.0.93, 1.0.94, 1.0.95, 1.0.96, 1.0.97, 1.0.98 and 1.0.99.

`packages/OptiShade.Core-source.tar.gz` is the corresponding source for the GPL-covered OptiScaler-derived portions. The launcher and installer are not included here.
