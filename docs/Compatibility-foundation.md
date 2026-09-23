# Compatibility foundation: local 0.20.6

This increment starts the phased compatibility work from the published 0.20.5 source. It is not a 0.21 release and does not advertise universal GPU support.

## Architecture and changes

Game-facing API interception, existing upscaler implementations, frame-generation implementations and the neural runtime remain separate existing subsystems. The current NR frame metadata already includes motion scaling, render/output sizes, subrects, exposure, reset/history flags and arrival-state information. These semantics and the existing backend-specific metadata are retained.

The new `shared/D3D12FrameContext.h` is a borrowed-input boundary used before NR records commands. It validates actual COM device identity across the command list and required/optional resources. It neither allocates replacement resources nor transitions or submits them. A mismatch skips that optional NR invocation and logs why, leaving the game's inputs untouched. This is an initial boundary, not a completed common temporal-frame API or cross-vendor neural backend.

`shared/RenderingCapability.h` separates unknown, negative and positive evidence and resolves a display stage without treating a DLL on disk as proof of support. The Performance page supplies observed game-input, initialization and recent-activity evidence. Hardware, installation and runtime evidence remain unknown when they have not actually been measured. The resolver currently reports state; it does not silently choose a new rendering backend.

The rendering GPU is matched by the active D3D12 device LUID or D3D11 DXGI adapter LUID. Unknown matches remain unknown. This fixes the UI's reliance on a preferred/first enumerated GPU; further backend-wide and manager-wide adapter selection remains a later phase.

## Multi-window defects addressed

- Presentation ownership previously used HWND only. It now also uses canonical swapchain COM identity and explicit retirement, while retaining the existing windowless/VR bypass.
- Secondary resize/release cannot clean up the primary swapchain's overlay, even when a different chain shares its HWND. Secondary fullscreen, colour-space and limiter calls bypass shared OptiShade state.
- The previous resize wait tested for an already-created fence before creating its first fence, so it never waited. The replacement uses the queue's own device and holds valid COM references. Cleanup follows a successful wait, never a timeout or device failure.
- A missing ResizeBuffers1 queue array was dereferenced in two layers. Both now reject it before touching live resources. Non-null invalid arrays remain subject to the API's normal pointer/argument contract.
- A queue supplied for a failed resize is not adopted. Primary retirement clears borrowed device/queue state; accepted primary Present refreshes it.

## Hardware and backend labels

| Target | Status in this increment |
| --- | --- |
| RTX 50 | Existing paths retained; actual 5090 D3D12 tests described below |
| RTX 40 / 30 / 20 | Existing behavior retained; no new native-neural/FG claim; hardware testing pending |
| AMD | Existing experimental effects and supported FSR paths retained; NVIDIA neural backend unavailable |
| Intel | Existing backend infrastructure retained; no new compatibility certification |
| Cross-vendor neural model | Not implemented or bundled |

Native, compatibility, experimental and fallback are not interchangeable. A working alternative backend does not make it native NVIDIA DLSS. Unknown capability is not silently upgraded to supported.

## Remaining phases

1. Extend the initial frame boundary to capture adapters and backend-independent temporal metadata; audit every arrival/return state.
2. Propagate authoritative adapter/runtime capability evidence into backend selection, not only status reporting. Preserve explicit user choices.
3. Validate RTX 50 behavior in MSFS before widening RTX 40/30/20 experimental paths.
4. Validate existing AMD/Intel FSR/XeSS/FG inputs and fallback paths on community hardware.
5. Separate the neural backend lifecycle completely before evaluating a vendor-neutral model. No additional model/runtime license is introduced here.
6. Add evidence-driven automatic upscaling/FG selection with tested failure fallbacks; no model-name or GPU-name spoofing.
7. Improve manager multi-GPU selection and structured diagnostics, preserving optional components and ownership policy.
8. Retain manual private report export until a consent-based reporting relay and contract are configured. No reporting credentials or automatic uploads.
9. Keep Library disabled; build game adapters only after the hardware/runtime foundation is validated.

