#pragma once

#include <cstdint>

namespace optishade::fg
{
struct DisplayExtent
{
    uint32_t width = 0;
    uint32_t height = 0;

    constexpr bool IsValid() const { return width != 0 && height != 0; }
};

// Prefer the frame-generation output surface. A fallback is only safe when
// the caller has already established that it belongs to the same output.
constexpr DisplayExtent SelectDisplayExtent(DisplayExtent output, DisplayExtent sameOutputFallback)
{
    if (output.IsValid())
        return output;
    if (sameOutputFallback.IsValid())
        return sameOutputFallback;
    return {};
}
} // namespace optishade::fg
