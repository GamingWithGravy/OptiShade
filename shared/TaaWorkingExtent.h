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

// Native extents are unchanged. Larger desktop inputs are bounded to 5120x2160.
// Both axes use the same rational scale, rounded once to the nearest pixel;
// raster quantization is at most half a pixel. No padding or cropped content is
// introduced. All image/guide sampling uses the resulting full raster extents,
// and motion is converted once per axis. Resolve transfers only the matched
// residual onto the untouched native image. Format/array/mip guards live at the
// resource admission boundary and are not relaxed by this size policy.
inline WorkingExtent TaaWorkingExtent(uint64_t width, unsigned height)
{
    if (!width || !height) return {};
    if (width <= 3840 && height <= 2160) return {static_cast<unsigned>(width), height};
    if(width>5120 || height>2160)return {};
    const uint64_t numerator=3840,denominator=width;
    const auto h=(uint64_t(height)*numerator+denominator/2)/denominator;
    if(h && h<=2160)return {3840,static_cast<unsigned>(h)};
    return {};
}
}
