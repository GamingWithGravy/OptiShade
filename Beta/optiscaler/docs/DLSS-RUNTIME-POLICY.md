# DLSS runtime compatibility policy

OptiShade pins the NVIDIA files it installs by release tag, file version, SHA-256 digest and Authenticode signer. The runtime components do not all share one version or update safely as a group.

## Current local stable candidate

- DLSS Super Resolution (`nvngx_dlss.dll`) and Ray Reconstruction (`nvngx_dlssd.dll`) use NVIDIA NGX 310.9.16. These are the signed files from NVIDIA's [DLSS 4.5 package](https://developer.nvidia.com/rtx/dlss).
- The private test candidate now uses DLSS Frame Generation (`nvngx_dlssg.dll`) 310.9.16 with [Streamline 2.14.16](https://github.com/NVIDIA-RTX/Streamline/releases/tag/v2.14.16), the latest official releases checked on 25 October 2026. OptiScaler's Streamline headers, runtime catalogue and local SDK manifest are aligned to 2.14.16. The downloaded release archive and all six runtime DLLs were hash-checked; the NVIDIA Authenticode signatures and signer identities matched. The MFG patcher's two version-specific gate signatures each appeared exactly once in the official 310.9.16 provider image, and the exact provider version is now explicitly admitted. This is source and binary-structure evidence only; actual game loading, controls, generated frames, mode switching, and rollback still require the consolidated test build and target testing.
- RTX 20/30 source routing now has an experimental path for the unmodified [DLSSG for SM86 v0.4.0 upstream component](https://github.com/sdli1995/dlssg_for_sm86). It brings its own DLSS-G runtime/backend, separate from OptiShade's shared SR/RR pins. OptiShade places the provider under `OptiShadeData/Engine/dlssg_sm86/` and enables OptiScaler's existing post-attach loader instead of installing a second game-root proxy. Upstream's standalone installation manual still says to remove OptiScaler and other frame-generation mods; this hosted configuration is source-tested only and must not be presented as a working Stable feature until it passes RTX 20 and RTX 30 game/output tests.
- Neural Rendering uses a separate signed model/runtime path selected for the GPU family. Updating the SR/RR DLLs does not update that model, enable NR, or prove NR output.

## DLSS 4.5 expectations

The newer NGX runtime is available to OptiShade's direct NGX loading path. It does not force a game to expose DLSS 4.5 features. The game must have a compatible integration, and its own plugin or NVIDIA profile may determine which model or options are active. Streamline SR is a separate integration; OptiShade does not inject `sl.dlss.dll` into a game's own Streamline stack as part of this update.

## Qualification required before changing the FG stack

Treat every new official release as a test candidate. Before changing the pin, verify the exact signed DLLs and release archive, confirm the MFG patch signatures and provider identity, run the automated regression suite, and test supported GPU families and simulator/game builds. Verify generated frames and mode switching before calling the upgrade qualified. A menu option or installed DLL is not proof that frame generation is active.

The 1.0.15 build is the latest locally packaged stable candidate. No release, tag or upload has been created. Multiplier support still depends on the active game provider's live capability report.
