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

Original manager workflows, interface code, installation and update handling,
integration code, compatibility safeguards, diagnostics and tests are credited
to gravy / GamingWithGravy to the extent original. They are distributed under
the project's existing GPL-3.0 licence unless a file has a separate applicable
licence. Original modifications to GPL-covered components remain GPL-covered.
Fusion Cinema retains the GPL-3.0 licence in installer/FusionCinema/LICENSE.

Recipients may copy, modify and redistribute GPL-covered work under that
licence. Distribution must comply with its notice, licensing and corresponding
source requirements. Modified versions must be identified as modified as the
licence requires. OptiShade authorship must not be falsely attributed to someone
else; required copyright and licence notices must be preserved.

There is no proprietary or "no reuse" exception for this release's original
GPL-covered contributions. Merely identifying code as original does not remove
the permissions granted by its licence.

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
to this release. Private research, private prompts and model weights are not
granted a licence by this document and are not included in this release.
