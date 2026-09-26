# OptiShade component licensing policy

OptiShade contains components under different licences. Copyright ownership does
not by itself cancel permissions granted by a licence. This policy identifies
boundaries; it does not replace component licence texts or relicense third-party
material. Specific file-level notices and applicable third-party licences take
precedence over general project summaries. No statement here overrides rights
granted by those licences.

## Ownership of original OptiShade / Fusion Engine material

Copyright (c) 2026 gravy / GamingWithGravy for independently created and owned
original project material. All Rights Reserved **only for validly designated
proprietary material**, subject to applicable law, platform terms and earlier
licence grants. This is not an All Rights Reserved designation of the repository.

Original code, tooling, user interfaces, workflows, documentation, artwork,
diagnostic, installer and compatibility systems remain the property of their
respective copyright holders. Original contributions owned by gravy /
GamingWithGravy remain owned by that rights holder even when licensed under GPL
or BSD; ownership is distinct from recipients' licence permissions. No exclusive
ownership is claimed over third-party contributions, ideas or general architecture.

For expressly designated proprietary material, no additional permission is
granted to copy, modify, redistribute, reupload, mirror, repackage, rebrand,
sublicense, sell, publish or incorporate it into another application without
prior written permission. The dedicated proprietary licence supplies the full
terms and exceptions. Existing GPL/BSD/CC/vendor and earlier grants prevail for
their material. The register below, not this ownership statement, defines scope.

## Fusion Engine identity and implementation

Fusion Engine and OptiShade Fusion Engine identify this project's technology
where owned by gravy / GamingWithGravy. Identity and endorsement are addressed
in BRANDING.md; no registered trademark or exclusive right to unrelated uses of
the words is asserted.

The implementation is not one proprietary work by virtue of its name. Its
OptiScaler-derived runtime and incorporated OptiShade modifications remain GPL;
ReShade-derived portions retain applicable BSD terms. RenoDX, shaders, CC-licensed
TAA helpers, NVIDIA, AMD, Intel/XeSS and other dependencies retain their own terms.
Standalone Fusion Engine support tools require the same file-specific provenance
and separability review as Manager code before proprietary designation.

## GPL-covered work

The root [LICENSE](LICENSE) remains the GNU GPL version 3. It governs GPL-covered
portions where applicable, including `optiscaler/`, OptiScaler-derived code, and
OptiShade modifications that form part of that runtime. Runtime menus, bridges,
and other additions forming part of the GPL-covered work remain GPL-covered;
calling them original OptiShade code does not make them proprietary.

Recipients retain the GPL's copying, modification and redistribution rights,
subject to its requirements, including notices and corresponding source.
Proprietary terms for separate material must not restrict those rights.

## ReShade and other third-party components

ReShade and ReShade-derived material retain their existing
[BSD 3-Clause terms](reshade/LICENSE.md), including copyright notices, conditions,
disclaimer and non-endorsement clause. Existing terms for integrated OptiShade
ReShade modifications, including `reshade/source/optishade_taa_bridge.inl`, are
unchanged.

RenoDX-derived material, dependencies, shaders, presets, NVIDIA runtimes, SDKs,
model files and other vendor material remain owned by their respective authors
and governed by their own terms. OptiShade does not grant additional rights to
them. See [NOTICE.md](NOTICE.md) and [LICENSING.md](LICENSING.md).

## Licensing boundary and designation register

Boundary date: **2026-09-26 (Europe/London)**. Repository baseline:
`3058628a6ed2b5161a26da04ba44a77ad01da2f9`, the state immediately before this
licensing change. The boundary begins with the commit introducing this section;
it does not retroactively apply to the baseline or earlier versions.

Original standalone OptiShade Manager/tooling code offered in designated
distributions after this licensing boundary is All Rights Reserved **only where
explicitly designated, independently owned and legally separable** from
GPL/BSD/third-party components. A date, a new commit or a header-only change is
not evidence of ownership or separability and does not erase earlier grants.

Previously published versions remain available under the licences under which
they were released. The proprietary designation applies only to eligible future
revisions/files expressly marked as such. The same code remains available under
any earlier GPL grant; no exclusivity over previously granted material is claimed.

### OptiShade Proprietary Material

The following files are expressly designated for the revised local distribution
dated **2026-09-26**, in the patch based on
`55547f60ecc13cb9468da7d7cda05fdfe3186472`. This is a source licensing change,
not an application release or a retroactive change to v0.20.11 or earlier copies.

