OptiMFG / OptiShade external-controller integration candidate — 27 October 2026

In-game controls are in OptiShade > Performance > Frame generation. The desktop
OptiMFG EXE remains available from the system tray for recovery and diagnostics.
OptiShade IPC v1 forwards the same multiplier request to whichever provider is
actually installed for the selected MSFS process.

Provider selection is per game installation and comes from the owned
OptiMFGTest-backend.json manifest:
- The optional OptiMFG component owns the controller and menu-free backend.
  RTX 20/30/40 installations receive the pinned 0.8.5 source-built backend,
  using the 0.8.2 file-transport route with later compatibility/transition fixes.
  RTX 50 uses native Streamline. Foreign loaders are never overwritten.
- Performance > Frame generation continues to send IPC v1 requests to the EXE.
  Existing component settings survive repair; removal preserves user settings.
- There is no separate backend overlay or Backspace menu in this payload.
- No backend manifest: native Streamline control. The controller waits for
  Streamline to load and settle before attaching its native helper.
- Provider 1.7.0: MFG Unlocker file-transport route.
- Provider 1.2.2-optimfg.1: menu-free RTX provider route.
An existing backend is no longer rejected as retired. The controller waits for
its proxy/provider module and live status, then connects without loading the
native helper. It refuses to stack the native helper with either backend.
For older valid MFG Unlocker installs without an OptiShade marker, the
controller recognizes the route only when both version.dll and the expected
version-13 settings shape are present; a missing proxy or malformed settings
file does not trigger backend routing.

Each live route reports its detected GPU family, bridge readiness and safe
multiplier ceiling. OptiShade only exposes/forwards multipliers reported by the
active provider. This is routing and protocol validation, not a claim that each
game/GPU combination has verified image quality or smooth output. RTX 20/30/40
backend behavior remains experimental and requires hardware testing. RTX 50
uses the native route. AMD MFG is not supported by these NVIDIA provider paths.

Auto-connect uses process/module/provider readiness polling; it does not use
SimConnect. Native attachment waits five seconds after Streamline appears.
Provider-backed routes wait for the corresponding loader and fresh status.
Waiting/Connected reflects a live controller lease; runtime acknowledgement
and generated output are reported separately.

Install/repair the OptiMFG component with the game closed, then restart MSFS.
Existing owned 1.7.0 providers can migrate on older RTX cards; foreign providers
must be removed through their owner first. DLSS-G 310.9.16 backport support in
this candidate is RTX 40 only; RTX 20/30 are not qualified for that DLL. An older EXE does not implement this IPC.
No vendor DLSS/Streamline files were changed or downgraded by these route changes.

Validation: MSVC controller/helper/core builds, controller IPC expiry/request
checks, backend route-selection matrix, RTX-family protocol checks and source
checks. No GPU execution was tested here. Live MSFS menu visibility, disconnect
and reconnect, real multiplier changes, frame pacing and output still require
hardware verification.

The theme/widgets are GPL-3.0-or-later OptiShade additions; ImGui is MIT.
Keep license notices and corresponding source when distributing this candidate.

R280 / backend 0.8.6: binds mixed runtime-Create/provider-Evaluate coverage to the selected module generation. Backend core file version 1.2.0.25. Desktop modes use the actual provider list; readiness failures are shown in both UIs. See licenses/RTX-backend-source-changes.patch. CPU regression tests pass; simulator output unverified.
