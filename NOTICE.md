# Source and dependency notices

The legacy loose TAA helper source retains its CC BY-NC 4.0 notices and is
not included in these candidate payloads. The Beta internal core guide is
original GPL-3.0-or-later source (reshade/res/shaders/optishade_guides.hlsl),
with generated DXIL/SPIR-V and build-core-guides.ps1. It does not use the
legacy helper's includes, textures or motion-estimator source. No legacy
third-party material is relicensed by this replacement.

Optishade's installer and integration were created by gravy. The modified performance engine is based on OptiScaler-DLSSNR-PreSR-Multipass, licensed under GPL-3.0; ReShade carries its BSD-3-Clause licence. RenoDX-derived portions retain their attribution. This project does not claim original authorship of those components.

See:
- LICENSE and optiscaler/LICENSE
- reshade/LICENSE.md
- optiscaler/Licenses/ (including RenoDX attribution)
- optiscaler/external/ and reshade/deps/ for dependency-specific licences
- optiscaler-revision.txt and reshade-revision.txt for engine baseline revisions

Downloaded effects retain their authors' licences, installed under OptiShadeData/Licenses/Shaders. Optional NVIDIA components remain subject to NVIDIA's applicable terms. The custom interface does not include DLSS 5 Manager UI source or assets.

## OptiShade contributions and reuse

See LICENSING.md for the component-by-component ownership and licensing summary.
See OPTISHADE_LICENSING.md for the boundary between GPL-covered runtime work,
BSD-covered ReShade work and eligible future standalone OptiShade components.
LICENSE.md provides the licence map. LICENSES contains full GPL and ReShade BSD
texts and the OptiShade Proprietary Licence for expressly designated eligible
standalone revisions. The local 2026-09-26 designation covers only the standalone
launcher, host and three logo/icon assets listed in OPTISHADE_LICENSING.md;
embedded payloads and hosted scripts retain their own terms. Official branding
is not granted for use as another
distribution's identity, subject to existing rights and the BRANDING.md exceptions.
These identity rules also cover OptiShade Fusion Engine branding where owned by
the project maintainer. Fusion Engine implementation components retain their
individual licences; its name is not a claim of proprietary ownership over
OptiScaler, ReShade, RenoDX or vendor material.

OptiShade-specific manager workflows, user interface integration, installation ownership/update handling, compatibility safeguards and associated tests are project contributions credited to gravy / GamingWithGravy, to the extent original. This attribution does not assert ownership of upstream algorithms, SDKs, model weights, shader packages or contributors' work. Existing file-level notices and revision history remain authoritative.

The project is distributed under the GPL-3.0 terms in LICENSE where applicable; separately identified components retain their own licences. OptiShade modifications to GPL-covered code remain GPL-covered. Attribution is not an additional prohibition on copying, modification or redistribution permitted by those licences. Existing grants are not revoked by this notice.

Original standalone OptiShade Manager/tooling may be separately licensed for
future versions only where explicitly identified, independently owned and legally
separable. No unlisted source file is relicensed by this change.
Original branding and eligible future assets may be separately protected, without
overriding existing grants. Third-party material remains the property of its
respective authors; its licence and attribution requirements remain intact.

Copyright (c) 2026 gravy / GamingWithGravy for original OptiShade contributions. Ownership remains with the respective authors; licensing the software does not transfer that ownership. Preserve copyright and licence notices as required by each applicable licence.

See BRANDING.md for the distinction between software permissions and use of the OptiShade name or logo to imply official endorsement. AMD Neural Rendering research tools and model weights are not included in this release.

Optional RTXMFG is unchanged third-party work by Michael Robles / dashdogy,
licensed under MIT. It is not OptiShade proprietary material. The packaged
Licenses/RTXMFG directory preserves the upstream MIT, Ultimate ASI Loader,
ImGui and MinHook notices, source/release references and binary provenance.
See https://github.com/dashdogy/RTX40MFG-Unlock. Other upstream dependencies
retain their own notices, including those embedded in the upstream binary.

The source-built OptiShadeMFG component derives from mcsoderh/RTX30MFG-Unlock,
revision 21a2b9931f0c13f46a4b3b8a5856620d9698f88e. Upstream MIT notices credit
Michael Robles and Marcus Soderholm; the exact upstream spelling is retained
in its LICENSE.txt. MinHook retains its own licence. The OptiShade integration
adapter and shared bridge retain GPL-3.0-or-later terms. This is a modified
combined component, not an unchanged MIT-only binary. Its packaged source-build
manifest identifies the exact DLL and source inputs. Vendor runtime rights are
separate from the upstream MIT grant.

This software is based in part on the work of the FreeType Team (https://www.freetype.org). Full FreeType, Detours, JSON for Modern C++, Streamline header and additional dependency notices accompany the distribution under LICENSES/ThirdParty. Header versions do not by themselves establish the build provenance of a prebuilt static library.
