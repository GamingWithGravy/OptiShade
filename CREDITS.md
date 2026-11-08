# Credits and component licensing

OptiShade is assembled from independently maintained software and content. This summary is not a replacement for a component's licence text. Each downloadable package must ship the exact notices and corresponding source required for that package.

## First-party work

- **OptiShade / Fusion Engine integration:** gravy / GamingWithGravy.
- **OptiMFG controller and OptiShade integration:** gravy / GamingWithGravy. This does not transfer ownership of upstream or vendor code used by its backend.
- **Image Effects / Look Editor integration:** gravy / GamingWithGravy, with shader authors individually credited in their original notices.

## Third-party work

| Work | Creator / source | Distribution rule for OptiShade |
| --- | --- | --- |
| OptiScaler | OptiScaler project contributors | GPL-3.0. Distributed binaries must include the applicable notices and corresponding source for the exact covered build and modifications. The Core channel is not publishable until this source bundle is reviewed. |
| ReShade | crosire and contributors | BSD 3-Clause. Preserve the copyright notice, licence conditions and disclaimer in binary distributions and derivative portions. |
| RTXMFG backend | Michael Robles / dashdogy, [RTX40MFG-Unlock](https://github.com/dashdogy/RTX40MFG-Unlock) | The pinned upstream DLL is kept unchanged under MIT. Include its MIT licence and all required third-party notices. Do not present it as OptiShade-authored code. |
| Glass Cockpit DLSS Fix | IFreemz, [official repository](https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix) | GPL-3.0-only with project-specific attribution and notice requirements. Credit the name and creator, link to the upstream repository, and include its licence, NOTICE and third-party notices if redistributed. |
| AtmosphereMod | tomwhoca, [official repository](https://github.com/tomwhoca/AtmosphereMod) | The author's licence does not permit redistribution. OptiShade downloads the official release after the user chooses the component; no AtmosphereMod binary is included in OptiShade branch packages. |
| NVIDIA DLSS / Streamline / models | NVIDIA | NVIDIA terms apply. OptiShade does not grant redistribution rights; use the existing official/pinned download path. |
| AMD FidelityFX, Intel XeSS, SDKs and other runtime dependencies | Respective owners | Preserve each applicable licence and notice. Review the exact package inventory before publication. |
| Shader effects and presets | Individual authors and upstream shader projects | Licences vary by file. Preserve individual authorship/licence notices. Files without a verified redistribution grant are excluded. The legacy TAA helper identified as CC BY-NC is excluded from the new effects package. |

## Publication gate

- **Core:** provide the matching source and notices for GPL-covered OptiScaler and OptiShade runtime modifications; exclude launcher, installer, PDBs, test data and unrelated proprietary source.
- **OptiMFG:** include OptiShade-owned controller files only as authorized, and carry the pinned RTXMFG MIT text, all upstream third-party notices, source provenance, version and hashes. Never include NVIDIA private models or driver files.
- **Effects:** publish only files with a checked redistribution licence; include per-file attribution/notices and exclude non-commercial or unclear-rights files.
- **Glass Cockpit:** keep the existing official-source install/update method and required creator credit/notices.
- **AtmosphereMod:** do not upload its ZIP, binaries or source to OptiShade branches.
- **Legacy:** EXE downloads only after confirming that each candidate is a public release, not an unpublished development build; never include source, installer or launcher in that branch.

This document is a practical distribution checklist. The individual licence files shipped beside each package remain authoritative.


