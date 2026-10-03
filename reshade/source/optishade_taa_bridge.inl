// OptiShade experimental native-D3D12 TAA input transport.
#include "../../shared/TaaBridge.h"
#include "../../shared/TaaRoutePolicy.h"
#include <Windows.h>
#include "optishade_core_guides.inl"
#include "optishade_vulkan_nr.inl"
namespace ostaa_impl {
struct Dependency {reshade::api::effect_runtime* runtime=nullptr;optishade::taa::GuideReloadBudget budget;std::string preset;bool requested=false;};
static std::array<Dependency,8> dependencies{};
static std::mutex dependencyMutex;
static void Retire(reshade::api::effect_runtime* runtime){std::lock_guard guard(dependencyMutex);for(auto& d:dependencies)if(d.runtime==runtime)d={};}
static ostaa::Requested Requested(){
    for(const auto* name:{L"winmm.dll",L"dxgi.dll",L"d3d12.dll",L"version.dll",L"dbghelp.dll",L"wininet.dll",L"winhttp.dll",L"OptiScaler.dll"})
        if(auto m=GetModuleHandleW(name))if(auto fn=reinterpret_cast<ostaa::Requested>(GetProcAddress(m,"OptiShadeTaaRequested")))return fn;
    return nullptr;
}
static bool RequiresGuides(reshade::api::effect_runtime* runtime){
    if(runtime->get_device()->get_api()!=reshade::api::device_api::d3d12)return false;
    {std::lock_guard guard(osfx_impl::lock);if(osfx_impl::owner!=runtime)return false;}
    const auto requested=Requested();const bool enabled=requested && requested();
    std::lock_guard guard(dependencyMutex);Dependency* state=nullptr;
    for(auto& d:dependencies)if(d.runtime==runtime){state=&d;break;}
    if(!state)for(auto& d:dependencies)if(!d.runtime){state=&d;d.runtime=runtime;break;}
    if(!state)return false;
    if(!enabled){state->requested=false;state->budget={};return false;}
    const auto desc=runtime->get_device()->get_resource_desc(runtime->get_current_back_buffer());
    for(const auto* name:{L"winmm.dll",L"dxgi.dll",L"d3d12.dll",L"version.dll",L"dbghelp.dll",L"wininet.dll",L"winhttp.dll",L"OptiScaler.dll"})
        if(auto module=GetModuleHandleW(name))
            if(auto query=reinterpret_cast<ostaa::NeedsGuides>(GetProcAddress(module,"OptiShadeTaaNeedsGuides")))
                return query(reinterpret_cast<void*>(runtime->get_device()->get_native()),desc.texture.width,desc.texture.height);
    return true;
}
static void Run(reshade::api::effect_runtime* runtime, reshade::api::command_list* cmd,
                reshade::api::resource_view rtv, reshade::api::color_space space, const osguide::Frame& guides) {
    osvnr_impl::Run(runtime, cmd, rtv, space, guides);
    ostaa::Requested requested = nullptr;
    ostaa::Submit submit = nullptr;
    for (const auto* name : {L"winmm.dll", L"dxgi.dll", L"d3d12.dll", L"version.dll", L"dbghelp.dll", L"wininet.dll", L"winhttp.dll", L"OptiScaler.dll"}) {
        auto module = GetModuleHandleW(name);
        if (!module) continue;
        requested = reinterpret_cast<ostaa::Requested>(GetProcAddress(module, "OptiShadeTaaRequested"));
        submit = reinterpret_cast<ostaa::Submit>(GetProcAddress(module, "OptiShadeTaaSubmit"));
        if (requested && submit) break;
    }
    if (!requested || !submit || !requested() || !RequiresGuides(runtime)) return;
    ostaa::Frame frame {};
    frame.runtime=reinterpret_cast<uint64_t>(runtime);frame.generation=guides.generation;
    frame.reason=guides.reason;frame.queue=reinterpret_cast<void*>(runtime->get_command_queue()->get_native());
    const auto refuse = [&] { submit(&frame); };
    auto* device = runtime->get_device();
    auto* queue = runtime->get_command_queue();
    if (device->get_api() != reshade::api::device_api::d3d12 ||
        (space != reshade::api::color_space::srgb_nonlinear && space != reshade::api::color_space::unknown) ||
        cmd != queue->get_immediate_command_list()) { refuse(); return; }
    const auto sourceDepth = guides.sourceDepth;
    const auto depth = guides.depth;
    const auto motion = guides.motion;
    if(!guides.ready){refuse();return;}
    const auto color = device->get_resource_from_view(rtv);
    if (!sourceDepth.handle || !depth.handle || !motion.handle || !color.handle) { refuse(); return; }
    const auto c = device->get_resource_desc(color), d = device->get_resource_desc(sourceDepth);
    // ReShade's unbound semantic is a tiny fallback texture, not scene depth.
    if (d.texture.width != c.texture.width || d.texture.height != c.texture.height ||
        d.texture.samples != 1 || c.texture.width < 64 || c.texture.height < 64) { refuse(); return; }
    // Flush the guide passes first. The consumer submits a separate command list on
    // this same queue and waits for completion before these borrowed textures can change.
    queue->flush_immediate_command_list();
    frame.queue = reinterpret_cast<void*>(queue->get_native());
    frame.color = reinterpret_cast<void*>(color.handle);
    frame.depth = reinterpret_cast<void*>(depth.handle);
    frame.motion = reinterpret_cast<void*>(motion.handle);
    frame.providerReady = 1;
    submit(&frame);
}
}
