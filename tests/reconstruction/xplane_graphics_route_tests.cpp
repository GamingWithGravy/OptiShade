#include "XPlaneGraphicsRoute.h"
#include "XPlaneVulkanTarget.h"
#include <cassert>

int main()
{
    using namespace optishade::xplane_layer;
    assert(ParseGraphicsRoute(L"")==GraphicsRoute::NativeVulkan);
    assert(ParseGraphicsRoute(L"native-vulkan")==GraphicsRoute::NativeVulkan);
    assert(ParseGraphicsRoute(L"legacy")==GraphicsRoute::NativeVulkan);
    assert(ParseGraphicsRoute(L"legacy-dxgi-extra")==GraphicsRoute::NativeVulkan);
    assert(ParseGraphicsRoute(L"menu-only")==GraphicsRoute::MenuOnly);
    assert(ParseGraphicsRoute(L" legacy-dxgi\t")==GraphicsRoute::LegacyDxgi);
    for(const auto route:{GraphicsRoute::NativeVulkan,GraphicsRoute::MenuOnly,GraphicsRoute::LegacyDxgi}){
        const bool vulkanEffects=UsesNativeEffects(route);
        const bool dxgiEffects=LoadsEffects(route)&&!DisablesGraphicsHooks(route);
        assert(!(vulkanEffects&&dxgiEffects));
        assert(route==GraphicsRoute::MenuOnly ? !vulkanEffects&&!dxgiEffects : vulkanEffects!=dxgiEffects);
    }
    assert(LoadsEffects(GraphicsRoute::NativeVulkan));
    assert(DisablesGraphicsHooks(GraphicsRoute::NativeVulkan));
    assert(!LoadsEffects(GraphicsRoute::MenuOnly));
    assert(!UsesNativeEffects(GraphicsRoute::MenuOnly));
    assert(!UsesNativeEffects(GraphicsRoute::LegacyDxgi));
    assert(WithoutEffectsLayers(L"VK_LAYER_OptiShade_effects;VK_LAYER_reshade;VK_LAYER_OTHER",L';')==L"VK_LAYER_OTHER");
    assert(WithoutEffectsLayers(L"VK_LAYER_OTHER; VK_LAYER_OptiShade_effects ;VK_LAYER_reshade;VK_LAYER_OTHER2",L';')==L"VK_LAYER_OTHER;VK_LAYER_OTHER2");
    assert(WithoutEffectsLayers(L"VK_LAYER_OptiShade_effects,VK_LAYER_reshade,VK_LAYER_OTHER",L',')==L"VK_LAYER_OTHER");
    assert(WithoutEffectsLayers(L"VK_LAYER_OptiShade_effects",L';').empty());
    assert(WithoutEffectsLayers(L"",L';').empty());
    assert(!IsXPlaneProcessName(L"FlightSimulator2024.exe"));
    assert(!IsXPlaneProcessName(L"X-Plane.exe.bak"));
    assert(IsXPlaneProcessName(L"X-Plane.exe"));
    assert(ShouldDisableReShadeGraphicsHooks(L"X-Plane.exe"));
    assert(ShouldDisableReShadeGraphicsHooks(L"X-Plane.exe",GraphicsRoute::MenuOnly));
    assert(!ShouldDisableReShadeGraphicsHooks(L"X-Plane.exe",GraphicsRoute::LegacyDxgi));
    assert(!ShouldDisableReShadeGraphicsHooks(L"FlightSimulator2024.exe",GraphicsRoute::NativeVulkan));
}
