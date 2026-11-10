Upstream: https://github.com/jlrouzies-fr/DLSS5-Feeder
Pinned commit: 34edfe16626d52a8f66c5996c58d5b7c982d3023
License: MIT (see LICENSE)

OptiShade adapts the project as an experimental bridge for 32-bit games: a ReShade x86 add-on sends frames to a separate x64 worker, which hosts the NVIDIA DLSS NR runtime. The imported commit above identifies the upstream baseline; the active integration includes OptiShade changes. Both halves are built locally. The worker's upstream internal `DLSS5_Feed` names are retained, and both halves must use the current matching IPC contract.

The default guide path borrows the current OptiShade core depth/motion guides. D3D10 executes the original core kernels through the existing D3D11 relay because D3D10 has no compute stage. These guides are estimates, not engine-provided motion vectors. An explicitly configured external motion shader remains an advanced alternative. Its `DLSS5_Feed.fx` and independent shader include are packaged for that route; installing the Neural component does not enable a feed technique or replace the user's existing guide choice.

The current process starts with NR Off. The x64 worker verifies the game process, rendering adapter, pinned model and preparation receipt before accepting the current-session activation exchange. The worker's explicit OptiShade control export then requests NR. A saved `Enabled=true` does not activate the current runtime. A successful install, worker preparation or transport round trip does not establish that NR inference or displayed output works in a particular game.

Native D3D9 cannot use the bridge; San Andreas requires a separately installed and configured D3D9-to-D3D11 wrapper (for example, dgVoodoo), followed by OptiShade Repair using the DXGI method. The wrapper is not bundled. x86 Vulkan requires an external compatible ReShade Vulkan layer, also not bundled. The installer does not provide x86 upscaling, frame generation, or Glass Cockpit support.

The imported layout and upstream notices remain under `upstream/`. The active adapted translation units are `upstream/src/dlss5-feed32.cpp` and `upstream/host/dlss5-feed-host64.cpp`, selected by `build-client32.bat` and `build-host64.bat`. Shared OptiShade contracts are under `../shared/`. There are no separate active `legacy-nr/src/` or `legacy-nr/host/` copies. The original upstream source and OptiShade additions retain their applicable file notices. No upstream prebuilt worker is substituted for the verified local build.
