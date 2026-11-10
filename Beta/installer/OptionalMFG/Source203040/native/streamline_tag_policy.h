#pragma once
#include <cstdint>
namespace optishade::mfg::streamline_tags {
// NVIDIA's 2.11 SDK used 68 for UI alpha. Since 2.12, 68 is the
// responsivity mask and UI alpha is 69. Interpret the active host ABI,
// not the SDK headers used to compile this observer.
inline constexpr uint32_t UiAlpha(uint32_t major, uint32_t minor) noexcept {
    if (major != 2 || minor < 11 || minor > 14) return UINT32_MAX;
    return minor == 11 ? 68u : 69u;
}
}
