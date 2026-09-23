#pragma once
#include "RenderingCapability.h"
namespace optishade {
// Resolve only measured evidence; the choice still requires module load and Init.
enum class AutomaticUpscaler { XeSS, Dlss, FidelityFX };
inline AutomaticUpscaler SelectAutomaticUpscaler(Evidence dlssHardware, Evidence dlssInitialized,
                                                 Evidence fidelityHardware) {
    // Retain the existing preference order, but never borrow another adapter's facts.
    if (fidelityHardware == Evidence::Yes) return AutomaticUpscaler::FidelityFX;
    if (dlssHardware == Evidence::Yes && dlssInitialized == Evidence::Yes) return AutomaticUpscaler::Dlss;
    return AutomaticUpscaler::XeSS;
}
inline const char* NvidiaUpscalerUnavailableReason(Evidence hardware, bool runtimeLocated) {
    if (hardware == Evidence::No) return "DLSS capability is not available on the selected rendering adapter";
    if (hardware == Evidence::Unknown) return "Rendering adapter capability is unknown";
    if (!runtimeLocated) return "Requested NVIDIA upscaler runtime was not located";
    return nullptr;
}
// Shared by inventory matching and standalone regression tests. Never choose front().
template<class Range, class Luid>
inline const typename Range::value_type* FindRenderingAdapter(const Range& adapters, Luid luid) {
    for (const auto& adapter : adapters)
        if (adapter.luid.HighPart == luid.HighPart && adapter.luid.LowPart == luid.LowPart) return &adapter;
    return nullptr;
}
}
