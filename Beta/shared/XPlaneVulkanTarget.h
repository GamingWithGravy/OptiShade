#pragma once

#include <string_view>
#include "XPlaneGraphicsRoute.h"

namespace optishade::xplane_layer {
inline constexpr bool IsXPlaneProcessName(std::wstring_view executableName) noexcept
{
    constexpr std::wstring_view target = L"X-Plane.exe";
    if (executableName.size() != target.size())
        return false;

    for (std::size_t index = 0; index < target.size(); ++index)
    {
        auto actual = executableName[index];
        auto expected = target[index];
        if (actual >= L'A' && actual <= L'Z')
            actual = static_cast<wchar_t>(actual - L'A' + L'a');
        if (expected >= L'A' && expected <= L'Z')
            expected = static_cast<wchar_t>(expected - L'A' + L'a');
        if (actual != expected)
            return false;
    }
    return true;
}

// Preserve the native profile by default. An explicit process-start desktop
// compatibility selection is the only route that permits graphics hooks.
// This decision must be applied before ReShade loads.
inline constexpr bool ShouldDisableReShadeGraphicsHooks(std::wstring_view executableName,
    GraphicsRoute route=GraphicsRoute::NativeVulkan) noexcept
{
    return IsXPlaneProcessName(executableName) && DisablesGraphicsHooks(route);
}
} // namespace optishade::xplane_layer
