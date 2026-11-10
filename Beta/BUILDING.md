Local 1.0.77 R223 private candidate: includes the R222 x64 MFG install path and R220 managed Present sampling, plus durable diagnostics when a native DLSS-G callback cannot resolve its provider. The unresolved-provider report captures caller and Present-thread correlation and is retained by the diagnostics exporter. Source contracts (134 tests), focused native callback/Auto (131) and NR-session (14) checks, MFG install/removal (117), full Windows reconstruction (178/178), WARP submission, OptiScaler/PDB identity, and all 242 embedded payload checks passed. MSFS activation remains untested. See `MDs/Reconstruction/Evidence/2026-10-26-tester-triage/R223-mfg-provider-resolution-diagnostics.md` before tester distribution.

Local 1.0.77 R214 tester build: MSFS Store MFG preparation no longer treats the unreadable launcher helper as the renderer. Simulator confirmation remains pending.

# Building Optishade

## Tools

- Windows x64.
- Visual Studio 2022 / Build Tools, Desktop development with C++, MSVC v143 and Windows SDK. The included scripts locate the installation with vswhere.
- Go 1.23 or newer on PATH (release installer built with Go 1.27.1).
- Python 3 with `jinja2` on PATH for ReShade's GLAD generator (`python -m pip install jinja2`). These are upstream build dependencies.
- Windows PowerShell 5.1 and .NET Framework 4.x.

The engine dependencies are vendored under optiscaler/external and reshade/deps, with their notices. Do not replace these with arbitrary newer versions when reproducing this release. Their upstream .gitmodules files document provenance; this repository contains the files directly.

## Build

From the `Beta` channel directory:

```powershell
powershell -NoProfile -File .\build-candidate.ps1
```

Use a PowerShell environment permitted to run your locally reviewed build scripts. Network access is needed for the pinned Go resource generator on its first run. Check each command succeeds before continuing.

The candidate script compiles the three simulator adapters, Fusion Engine/OptiScaler, the NR forwarder, ReShade, sensor helper and installer. It stamps source/component hashes, builds one EXE, and verifies a fresh extraction. `-SkipPackage` stops after native compilation. Packaging neither publishes nor deploys.

MFG is a separately built component: run `installer/OptionalMFG/build-source203040.ps1` when its source changes, then rebuild the channel. See [the active backend and build requirements](optiscaler/docs/RTX40-MFG.md). Stable and Beta have different activation policies; bundled-but-inactive code is not a delivered hardware capability.

Pinned vendor DLLs, `optiscaler/OptiScaler/library` static libraries and `external/freetype/freetype.lib` are required local inputs. These are not interchangeable with arbitrary latest downloads. Existing provenance/notices and approved acquisition instructions apply; this source tree is not a dependency-free SDK. Their actual hashes are included in the build identity. Missing declared inputs now stop the build.

Git checkouts use the tracked/non-ignored source inventory. Source ZIPs retain `R10-SOURCE-MANIFEST.json` beside `Beta`/`Stable`; the earlier `Source/<channel>` plus `Notes/FILE-MANIFEST-SHA256.json` layout is also supported. The manifest selects files to hash; the build hashes their current contents. Preserve the matching original manifest and dependency inputs for reproduction.

Generated binaries, objects, staging and private evidence are ignored. Go tests run after payload generation. A local compile or isolated GPU test is not a simulator pass; consult the candidate's private results for exact coverage and outstanding target tests.

## Runtime files

Standard and SweetFX packs are bundled from installer/DefaultEffects. Additional effect packs and optional NVIDIA files are downloaded using the included manifests. A compatible neural-rendering model may need to be supplied separately. These are not a promise that every NVIDIA card supports every feature.

## Update compatibility

### R215 MFG state display

When MFG provider telemetry becomes stale during a focus change, the in-game control retains the last accepted ON state and labels it as waiting for a fresh report. Freshness still gates edits and current-activation claims. This fixes a misleading visual OFF transition; only an in-game MSFS test can confirm provider load or generated frames.

### R214 MSFS Store MFG preparation

When an installed Xbox/Microsoft Store simulator records only `gamelaunchhelper.exe` and Windows denies reads of the renderer, an explicit RTX 40 MFG install now attempts the pinned provider through a free supported `version.dll` alias. This is an installation attempt, not proof the simulator loads the proxy or generates frames. An occupied or receipt-owned alias still blocks the change; verify provider-load evidence in the in-game panel. Other unknown game routes retain the previous guarded behavior.

Stable 1.0.77 is the current private candidate under validation. After an update operation, the manager forces a new installation-status scan before comparing results, so a stale pre-update snapshot cannot leave a completed update yellow. Crash and suspected-stall dump summaries now include bounded PID and process-start metadata from `MINIDUMP_MISC_INFO` when the stream's validity flags permit it, allowing direct comparison with `LastSession` process birth. MFG preparation is not restricted to flight simulators: generic x64 D3D12/Vulkan games are admitted when a fresh capability receipt binds the current executable, hashed provider image, rendering adapter, driver and output identity. Xbox MSFS routes retain their explicit x64 route when Windows denies reading the encrypted renderer executable and the selected content helper is used; helper imports and hash are not treated as rendering evidence. Storefront does not change admission. Game/provider integration is still required, and installation does not prove MFG output in every title. Dynamic MFG remains D3D12-only. Neural preparation honors an exact rendering-adapter hint before considering an older NVIDIA adapter in a game log. XP12 and generic Vulkan NR external flushes now join ReShade's game-present semaphore chain before submitting copied frames; completed private command-list leases are retired before NR shutdown. The one-button launcher-log export captures bounded `Installer.log`, `Manager-error.txt` and `Update-error.txt` tails with file timestamps and omitted-byte counts. Physical GPU, simulator output, XP12+NR, VR, cross-store/game, public-test and release gates remain open.

