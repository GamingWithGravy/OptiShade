#pragma once
#include <nvsdk_ngx_defs.h>
#include <cstdint>
#include <optional>

namespace optishade::deferred_quality
{
constexpr uint32_t Unknown = UINT32_MAX;

// This selects only the private residual SR feature's creation mode. It never
// edits the game's parameters or reroutes its main DLSS/DLAA feature.
inline std::optional<NVSDK_NGX_PerfQuality_Value> Resolve(uint32_t supplied,
    uint32_t inputWidth, uint32_t inputHeight, uint32_t outputWidth, uint32_t outputHeight,
    std::optional<NVSDK_NGX_PerfQuality_Value> sameContractAuthoritative = std::nullopt)
{
    if (!inputWidth || !inputHeight || !outputWidth || !outputHeight ||
        inputWidth > outputWidth || inputHeight > outputHeight)
        return std::nullopt;
    if (supplied != Unknown)
    {
        if (supplied > static_cast<uint32_t>(NVSDK_NGX_PerfQuality_Value_DLAA))
            return std::nullopt;
        return static_cast<NVSDK_NGX_PerfQuality_Value>(supplied);
    }
    // The caller may retain an explicit creation mode only after checking the
    // same owner and full private-generation contract. Omission in an Evaluate
    // map is not an instruction to change a previously authoritative mode.
    if (sameContractAuthoritative)
    {
        if (static_cast<uint32_t>(*sameContractAuthoritative) >
            static_cast<uint32_t>(NVSDK_NGX_PerfQuality_Value_DLAA)) return std::nullopt;
        return sameContractAuthoritative;
    }
    // Evaluate maps are not required to repeat feature-creation parameters.
    // Missing quality at 1:1 used to create a Performance private feature. Use
    // native-AA for that private 1:1 operation; retain the existing scaled
    // fallback until the caller provides an authoritative creation contract.
    return inputWidth == outputWidth && inputHeight == outputHeight
        ? NVSDK_NGX_PerfQuality_Value_DLAA : NVSDK_NGX_PerfQuality_Value_MaxPerf;
}
}
