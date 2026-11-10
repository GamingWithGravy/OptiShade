#include "XPlaneVulkanProcess.h"
#include <cassert>
#include <cstring>

int main(int argc, char** argv)
{
    using namespace optishade::xplane_layer;
    assert(argc==2);
    const bool xplane=std::strcmp(argv[1],"other")!=0;
    const auto expected=std::strcmp(argv[1],"menu-only")==0?GraphicsRoute::MenuOnly:
        std::strcmp(argv[1],"legacy-dxgi")==0?GraphicsRoute::LegacyDxgi:GraphicsRoute::NativeVulkan;
    // These variables belong only to this fixture process. No installed game
    // or user's environment is changed by the test.
    SetEnvironmentVariableW(L"VK_INSTANCE_LAYERS",L"VK_LAYER_OptiShade_effects;VK_LAYER_reshade;VK_LAYER_OTHER");
    SetEnvironmentVariableW(L"VK_LOADER_LAYERS_ENABLE",L"VK_LAYER_OptiShade_effects,VK_LAYER_reshade,VK_LAYER_OTHER");
    SetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE",L"VK_LAYER_UNRELATED");
    SetEnvironmentVariableW(L"RESHADE_DISABLE_GRAPHICS_HOOK",L"inherited");
    SetEnvironmentVariableW(L"XR_ENABLE_API_LAYERS",L"XR_APILAYER_optishade;XR_APILAYER_reshade;XR_APILAYER_OTHER");
    assert(ProcessRoute().xplane==xplane);
    assert(CurrentRoute()==expected);
    assert(ConfigureRouteBeforeEffects());
    if(!xplane){
        assert(Env(L"RESHADE_DISABLE_GRAPHICS_HOOK")==L"inherited");
        assert(Env(L"VK_INSTANCE_LAYERS")==L"VK_LAYER_OptiShade_effects;VK_LAYER_reshade;VK_LAYER_OTHER");
    }else if(expected==GraphicsRoute::NativeVulkan){
        assert(Env(L"RESHADE_DISABLE_GRAPHICS_HOOK")==L"1");
        assert(Env(L"VK_INSTANCE_LAYERS")==L"VK_LAYER_OptiShade_effects;VK_LAYER_reshade;VK_LAYER_OTHER");
    }else{
        assert(Env(L"VK_INSTANCE_LAYERS")==L"VK_LAYER_OTHER");
        assert(Env(L"VK_LOADER_LAYERS_ENABLE")==L"VK_LAYER_OTHER");
        assert(Env(L"VK_LOADER_LAYERS_DISABLE")==L"VK_LAYER_UNRELATED,VK_LAYER_OptiShade_effects,VK_LAYER_reshade");
        assert(Env(L"DISABLE_VK_LAYER_reshade_1")==L"1");
        assert(Env(L"XR_ENABLE_API_LAYERS")==L"XR_APILAYER_OTHER");
        assert(Env(L"DISABLE_XR_APILAYER_reshade_1")==L"1");
        assert(Env(L"RESHADE_DISABLE_GRAPHICS_HOOK")==
            (expected==GraphicsRoute::MenuOnly?L"1":L""));
        const auto before=Env(L"VK_LOADER_LAYERS_DISABLE");
        assert(ConfigureRouteBeforeEffects());
        assert(Env(L"VK_LOADER_LAYERS_DISABLE")==before);
    }
    // Changing the file after selection cannot switch an active renderer.
    wchar_t executable[32768]{};
    GetModuleFileNameW(nullptr,executable,32768);
    const auto file=std::filesystem::path(executable).parent_path()/L"OptiShadeData"/L"XPlane-compatibility.ini";
    assert(WritePrivateProfileStringW(L"XPlane",L"GraphicsRoute",L"legacy-dxgi",file.c_str()));
    assert(CurrentRoute()==expected);
}
