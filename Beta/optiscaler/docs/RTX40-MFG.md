# MFG backends in the maintained private build

The backend selected by the installer matters; the presence of a DLL in the payload is not evidence that it is active.

- The local source routes RTX 20/30 MSFS 2020/2024 DX12 installations to the pinned, unmodified upstream `dlssg_for_sm86` v0.4.0 component. It supports RTX 20 Turing (SM75) and RTX 30 Ampere (SM86) and leaves the upstream default multiplier ceiling at 4x. The installer records package/file pins, preserves unrelated proxies, migrates both the previous source-provider and game-folder proxy receipts transactionally, and removes only files still matching their ownership records. The provider DLL is placed under `OptiShadeData/Engine/dlssg_sm86/` for OptiScaler's post-attach `AmpereMfgLoader`; it is not installed as another game-root proxy. This is still experimental: upstream's manual warns against OptiScaler coexistence, and the hosted integration has no RTX 20/30 game-output qualification. See [SM86 provider provenance](../../installer/OptionalMFG/SM86-PROVENANCE.md).
- Stable retains the pinned upstream RTXMFG v1.3.3-hotfix.2 provider for supported RTX 40 installations.
- Beta retains the headless source-built `OptiShadeMFG.dll` route for eligible RTX 40 MSFS installations. Its source is `installer/OptionalMFG/Source203040`, based on revision `21a2b9931f0c13f46a4b3b8a5856620d9698f88e` of mcsoderh/RTX30MFG-Unlock. The build receipt, installer hash and runtime identity header must match. Previous RTX 20/30 source receipts migrate to the SM86 provider selected by the current policy.
- RTX 50 uses the simulator/NVIDIA native FG provider. X-Plane FG is not supplied by either integration. Ordinary AMD functionality is separate.

Each route uses the existing OptiShade controls or game controls appropriate to that provider. The RTX 20/30 OptiScaler external-provider code forwards requested modes/multipliers through the game's Streamline API and displays only its fresh reported range. Source tests cover installation, ownership, migration and loader selection only; they do not establish that the upstream initialization hooks coexist safely or that any generated frames reach the display. Older-GPU simulator output and the reported fixed-2x/pending failures still require target tests.

The v0.4.0 upstream package is configured to install on demand from its official release. It is not copied into the OptiShade EXE. The helper checks the archive and selected file hashes before installation, but the upstream archive was not re-downloaded and independently rehashed in this pass. Only MFG files and the upstream licence/notices are selected; the upstream optional SR package is not selected.

## Source-built component

Use `installer/OptionalMFG/build-source203040.ps1 -StreamlineRoot <SDK> -BuildDirectory <empty-build-folder>`. CMake 3.24+, MSVC v143 and MASM are required. The SDK must contain `include` and `external/ngx-sdk/include`; preserve its applicable NVIDIA terms. The existing OptiScaler headers can be copied into that layout. The script records the exact headers and source hashes, updates the installer/runtime DLL pin, and emits matching symbols. Rebuild the channel with `build-candidate.ps1` afterwards.

The source component has no separate UI/hotkey. Controls are in OptiShade. Streamline resource tags are interpreted using the actual host version: UI alpha is 68 in 2.11 and 69 in 2.12–2.14; unknown contracts are not inferred. The preserved upstream binary has its original menu; that binary has not been rebuilt by this change.

The older `optiscaler/build_mfg_unlocker.ps1` and `build-controls-only.ps1` describe different historical upstream targets, not the active source-backend recipe. Their provenance remains for reference. Do not apply their submodule commands to this vendored source tree.

## Installation and recovery

Installer ownership records protect existing files. The legacy provider uses a recorded `version.dll`; source-backed installations use the dedicated OptiShade MFG location and startup worker. Do not rename arbitrary loaders or replace the game's Streamline DLLs. Restore can remove a renamed copy only when its bytes match the recorded OptiShade/MFG loader hash. Foreign loaders are retained.

Upstream MIT, loader, ImGui, MinHook and applicable OptiShade GPL notices remain with their respective components. This document does not grant rights to NVIDIA runtime/model assets.
