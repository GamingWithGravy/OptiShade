#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace optishade::guides {
constexpr uint32_t MinGuideDimension = 64;
constexpr uint32_t MaxGuideSourceDimension = 16384;
constexpr double MinDepthScale = 0.25;
constexpr double MaxDepthScale = 4.0;
constexpr double MaxRelativeScaleDifference = 0.005;

// Scene depth can be rendered at a different TAA scale from the final colour
// image. It is safe to sample it at normalized display coordinates only when
// both axes use effectively the same scale and the source stays bounded.
inline bool CompatibleDepthExtent(uint32_t outputWidth, uint32_t outputHeight,
                                 uint32_t depthWidth, uint32_t depthHeight) {
    if (outputWidth < MinGuideDimension || outputHeight < MinGuideDimension ||
        depthWidth < MinGuideDimension || depthHeight < MinGuideDimension ||
        depthWidth > MaxGuideSourceDimension || depthHeight > MaxGuideSourceDimension)
        return false;

    const double scaleX = static_cast<double>(depthWidth) / outputWidth;
    const double scaleY = static_cast<double>(depthHeight) / outputHeight;
    if (scaleX < MinDepthScale || scaleX > MaxDepthScale ||
        scaleY < MinDepthScale || scaleY > MaxDepthScale)
        return false;

    const double relativeDifference = std::abs(scaleX - scaleY) / std::max(scaleX, scaleY);
    return relativeDifference <= MaxRelativeScaleDifference;
}
}
