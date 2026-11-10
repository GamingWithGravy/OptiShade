# Experimental TAA and Vulkan neural rendering

The R10 candidate retains Fusion Engine as the shared renderer, with separate simulator adapters. No cosmetic ReShade FX technique should be required to start NR.

## MSFS DirectX 12

Select TAA, enable the experimental TAA route and NR, and use the matching verified model. Internal guides serve the FG-off path; turning a cosmetic FX on/off is not a setup step. With native FG active, Beta attempts its early producer-frame route using accepted constants, exact viewport/frame resources, and observed submission/fence ownership. Missing evidence preserves the original image and reports the stage; it does not run an unsafe late pass.

Test unpaused flight with FG off, then on, followed by pause/resume, resize and a cosmetic-FX toggle. Check visible output, timings and stability. Isolated production/GPU tests do not establish that this combination works in MSFS; reported unpaused failures remain open pending target confirmation.

## X-Plane 12 Vulkan (Beta only)

Use the matching Beta manager/Play launch setup. The internal guide path is independent of the selected cosmetic preset. The private Vulkan-to-D3D12 bridge owns copy-in, actual submission observation, NR and copy-back; it preserves the original image during warm-up, unavailable inputs or unsafe resource ownership. No X-Plane FG or DLSS upscaler is added.

Loading hangs and older-GPU NR reports still require live testing of the new candidate. Local RTX 5090 transport/model tests are not a simulator pass. Export diagnostics for the selected running simulator, preferably while the problem occurs.

Guides retain their notices in `installer/DefaultEffects/Licenses/OptiShade-TAA-THIRD-PARTY.txt`. Unsupported configurations are reported rather than assigned invented timings or successful output.
