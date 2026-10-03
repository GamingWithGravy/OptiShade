# Building Optishade

## Tools

- Windows x64.
- Visual Studio 2022 / Build Tools, Desktop development with C++, MSVC v143 and Windows SDK. The included scripts locate the installation with vswhere.
- Go 1.23 or newer on PATH (release installer built with Go 1.27.1).
- Python 3 with `jinja2` on PATH for ReShade's GLAD generator (`python -m pip install jinja2`). These are upstream build dependencies.
- Windows PowerShell 5.1 and .NET Framework 4.x.

The engine dependencies are vendored under optiscaler/external and reshade/deps, with their notices. Do not replace these with arbitrary newer versions when reproducing this release. Their upstream .gitmodules files document provenance; this repository contains the files directly.

## Build

From the repository root:

```powershell
powershell -NoProfile -File .\build-candidate.ps1
```

Use a PowerShell environment permitted to run your locally reviewed build scripts. Network access is needed for the pinned Go resource generator on its first run. Check each command succeeds before continuing.

The candidate script compiles the engine DLLs, installer host and version resources, then records their hashes against the source used to build them. Packaging requires that matching record, verifies embedded files, and produces one installer EXE in `dist`. Use `-SkipPackage` to compile and verify only the core components. This build retains the hash-pinned upstream MFG DLL, including its separate Backspace menu, alongside the new OptiShade controls. The future controls-only replacement is separate work; see [MFG build requirements](optiscaler/docs/RTX40-MFG.md). Packaging does not publish or deploy anything.

For this build, the ignored `optiscaler/OptiScaler/library` directory and `reshade/res/version.h` were restored from the existing local development inputs because they were absent from the public checkout. Keep these matching inputs to reproduce this build; do not substitute newer libraries.

Generated executables, objects, payload staging and dist are excluded from Git. Go tests run during packaging, after payload generation. An engine build is required before packaging a clean checkout. The release source was prepared from the tested workspace; a complete clean-room engine rebuild from this publication folder has not yet been performed.

## Runtime files

Standard and SweetFX packs are bundled from installer/DefaultEffects. Additional effect packs and optional NVIDIA files are downloaded using the included manifests. A compatible neural-rendering model may need to be supplied separately. These are not a promise that every NVIDIA card supports every feature.

## Update compatibility

The display names are **0.21.6 stable** and **0.21.7 beta**. The beta's internal
release identity remains `0.21.7-beta.1` for existing updater compatibility;
the beta revision is omitted from the app's ordinary version display.

When publishing is explicitly authorised, use one installer asset per release:

| Release tag | Single EXE asset name | Display label |
| --- | --- | --- |
| `v0.21.6` | `OptiShade_Version_0.21.6.exe` | Optishade 0.21.6 stable |
| `v0.21.7-beta.1` | `OptiShade_Version_0.21.7-beta.1.exe` | Optishade 0.21.7 beta |

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

The read-only hardware temperature helper is built from installer/HardwareSensors.cs by build-installer-host.cmd using the Windows .NET Framework compiler. No sensor driver is bundled. CPU and additional sensor readings require a running Libre Hardware Monitor WMI provider; NVIDIA sensors use the installed system NVAPI.

