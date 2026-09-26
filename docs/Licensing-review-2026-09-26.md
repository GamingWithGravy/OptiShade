# Licensing review: 2026-09-26

Baseline: `3058628a6ed2b5161a26da04ba44a77ad01da2f9`.
Scope: repository licensing notices, listed manager candidates, their available
Git history and integration references. This is a technical provenance review,
not a legal opinion or a claim that every historical source was independently
verified. No runtime or installer implementation is changed.

## Proprietary-designated files

None. The proprietary register is deliberately empty. A dedicated licence and
dated boundary do not themselves establish ownership, legal separability or
exclusive rights over code already released under GPL. No source header was
changed. The new licence text is not a blanket source-code designation.

## GPL files intentionally unchanged

- Root LICENSE and optiscaler/LICENSE.
- optiscaler/OptiScaler/menu/optishade_effects_ui.inl.
- optiscaler/OptiScaler/menu/optishade_update_notice.inl.
- Other OptiScaler runtime menus, preset hotswap, rendering hooks and bridges.
- Shared runtime components and runtime-linked tests: no proprietary designation.
- addons/FusionCinema/LICENSE and installer/FusionCinema/LICENSE, and the existing
  Fusion Cinema shader/preset material.

## BSD/ReShade files intentionally unchanged

- reshade/LICENSE.md and all existing ReShade source notices.
- reshade/source/optishade_taa_bridge.inl and other integrated modifications.
- ReShade dependencies retain their component-specific terms; the repository map
  is not a substitute for those notices.

## Third-party files intentionally unchanged

- optiscaler/Licenses, optiscaler/external and reshade/deps.
- installer/DefaultEffects/Licenses, shader packages and standard shader headers.
- RenoDX attribution and the TAA CC BY-NC notice
  (installer/DefaultEffects/Licenses/OptiShade-TAA-THIRD-PARTY.txt).
- NVIDIA/vendor SDKs, runtime/model terms, download catalogues and external assets.

## Ambiguous files and candidate review

All paths below are relative to installer/. The first-add commits and current
integration references were checked. The history attributes these candidates to
the project maintainer; that records authorship claims, not an independent chain
of title. An initial repository import does not show pre-import development.
No absence of a third-party header is treated as proof of originality.

