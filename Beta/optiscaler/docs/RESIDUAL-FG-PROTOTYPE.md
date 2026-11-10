# Residual-only NVIDIA FG investigation

Status: experimental source integration with standalone hardware tests. Not a public release.
The default DeferredDLSS mode still evaluates NR every rendered frame. The optional half-rate
mode is deliberately disabled by default.

## Experimental UI / INI controls

Under DLSS Neural Rendering, enable **Generate before SR, apply after SR (DLSS)**,
then **NR every second frame (NVIDIA FG, experimental)**. The initial game-bridge
integration also needs **Allow approximate FG camera guides (experimental)**.

```ini
[DlssNr]
DeferredDLSS=true
ResidualFG=true
ResidualFGApproxCamera=true
```

WARNING: the clean SR colour and residual are delayed together by one rendered frame.
Later game effects may use newer motion/depth/exposure information. Motion blur,
lighting effects and HUD alignment can therefore be wrong. Approximate camera
guides use the existing FSR camera near/far/FOV configuration, identity inter-frame
camera transforms and real motion vectors. They are not game-supplied transforms.

This requires a working NVIDIA FG runtime and device capability, plus low-resolution,
non-jittered motion vectors. It does not enable NVIDIA FG on unsupported GPUs.
The current path is D3D12 or its D3D11 bridge, not native Vulkan or the RR path.
No full-game frame generation setting is changed by this control.

Watch the Residual DLSS status: it must report **NR every second frame + NVIDIA
residual FG**. An inactive status means ordinary every-frame NR is retained, not
successful half-rate processing. Runtime creation/evaluation failures are logged.
Disable ResidualFG to return to ordinary deferred NR; a restart is useful after a
runtime failure. No NVIDIA runtime is distributed with this source change.

### Missing-motion fallback: sample-and-hold

When the every-second-frame option is enabled and the motion texture is absent,
each successfully generated residual is applied to two consecutive **current**
SR images. The next pair gets a fresh sample. There is no raster delay, motion
warping or residual FG evaluation in this fallback. The status explicitly says
**sample-and-hold (motion unavailable)**; it does not claim interpolation.

Fresh private NR and residual-DLSS evaluations use an owned zero-motion texture
and reset history every time, rather than inventing motion continuity. This does
not repair missing inputs to the game's own upscaler: it must still produce a valid
clean SR image. Depth remains required. Cuts, frame gaps, failed composition,
resolution changes and returning motion vectors invalidate the held sample.
This may show a two-frame stepping effect in the NR edit, but does not freeze the raster.

## NVIDIA interface

The public [DLSS-FG Programming Guide](https://github.com/NVIDIA-RTX/Streamline/blob/main/docs/DLSS-FG%20Programming%20Guide.pdf)
(SDK 310.7, June 2026) documents a direct NGX FrameGeneration feature with an
application-owned `DLSSG.OutputInterpolated` resource. This is distinct from
Streamline's presentation-managed FG wrapper. Direct resource output is possible;
absence of a Streamline offscreen helper is not evidence otherwise.

`tests/nr_residual_fg_smoke.cpp` exercises that documented interface using the
existing NGX headers and public parameter names. It does not download, bundle,
patch or inject a runtime. Supply your own installed official DLL paths.

Build from an x64 Visual Studio developer prompt at the repository root:

```bat
cl /nologo /std:c++20 /EHsc /Iexternal\nvngx_dlss_sdk tests\nr_residual_fg_smoke.cpp /Fe:x64\nr_residual_fg_smoke.exe /Fo:x64\nr_residual_fg_smoke.obj /link d3d12.lib dxgi.lib
x64\nr_residual_fg_smoke.exe "ABSOLUTE_PATH_TO\nvngx.dll" "DIRECTORY_CONTAINING_OFFICIAL_FG_DLL"
```

The test queries FG capability, creates a separate feature, submits creation,
provides read-state depth/motion/color and UAV output, evaluates consecutive
anchors, waits for GPU completion before readback/reuse, and releases the feature
after completion. Its stationary camera transforms are accurate for the synthetic
scene, not proposed substitutes for real game camera data.

## Local results, 7 September 2026

RTX 5090, signed NVIDIA `nvngx_dlssg.dll` 310.8.0.0 already installed with BG3:

- RGBA16F neutral carrier: 0.500000 at all three sampled positions.
- Signed carrier regions: 0.250000 / 0.500000 / 0.750000.
- The production FG adapter was tested with a 4K RGBA16F residual and 1080p guides.
  Translating plane, 32-pixel anchor displacement: interpolated left edge 336;
  mathematical midpoint 336; current anchor 352. Five-pixel tolerance passed.
- The motion test uses current-to-previous vectors with the normalized scale
  documented in NVIDIA's public DLSSG header. Zero-motion-only tests would not
  establish this convention.

The signed driver fallback runtime 310.2.1.0 reported FG capability and allowed
feature creation, but its first evaluation failed with `BAD00005` and cached-size
validation errors. Explicit resource extents did not resolve it. This is an
observed compatibility failure, not proof of its underlying cause or a universal
minimum-version requirement. Capability checks alone do not prove evaluation works.

The synthetic pass does not validate NR-generated imagery, changing exposure,
disocclusions, moving cameras, nonuniform motion or real-game presentation.

## Temporal matching and remaining limitations

For anchors at game frames 0 and 2, FG produces residual 1 only after residual 2
exists. It must then be composed with clean game image 1, not clean image 2.

The current `DeferredSr::After` writes into the current game's SR output before
the game performs its remaining post-processing. Buffering clean SR image 1 and
putting it into frame 2's output would leave the downstream game effects using
frame 2's other resources. Merely delaying Present does not allow previously
recorded post-processing to be rerun with the newly available residual either.

A fully engine-matched integration would still need:

1. A composition/buffering point that preserves the matching frame's downstream
   effects and exposure, or engine integration to defer that work. The current
   pre-exposed linear residual cannot just be added to a tone-mapped backbuffer.
2. Full camera transforms. The current NR bridge does not carry them; this preview
   requires explicit consent to approximate guides instead.

The preview does implement displaced two-frame motion composition, matching clean
colour/exposure buffers, NR and private-SR cadence, generation completion markers,
cut/gap resets, and a GPU-side clean-frame fallback for NVIDIA's suppression flag.
Both NR and its private residual SR receive the anchor-to-anchor motion field.
Initial history repeats the first anchor while establishing the one-frame delay.
It is not a promise that halving NR work improves total FPS: interpolation itself
costs GPU time, and buffering increases VRAM use and latency.

Reprojecting the previous residual into the current frame would avoid waiting for
the next anchor, but would be a different algorithm. It must not be presented as
NVIDIA interpolation. Live-game validation is separate from the synthetic tests above.
