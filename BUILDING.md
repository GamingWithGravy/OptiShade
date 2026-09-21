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
.\build-performance.cmd
.\build-reshade.cmd
.\build-installer-host.cmd
powershell -NoProfile -File .\package.ps1
```

Use a PowerShell environment permitted to run your locally reviewed build scripts. Network access is needed for the pinned Go resource generator on its first run. Check each command succeeds before continuing.

The first two commands compile the engine DLLs. The third builds the WPF/PowerShell host and icon resources. package.ps1 assembles the payload, verifies embedded hashes and script encoding, and builds `dist/OptiShade_Version_0.19.17.exe`. The three text guides under installer/Help are embedded in the EXE.

Generated executables, objects, payload staging and dist are excluded from Git. Go tests run during packaging, after payload generation. An engine build is required before packaging a clean checkout. The release source was prepared from the tested workspace; a complete clean-room engine rebuild from this publication folder has not yet been performed.

## Runtime files

Effect packs and optional NVIDIA files are downloaded during installation using the included manifests. A compatible neural-rendering model may need to be supplied separately. These are not a promise that every NVIDIA card supports every feature.
