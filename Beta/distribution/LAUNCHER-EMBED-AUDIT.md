# Launcher embedded-file audit

Generated from the actual `//go:embed` patterns in `Beta/installer/public_bundle.go`. Each resolved file is recorded with its byte size and SHA-256. This inventory is descriptive; it removes nothing and does not treat a small file as safe to delete.

Embedded files: **338**; total source bytes: **323,487,589 (308.5 MiB)**.
`PayloadFusion`: **319,707,637 bytes (304.9 MiB, 98.8%)**. All other embedded launcher resources: **3,779,952 bytes (3.6 MiB)**.

The local R381 executable observed during this audit is 296,325,120 bytes (282.6 MiB). This is a different measurement from the raw file sum above: the final executable includes linker/build overhead and may share identical embedded byte content across duplicate install paths. Measure a new build directly before quoting its final size or promised reduction.

PE compatibility scan: the inventory records the PE machine architecture for every embedded EXE and DLL (x86, x64, ARM64, or an explicit invalid/unknown result). This is a static format check, not proof that a binary loads on a given Windows build, GPU, game or graphics API. Before removal or replacement, compare architecture and dependencies with every invocation and loader path, then exercise the affected install, launch, update, repair, rollback and uninstall routes.

## PE architecture counts

| PE machine | Files |
|---|---:|
| x64 (AMD64) | 44 |
| x86 (I386) | 1 |

## Size by category

| Category | Files | MiB |
|---|---:|---:|
| Payload: Providers | 8 | 171.21 |
| Payload: Neural | 24 | 81.23 |
| Payload: Core | 148 | 43.59 |
| Payload: OptiMfg | 31 | 6.80 |
| Payload: Cockpit | 1 | 1.63 |
| Launcher: Source/metadata | 69 | 1.43 |
| Launcher: Branding asset | 3 | 1.16 |
| Launcher: Helper executable | 3 | 0.98 |
| Payload: Effects | 49 | 0.43 |
| Launcher: Other embedded resource | 2 | 0.04 |

## Largest embedded files

| File | MiB | Current disposition |
|---|---:|---|
| `PayloadFusion/OptiShadeData/Engine/libxess.dll` | 74.19 | Payload: Providers |
| `PayloadFusion/OptiShadeData/Engine/amd_fidelityfx_framegeneration_dx12.dll` | 38.23 | Payload: Providers |
| `PayloadFusion/OptiScaler/nvfp4/hybrid/weights.bin` | 36.02 | Payload: Neural |
| `PayloadFusion/OptiShadeData/Engine/amd_fidelityfx_upscaler_dx12.dll` | 27.43 | Payload: Providers |
| `PayloadFusion/winmm.dll` | 26.24 | Payload: Core |
| `PayloadFusion/host64/winmm.dll` | 26.24 | Payload: Neural |
| `PayloadFusion/OptiShadeData/Engine/libxess_fg.dll` | 21.89 | Payload: Providers |
| `PayloadFusion/OptiShadeData/Engine/amd_fidelityfx_vk.dll` | 8.90 | Payload: Providers |
| `PayloadFusion/host64/dxgi.dll` | 5.66 | Payload: Neural |
| `PayloadFusion/ReShade64.dll` | 5.66 | Payload: Core |
| `PayloadFusion/OptiScaler/nvfp4/hybrid/candidate/split-half/fused_expand.cubin` | 4.78 | Payload: Neural |
| `PayloadFusion/OptiScaler/nvfp4/hybrid/expansion/fused_expand.cubin` | 4.73 | Payload: Neural |

## Removal and compatibility rule

The only high-impact size reduction is to stop embedding `PayloadFusion` after online component selection, integrity checks, compatibility gating and transactional install/recovery all use the verified staged package. Do not remove just a DLL or payload group based on one GPU/game result. Preserve legacy API and architecture variants, helper binaries, installer/manager scripts, signatures, ownership records, required notices and backups until their consumers are replaced and verified. The per-file role, compatibility risk and removal gate are recorded in `LAUNCHER-EMBED-INVENTORY.csv`; detailed game-payload analysis remains in `PAYLOAD-TEARDOWN-AUDIT.md`.

No file was removed by this audit.
