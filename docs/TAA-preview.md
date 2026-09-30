# Experimental neural rendering with TAA and Vulkan

OptiShade 0.21 adds a guide-input route that does not require the simulator to expose a DLSS option. It estimates motion from image-effects inputs; it is not a native game motion-vector integration or a new upscaler.

## MSFS DirectX 12 with TAA

1. Select TAA and SDR in the simulator; turn frame generation off.
2. Enable Image effects and the **TAA neural guides (experimental)** technique. Keep it before look effects.
3. In Neural rendering, select **TAA neural rendering (experimental)** and enable NR.

This route uses one model pass and starts off each launch. Native sizes up to 3840x2160 retain full-resolution processing. The beta also has a narrow experimental 5120x1440 route: it processes the model at 3840x1080, keeps full-size depth and motion guides, then applies the model's change to the original 5120x1440 picture. Other sizes outside the native envelope remain guarded. Your stored working-scale and pass-count settings are preserved.

Compatible RTX hardware and its matching model are required. MSFS 2020 and 2024 were visually tested at native 4K on an RTX 5090, with completed GPU work and no shimmer reported in those tests. The new ultrawide route has passed isolated GPU mapping and model-evaluation checks; it still needs an in-simulator check for appearance, shimmer and performance. These limited tests do not validate every GPU, aircraft or display configuration. Support remains experimental; performance and appearance vary by scene and GPU.

## X-Plane 12 Vulkan

Install through the manager and launch using **Play** in OptiShade. The manager enables the Vulkan layer for that game process only. The default X-Plane guide preset supplies the inputs; if you select another look, enable the guide technique in that preset as well. Then enable NR in Neural rendering. No DLSS or TAA option in X-Plane is required.

The Vulkan route is experimental, SDR only, up to 3840x2160, with one full-resolution model pass. It does not provide frame generation or DLSS upscaling. A prior five-minute RTX 5090 test produced visible, stable changes; this is not validation of every GPU, aircraft or display configuration.

If NR fails, switch it off and restart before retrying. Export diagnostics with a description of the problem and send the ZIP to the **diagnostic zips** channel in [BlackBox Discord](https://discord.gg/6hjR9cSsy7).

Guide assets retain their third-party licences; see `installer/DefaultEffects/Licenses/OptiShade-TAA-THIRD-PARTY.txt`.
