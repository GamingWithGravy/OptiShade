# OptiShade ownership and component licensing

Copyright (c) 2026 gravy / GamingWithGravy for original OptiShade contributions.
Third-party contributions remain the property of their respective authors.
Ownership and permission to use a work are different: a software licence grants
specified permissions without transferring the author's copyright.

This document explains the applicable licences; it does not replace their full
texts, relicense third-party work, or withdraw permissions already granted.
File-level notices and the applicable licence texts take precedence over this
summary. The GNU GPL text in LICENSE is retained unchanged.

## Original OptiShade work

Original OptiShade contributions are credited to gravy / GamingWithGravy to the
extent original. Their applicable licence depends on the component and its
provenance, not just the author's identity or the directory containing it.
See [OPTISHADE_LICENSING.md](OPTISHADE_LICENSING.md) for the component boundaries
and the policy for future independently owned work.
The boundary is dated 2026-09-26 against baseline commit
3058628a6ed2b5161a26da04ba44a77ad01da2f9. LICENSE.md provides the mixed-licence
map; LICENSES/OPTISHADE-PROPRIETARY.txt supplies terms only for expressly
designated eligible revisions. The current proprietary source register is empty.

OptiScaler-derived runtime code and OptiShade additions forming part of that
GPL-covered runtime remain GPL-3.0. ReShade retains its BSD 3-Clause terms.
Separately identified original standalone Manager/tooling may carry All Rights
Reserved terms in future versions only where ownership and legal separability
are established and third-party obligations permit it. No current source file
is designated proprietary by this cleanup: existing manager/tooling licences
remain unchanged pending file-specific provenance review. Previously released
GPL versions retain all previously granted GPL rights.

Existing Fusion Cinema material retains the GPL-3.0 licences in
addons/FusionCinema/LICENSE and installer/FusionCinema/LICENSE.

Recipients may copy, modify and redistribute GPL-covered work under that
licence. Distribution must comply with its notice, licensing and corresponding
source requirements. Modified versions must be identified as modified as the
licence requires. OptiShade authorship must not be falsely attributed to someone
else; required copyright and licence notices must be preserved.

There is no proprietary or "no reuse" exception for GPL-covered contributions.
Merely identifying code as original does not remove its licence permissions.
File-level notices control where more specific; nothing in this summary
overrides third-party licence rights.

## Upstream components

| Component | Applicable terms | What the terms mean |
| --- | --- | --- |
| OptiScaler-based performance engine and GPL-covered modifications | LICENSE and optiscaler/LICENSE (GPL-3.0) | Copying and modification are permitted; redistribution must comply with GPL requirements, including corresponding source and notices. |
| ReShade | reshade/LICENSE.md (BSD-3-Clause) | Reuse and modification are permitted with the required copyright, conditions and disclaimer; upstream names cannot be used for endorsement without permission. |
| RenoDX-derived portions and other dependencies | Their notices in optiscaler/Licenses, optiscaler/external and reshade/deps | Retain each component's attribution and comply with its own terms. OptiShade does not claim their original authorship. |
| Shader packages | Their individual licences, installed under OptiShadeData/Licenses | Permissions vary by author and package. Do not assume every shader uses the project's GPL licence. |
| TAA motion-estimator helper | installer/DefaultEffects/Licenses/OptiShade-TAA-THIRD-PARTY.txt (CC BY-NC 4.0) | Attribution and non-commercial restrictions apply to that separately identified material. |
| Optional NVIDIA runtimes and other vendor components | The vendor's applicable terms | This project does not grant additional rights to vendor binaries, SDKs or model weights. |

## OptiShade name, logo and endorsement

The OptiShade identity belongs to its respective rights holder. No trademark or
endorsement permission is granted to market an independent fork or product as
official OptiShade, or as endorsed by gravy / GamingWithGravy. No registered
trademark status is asserted.

Accurate references, legally permitted uses and required attribution remain
permitted. These identity protections do not prohibit copying or modification
of software or artwork where an existing licence permits it. See BRANDING.md.

## Separate future work

Future independently developed material can carry separate terms only where
its owners have the necessary rights and those terms are compatible with its
dependencies and distribution. No such future restriction applies retroactively
to existing grants. The designation process and proprietary-material disclaimer
are in OPTISHADE_LICENSING.md. This summary grants no rights to private research
or vendor model weights.