| Candidate | First-add commit | Evidence / unresolved boundary; existing licence retained |
| --- | --- | --- |
| main.go | 8fb6007 | Initial import; embeds the manager, GPL payload and helpers. No pre-import provenance record established. |
| manager.ps1 | 8fb6007 | Initial import; loads installer/helper scripts into the manager process. Ownership and whole-program boundary need review. |
| manager.xaml | 8fb6007 | Initial import; WPF layout consumed by manager.ps1. Original design provenance and combined-manager terms unresolved. |
| FusionSetup.cs | 8fb6007 | Initial import; hosts the PowerShell manager in process. Uses framework APIs; pre-import provenance unresolved. |
| DumpSummary.cs | 4b899b1 | Bounded .NET minidump reader referencing Windows SDK format; loaded by crash-dumps.ps1. Project-local introduction found, but proprietary/GPL manager combination not cleared. |
| compatibility.ps1 | 8fb6007 | Initial import; game/runtime capability and configuration handling. Pre-import provenance unresolved. |
| consent.ps1 | 8fb6007 | Initial import; manager dialogs and installation decisions. Provenance and combined-manager boundary unresolved. |
| crash-dumps.ps1 | 8b352c9 | Project-local introduction; loaded by diagnostics.ps1 and loads DumpSummary.cs. Combined-manager licensing not cleared. |
| diagnostics.ps1 | 0978e2b | Manager-loaded diagnostic workflows; depends on existing manager/helper functions. Separate proprietary boundary not established. |
| dialog-theme.xaml | eb7a3ae | Shared WPF templates loaded by manager dialogs; design provenance not independently established. |
| effects.ps1 | 8fb6007 | Initial import; third-party shader download/install workflow. Does not transfer shader ownership; helper provenance unresolved. |
| import-effects.ps1 | 0978e2b | Distributed as an installed helper and invoked by runtime optishade_zip_import.inl. Interoperation alone neither proves nor disproves separability. |
| library.ps1 | 8fb6007 | Initial import; game discovery, GPU detection and artwork handling. Code/artwork provenance must be separated. |
| menu-settings.ps1 | 0978e2b | Reads/writes runtime configuration; manager-loaded. Separate licensing clearance not established. |
| neural-download.ps1 | c4f693e | Vendor/community model download and configuration workflow. Model terms and helper ownership are separate questions. |
| nvidia.ps1 | 8fb6007 | Initial import; vendor download/signature checks. Vendor terms unaffected; pre-import provenance unresolved. |
| ownership.ps1 | 8fb6007 | Initial import; shared installation/restore functions. Broad manager dependency; pre-import provenance unresolved. |
| recovery.ps1 | c4f693e | Manager helper with runtime/preset recovery and Fusion Cinema references. Combined-manager boundary unresolved. |
| release-notes.ps1 | 9316f50 | Manager dialog and shared theme use. Separate proprietary boundary not established. |
| update-install.ps1 | f5b822c | Manager update entry point using existing helpers. Combined-manager boundary unresolved. |
| update-worker.ps1 | f5b822c | Update worker, UI and setup invocation. Separate ownership/separability clearance not established. |
| updates.ps1 | f5b822c | GitHub release lookup used by manager; project-local history found, but no independent proprietary boundary approved. |
| payload_test.go | 8fb6007 | Same Go package as main.go, testing its embedded payload; initial-import provenance unresolved. |

The tracked tests/ tree was inventoried and scanned for licensing notices and
integration. Manager tests load the existing scripts; C++ rendering/runtime tests
must not be blanket-designated proprietary. No tests are relicensed. Other
installer data, binaries, resources and files outside this candidate list receive
no proprietary designation without a separate review.

Branding candidates installer/OptiShade-icon.png, installer/OptiShade.ico,
installer/OptiShade-app.ico and docs/images/optishade.png are identified for origin
clarity. Their artwork history and any embedded third-party material were not
independently cleared for copyright relicensing. Existing artwork grants remain;
the branding notice addresses false official identity, not revocation of grants.

## Packaging/licence changes

- LICENSE.md adds a component map while preserving the root GPL LICENSE.
- LICENSES/GPL-3.0.txt and LICENSES/ReShade-BSD-3-Clause.txt are exact byte copies
  of the existing authoritative texts.
- LICENSES/OPTISHADE-PROPRIETARY.txt defines terms only for explicitly designated
  eligible revisions, preserving previous and hosting-platform grants.
- OPTISHADE_LICENSING.md records the date, baseline and empty designation register.
- LICENSING.md, NOTICE.md and BRANDING.md explain the same boundaries and origin.
- CONTRIBUTING.md requires explicit proprietary-use permission where applicable,
  with no implied copyright assignment.
- package.ps1 adds the new licensing documents and full texts to the installed
  licence directory, retaining every existing third-party copy operation.
  No executable has been rebuilt and existing released binaries are unchanged.

## Risk notes and clearance needed

Historical maintainer commits alone do not establish that all incorporated
expression was independently authored or that all contribution rights are held.
For imported files, obtain the original development/source records and any
third-party or contributor permissions. For integrated manager helpers, establish
the licence of the combined manager and its actual dependencies before applying
different terms. Legal review is needed where that boundary remains uncertain.

A copyright holder may offer material under different licences when entitled to
do so, but earlier GPL grants still permit use of those earlier copies. A cosmetic
header change cannot make previously granted code exclusive. Public GitHub terms
also grant in-service viewing/forking rights; the proprietary licence preserves
them. No technical or legal guarantee against copying is asserted.