The current private test candidate pins DLSS SR/RR and DLSS-G to NVIDIA 310.9.16 with Streamline 2.14.16. The exact provider version is admitted by the MFG compatibility policy and its patch signatures are checked against the official DLL; game-level frame-output qualification remains outstanding. See [the runtime compatibility policy](optiscaler/docs/DLSS-RUNTIME-POLICY.md). This does not by itself make every game expose DLSS 4.5 or prove MFG/Neural Rendering output on a target GPU.

When publishing is explicitly authorised, use one installer asset per release:

| Release tag | Single EXE asset name | Display label |
| --- | --- | --- |
| `v0.21.6` | `OptiShade_Version_0.21.6.exe` | OptiShade 0.21.6 stable |
| `v0.21.7` | `OptiShade_Version_0.21.7.exe` | OptiShade 0.21.7 stable |
| `v1.0.0` | `OptiShade_Version_1.0.0.exe` | OptiShade 1.0.0 stable |
| `v1.0.1` | `OptiShade_Version_1.0.1.exe` | OptiShade 1.0.1 stable |
| `v1.0.2` | `OptiShade_Version_1.0.2.exe` | OptiShade 1.0.2 stable |
| `v1.0.3` | `OptiShade_Version_1.0.3.exe` | OptiShade 1.0.3 stable |
| `v1.0.4` | `OptiShade_Version_1.0.4.exe` | OptiShade 1.0.4 stable |
| `v1.0.5` | `OptiShade_Version_1.0.5.exe` | OptiShade 1.0.5 stable |
| `v1.0.6` | `OptiShade_Version_1.0.6.exe` | OptiShade 1.0.6 stable |
| `v1.0.7` | `OptiShade_Version_1.0.7.exe` | OptiShade 1.0.7 stable |
| `v1.0.8` | `OptiShade_Version_1.0.8.exe` | OptiShade 1.0.8 stable |
| `v1.0.9` | `OptiShade_Version_1.0.9.exe` | OptiShade 1.0.9 stable |
| `v1.0.10` | `OptiShade_Version_1.0.10.exe` | OptiShade 1.0.10 stable |
| `v1.0.11` | `OptiShade_Version_1.0.11.exe` | OptiShade 1.0.11 stable |
| `v1.0.12` | `OptiShade_Version_1.0.12.exe` | OptiShade 1.0.12 stable |
| `v1.0.13` | `OptiShade_Version_1.0.13.exe` | OptiShade 1.0.13 stable |
| `v1.0.15` | `OptiShade_Version_1.0.15.exe` | OptiShade 1.0.15 stable |
| `v1.0.16` | `OptiShade_Version_1.0.16.exe` | OptiShade 1.0.16 private stable tester build |
| `v1.0.17` | `OptiShade_Version_1.0.17.exe` | OptiShade 1.0.17 private stable tester build |
| `v1.0.18` | `OptiShade_Version_1.0.18.exe` | OptiShade 1.0.18 private stable tester build |
| `v1.0.20` | `OptiShade_Version_1.0.20.exe` | OptiShade 1.0.20 private stable tester build |

Retain the exact asset names: older launchers match them before downloading.
Do not upload a second renamed copy. A portable ZIP may accompany that EXE.
Mark beta as a prerelease; stable is the latest stable release. New launchers
save the downloaded manager with a readable Desktop name and verify its hash
before removing the recorded previous EXE.

The published 0.21.3 update readers accept this format. Older beta launchers
must have beta opt-in enabled when checking. The published 0.21.2 reader has an
existing release-array handling defect; a new asset name cannot repair that
already-installed code. The compatibility fixtures retain this known failure
rather than claiming that all historical launchers can update.

## Hybrid runtime assets

Acquire the hash-pinned upstream archive using optiscaler/get_hybrid_assets.ps1 into a new staging folder. Copy its OptiScaler/nvfp4/hybrid contents to installer/HybridAssets, preserving PROVENANCE.json. The provenance file records every expected hash; do not disable verification. These upstream binary assets are supplied separately from their source and retain their applicable terms.

The read-only hardware monitor is built from `installer/HardwareSensors.cs` using the Windows .NET Framework compiler. Its fixed metric rows cover Windows CPU usage/clock/RAM and capability-probed NVIDIA NVAPI / AMD ADL metrics. Unsupported values, including CPU temperature where no provider exists, remain Unavailable. No kernel sensor driver or Libre Hardware Monitor is bundled or required.

## Local R109 test candidate

1.0.28 adds read-only discovery of real DLSS-G state-function availability on routes where OptiShade does not expose native MFG; game-visible controls and provider configuration remain unchanged. Use `build-candidate.ps1 -SkipPackage -ReuseVerifiedLegacyNRHost`, then `package.ps1 -PrivateTesting $true -PrivateBuildLabel 'Rebuild R111'` after all sources are frozen. The reused x64 legacy host must match a previously verified local package; all changed runtimes are rebuilt. Run `tests/reconstruction/run_tests.py --compiler cl` from the configured MSVC environment. XP12 alternative graphics routes are per-game desktop test settings, selected in Setup, and require game restart. Native Vulkan remains the default. No packaging step is simulator acceptance.
