# Optional RTXMFG component

Upstream: https://github.com/dashdogy/RTX40MFG-Unlock

Author: Michael Robles / dashdogy. Original project code: MIT.
OptiShade does not claim authorship or proprietary rights over this component.

## Preserved upstream binary

Release: v1.3.3-hotfix.2
Source commit: 53e3311157140df7b72a6cf0c76fb4e93c44fc04
Official asset: RTXMFG-v1.3.3-hotfix.2.zip
Archive SHA-256: edd671188b24520b2c1a313ce55d2184538e7a561263408d3460b5663d60dca5
Unmodified RTXMFG.dll SHA-256: e9ca3587854eeb723e0579f7ddf6cfb1e6cf4bed79b0d75bc716003ed98fe040

The original MIT, Ultimate ASI Loader, ImGui and MinHook notices accompany this
file. Other third-party notices remain embedded in the unchanged upstream DLL,
as documented in UPSTREAM-BUILD.md. Upstream's release build uses separately
prepared kernel-cache inputs. This preserved file is an upstream distribution;
it has not been independently rebuilt by OptiShade and still contains the
upstream first-launch/Backspace menu.

The maintained installer automatically selects this optional component only for
supported MSFS 2020/2024 installations with one detected NVIDIA RTX 40 GPU.
An integrated AMD companion GPU does not exclude that RTX 40 configuration.
OptiShade keeps the payload inactive until setup installs one verified copy as
version.dll; it does not overwrite a foreign loader. Repeated setup preserves
frame-generation preferences. The game must load the proxy early and provide a
compatible Streamline/DLSS Frame Generation pipeline. Installation alone does
not prove generated frames or a particular multiplier on that hardware.

RTX 30 support in this upstream release is very early and experimental, with
D3D12/provider and validated native-kernel requirements. OptiShade does not
automatically deploy it to RTX 30 or unsupported RTX 20 GPUs. RTX 50 native
frame generation and ordinary AMD functionality retain their existing paths.

## Local controls-only source candidate (not ready for distribution)

controls-only.patch is an OptiShade integration change against the pinned
upstream source. Together with the supported EnableOverlayMenuDraw=false build
option, it removes the default binding, saved-key binding, key consumption,
input capture/attachment and first-launch UI entry points from that build.
There is no replacement key or secondary menu. Provider/GPU dispatch, kernel
validation, status ABI and backend settings behavior remain upstream-owned.

build-controls-only.ps1 verifies the immutable source archive, applies the
patch and invokes the unchanged upstream build script with its pinned input
checks. Original native-cache manifests/JSON contracts and matching kernel
inputs are currently missing, so a complete replacement DLL has not been built
or verified. Native tests of the patched hotkey/input functions do not establish
full DLL input isolation or actual MFG rendering.

The current package retains the hash-pinned upstream DLL and its separate
menu. For a future replacement, verify-controls-only.ps1 requires a matching
reviewed input-isolation/backend verification receipt. It explicitly rejects
the preserved upstream DLL as a controls-only build. The patch and recipe are
development work, not a claim that Backspace is already removed from the
preserved binary. Any future rebuilt distribution must retain
all upstream licence/copyright/third-party notices and record its changed hash
and source/build provenance.
