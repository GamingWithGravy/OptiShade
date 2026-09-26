# Ownership and licensing audit

Review date: 2026-09-26. Exact starting HEAD:
`55547f60ecc13cb9468da7d7cda05fdfe3186472` (maintenance/flight-sim-local).
The supplied reference documents match that tree, ignoring checkout line endings.
The remote main observed during review is `3058628a6ed2b5161a26da04ba44a77ad01da2f9`.
No push, release, version change or executable build is part of this patch.

## Decision and effective boundary

Five files are designated for this revised local distribution:

- installer/main.go
- installer/FusionSetup.cs
- installer/OptiShade-icon.png
- installer/OptiShade.ico
- installer/OptiShade-app.ico

The two source files have explicit headers; the three unchanged binary assets
have the adjacent installer/BRANDING-LICENSE.md notice. The effective local
designation is the 2026-09-26 patch based on the exact HEAD above, not any existing
application tag. A future public distribution must carry these notices and full
terms. Source and artwork previously obtained under GPL remain usable under that
grant. No substantive rewrite is required merely to offer an owner's separable
work on other terms, but no exclusive rights over earlier granted copies result.

The owner confirmed original project authorship of the launcher, host, dump
reader and three logo/icon assets. This evidence is used alongside content,
history and architecture checks, not as an assertion of ownership of third-party
material. No conversation transcript or private instruction is reproduced here.

## Architecture findings that refine the earlier review

1. installer/main.go imports only the Go standard library. It embeds files as
   data, extracts them and starts FusionSetup.exe as a separate process. It does
   not link to or call the graphics runtime. The package is treated as an
   aggregation of separately licensed components; its GPL payload remains GPL
   with source and notices, not proprietary merely because it is embedded.
2. build-installer-host.cmd compiles FusionSetup.cs against .NET and Windows
   PowerShell assemblies. FusionSetup.cs invokes a script through the standard
   PowerShell hosting API. No OptiScaler/ReShade library, header, private runtime
   structure or GPL library call is part of that host. Its script-host role is
   distinguished from the licence of scripts being executed. Framework/runtime
   terms remain applicable; they are not claimed as project-owned.
3. manager.ps1 loads manager helper scripts and WPF resources. Those helpers are
   not made proprietary just by changing the host's terms. Read-only process
   module inspection in diagnostics is not loading a game DLL into the manager.
4. DumpSummary.cs is a generic .NET minidump parser, but crash-dumps.ps1 explicitly
   loads it through Add-Type and invokes its class in process. The diagnostic
   scripts remain GPL in this patch. Ownership of the reader is confirmed;
   compatibility of that linked distribution if the reader alone were exclusive
   remains unresolved. Keep it GPL pending a coherent diagnostic-component
   review or appropriate permissions. This is not a claim that an owner can
   never relicense their own diagnostic code.
5. import-effects.ps1 is called by both the manager and the GPL runtime. The
   runtime invokes PowerShell with file/path arguments and reads an OK/ERROR
   result file; no shared runtime objects are passed. This is evidence of process
   separation, not automatic legal clearance. Its copied-code provenance and
   whether the specialised installed helper is required corresponding source for
   the runtime feature still need resolution before exclusive designation.
6. Shared C++ interfaces and policy headers are incorporated into graphics
   runtime builds. They are not standalone Manager programs and are not
   proprietary-designated. The Fusion Engine label changes none of these facts.

## History, upstream comparison and limits

The public v0.19.17 tag contains the root GPL text and a NOTICE attributing the
installer/integration to gravy. v0.20.8 (bdec4f3) explicitly states that original
manager/interface/install/update/diagnostic/test work is distributed under GPL
unless separately licensed. v0.20.9 (8b352c9), v0.20.10 (4b899b1) and v0.20.11
(2439aad) preserve that statement. The tags and current remote refs were inspected;
previously downloaded release binaries are not modified or relicensed.

