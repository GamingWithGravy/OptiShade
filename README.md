# OptiShade Core 1.0.103

Signed OptiShade Core package for the OptiShade launcher. The launcher reads [`channel.json`](channel.json), checks its signature, then downloads and verifies `packages/OptiShade.Core-1.0.103.tar.gz` and every file in it before installing.

Changes in 1.0.103:
- Fixes "Upscaler failed to run: DLSS" and a black screen with DLSS Ultra Performance. DLSS now adjusts itself in a moment, with no error message.
- Fixes MSFS 2024 crashing when entering VR while a VR add-on that runs its own DLSS (such as OFXR Bridge) is active.
- OptiMFG on older NVIDIA cards uses OptiShade's own frame-generation backend again, as before 1.0.100, and no longer shows a black screen with frame generation on.
- The OptiMFG page says when MSFS needs a restart because frame generation was switched on after the sim started.
- Clearer X-Plane 12 Neural Rendering messages.

Changes in 1.0.102:
- Fixes a black screen with "Upscaler failed to run: DLSS" in MSFS when DLAA or dynamic resolution is used.
- OptiMFG: the frame-generation multiplier chosen in Performance > Frame generation applies straight away during a flight, without pausing. The page shows the multiplier running and the highest your graphics card allows.

Changes in 1.0.101:
- Fixes MSFS crashing a few minutes into a flight with frame generation on while the Steam overlay (or another overlay that hooks the game) is running. The overlay can stay on.
- Automatic diagnostic reports use Troubleshooter 0.2.38. It names the Steam overlay when its hook crashes the game, and keeps frame generation's own crash log with the report.

Changes in 1.0.100:
- Fixes MSFS 2024 closing straight away on start when another tool's nvngx.dll is in the game folder.
- AMD frame generation goes up to 6x.
- Troubleshooter 0.2.37 names another tool's graphics DLL in the game folder and no longer shows a routine NR rebuild wait as a problem.

Includes every change from 1.0.78 and 1.0.93 to 1.0.99.

`packages/OptiShade.Core-source.tar.gz` is the corresponding source for the GPL-covered OptiScaler-derived portions. The launcher and installer are not included here.
