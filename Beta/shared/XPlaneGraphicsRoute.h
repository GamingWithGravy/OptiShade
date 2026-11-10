#pragma once
#include <string>
#include <string_view>

namespace optishade::xplane_layer {
enum class GraphicsRoute { NativeVulkan, MenuOnly, LegacyDxgi };

inline GraphicsRoute ParseGraphicsRoute(std::wstring_view value) noexcept
{
    while (!value.empty() && (value.front() == L' ' || value.front() == L'\t')) value.remove_prefix(1);
    while (!value.empty() && (value.back() == L' ' || value.back() == L'\t')) value.remove_suffix(1);
    if (value == L"menu-only") return GraphicsRoute::MenuOnly;
    if (value == L"legacy-dxgi") return GraphicsRoute::LegacyDxgi;
    // Missing, truncated and unknown values preserve the established route.
    return GraphicsRoute::NativeVulkan;
}
inline constexpr const char* GraphicsRouteName(GraphicsRoute route) noexcept
{
    return route == GraphicsRoute::MenuOnly ? "menu-only" :
        route == GraphicsRoute::LegacyDxgi ? "legacy-dxgi" : "native-vulkan";
}
inline constexpr bool UsesNativeEffects(GraphicsRoute route) noexcept { return route == GraphicsRoute::NativeVulkan; }
inline constexpr bool LoadsEffects(GraphicsRoute route) noexcept { return route != GraphicsRoute::MenuOnly; }
inline constexpr bool DisablesGraphicsHooks(GraphicsRoute route) noexcept { return route != GraphicsRoute::LegacyDxgi; }

// Remove only OptiShade/ReShade requests; preserve unrelated explicit layers.
// Discovery paths remain untouched: a discoverable explicit layer is not an
// enabled layer. The process additionally excludes both layers through the
// loader's disable filter, including inherited enable requests.
inline std::wstring WithoutEffectsLayers(std::wstring_view list, wchar_t separator)
{
    std::wstring result;
    while (!list.empty()) {
        const auto end = list.find(separator);
        auto part = list.substr(0, end);
        while (!part.empty() && (part.front() == L' ' || part.front() == L'\t')) part.remove_prefix(1);
        while (!part.empty() && (part.back() == L' ' || part.back() == L'\t')) part.remove_suffix(1);
        if (!part.empty() && part != L"VK_LAYER_OptiShade_effects" && part != L"VK_LAYER_reshade" &&
            part != L"XR_APILAYER_optishade" && part != L"XR_APILAYER_reshade") {
            if (!result.empty()) result += separator;
            result.append(part);
        }
        if (end == std::wstring_view::npos) break;
        list.remove_prefix(end + 1);
    }
    return result;
}
} // namespace optishade::xplane_layer