The file register records each candidate's first repository addition and earliest
containing release tag. A containing tag proves presence in tagged source, not an
independent verification of every downloadable release asset. Earlier root-GPL
coverage is preserved conservatively; v0.20.8 makes Manager coverage explicit.

Recorded candidate authors are the gravy / GamingWithGravy identities using the
same account email, unless separately noted. No external author or assignment
was found in these candidate histories; that alone is not proof that no code was
copied. The two cleared sources were read completely and their framework imports,
build references and calls inspected. Distinctive launcher/host/dump-reader text
was searched in the local OptiScaler/ReShade trees with no matches. Whole-file
blob comparison and targeted searches are limited evidence, not an exhaustive
internet plagiarism search. Earlier local prototype folders were checked for
pre-import launcher/artwork context; the owner's specific authorship confirmation
resolves the creation question for the designated files, not all other files.

The remaining Manager rows specify the particular content whose creation or
dependency boundary remains unconfirmed. Framework API usage and an initial Git
import are not, by themselves, reasons to forbid proprietary distribution.

## Other obligations and private-source options

OptiScaler-derived runtime remains GPL, ReShade remains BSD, Fusion Cinema retains
its GPL grants, and RenoDX, CC TAA helpers, shaders and vendor dependencies retain
their notices and terms. The original GPL and ReShade texts, source trees and
third-party notice folders are unchanged. GPL corresponding-source requirements
remain independently applicable to distributions of the GPL components.

The two designated standalone sources are candidates for private development of
future versions, after confirming their distribution boundary remains as audited.
The original artwork source can also be developed privately. No current public
file/history is moved or deleted. Existing public copies retain their grants.
Public proprietary source remains subject to platform viewing/forking rights and
is technically copyable. GPL requires compliant source availability, not always
a public GitHub repository; BSD does not generally mandate source publication.

Legal review should confirm the aggregation/host boundary before shipping a
mixed proprietary build, the linked diagnostic boundary before extending the
register, and any contribution agreement intended to secure exclusive ownership.
No guarantee of absolute exclusivity, copyright validity in every jurisdiction,
or protection against independent implementation is made.

## Validation and distribution

Only two source comment headers, licensing documentation and licence-copy lines
in package.ps1 change. The revised documentation names only gravy /
GamingWithGravy as owner. The licence preserves prior grants and platform rights
and grants end users permission to install/run lawful official builds, including
necessary extraction and artwork display. Unlisted files retain existing terms.

Package validation is performed in a temporary directory using only the licence
copy block, without building or executing the installer. The review ZIP is a
changed-file patch against the exact starting HEAD, not a complete source tree
or an installer; its short review README records how to assess it.

## Per-file register

Abbreviations: G = recorded gravy / GamingWithGravy author identity. GPL-existing
means the existing project grant, with more-specific third-party terms preserved.
First-public evidence identifies the first addition and earliest containing tag;
it does not assert unverified release binary contents. "Needs fact" is a current
decision to retain existing terms, not a blanket legal conclusion of dependence.

