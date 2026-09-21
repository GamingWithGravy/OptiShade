# Vulkan NR and selected y4my4my4m v4 changes

Included in the **v0.7.0 Vulkan/NR preview**, September 8, 2026. Not included in v0.6.2.

Reviewed source: [y4my4my4m v4](https://github.com/y4my4my4m/OptiScaler_DLSSNR_Multipass_MFG/releases/tag/v10.0.0-dev-fork-y4my4my4m-v4), commit `7b7220bb` (GPL-3.0).
Its release notes mark its native Vulkan split as untested. Its reported timing is not an A/B
benchmark against this fork; we do not claim the same speedup.

## Native Vulkan

- `RunBeforeSR=true` now runs NR on an owned, render-sized Color image before the existing upscaler.
  The game's Color is not overwritten or required to support storage writes. Its parameter is restored
  even when upscaling fails. A per-evaluate result prevents running NR again after SR.
- Active, origin-zero rectangles are used rather than allocation dimensions or preset tables.
  Invalid/offset Color rectangles fall back after SR. Missing/invalid guides leave the image clean.
- Multiple passes have separate features/history, ping-pong their answers and compose once.
  D3D12 and Vulkan share profile/inheritance/clamping code, including skin controls.
- Style/strength changes rebuild the Vulkan model; previously only resolution changes did.
- Model creation records a GPU event. Until it completes, evaluations stay clean without waiting.
  A second evaluate on an unsubmitted command buffer cannot use unready models.
- RR runs after reconstruction with `ApplyAfterRR`, `RRPasses` and `RRWorkingScale`.
  Vulkan-to-D3D12 bridges retain their existing NR path without a second native Vulkan NR call.
- Shared SPIR-V regenerated; owned-image transfer barriers corrected.

Keep the required NR runtime and matching forwarder. Disable **Generate before SR, apply after SR
(DLSS)** and enable **Apply before Super Resolution**. For example, merge into the existing INI:

```ini
[Upscalers]
VulkanUpscaler=dlss
[DlssNr]
Enabled=true
RunBeforeSR=true
DeferredDLSS=false
ResidualFG=false
Passes=1
WorkingScale=1.0
```

Select DLSS quality in the game. Pre-SR NR working scale is relative to the active input size.
Start with one pass and check the logged model/frame dimensions before trying two.
`RunBeforeSR=false` selects post-SR NR. Native Vulkan **does not yet implement deferred DLSS residual
composition, residual FG or async-latest NR**. Exposure scanning remains D3D12-only.

## Adopted fixes and options

- Vulkan creation hooks query the actual physical device instead of enumerating DXGI, avoiding
  Proton/DXVK re-entry. Adapted from `7c3b65dc`.
- Vulkan/D3D12 output parameters restored on failed pipeline exits. D3D11 saved bindings retain COM
  references through restoration, including failure paths and null bindings. Restore API calls are
  batched. HUDless/UI helpers retain swapchain buffers while recording. These include upstream fixes
  carried by the reviewed fork.
- Vulkan framebuffer teardown checks the correct handle. The Vulkan-menu FG interlock covers an
  active Vulkan overlay on D3D12/Proton and OptiScaler's direct FG-options route.
- Streamline state fields are guarded by struct version. Multiplier clamps no longer overwrite the
  saved INI request. Overrides on Streamline older than 2.7.1 explain why they cannot work. Capability
  caching waits for an enabled Ada unlock attempt. Adapted from `8039dbd1`/`e7966f6b`; our external-FG
  ownership guards are retained.
- Optional **Lift model pass limit** permits 30 passes. Normal ceiling stays 3, preserving our defaults.
  Extra features are allocated only when requested. Passes 4–30 expose style, intensity, structure,
  tone, skin and auto-mask controls, saved as individual keys such as `Pass4Style` and `Pass4LocalTone`.
  Legacy pass 2/3 keys remain compatible. Later-pass local tone defaults to zero.
- Native D3D11 explains the required D3D12 bridge rather than waiting indefinitely.

### Built-in Ada MFG unlock: experimental, off by default

Adapted from the reviewed fork's `MfgUnlock.cpp/.h`, with unique-signature checks, bounds validation
and narrower hardware/ownership guards. This is an **alternative** to the external unlocker.

Back up the setup and close the game. Remove/disable the external unlocker using its instructions;
set `[FrameGen] External=false` and `[DLSSG] AdaMfgUnlock=true`, then save and restart. Enable game/
OptiScaler FG using the existing instructions and choose a multiplier. It does not supply missing
FG inputs or turn an unsupported game into a native-FG game. Overrides require Streamline 2.7.1+.

Only RTX 40/Ada is patched. RTX 20/30/50 and external-FG sessions are excluded. The actual loaded
DLSSG module is checked for known unique gate signatures and compatible interpolation kernels before
opening the count gates. Keep `AdaBlackwellKernels=auto`. Unknown signatures are left unchanged.
The UI reports runtime version, matched gates and retargeted kernel groups; a checkbox is not proof
of working MFG. Memory patches do not modify DLLs on disk. Disable, save and restart to remove them.

**Not validated on RTX 40 hardware here.** Test moving scenes at 2x then 3x and confirm intermediate
frames advance, not merely a larger FPS number. No NVIDIA DLLs from the other fork were added to our
distribution; existing runtime download/license instructions still apply. Never disable antivirus
or use these patches in anti-cheat-protected multiplayer games.

## Not imported wholesale

- `DualFeature`/`DualEnlarger` changes the first upscaler to a render-sized stage and adds another
  enlarger. Our pre-SR route already runs reduced NR followed by one existing upscaler. Replacing it
  with two upscaler instances would change history and cost without a comparable benchmark.
- Broad controller-input rewrites, unconditional Reflex-interface suppression and Proton overlay
  backend rerouting need separate platform testing; they are not bundled into this NR change.
- Binary bundles and release workflows were not copied. Source GPL-3.0 licensing does not itself
  grant redistribution rights for NVIDIA runtime DLLs.

## Validation and remaining checks

- Release x64 build and `git diff --check`.
- RTX 5090 execution of production Vulkan SPIR-V encode/resolve: 1507x847 active inside 1536x864,
  all RGBA pixels checked, padding unchanged (`tests/nr_vulkan_shader_smoke.cpp`). This is a shader
  test, **not a full game/NGX Vulkan model test**.
- Existing D3D12 active-region copy and shader tests passed: skin/scene controls, signed residuals,
  motion composition, rejected FG output and sample-and-hold.
- Recompiled D3D shader bytecode is identical to the pre-change bytecode.
- Existing NVIDIA hardware SR/offscreen FG tests passed, including a moving residual's midpoint.
  These do not validate the new Ada unlock or game presentation pacing.

Before a release claim, still test native Vulkan pre/post A/B in a game, multipass/profile changes,
quality/dynamic-resolution switches, RR, RTX 40 MFG and Proton. No game files were changed by this
work. Compile and shader tests alone do not establish regression-free FPS or frame pacing.
