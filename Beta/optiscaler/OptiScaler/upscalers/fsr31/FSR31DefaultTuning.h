#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace optishade::fsr31 {

struct DefaultTuning {
    float velocity = 0.5f;
    float reactiveScale = 0.25f;
    float shadingScale = 0.0f;
    float accumulationPerFrame = 0.0f;
    float minimumDisocclusionAccumulation = 0.0f;
};

// Derive FSR 3.1 temporal stability defaults from the actual target/render
// ratio. Return false for incomplete extents so callers retain their defaults.
inline bool TryCalculateDefaultTuning(uint32_t targetWidth, uint32_t targetHeight,
                                     uint32_t renderWidth, uint32_t renderHeight,
                                     DefaultTuning& result) noexcept {
    if (!targetWidth || !targetHeight || !renderWidth || !renderHeight)
        return false;

    const float ratioX = static_cast<float>(targetWidth) / static_cast<float>(renderWidth);
    const float ratioY = static_cast<float>(targetHeight) / static_cast<float>(renderHeight);
    const float scaleRatio = std::max(ratioX, ratioY);
    if (!(scaleRatio > 0.0f) || !std::isfinite(scaleRatio))
        return false;

    result = {0.5f, 0.25f, 0.5f / scaleRatio,
              scaleRatio / 10.0f, scaleRatio / 20.0f};
    return true;
}

} // namespace optishade::fsr31