| Path | Current licence | First addition / containing public tag | Recorded owner/contributors | Copied/third-party evidence | Coupling | Conclusion | Next action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| build-compat-test.cmd | GPL-existing | 0978e2b / v0.20.5 | G (recorded) | Build-tool invocations and paths do not prove script origin | Build/test orchestration | needs fact | Confirm original script content; preserve upstream build dependencies |
| build-env.cmd | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Build-tool invocations and paths do not prove script origin | Build/test orchestration | needs fact | Confirm original script content; preserve upstream build dependencies |
| build-foundation-test.cmd | GPL-existing | c1e341f / v0.20.7 | G (recorded) | Build-tool invocations and paths do not prove script origin | Build/test orchestration | needs fact | Confirm original script content; preserve upstream build dependencies |
| build-fxc-test.cmd | GPL-existing | c4f693e / v0.19.19 | G (recorded) | Build-tool invocations and paths do not prove script origin | Build/test orchestration | needs fact | Confirm original script content; preserve upstream build dependencies |
| build-hotswap-test.cmd | GPL-existing | d42b152 / v0.20.11 | G (recorded) | Build-tool invocations and paths do not prove script origin | Build/test orchestration | needs fact | Confirm original script content; preserve upstream build dependencies |
| build-installer-host.cmd | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Build-tool invocations and paths do not prove script origin | Build/test orchestration | needs fact | Confirm original script content; preserve upstream build dependencies |
| build-nr-test.cmd | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Build-tool invocations and paths do not prove script origin | Build/test orchestration | needs fact | Confirm original script content; preserve upstream build dependencies |
| build-performance.cmd | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Build-tool invocations and paths do not prove script origin | Build/test orchestration | needs fact | Confirm original script content; preserve upstream build dependencies |
| build-reshade.cmd | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Build-tool invocations and paths do not prove script origin | Build/test orchestration | needs fact | Confirm original script content; preserve upstream build dependencies |
| build-streamline-policy-test.cmd | GPL-existing | 4b899b1 / v0.20.10 | G (recorded) | Build-tool invocations and paths do not prove script origin | Build/test orchestration | needs fact | Confirm original script content; preserve upstream build dependencies |
| build-test.cmd | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Build-tool invocations and paths do not prove script origin | Build/test orchestration | needs fact | Confirm original script content; preserve upstream build dependencies |
| build-update-notice-test.cmd | GPL-existing | bdec4f3 / v0.20.8 | G (recorded) | Build-tool invocations and paths do not prove script origin | Build/test orchestration | needs fact | Confirm original script content; preserve upstream build dependencies |
| docs/Compatibility-foundation.md | GPL-existing | c1e341f / v0.20.7 | G (recorded) | Text not covered by specific code/artwork authorship confirmation | Project documentation/help | needs fact | Confirm author and any adapted passages in docs/Compatibility-foundation.md |
| docs/Features.txt | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Text not covered by specific code/artwork authorship confirmation | Project documentation/help | needs fact | Confirm author and any adapted passages in docs/Features.txt |
| docs/How-it-works.txt | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Text not covered by specific code/artwork authorship confirmation | Project documentation/help | needs fact | Confirm author and any adapted passages in docs/How-it-works.txt |
| docs/images/installer.png | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Logo authorship does not establish all screenshot/image rights | Documentation image; may include UI/game/third-party content | needs fact | Identify image creator and embedded third-party content before designation |
| docs/images/optishade.png | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Logo authorship does not establish all screenshot/image rights | Documentation image; may include UI/game/third-party content | needs fact | Identify image creator and embedded third-party content before designation |
| docs/Local-0207-testing.md | GPL-existing | c1e341f / v0.20.7 | G (recorded) | Text not covered by specific code/artwork authorship confirmation | Project documentation/help | needs fact | Confirm author and any adapted passages in docs/Local-0207-testing.md |
| docs/TAA-preview.md | GPL-existing | c4f693e / v0.19.19 | G (recorded) | Text not covered by specific code/artwork authorship confirmation | Project documentation/help | needs fact | Confirm author and any adapted passages in docs/TAA-preview.md |
| docs/Tutorial.txt | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Text not covered by specific code/artwork authorship confirmation | Project documentation/help | needs fact | Confirm author and any adapted passages in docs/Tutorial.txt |
| installer/compatibility.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Source of runtime capability decision rules not specifically confirmed | Manager capability checks and runtime config reads | needs fact | Confirm compatibility logic origin and whether adapted from upstream tools |
| installer/consent.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Dialog markup and decision routines require origin check separately from icons | WPF installation and GPU warning dialogs | needs fact | Confirm original warning code/markup or name template sources |
| installer/crash-dumps.ps1 | GPL-existing | 8b352c9 / v0.20.9 | G (recorded) | Archive/discovery routines not covered by confirmation of reader class alone | Loaded by diagnostics.ps1; directly loads DumpSummary.cs | needs fact | Confirm routine origin and review diagnostic trio as a component |
| installer/diagnostics.ps1 | GPL-existing | 0978e2b / v0.20.5 | G (recorded) | Report/export routines distinct from confirmed dump reader | Manager helper reads files/events/modules; calls crash-dumps helper | needs fact | Confirm routine origin; resolve licensing of linked diagnostic helpers together |
| installer/dialog-theme.xaml | GPL-existing | eb7a3ae / v0.20.2 | G (recorded) | Possible third-party template source not established by icon ownership | WPF templates shared by dialogs | needs fact | Identify source of Button/CheckBox/ScrollBar templates |
| installer/DumpSummary.cs | GPL-existing | 4b899b1 / v0.20.10 | G (recorded) | Owner confirms original reader, but diagnostic caller remains GPL | Add-Type class directly invoked by crash-dumps.ps1 in process | needs fact | Resolve caller/helper combination permissions before exclusive distribution |
| installer/EffectPackages.ini | Existing component/catalogue terms | 8fb6007 / v0.19.17 | G (recorded) | Contains external author/project metadata; no claim of original package ownership | Third-party shader package catalogue | BSD/other | Keep existing catalogue/component terms; do not designate as exclusive |
| installer/effects.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Downloading third-party shaders does not establish origin of extraction code | Shader archive transport/install, preserves licences | needs fact | Confirm archive/install implementation was independently created |
| installer/FusionSetup.cs | Proprietary for designated distribution; earlier GPL grants intact | 8fb6007 / v0.19.17 | G (recorded) | Owner confirms original host; build references framework assemblies only | .NET host invokes scripts via Windows PowerShell APIs; no graphics library linkage | proprietary eligible | Header applied; hosted scripts retain their terms |
| installer/go.mod | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Metadata includes interface/version/vendor facts, not exclusive ownership evidence | Build/version/vendor metadata | needs fact | Keep existing terms; do not claim vendor facts as proprietary |
| installer/Help/Features.txt | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Text not covered by specific code/artwork authorship confirmation | Project documentation/help | needs fact | Confirm author and any adapted passages in installer/Help/Features.txt |
| installer/Help/How-it-works.txt | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Text not covered by specific code/artwork authorship confirmation | Project documentation/help | needs fact | Confirm author and any adapted passages in installer/Help/How-it-works.txt |
| installer/Help/Release-notes.txt | GPL-existing | 9316f50 / v0.20.1 | G (recorded) | Text not covered by specific code/artwork authorship confirmation | Project documentation/help | needs fact | Confirm author and any adapted passages in installer/Help/Release-notes.txt |
| installer/Help/Tutorial.txt | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Text not covered by specific code/artwork authorship confirmation | Project documentation/help | needs fact | Confirm author and any adapted passages in installer/Help/Tutorial.txt |
| installer/import-effects.ps1 | GPL-existing | 0978e2b / v0.20.5 | G (recorded) | Specialised runtime dependency plus unconfirmed parser/import routine origins | Manager helper and installed runtime-spawned process; paths and status file IPC | needs fact | Confirm importer origin and assess runtime corresponding-source dependency |
| installer/library.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Code origin and game imagery are distinct; artwork is not automatically project-owned | Discovery/GPU routines; extracts game artwork for display | needs fact | Confirm discovery implementation sources; exclude extracted game imagery |
| installer/main.go | Proprietary for designated distribution; earlier GPL grants intact | 8fb6007 / v0.19.17 | G (recorded) | Owner confirms original launcher; no graphics runtime linking | Extracts embedded files; launches host process; Go standard library only | proprietary eligible | Header applied; preserve embedded component terms |
| installer/manager.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Installer/UI orchestration not covered by the specific launcher/host authorship confirmation | Loads helper scripts and manager.xaml; WPF UI; no game DLL linking observed | needs fact | Confirm origin of manager orchestration and all loaded helper contributions |
| installer/manager.xaml | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Layout may contain reusable templates; logo confirmation does not establish XAML origin | WPF manager layout and templates | needs fact | Identify any copied WPF styles/templates or confirm original layout construction |
| installer/menu-settings.ps1 | GPL-existing | 0978e2b / v0.20.5 | G (recorded) | Configuration protocol alone is not copied implementation; parser origin unconfirmed | Reads/writes OptiScaler INI values | needs fact | Confirm INI/key validation routines were independently created |
| installer/neural-download.ps1 | GPL-existing | c4f693e / v0.19.19 | G (recorded) | Runtime URLs/hashes are third-party references; helper origin unconfirmed | Vendor/community model downloads and INI edits | needs fact | Confirm download/config routines; preserve model/vendor terms |
| installer/nvidia-files.json | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Metadata includes interface/version/vendor facts, not exclusive ownership evidence | Build/version/vendor metadata | needs fact | Keep existing terms; do not claim vendor facts as proprietary |
| installer/nvidia.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Code and vendor payload rights require separate treatment | Vendor downloads/signature validation | needs fact | Confirm helper implementation sources; retain NVIDIA payload terms |
| installer/OptiShade-app.ico | Proprietary for designated distribution; earlier GPL grants intact | 8fb6007 / v0.19.17 | G (recorded) | Owner confirms original icon artwork | Embedded host/application icon | proprietary eligible | Adjacent asset notice applied; prior grants preserved |
| installer/OptiShade-icon.png | Proprietary for designated distribution; earlier GPL grants intact | 8fb6007 / v0.19.17 | G (recorded) | Owner confirms original logo artwork | Displayed in manager; no runtime code | proprietary eligible | Adjacent asset notice applied; prior grants preserved |
| installer/OptiShade.ico | Proprietary for designated distribution; earlier GPL grants intact | 8fb6007 / v0.19.17 | G (recorded) | Owner confirms original icon artwork | Embedded launcher icon | proprietary eligible | Adjacent asset notice applied; prior grants preserved |
| installer/ownership.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Implementation origin of backup/manifest/path routines unconfirmed | Shared installation ownership/backup/restore routines | needs fact | Confirm any borrowed installation or recovery implementation |
| installer/payload_test.go | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Launcher ownership does not prove test/fixture origin | Same Go package as launcher; checks embedded bytes | needs fact | Confirm test authorship before relicensing or distributing combined test binaries |
| installer/recovery.ps1 | GPL-existing | c4f693e / v0.19.19 | G (recorded) | Helper origin and imported routine boundary unconfirmed | Loads import-effects; recovery plus GPL Fusion Cinema file copying | needs fact | Confirm recovery code origin; preserve Fusion Cinema/importer terms |
| installer/release-notes.ps1 | GPL-existing | 9316f50 / v0.20.1 | G (recorded) | UI/theme authorship not established by host confirmation | WPF window using shared theme | needs fact | Confirm original dialog implementation and shared template origin |
| installer/streamline-files.json | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Metadata includes interface/version/vendor facts, not exclusive ownership evidence | Build/version/vendor metadata | needs fact | Keep existing terms; do not claim vendor facts as proprietary |
| installer/update-install.ps1 | GPL-existing | f5b822c / v0.19.19 | G (recorded) | Update orchestration and ownership dependency not independently cleared | Loads ownership helper; applies updates | needs fact | Confirm update script origin and ownership-helper rights |
| installer/update-worker.ps1 | GPL-existing | f5b822c / v0.19.19 | G (recorded) | UI and update state machine origin not covered by launcher confirmation | Separate WPF worker invokes installer executable | needs fact | Confirm worker/state-machine implementation and templates |
| installer/updates.ps1 | GPL-existing | f5b822c / v0.19.19 | G (recorded) | Framework-only small helper; ownership confirmation not yet specific to its implementation | GitHub REST release query and asset verification | needs fact | Confirm release-query/validation code originated in project |
| installer/versioninfo.json | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Metadata includes interface/version/vendor facts, not exclusive ownership evidence | Build/version/vendor metadata | needs fact | Keep existing terms; do not claim vendor facts as proprietary |
| shared/BackendSelection.h | GPL-existing | bdec4f3 / v0.20.8 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| shared/D3D11Adapter.h | GPL-existing | bdec4f3 / v0.20.8 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| shared/D3D12Capabilities.h | GPL-existing | bdec4f3 / v0.20.8 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| shared/D3D12FrameContext.h | GPL-existing | c1e341f / v0.20.7 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| shared/D3D12QueueWait.h | GPL-existing | c1e341f / v0.20.7 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| shared/EffectsBridge.h | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| shared/OptiShadeStreamlinePolicy.h | GPL-existing | 4b899b1 / v0.20.10 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| shared/OptiShadeVersion.h | GPL-existing | bdec4f3 / v0.20.8 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| shared/PresentationOwner.h | GPL-existing | 0978e2b / v0.20.5 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| shared/PresetHotSwapPolicy.h | GPL-existing | d42b152 / v0.20.11 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| shared/PresetPathIdentity.h | GPL-existing | 9c6ab81 / v0.20.11 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| shared/RenderingCapability.h | GPL-existing | c1e341f / v0.20.7 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| shared/TaaBridge.h | GPL-existing | c4f693e / v0.19.19 | G (recorded) | Runtime integration, existing root/component grants; no separate designation | Header incorporated into graphics runtime | GPL | Preserve GPL-compatible runtime distribution |
| tests/amd-warning.ps1 | GPL-existing | 0978e2b / v0.20.5 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/consent.ps1, installer/manager.xaml | needs fact | Confirm original assertions/fixtures in tests/amd-warning.ps1 and helper licences |
| tests/anti-cheat.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/consent.ps1, installer/library.ps1 | needs fact | Confirm original assertions/fixtures in tests/anti-cheat.ps1 and helper licences |
| tests/backup-policy.ps1 | GPL-existing | 9316f50 / v0.20.1 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/ownership.ps1 | needs fact | Confirm original assertions/fixtures in tests/backup-policy.ps1 and helper licences |
| tests/compatibility-0207.ps1 | GPL-existing | c1e341f / v0.20.7 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/compatibility.ps1, installer/FusionSetup.exe, installer/library.ps1, installer/neural-download.ps1, installer/ownership.ps1 | needs fact | Confirm original assertions/fixtures in tests/compatibility-0207.ps1 and helper licences |
| tests/compatibility.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/compatibility.ps1, installer/FusionSetup.exe | needs fact | Confirm original assertions/fixtures in tests/compatibility.ps1 and helper licences |
| tests/crash-dumps.ps1 | GPL-existing | 8b352c9 / v0.20.9 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/diagnostics.ps1 | needs fact | Confirm original assertions/fixtures in tests/crash-dumps.ps1 and helper licences |
| tests/diagnostics.ps1 | GPL-existing | 0978e2b / v0.20.5 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/diagnostics.ps1 | needs fact | Confirm original assertions/fixtures in tests/diagnostics.ps1 and helper licences |
| tests/download-retry.ps1 | GPL-existing | f5b822c / v0.19.19 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/effects.ps1, installer/ownership.ps1 | needs fact | Confirm original assertions/fixtures in tests/download-retry.ps1 and helper licences |
| tests/driver-warning.ps1 | GPL-existing | bdec4f3 / v0.20.8 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/consent.ps1, installer/manager.ps1 | needs fact | Confirm original assertions/fixtures in tests/driver-warning.ps1 and helper licences |
| tests/dump-summary.ps1 | GPL-existing | 4b899b1 / v0.20.10 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/diagnostics.ps1, installer/DumpSummary.cs | needs fact | Confirm original assertions/fixtures in tests/dump-summary.ps1 and helper licences |
| tests/flight-controller-hooks.py | GPL-existing | 8b352c9 / v0.20.9 | G (recorded) | Existing runtime-related test grant; proprietary eligibility not sought | Runtime rendering/input/policy test | GPL | Retain existing terms |
| tests/fusion_nr.cpp | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Existing runtime-related test grant; proprietary eligibility not sought | Runtime rendering/input/policy test | GPL | Retain existing terms |
| tests/fusion_render.cpp | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Existing runtime-related test grant; proprietary eligibility not sought | Runtime rendering/input/policy test | GPL | Retain existing terms |
| tests/game-discovery.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/FusionSetup.exe, installer/library.ps1 | needs fact | Confirm original assertions/fixtures in tests/game-discovery.ps1 and helper licences |
| tests/install-state.ps1 | GPL-existing | c4f693e / v0.19.19 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/compatibility.ps1, installer/library.ps1, installer/ownership.ps1, installer/recovery.ps1 | needs fact | Confirm original assertions/fixtures in tests/install-state.ps1 and helper licences |
| tests/menu-keys-ui.ps1 | GPL-existing | 0978e2b / v0.20.5 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/manager.ps1, installer/manager.xaml, installer/menu-settings.ps1, installer/ownership.ps1 | needs fact | Confirm original assertions/fixtures in tests/menu-keys-ui.ps1 and helper licences |
| tests/msfs-edition.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/FusionSetup.exe, installer/library.ps1 | needs fact | Confirm original assertions/fixtures in tests/msfs-edition.ps1 and helper licences |
| tests/neural-download.ps1 | GPL-existing | c4f693e / v0.19.19 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/neural-download.ps1, installer/nvidia.ps1, installer/ownership.ps1 | needs fact | Confirm original assertions/fixtures in tests/neural-download.ps1 and helper licences |
| tests/nvidia-reuse.ps1 | GPL-existing | c4f693e / v0.19.19 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/nvidia-files.json, installer/nvidia.ps1, installer/ownership.ps1, installer/streamline-files.json | needs fact | Confirm original assertions/fixtures in tests/nvidia-reuse.ps1 and helper licences |
| tests/optional-dlss.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/consent.ps1, installer/manager.xaml | needs fact | Confirm original assertions/fixtures in tests/optional-dlss.ps1 and helper licences |
| tests/OptiShade_Test.fx | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Existing runtime-related test grant; proprietary eligibility not sought | Runtime rendering/input/policy test | GPL | Retain existing terms |
| tests/own-preset.ps1 | GPL-existing | bdec4f3 / v0.20.8 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/FusionCinema, installer/ownership.ps1, installer/recovery.ps1 | needs fact | Confirm original assertions/fixtures in tests/own-preset.ps1 and helper licences |
| tests/ownership.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/ownership.ps1 | needs fact | Confirm original assertions/fixtures in tests/ownership.ps1 and helper licences |
| tests/patch-0205.ps1 | GPL-existing | 0978e2b / v0.20.5 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/compatibility.ps1, installer/EffectPackages.ini, installer/import-effects.ps1, installer/library.ps1, installer/menu-settings.ps1, installer/ownership.ps1 | needs fact | Confirm original assertions/fixtures in tests/patch-0205.ps1 and helper licences |
| tests/platform-lifecycle.ps1 | GPL-existing | c4f693e / v0.19.19 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/compatibility.ps1, installer/FusionSetup.exe, installer/library.ps1, installer/ownership.ps1 | needs fact | Confirm original assertions/fixtures in tests/platform-lifecycle.ps1 and helper licences |
| tests/presentation-owner.cpp | GPL-existing | 0978e2b / v0.20.5 | G (recorded) | Existing runtime-related test grant; proprietary eligibility not sought | Runtime rendering/input/policy test | GPL | Retain existing terms |
| tests/preset-hotswap-settings.ps1 | GPL-existing | d42b152 / v0.20.11 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/menu-settings.ps1 | needs fact | Confirm original assertions/fixtures in tests/preset-hotswap-settings.ps1 and helper licences |
| tests/preset-hotswap.cpp | GPL-existing | d42b152 / v0.20.11 | G (recorded) | Existing runtime-related test grant; proprietary eligibility not sought | Runtime rendering/input/policy test | GPL | Retain existing terms |
| tests/recovery-import.ps1 | GPL-existing | c4f693e / v0.19.19 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/ownership.ps1, installer/recovery.ps1 | needs fact | Confirm original assertions/fixtures in tests/recovery-import.ps1 and helper licences |
| tests/release-notes.ps1 | GPL-existing | 9316f50 / v0.20.1 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/release-notes.ps1 | needs fact | Confirm original assertions/fixtures in tests/release-notes.ps1 and helper licences |
| tests/rendering-foundation.cpp | GPL-existing | c1e341f / v0.20.7 | G (recorded) | Existing runtime-related test grant; proprietary eligibility not sought | Runtime rendering/input/policy test | GPL | Retain existing terms |
| tests/replace-addons.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/ownership.ps1 | needs fact | Confirm original assertions/fixtures in tests/replace-addons.ps1 and helper licences |
| tests/restore-receipt.ps1 | GPL-existing | c4f693e / v0.19.19 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/ownership.ps1 | needs fact | Confirm original assertions/fixtures in tests/restore-receipt.ps1 and helper licences |
| tests/runtime-diagnostics.ps1 | GPL-existing | c4f693e / v0.19.19 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/compatibility.ps1, installer/library.ps1 | needs fact | Confirm original assertions/fixtures in tests/runtime-diagnostics.ps1 and helper licences |
| tests/selector.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/manager.ps1, installer/manager.xaml | needs fact | Confirm original assertions/fixtures in tests/selector.ps1 and helper licences |
| tests/setup-layout-check.ps1 | GPL-existing | bdec4f3 / v0.20.8 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/manager.ps1, installer/manager.xaml | needs fact | Confirm original assertions/fixtures in tests/setup-layout-check.ps1 and helper licences |
| tests/streamline-policy.cpp | GPL-existing | 4b899b1 / v0.20.10 | G (recorded) | Existing runtime-related test grant; proprietary eligibility not sought | Runtime rendering/input/policy test | GPL | Retain existing terms |
| tests/ui.ps1 | GPL-existing | 8fb6007 / v0.19.17 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/manager.ps1, installer/manager.xaml | needs fact | Confirm original assertions/fixtures in tests/ui.ps1 and helper licences |
| tests/update-lifecycle.ps1 | GPL-existing | f5b822c / v0.19.19 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/library.ps1, installer/ownership.ps1, installer/update-install.ps1 | needs fact | Confirm original assertions/fixtures in tests/update-lifecycle.ps1 and helper licences |
| tests/update-notice.cpp | GPL-existing | 05ffb82 / v0.20.3 | G (recorded) | Existing runtime-related test grant; proprietary eligibility not sought | Runtime rendering/input/policy test | GPL | Retain existing terms |
| tests/update-repository.ps1 | GPL-existing | 9acb8c5 / v0.20 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/updates.ps1 | needs fact | Confirm original assertions/fixtures in tests/update-repository.ps1 and helper licences |
| tests/updater-worker.ps1 | GPL-existing | f5b822c / v0.19.19 | G (recorded) | Test assertions and fixtures not covered by specific launcher/host confirmation | installer/update-worker.ps1 | needs fact | Confirm original assertions/fixtures in tests/updater-worker.ps1 and helper licences |