| File | Designated scope and evidence |
| --- | --- |
| installer/main.go | Original standalone extraction/launcher code; owner-confirmed project creation, standard-library imports, payload extracted as separate files rather than linked runtime code |
| installer/FusionSetup.cs | Original standalone Windows/.NET PowerShell host; owner-confirmed project creation, framework-only build references; hosted scripts are not covered by this designation |
| installer/OptiShade-icon.png | Owner-confirmed original logo artwork; adjacent installer/BRANDING-LICENSE.md notice |
| installer/OptiShade.ico | Owner-confirmed original icon artwork; same adjacent notice |
| installer/OptiShade-app.ico | Owner-confirmed original application icon artwork; same adjacent notice |

See [docs/Ownership-licensing-audit.md](docs/Ownership-licensing-audit.md) for the
current file register, evidence and outstanding questions. The earlier
Licensing-review-2026-09-26.md is a historical review, not the current register.

Any file not expressly listed or carrying an applicable, valid proprietary
header remains governed by its existing licence. Future entries must identify
the path, first designated revision, review evidence and any third-party exclusions.
The dedicated terms are [LICENSES/OPTISHADE-PROPRIETARY.txt](LICENSES/OPTISHADE-PROPRIETARY.txt).

No additional Fusion Engine implementation files are designated. No source or
artwork becomes proprietary solely through ownership or branding wording. Each
approved future file must appear
in this register and carry a matching notice (or an adjacent notice for binary
assets), with its first designated revision recorded.

## Future standalone OptiShade Manager and tooling

Future versions of genuinely original, independently owned and legally separable
OptiShade Manager, installer, updater, diagnostics or management tooling may carry
the following notice after ownership, provenance and dependency obligations have
been checked:

> Copyright (c) 2026 gravy / GamingWithGravy. All Rights Reserved.

This is not a blanket designation of `installer/`, tests, integration code or
other source directories. A future proprietary designation must explicitly
identify the covered files and version, preserve required third-party notices,
and state any permissions supplied to users. Merely distributing or managing a
GPL program does not automatically determine a separate program's licence;
neither does placing code in a separate directory prove legal separability.
GPL-derived or combined GPL-covered work cannot use this proprietary designation.

For a verified eligible source file, a language-appropriate comment may use:

```text
Copyright (c) 2026 gravy / GamingWithGravy. All Rights Reserved.

This file is an original standalone OptiShade component.
Licensed under the OptiShade Proprietary Licence.
See LICENSES/OPTISHADE-PROPRIETARY.txt and OPTISHADE_LICENSING.md.
Previously granted rights remain intact.
```

Unless expressly permitted in writing by the rights holder or by applicable law,
separately designated proprietary material may not be copied, modified,
redistributed or incorporated into another product. This restriction applies
only to material validly designated under these terms, never to GPL/BSD-covered
code, third-party material or rights already granted under another licence.
Applicable hosting-platform permissions also remain intact. The dedicated
proprietary licence controls proprietary terms; this section is a summary.

To the extent permitted by applicable law, original proprietary portions are
provided "AS IS", without express or implied warranties, including merchantability,
fitness for a particular purpose and non-infringement. Their rights holders are
not liable for claims or damages arising from their use. This disclaimer does
not replace third-party disclaimers or exclude rights that cannot lawfully be
excluded.

## Existing files and previous releases

Only the five files in the explicit register receive the new designation for
this distribution. Other manager/tooling files, including manager.ps1,
manager.xaml, DumpSummary.cs, other installer scripts and associated tests, keep
their existing terms. Ownership confirmation for the dump reader does not by
itself clear its direct loading into the still-GPL diagnostic script combination.
Mixed or uncertain material keeps its existing licence pending a file-specific
review; absence of a header does not establish proprietary status. An owner with
the necessary rights can offer an independently separable work under different
terms without a substantive rewrite. That does not withdraw earlier grants.

Previously released GPL versions retain the GPL rights already granted to them.
Future separately licensed work does not revoke those grants. Existing Fusion
Cinema material retains the licences in `addons/FusionCinema/LICENSE` and
`installer/FusionCinema/LICENSE`. A separately developed replacement would require
a separate ownership and provenance review.

## Branding, documentation and assets

Original OptiShade logos, icons and branding are distinct from software licensing.
The software licences do not grant permission to present an unofficial product
as official OptiShade or imply endorsement by gravy / GamingWithGravy. See
[BRANDING.md](BRANDING.md) for permitted attribution and nominative references.
No registered trademark status is claimed.

Future original documentation, artwork or presets may be separately designated
All Rights Reserved only after ownership and existing grants are checked. This
policy does not retroactively relicense existing artwork, documentation, presets
or third-party assets. It asserts no ownership of third-party game imagery.

## Forks and distribution

Forks must comply with each component's actual licence and identify their own
maintainer without false official affiliation. Branding rules must not be used
to restrict GPL rights. Preserve applicable copyright notices, licence texts,
attribution and source obligations. When a general summary conflicts with a
specific applicable licence or an existing grant, that licence or grant controls.
