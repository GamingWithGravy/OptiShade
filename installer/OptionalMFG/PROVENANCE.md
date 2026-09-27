# Optional RTXMFG component

Upstream: https://github.com/dashdogy/RTX40MFG-Unlock

Author: Michael Robles / dashdogy. Original project code: MIT.
OptiShade does not claim authorship or proprietary rights over this component.

Release: v1.3.3-hotfix.2
Source commit: 53e3311157140df7b72a6cf0c76fb4e93c44fc04
Official asset: RTXMFG-v1.3.3-hotfix.2.zip
Archive SHA-256: edd671188b24520b2c1a313ce55d2184538e7a561263408d3460b5663d60dca5
Unmodified RTXMFG.dll SHA-256: e9ca3587854eeb723e0579f7ddf6cfb1e6cf4bed79b0d75bc716003ed98fe040

The original MIT, Ultimate ASI Loader, ImGui and MinHook notices accompany this
file. Other third-party notices remain embedded in the unchanged upstream DLL,
as documented in UPSTREAM-BUILD.md. Upstream's release build uses separately
prepared kernel-cache inputs; this is an upstream binary distribution, not a
claim that OptiShade independently rebuilt every part from the public checkout.

OptiShade stores the DLL in an inactive MFG directory. Optional setup installs
one copy as version.dll only when that name is unoccupied, for RTX 40 users.
The game must load that proxy early and provide a compatible DLSS FG pipeline.
This does not provide the separate DLSS Enabler backend or establish in-game
MFG operation on RTX 4060/4070 Ti. It is experimental and disabled by default.
