# MSFS 2020 experimental testing - 0.20.7

## What this build attempts

This increment adds an explicit older-RTX preparation workflow and opens the existing rendering engine to an experimental MSFS 2020 manager target. It does not add a newly developed neural model, replace hardware capability checks, or demonstrate that unsupported hardware can execute a model.

The older-RTX model selection already existed in 0.20.5/0.20.6. The new work exposes it as a deliberate test action with clear labelling, companion-runtime preparation, retry state, one-pass initialization and off-at-startup behavior. Runtime failures still use the existing failure reason and optional-feature handling. No NVIDIA architecture spoofing or new runtime binary dependency was introduced.

The model sources and hashes remain pinned in `installer/neural-download.ps1`; the older-RTX community model is not NVIDIA-signed. The manager verifies the archive and extracted file hashes, imports only the expected model and uses existing ownership tracking. All existing licenses and attributions are retained.

## First test: MSFS 2020, Steam, RTX 5090

1. Finish the simulator download and close MSFS 2020.
2. Open the 0.20.7 manager and select Microsoft Flight Simulator 2020 (test).
3. Confirm the selected folder contains FlightSimulator.exe. Select the executable folder, rather than the downloaded content packages.
4. Install with your desired optional effects choice. The ordinary NVIDIA-model option selects the existing RTX 50 model. Do not use Prepare older RTX test on the 5090.
5. Select DX12 and DLSS in the simulator, restart, and enter a flight. First check the menu, effects and the active upscaling connection with NR/FG off.
6. Test Neural Rendering manually only after the baseline works; start with one pass. Test frame generation separately afterward.
7. Record API, selected upscaler, NR/FG status and frame time. Export the diagnostics ZIP if the menu fails to load, no connection appears or the simulator crashes.

MSFS 2020's existing engine quirk disabling FSR2/FSR3 input hooks is retained. This first test uses its DLSS integration. Copying runtime files does not create a temporal input connection.

## Xbox / Microsoft Store

Discovery includes XboxGames and Xbox games installation folders and manual Browse. The launch helper is selected when present. Accessible older MSFS 2020 main executables are accepted without requiring a helper. Choose the executable folder, not the downloaded Community/Official content packages.

Protected legacy WindowsApps installations are not made writable and no ownership/ACL changes are performed. Use an accessible installation offered by the Xbox app where available. The folder/loader lifecycle is tested with fixtures; actual Xbox MSFS 2020 startup and rendering are not yet tested.

## Older RTX test

Use an RTX 20, 30 or 40 system with one unambiguously detected RTX card. Install OptiShade, close the simulator, then use Setup > Advanced options and downloads > Prepare older RTX test. The manager prepares the pinned community model and companion runtimes, and saves NR off / one pass. In-flight, manually enable the experimental compatibility control.

An initialization failure or excessive GPU cost is a failed/unsuitable experiment, not a reason to claim support. Leave NR disabled if it fails; ordinary upscaling and image effects can be assessed independently. No new native NVIDIA FG or AMD neural path is added by this work.

## Version and release scope

Version 0.20.7 is the first public release enabling MSFS 2020 for experimental testing and includes the previously local 0.20.6 foundation changes. The remaining universal-compatibility phases in Compatibility-foundation.md still apply. MSFS 2020 is the explicitly requested early test exception to the broader multi-game deferral; Library and X-Plane remain disabled.

## Reference

MSFS 2020's DLSS input is documented in the [official Sim Update 10 release notes](https://www.flightsimulator.com/release-notes-1-27-21-0-sim-update-x-now-available/). This establishes the game integration, not validation of OptiShade's experimental path.

## Checks completed on 23 September 2026

- All 27 PowerShell regression scripts passed; updated fixture tests do not interfere with the user's running MSFS downloader.
- Steam/Xbox install, repair, restore and uninstall fixtures passed for both 2020 and 2024, preserving game-owned NVIDIA files and saved presets.
- The update helper also passed a separate MSFS 2020 staging/update/rollback/configuration-preservation run.
- RTX 2060/3080/4070 model-selection fixtures, multiple-RTX rejection and idempotent one-pass/off-at-startup settings preparation passed. These are selection/configuration tests, not older-GPU rendering tests.
- Release x64 native build succeeded with existing compiler/linker warnings. The actual D3D12 effects test passed with multi-window and recreation options, four GPU readbacks and zero debug errors.
- WPF layout/syntax checks passed and the rendered Home preview was visually inspected.
- Final package verified all 100 embedded payload files and script encoding. Isolated manager validation returned OK; EXE version metadata is 0.20.7.0.
- The release asset digest identifies the final packaged executable.
- A user subsequently confirmed successful MSFS 2020 Steam loading and Neural Rendering on an RTX 5090. Inspection of the actual game logs confirmed the rendering adapter, game DLSS input, model initialization and active 3840 x 2160 Neural Rendering, including two-pass operation. The installed performance DLL matched the built DLL.
- This is a single-system result. Older RTX rendering, Xbox startup, frame generation and triple-monitor stability remain unconfirmed. The session included Streamline warnings/errors outside the confirmed Neural Rendering interval, so it is not described as error-free.
- Private prompts, screenshots and raw user logs are excluded from publication.