## Validation record

Checks completed on 23 September 2026:

- Release x64 OptiScaler and ReShade builds succeeded. Existing OptiScaler inheritance/LTCG/default-library warnings remain; this is not a warning-free build.
- All 26 PowerShell regression scripts passed, including real WPF key capture/layout, optional component persistence, backup/restore and updater lifecycle.
- `build-compat-test.cmd`: main/secondary/child windows, same-HWND competing identities, explicit retirement and destroyed-window replacement passed.
- `build-foundation-test.cmd`: unknown/detected/loaded/initialized/active/failed/unavailable/unsupported evidence decisions passed. Actual D3D12 queue first/repeated waits, timeout and recovery passed. Missing inputs and foreign resource/exposure/queue identities were rejected; valid inputs recovered. This test uses separate hardware and WARP devices, not an AMD compatibility certification.
- `OptiShade_Fusion_Test.exe --auto --multi --recreate` ran on the RTX 5090: primary swapchain recreation, both resize methods, null queue-array rejection, secondary Present/resize/teardown, shader compilation, preset edits/save/discard and four GPU readbacks passed. Zero D3D12 debug errors. NR/FG were not enabled by this fixture.
- The initial negative resize test exposed the bundled effects-layer dereference, which was corrected before the successful final run.
- Packaging verified all 100 embedded payload files and PowerShell encoding. The built manager's isolated `--check-update` validation returned `OK`; this does not claim a published end-to-end update.
- Final executable metadata: 0.20.6.0; SHA-256: `CD49216B3C541A442B32B946858E7B422AACE0BA9BB7239F000661D0520C92C6`.
- `git diff --check` passed. Tracked files and payload contain no private prompt documents or supplied screenshots.

Build success and synthetic tests do not establish MSFS compatibility. No live triple-monitor MSFS, NR, FG, HDR or VR reproduction was performed.

## Manual/community matrix

All real simulator combinations below remain untested for this build: Steam and Xbox; single window across three monitors; extra MSFS render windows; instrument pop-outs; HDR and SDR; VR; NR on/off; FG on/off; effects on/off. Repeat on RTX 50/40/30/20 and available AMD/Intel hardware. Record exact topology, resolution, adapter, driver, feature settings and whether disabling one optional feature changes the result.

A primary window is still selected from the first eligible presenting top-level window. Null/windowless paths retain legacy routing. General multi-node/alternating-queue rendering and multiple simultaneous enhanced views are not certified. The fence wait covers the queue available to the current wrapper; this is not a blanket guarantee for every third-party FG queue.

## Later game adapters

Keep discovery separate from graphics API interception and backend capability evidence. A future Library card should report detected integration, measured hardware/backend state and tested compatibility level. MSFS 2020 and generic DX12 come after MSFS 2024 validation; Vulkan and X-Plane need their own capture/state contracts. Nothing in this increment enables arbitrary other-game injection.

## Distribution and privacy

Local source and artifacts only. No release/tag/push. Private planning documents and screenshots are not copied into source or payload. Existing third-party attribution and licenses remain; no new external dependency, model or proprietary implementation is added.

## Files changed

Shared code: PresentationOwner, D3D12QueueWait, D3D12FrameContext and RenderingCapability. Native integration: wrapped_swapchain, menu_overlay_dx, menu_common, DlssNr_Dx12 and ReShade dxgi_swapchain. Tests: presentation-owner, rendering-foundation, fusion_render and the foundation build script. Manager/package edits only update current version identifiers and the local patch notes; migration/ownership behavior is unchanged.

## API reference

Queue-array and multi-node semantics were checked against [Microsoft's ResizeBuffers1 documentation](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/nf-dxgi1_4-idxgiswapchain3-resizebuffers1). This documentation does not establish compatibility with a particular simulator or third-party graphics proxy.
