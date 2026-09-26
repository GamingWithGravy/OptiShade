# OptiShade component licensing policy

OptiShade contains components under different licences. Copyright ownership does
not by itself cancel permissions granted by a licence. This policy identifies
boundaries; it does not replace component licence texts or relicense third-party
material. Specific file-level notices and applicable third-party licences take
precedence over general project summaries. No statement here overrides rights
granted by those licences.

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

Original standalone OptiShade Manager/tooling code first published or materially
revised after this licensing boundary is All Rights Reserved **only where
explicitly designated, independently owned and legally separable** from
GPL/BSD/third-party components. A date, a new commit or a header-only change is
not evidence of ownership or separability and does not erase earlier grants.

Previously published versions remain available under the licences under which
they were released. The proprietary designation applies only to eligible future
revisions/files expressly marked as such. The same code remains available under
any earlier GPL grant; no exclusivity over previously granted material is claimed.

### Proprietary OptiShade components

**None designated at this boundary.** Candidate source files have not been
cleared for proprietary treatment. See [docs/Licensing-review-2026-09-26.md](docs/Licensing-review-2026-09-26.md)
for the evidence, integration concerns and outstanding provenance questions.

Any file not expressly listed or carrying an applicable, valid proprietary
header remains governed by its existing licence. Future entries must identify
the path, first designated revision, review evidence and any third-party exclusions.
The dedicated terms are [LICENSES/OPTISHADE-PROPRIETARY.txt](LICENSES/OPTISHADE-PROPRIETARY.txt).

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

This cleanup does not designate any existing source file as proprietary. The
existing manager/tooling files retain their applicable licences. Their history
records project authorship and prior publication, but is not a complete
provenance or separability determination. In particular, `installer/main.go`,
`manager.ps1`, `manager.xaml`, `FusionSetup.cs`, `DumpSummary.cs`, the other
installer scripts, and associated tests are not relicensed by this policy.
Mixed or uncertain material keeps its existing licence pending a file-specific
review; absence of a header does not establish proprietary status.

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
