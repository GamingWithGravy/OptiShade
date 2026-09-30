#pragma once
#include <cstdint>

namespace optishade::taa
{
struct WorkingExtent
{
    unsigned width = 0, height = 0;
    bool valid() const { return width != 0 && height != 0; }
    bool reduced(unsigned nativeWidth, unsigned nativeHeight) const
    { return width != nativeWidth || height != nativeHeight; }
};

// The existing native route is unchanged. The extra route is deliberately one
// targeted 32:9 size, with an exact 3/4 ratio in both axes. Colour is area-filtered
// to this extent; full-size depth/motion regions are retained and motion units are
// scaled once by the same ratio. Resolve returns only the model residual onto the
// untouched native picture. This is not permission to accept arbitrary large,
// padded, stereo, HDR or multi-sampled inputs.
inline WorkingExtent TaaWorkingExtent(uint64_t width, unsigned height)
{
    if (!width || !height) return {};
    if (width <= 3840 && height <= 2160) return {static_cast<unsigned>(width), height};
    if (width == 5120 && height == 1440) return {3840, 1080};
    return {};
}
}
