# OptiShade source (stable)

This branch contains the source code for **OptiShade 1.0** as released. To install OptiShade, use the installer from the [latest release](https://github.com/GamingWithGravy/OptiShade/releases/latest); you do not need anything from this branch to play.

## What is here

| Folder | Contents |
| --- | --- |
| `Beta/installer` | The OptiShade launcher (Go and PowerShell), its WPF interface, the Update Manager, per-game installation, ownership, backup and restore, and the Troubleshooter (`Beta/installer/Troubleshooter`). |
| `Beta/distribution` | The installer (`bootstrapper`), the signed channel tools and the component packaging scripts. |
| `Beta/optiscaler` | OptiShade's OptiScaler-based runtime, including Neural Rendering and the OptiMFG RTX backend (`external/RTX40MFG-Unlock`). |
| `Beta/reshade` | The ReShade-based runtime and in-game interface. |
| `Beta/shared` | Code shared between the runtimes and the launcher (control protocol, panel UI). |
| `Beta/legacy-nr`, `Beta/routes`, `Beta/xplane-camera` | Legacy Neural Rendering host, simulator routes and the X-Plane 12 camera work. |
| `tests/reconstruction` | Automated tests and fixtures. |

Compiled programs and libraries are not included. Official builds come from the signed release channels (`launcher-stable`, `core-stable`, `effects-stable`, `optimfg-stable`) and the installer on the Releases page. See `Beta/BUILDING.md` for build notes.

## Licensing

OptiShade combines components under different licences. Each file and component keeps its own licence:

- OptiShade's own designated material: see [`Beta/OPTISHADE_LICENSING.md`](Beta/OPTISHADE_LICENSING.md) and [`Beta/LICENSES/OPTISHADE-PROPRIETARY.txt`](Beta/LICENSES/OPTISHADE-PROPRIETARY.txt).
- GPL and BSD components (including OptiScaler and ReShade): see [`Beta/LICENSES`](Beta/LICENSES) and the notices in each component's folder.
- Third-party SDKs and libraries keep their own licences and notices in their folders.

Publishing this source does not change any of those licences. Read [`Beta/OPTISHADE_LICENSING.md`](Beta/OPTISHADE_LICENSING.md) before reusing any part of it.

## Reporting problems

Use **Troubleshooting** in OptiShade to send a report, then share the report ID in the OptiShade Discord.
