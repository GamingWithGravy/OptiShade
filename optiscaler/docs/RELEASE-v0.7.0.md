# Vulkan and NR experiments — v0.7.0 preview

Complete rebuilt package with game-neutral defaults. This is a **pre-release**, not a claim that
native Vulkan gameplay or RTX 40 MFG has been validated. v0.6.2 remains available for rollback.

## Changes

- Native Vulkan pre-SR, multipass, per-pass controls, active padded resolutions and post-RR handling.
- Selected y4my4my4m v4 fixes: Vulkan/Proton GPU identification, resource lifetimes, output restoration,
  MFG capability/struct-version handling and Vulkan-menu FG interlocks. Attribution and exclusions
  are in `docs/VULKAN-PARITY-REVIEW.md`.
- Optional extended 30-pass range and experimental built-in Ada MFG unlock, both off by default.
- D3D12 deferred DLSS residual composition, half-rate residual FG/sample-and-hold, and latest-completed
  async NR experiments. These are off by default and are not native Vulkan features.
- README now records Aphelion issue #3 as unresolved. No speculative HDR fix is included.

## Updating

1. Close the game. Back up the existing mod DLLs and `OptiScaler.ini`.
2. Download **OptiScaler-DLSSNR-v0.7.0-vulkan-preview.zip**, not GitHub's source-code ZIP.
3. Extract the complete package into the existing mod location and rerun `setup_windows.bat` with
   your previous proxy choice. Updating `OptiScaler.dll` alone does not update an installed `dxgi.dll`.
4. Restore your saved INI to retain settings, or use the new INI for a clean baseline. Saved experimental
   settings remain enabled if you restore them; new-package defaults do not override your old INI.
5. Keep separately obtained NVIDIA runtimes. Do not combine built-in and external MFG unlockers.

For native Vulkan, disable DeferredDLSS/AsyncLatest/ResidualFG and select Apply before Super Resolution.
See `docs/VULKAN-PARITY-REVIEW.md` for full setup and `INSTALL-DLSSNR.md` for a new installation.

No NVIDIA NR, SR, RR, FG or Streamline DLLs are bundled. The official dependency downloader and
licence guidance remain included. No installed game is modified by downloading this package.

## Checks and limitations

Release x64 build; production Vulkan shader on RTX 5090 at odd/padded dimensions; existing D3D shader,
active-region, NVIDIA SR and offscreen FG tests passed during development. Native Vulkan gameplay,
RR integration, RTX 40 MFG and Proton still need live validation. Tests do not establish regression-free
FPS or presentation pacing. Known compiler/linker warnings remain. Keep antivirus enabled.

`SHA256SUMS.txt` verifies files inside the package; `ASSET-SHA256SUMS.txt` verifies the download.