References: [GNU licensing FAQ](https://www.gnu.org/licenses/gpl-faq.html),
[GitHub Terms of Service](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service).

## Final ownership-protection addendum

Reviewed against local commit `9f79fc0273f4fe13b2cde8cf5b0423d6934fd98c`.
This addendum expands identity, contribution and proprietary-term wording; it
supplies no new chain-of-title evidence for the unresolved candidates above.

### Confirmed proprietary OptiShade files

None. No source or asset was newly cleared and no proprietary source headers
were applied. Existing licensing remains authoritative.

### Confirmed proprietary Fusion Engine files

None. The name describes the integrated technology, not a blanket proprietary
implementation. No independently verified standalone Fusion Engine component
was identified in this checkout for designation.

### Component classifications

| Component | Classification and action |
| --- | --- |
| OptiScaler-derived runtime and incorporated OptiShade menus/hooks | GPL - derivative/combined; unchanged |
| ReShade and integrated ReShade modifications, including optishade_taa_bridge.inl | BSD / third-party; unchanged |
| shared/EffectsBridge.h, shared/TaaBridge.h | AMBIGUOUS as independently licensable interfaces; compiled into the existing runtime integration. Existing terms retained; no proprietary designation |
| Existing Fusion Cinema shader and preset copies | GPL under existing notices; unchanged |
| Manager/tooling candidates in the table above and associated tests | AMBIGUOUS for proprietary clearance; unchanged |
| NVIDIA, AMD/FidelityFX, Intel/XeSS, RenoDX, shader packs, CC TAA helpers and other dependencies | BSD / third-party or their specific GPL/CC/vendor terms, as applicable; unchanged |
| Existing logos/icons and documentation artwork, including docs/images/installer.png | AMBIGUOUS for new copyright restrictions; prior grants and any third-party imagery remain intact |
| Other original documentation, diagrams, presets and release artwork | No new file-specific clearance; no proprietary designation |

The shared headers define runtime interfaces; their comments use "private" to
describe those interfaces, not to establish a proprietary copyright licence.
Their current contents and available history were inspected. These boundaries
do not infer legal independence from filenames or from a DLL/process boundary.

### Private-repository candidates

No existing file is cleared for removal from public distribution in this review.
If independently developed and legally separable future Manager/tooling or
Fusion Engine support components are cleared, private development may reduce
casual copying. Such future components could instead be public under express
proprietary terms, subject to hosting-platform rights; public visibility cannot
make copying technically impossible. No source is moved or deleted here.

GPL-covered distributions must continue to provide corresponding source by a
GPL-compliant method. GPL does not universally require a public GitHub repository;
source obligations to recipients must still be met. BSD also does not generally
require publishing modified source, but its notices and conditions remain
mandatory. This task deliberately preserves both existing source trees and all
notices, rather than changing their publication model.

### Historical rights

Earlier releases and revisions keep every licence grant validly made for them,
including the existing GPL Manager code and Fusion Cinema. New proprietary terms
cannot prevent reuse of copies obtained under those grants. No tags, releases,
source history or previously granted rights are removed.

### Remaining legal risks

Ownership/separability clearance is still needed before any proprietary register
entry. A new ownership statement does not resolve it. Exclusive ownership of
outside contributions would require an appropriate lawyer-drafted agreement/CLA;
the current contribution policy requires written permission without inventing
an assignment. Branding terms claim neither registered trademark status nor
rights in unrelated uses of "Fusion Engine". Platform rights, lawful references,
ideas and independently implemented functionality are not excluded.

### Final changes and checks

The proprietary licence now expressly covers reuploads, mirrors, repackaging,
copied/modified binaries and covered UI/design assets, only where validly
designated. Ownership, Fusion Engine identity, README origin, component maps and
contributor rules agree that the register remains empty. The existing licensing
packaging block automatically includes these revised documents. No functional
code, application version, package operations or dependency licence texts changed
in this addendum. No executable is built and no release is created.
