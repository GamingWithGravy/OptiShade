#pragma once

#include "../../../shared/NativeMfgControl.h"
#include "../../../shared/RuntimeRenderContext.h"

namespace optishade::native_mfg_ui {
inline std::string CapabilityRangeDetail(uint32_t maximum) {
    if (maximum == 1)
        return "The game/provider reports one generated frame (2x). It has not exposed 3x or higher Multi Frame Generation in this session.";
    if (maximum >= 2 && maximum <= 6)
        return "The game/provider reports support from 2x to " + std::to_string(maximum + 1) + "x Multi Frame Generation for this session.";
    return "The game/provider has not reported a usable frame-generation multiplier range for this session.";
}

inline const char* CapabilityQueryDetail(const std::string& reason) {
    if (reason == "Provider query skipped: caller is not synchronized with Present")
        return "The game called DLSS-G GetState away from its Present thread. OptiShade skipped the provider query because this callback can crash or consume invalid frame state off-thread. MFG may be supported by the game, but its live capability is unverified; use the game's own Frame Generation setting and send diagnostics if this persists.";
    if (reason == "Provider query skipped: no Present thread has been observed")
        return "The game requested DLSS-G state before OptiShade observed a rendered Present. MFG support is not yet verified; return to a rendered scene and check again.";
    if (reason == "Provider function unavailable")
        return "No live DLSS-G provider callback has been exposed to OptiShade yet. MFG setup does not require that callback; enable the game's supported DLSS Frame Generation option (in MSFS, use Graphics settings) and return to a rendered scene so OptiShade can check it in-game. If it stays locked after Frame Generation is enabled, send diagnostics. A missing callback alone does not mean MFG installation failed.";
    if (reason == "Provider query disabled after contained fault")
        return "The DLSS-G provider state callback faulted earlier in this run. OptiShade stopped querying it to avoid another crash; restart the game and send diagnostics so the provider failure can be identified.";
    return "";
}
inline const char* ControlBlocker(const native_mfg::Snapshot& state,
                                 bool compatibilityOwned,
                                 bool alternateOutputOwns,
                                 const runtime_render::Snapshot& live,
                                 uint64_t now) {
    if (compatibilityOwned) return "A compatibility MFG provider owns this session.";
    if (alternateOutputOwns) return "Another frame-generation route owns this output.";
    if (!state.provider) return "The game has not supplied a DLSS-G provider callback.";
    if (!state.known) return "The provider did not report a supported frame-generation range.";
    if (!native_mfg::Control::Fresh(state)) return "The provider capability sample is stale.";
    if (!state.controllable) return "The provider is observable, but its settings callback is not writable.";
    if (!live.Fresh(now)) return "The active rendering-device and output context is stale or incomplete.";
    if (!live.device.Known()) return "The active rendering adapter is not identified.";
    if (live.native.passive) return "The game owns this provider state; OptiShade is read-only.";
    if (live.native.device != live.device.identity) return "The provider report belongs to a different rendering device.";
    if (live.native.luid != live.device.luid) return "The provider report belongs to a different GPU adapter.";
    if (!live.native.provider || live.native.provider != state.provider) return "The capability report and settings callback belong to different providers.";
    if (live.native.generation != state.generation) return "The provider changed after its capability report.";
    if (live.native.view != state.view || live.native.view != live.context.view) return "The provider report belongs to a different game viewport.";
    if (!live.native.sampledAt || now < live.native.sampledAt || now - live.native.sampledAt > 3000)
        return "The provider-to-rendering match is older than three seconds.";
    return "The live provider supports 2x frame generation; higher multipliers are limited to its reported maximum.";
}
}
