# Generate NR before SR; apply its contribution after SR

Experimental third placement mode. The contribution upscaler is **NVIDIA DLSS Super Resolution**,
not a spatial filter, FSR or XeSS. The game's selected main upscaler is not changed automatically;
select DLSS in the game/OptiScaler as well for a DLSS-on-both-branches comparison.

## Enable

Use v0.7.0 or a newer build containing this change (not v0.6.2). Under **DLSS Neural Rendering**, enable
**Generate before SR, apply after SR (DLSS)**. It overrides, but does not erase, the existing
**Apply before Super Resolution** checkbox. Or configure:

```ini
[DlssNr]
Enabled=true
DeferredDLSS=true
WorkingScale=1.0
Passes=1
```

Keep **Apply model** on; turn off frame hold, debug/compare views and skin-mask preview. For a first
comparison keep FG and RR off and use the same model profile, exposure and strengths. Model resolution
is relative to the active render raster, not final output: 100% for a 1080p input runs NR at 1080p.
Existing per-pass controls remain effective. The menu reports the private DLSS path separately.

An optional [half-rate residual FG experiment](RESIDUAL-FG-PROTOTYPE.md) adds every-other-frame
NR with NVIDIA interpolation. It has additional latency, camera and downstream-effect limitations;
the every-frame pipeline described below remains the default.

Requires your own working NVIDIA DLSS SR runtime and NVIDIA NR runtime. None is redistributed with
this change. GPU/runtime support is determined by actual private DLSS creation/evaluation, not a GPU
series whitelist. This mode is on the D3D12 seam, including the existing D3D11/Vulkan-to-D3D12 bridges.
Native Vulkan skips NR with a diagnostic rather than silently substituting a different placement.
Native RR retains its existing separate post-RR route; this experiment never edits RR's noisy inputs.

## What it computes

1. Copy only the active original colour rectangle to an owned UAV; do not edit the game's colour.
2. Run the existing NR model/passes and low-resolution composition on that copy. The resulting
   difference includes the existing intensity/colour/skin controls; they aren't applied twice.
3. Encode `d = (NR-composed - original) / preExposure` as `0.5 + 0.5*d/(1+abs(d))` into an RGBA16F
   carrier. Neutral grey means zero change; values below grey carry darkening, above grey brightening.
4. Let the game's SR operate on the untouched colour. Then run a private DLSS SR feature on the carrier,
   using separately allocated parameters and history, copied jitter/motion/depth data and unit exposure.
   Calls go directly to the NVIDIA runtime, not back through OptiScaler's interception layer.
5. Decode the enlarged carrier and add the signed edit to a copy of the clean final-resolution raster,
   preserving its alpha. Copy back only after successful DLSS evaluation and composition.

This is not a separate physical lighting or shadow buffer. NR returns an edited RGB image; the layer
is inferred from its difference to the original. The signed compression is deliberately experimental.
DLSS sees biased/compressed data rather than natural colour and may smooth, distort or temporally
destabilize it. FP16 carrier precision and the nonlinear inverse can amplify errors. The inverse is
clamped to signed magnitude 0.999 before decoding (about 999 times pre-exposure); this prevents poles,
but does not guarantee desirable brightness. Negative final RGB is clamped to zero. No promise of
matching full-resolution NR or restoring the reported gun-rack shadows is made.

## Failure and lifetime behaviour

- Unsupported layouts, non-zero subrect offsets, missing guides, allocation/runtime/evaluation failure
  or unmatched before/after calls retain the clean main-SR result. No alternative residual upscaler runs.
- Private creation and evaluation are separated by a submission epoch. Camera cuts, disabled/missed
  frames and generation changes reset private history. Main-game parameters/handles are never edited.
- Resolution/format/device/queue changes create a new generation. Retired histories, shaders and buffers
  are released only after the last recorded GPU timestamp completion marker is visible. Completion slots
  also limit outstanding work; retired generations are bounded, with clean-frame fallback under backlog.
- Only one upscale per submission epoch and a known same-device direct queue are supported. Multi-view,
  asynchronous-compute and unusual engine submission patterns require further work/testing.
- If GPU work cannot be confirmed complete at shutdown, its generation is retained for process teardown
  instead of releasing in-flight resources. A private runtime failure latches for its generation; restart
  the game to retry reliably. Turning the option off restores the selected existing placement.
- NR's existing GPU timer measures NR work, **not** the extra DLSS pass and final-resolution copies/
  composition. Compare total frame time; this mode costs more than ordinary pre-SR NR and uses more VRAM.

## Validation

- Shared HLSL WARP smoke tests: signed shadow/brightening roundtrip, neutral identity, alpha preservation,
  non-finite/overshoot guards and fixed unit exposure passed; existing skin-control tests also passed.
- Headless RTX 5090 test using the installed NVIDIA NGX driver and an existing, signature-verified official
  SR DLL: two distinct DLSS feature handles created, and 1080p carriers upscaled to 4K over eight frames.
  Neutral samples stayed exactly 0.5; dark/neutral/bright band centres returned 0.25/0.5/0.75.
- That hardware test uses synthetic static inputs and real DLSS, not an NR model, game injection or the
  complete before/after hook. Moving-scene alignment, private-pass scheduling in games, FG compatibility,
  visual quality and performance require separate live-game validation. Experimental builds have been
  installed locally in BG3 and Jedi Survivor; see the residual FG notes for the newer tests.

Reproduce from an x64 VS developer prompt:

```bat
cl /nologo /std:c++20 /EHsc /Iexternal\nvngx_dlss_sdk tests\nr_residual_dlss_smoke.cpp /Fe:x64\nr_residual_dlss_smoke.exe /Fo:x64\nr_residual_dlss_smoke.obj /link d3d12.lib dxgi.lib
x64\nr_residual_dlss_smoke.exe "FULL PATH TO INSTALLED nvngx.dll" "DIRECTORY CONTAINING YOUR OFFICIAL nvngx_dlss.dll"
```

The test loads user-supplied local DLLs and does not download, redistribute or inject them into a game.
