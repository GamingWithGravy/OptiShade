// OptiShade experimental native-D3D12 TAA input transport.
#include "../../shared/TaaBridge.h"
#include "../../shared/TaaRoutePolicy.h"
#include "../../shared/GuideExtent.h"
#include <Windows.h>
#include <atomic>
#include "optishade_core_guides.inl"
#include "optishade_vulkan_nr.inl"
namespace ostaa_impl {
struct Dependency {reshade::api::effect_runtime* runtime=nullptr;optishade::taa::GuideReloadBudget budget;std::string preset;bool requested=false;};
static std::array<Dependency,8> dependencies{};
static std::mutex dependencyMutex;
static void Retire(reshade::api::effect_runtime* runtime){
    {std::lock_guard guard(dependencyMutex);for(auto& d:dependencies)if(d.runtime==runtime)d={};}
    // Drop the dependency lock before publishing. The export only marks the
    // owner ended; GPU cleanup is deferred to a regular NR entry point.
    for(const auto* name:{L"winmm.dll",L"dxgi.dll",L"d3d12.dll",L"version.dll",L"dbghelp.dll",L"wininet.dll",L"winhttp.dll",L"OptiScaler.dll"})
        if(auto module=GetModuleHandleW(name))if(auto retire=reinterpret_cast<ostaa::RetireRuntime>(GetProcAddress(module,"OptiShadeTaaRetireRuntime"))){
            retire(ostaa::RetirementVersion,reinterpret_cast<uint64_t>(runtime));break;
        }
}
static ostaa::Requested Requested(){
    for(const auto* name:{L"winmm.dll",L"dxgi.dll",L"d3d12.dll",L"version.dll",L"dbghelp.dll",L"wininet.dll",L"winhttp.dll",L"OptiScaler.dll"})
        if(auto m=GetModuleHandleW(name))if(auto fn=reinterpret_cast<ostaa::Requested>(GetProcAddress(m,"OptiShadeTaaRequested")))return fn;
    return nullptr;
}
static bool RequiresGuides(reshade::api::effect_runtime* runtime){
    const bool dx11=runtime->get_device()->get_api()==reshade::api::device_api::d3d11;
    if(!dx11&&runtime->get_device()->get_api()!=reshade::api::device_api::d3d12)return false;
    const auto requested=Requested();const bool enabled=requested&&requested();
    if(!enabled){std::lock_guard guard(dependencyMutex);for(auto& item:dependencies)if(item.runtime==runtime){item.requested=false;item.budget={};break;}return false;}
    bool owns=false;
    for(const auto* name:{L"winmm.dll",L"dxgi.dll",L"d3d12.dll",L"version.dll",L"dbghelp.dll",L"wininet.dll",L"winhttp.dll",L"OptiScaler.dll"})
        if(auto m=GetModuleHandleW(name))if(auto fn=reinterpret_cast<bool(*)(uint64_t)>(GetProcAddress(m,"OptiShadeTaaOwnsWindow"))){owns=fn(reinterpret_cast<uint64_t>(runtime->get_hwnd()));break;}
    static std::atomic_flag ownerMiss=ATOMIC_FLAG_INIT,admitted=ATOMIC_FLAG_INIT,queryMiss=ATOMIC_FLAG_INIT;
    if(!owns){if(!ownerMiss.test_and_set())reshade::log::message(reshade::log::level::warning,"OptiShade TAA guide request was blocked because this ReShade runtime does not own the primary game window.");return false;}
    std::lock_guard guard(dependencyMutex);Dependency* state=nullptr;
    for(auto& d:dependencies)if(d.runtime==runtime){state=&d;break;}
    if(!state)for(auto& d:dependencies)if(!d.runtime){state=&d;d.runtime=runtime;break;}
    if(!state)return false;
    state->requested=true;
    const auto desc=runtime->get_device()->get_resource_desc(runtime->get_current_back_buffer());
    for(const auto* name:{L"winmm.dll",L"dxgi.dll",L"d3d12.dll",L"version.dll",L"dbghelp.dll",L"wininet.dll",L"winhttp.dll",L"OptiScaler.dll"})
        if(auto module=GetModuleHandleW(name))
            if(auto query=reinterpret_cast<ostaa::NeedsGuides>(GetProcAddress(module,dx11?"OptiShadeD3D11TaaNeedsGuides":"OptiShadeTaaNeedsGuides"))){
                const bool result=query(reinterpret_cast<void*>(runtime->get_device()->get_native()),desc.texture.width,desc.texture.height);
                if(result){if(!admitted.test_and_set())reshade::log::message(reshade::log::level::info,"OptiShade TAA guide request admitted for %s at %ux%u.",dx11?"D3D11":"D3D12",desc.texture.width,desc.texture.height);}
                else if(!queryMiss.test_and_set())reshade::log::message(reshade::log::level::warning,"OptiShade TAA guide request was rejected by the device/input capability check.");
                return result;
            }
    if(!queryMiss.test_and_set())reshade::log::message(reshade::log::level::warning,"OptiShade TAA guide request could not find its device/input capability check.");
    return false;
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
        submit = reinterpret_cast<ostaa::Submit>(GetProcAddress(module, runtime->get_device()->get_api()==reshade::api::device_api::d3d11?"OptiShadeD3D11TaaSubmit":"OptiShadeTaaSubmit"));
        if (requested && submit) break;
    }
    if (!requested || !submit || !requested() || !RequiresGuides(runtime)) return;
    ostaa::Frame frame {};
    frame.runtime=reinterpret_cast<uint64_t>(runtime);frame.generation=guides.generation;
    frame.reason=guides.reason;frame.queue=reinterpret_cast<void*>(runtime->get_command_queue()->get_native());
    const auto refuse = [&] { submit(&frame); };
    auto* device = runtime->get_device();
    auto* queue = runtime->get_command_queue();
    if ((device->get_api() != reshade::api::device_api::d3d12 && device->get_api() != reshade::api::device_api::d3d11) ||
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
    if (d.texture.samples != 1 ||
        !optishade::guides::CompatibleDepthExtent(c.texture.width,c.texture.height,
                                                   d.texture.width,d.texture.height)) { refuse(); return; }
    // Flush the guide passes first. The consumer submits a separate command list on
    // this same queue and keeps a reference to each borrowed texture until its own fence passes.
    queue->flush_immediate_command_list();
    frame.queue = reinterpret_cast<void*>(queue->get_native());
    frame.color = reinterpret_cast<void*>(color.handle);
    frame.depth = reinterpret_cast<void*>(depth.handle);
    frame.motion = reinterpret_cast<void*>(motion.handle);
    frame.providerReady = 1;
    submit(&frame);
}
}
