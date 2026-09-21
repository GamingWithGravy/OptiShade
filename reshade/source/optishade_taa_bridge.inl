// OptiShade experimental native-D3D12 TAA input transport.
#include "../../shared/TaaBridge.h"
#include <Windows.h>
namespace ostaa_impl {
static void Run(reshade::api::effect_runtime* runtime, reshade::api::command_list* cmd,
                reshade::api::resource_view rtv, reshade::api::color_space space) {
    ostaa::Requested requested = nullptr;
    ostaa::Submit submit = nullptr;
    for (const auto* name : {L"winmm.dll", L"dxgi.dll", L"d3d12.dll", L"version.dll", L"dbghelp.dll", L"wininet.dll", L"winhttp.dll", L"OptiScaler.dll"}) {
        auto module = GetModuleHandleW(name);
        if (!module) continue;
        requested = reinterpret_cast<ostaa::Requested>(GetProcAddress(module, "OptiShadeTaaRequested"));
        submit = reinterpret_cast<ostaa::Submit>(GetProcAddress(module, "OptiShadeTaaSubmit"));
        if (requested && submit) break;
    }
    if (!requested || !submit || !requested()) return;
    ostaa::Frame frame {};
    const auto refuse = [&] { submit(&frame); };
    auto* device = runtime->get_device();
    auto* queue = runtime->get_command_queue();
    if (device->get_api() != reshade::api::device_api::d3d12 ||
        (space != reshade::api::color_space::srgb_nonlinear && space != reshade::api::color_space::unknown) ||
        cmd != queue->get_immediate_command_list()) { refuse(); return; }
    const auto texture = [&](const char* name) {
        reshade::api::resource_view view {};
        const auto variable = runtime->find_texture_variable("OptiShade_TAA_Guides.fx", name);
        if (variable.handle) runtime->get_texture_binding(variable, &view, nullptr);
        return view.handle ? device->get_resource_from_view(view) : reshade::api::resource {};
    };
    const auto sourceDepth = texture("DepthTex");
    const auto depth = texture("OptiShadeTaaDepth");
    const auto motion = texture("MotVectTexVort");
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
