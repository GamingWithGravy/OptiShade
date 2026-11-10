#pragma once

#include <cstdint>

namespace optishade::fsr4
{
inline constexpr float QualityModel1ScaleThreshold = 1.29f;

inline uint32_t CorrectPreset(uint32_t requestedPreset, uint32_t targetWidth, uint32_t renderWidth,
	bool overridePresent, uint32_t overridePreset)
{
	if (overridePresent)
		return overridePreset;

	if (requestedPreset != 0 || targetWidth == 0 || renderWidth == 0)
		return requestedPreset;

	const float scale = static_cast<float>(targetWidth) / static_cast<float>(renderWidth);
	return scale >= QualityModel1ScaleThreshold ? 1u : requestedPreset;
}
} // namespace optishade::fsr4
