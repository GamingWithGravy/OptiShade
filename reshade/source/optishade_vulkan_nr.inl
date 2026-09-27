// Experimental XP12 release path; explicit in-game NR toggle, SDR only.
#include "../../shared/VulkanNeuralBridge.h"
namespace osvnr_impl {
static void Run(reshade::api::effect_runtime* runtime, reshade::api::command_list* cmd,
                reshade::api::resource_view rtv, reshade::api::color_space space) {
    using namespace reshade;
    static const bool enabled = [] {
        wchar_t exe[MAX_PATH]{};
        GetModuleFileNameW(nullptr, exe, MAX_PATH);
        const auto* name = wcsrchr(exe, L'\\');
        return name && _wcsicmp(name + 1, L"X-Plane.exe") == 0;
    }();
    static unsigned calls = 0, completed = 0;
    static bool failed = false;
    static ULONGLONG started = 0, reported = 0;
    if (!enabled || runtime->get_device()->get_api() != api::device_api::vulkan) return;
    // XP12 cockpit pop-outs must not share the main window's temporal history.
    wchar_t title[256]{};
    GetWindowTextW(static_cast<HWND>(runtime->get_hwnd()), title, 256);
    if (wcsncmp(title, L"X-System", 8) != 0 && wcsncmp(title, L"X-Plane", 7) != 0) return;
    const auto now = GetTickCount64();
    auto module = GetModuleHandleW(L"dxgi.dll");
    using Requested = bool (*)();
    using Reset = void (*)();
    const auto requested = reinterpret_cast<Requested>(GetProcAddress(module, "OptiShadeVulkanNrRequested"));
    const auto reset = reinterpret_cast<Reset>(GetProcAddress(module, "OptiShadeVulkanNrReset"));
    static bool active = false;
    if (!requested || !requested()) {
        if (active && reset) reset();
        if (active) log::message(log::level::info, "XP12 Vulkan NR: disabled by user; completed=%u", completed);
        active = false;
        return;
    }
    if (!active) {
        if (reset) reset();
        active = true;
        started = reported = now;
        log::message(log::level::info, "XP12 Vulkan NR: enabled by user; full-resolution model, SDR, estimated guides.");
    }
    if (failed) return; // Submission/device failure is latched until game restart.
    auto* device = runtime->get_device();
    auto* queue = runtime->get_command_queue();
    if (device->get_api() != api::device_api::vulkan || space != api::color_space::srgb_nonlinear ||
        cmd != queue->get_immediate_command_list()) return;
    wchar_t proxyPath[MAX_PATH]{};
    GetModuleFileNameW(nullptr, proxyPath, MAX_PATH);
    auto* slash = wcsrchr(proxyPath, L'\\');
    if (!slash) return;
    wcscpy_s(slash + 1, MAX_PATH - (slash + 1 - proxyPath), L"dxgi.dll");
    const auto submit = reinterpret_cast<osvtaa::Submit>(GetProcAddress(GetModuleHandleW(proxyPath), "OptiShadeVulkanNrSubmit"));
    using Wait = int (*)(uint64_t);
    const auto wait = reinterpret_cast<Wait>(GetProcAddress(GetModuleHandleW(L"vulkan-1.dll"), "vkQueueWaitIdle"));
    static bool saidExports = false;
    if (!saidExports) {
        saidExports = true;
        log::message(log::level::info, "XP12 Vulkan NR: consumer=%d queue-wait=%d", submit != nullptr, wait != nullptr);
    }
    if (!submit || !wait) return;
    api::resource_view views[3]{};
    api::resource resources[3]{};
    const char* names[] = {"DepthTex", "OptiShadeTaaDepth", "MotVectTexVort"};
    for (unsigned i = 0; i != 3; ++i) {
        const auto var = runtime->find_texture_variable("OptiShade_TAA_Guides.fx", names[i]);
        if (var.handle) runtime->get_texture_binding(var, &views[i], nullptr);
        if (!views[i].handle) return;
        resources[i] = device->get_resource_from_view(views[i]);
    }
    const auto color = device->get_resource_from_view(rtv);
    const auto desc = device->get_resource_desc(color);
    static bool saidFormat = false;
    if (!saidFormat) {
        saidFormat = true;
        log::message(log::level::info, "XP12 Vulkan NR: colour format=%u samples=%u size=%ux%u", unsigned(desc.texture.format), unsigned(desc.texture.samples), desc.texture.width, desc.texture.height);
    }
    if (desc.texture.samples != 1 || desc.texture.width < 64 || desc.texture.height < 64 ||
        desc.texture.width > 3840 || desc.texture.height > 2160 ||
        (desc.texture.format != api::format::b8g8r8a8_unorm && desc.texture.format != api::format::b8g8r8a8_unorm_srgb &&
         desc.texture.format != api::format::b8g8r8a8_typeless)) return;
    for (const auto r : resources) {
        const auto d = device->get_resource_desc(r);
        if (d.texture.width != desc.texture.width || d.texture.height != desc.texture.height || d.texture.samples != 1) return;
    }
    if (device->get_resource_desc(resources[1]).texture.format != api::format::r32_float ||
        device->get_resource_desc(resources[2]).texture.format != api::format::r16g16_float) return;
    static uint32_t testWidth = 0, testHeight = 0;
    if (testWidth != desc.texture.width || testHeight != desc.texture.height) {
        if (reset) reset();
        testWidth = desc.texture.width; testHeight = desc.texture.height;
        log::message(log::level::info, "XP12 Vulkan NR: extent=%ux%u; history reset.", testWidth, testHeight);
    }
    if (!device->check_format_support(api::format::b8g8r8a8_unorm, api::resource_usage::unordered_access | api::resource_usage::shader_resource)) {
        failed = true; log::message(log::level::warning, "XP12 Vulkan NR: BGRA storage unsupported."); return;
    }
    queue->flush_immediate_command_list();
    if (wait(queue->get_native()) != 0) { failed = true; return; }
    api::resource work{};
    api::resource_view view{};
    const api::resource_desc workDesc(desc.texture.width, desc.texture.height, 1, 1,
        api::format::b8g8r8a8_unorm, 1, api::memory_heap::default_,
        api::resource_usage::unordered_access | api::resource_usage::shader_resource | api::resource_usage::copy_source | api::resource_usage::copy_dest);
    if (!device->create_resource(workDesc, nullptr, api::resource_usage::copy_dest, &work)) { failed = true; return; }
    if (!device->create_resource_view(work, api::resource_usage::unordered_access | api::resource_usage::shader_resource,
        api::resource_view_desc(api::format::b8g8r8a8_unorm), &view)) {
        device->destroy_resource(work); failed = true; return;
    }
    // Copy compatible bytes to UNORM: avoid an sRGB storage view or a double gamma conversion.
    cmd->barrier(color, api::resource_usage::render_target, api::resource_usage::copy_source);
    cmd->copy_resource(color, work);
    cmd->barrier(work, api::resource_usage::copy_dest, api::resource_usage::unordered_access);
    osvtaa::Frame f{};
    f.device = device->get_native(); f.commands = cmd->get_native();
    f.color = work.handle; f.colorView = view.handle;
    f.depth = resources[1].handle; f.depthView = views[1].handle;
    f.motion = resources[2].handle; f.motionView = views[2].handle;
    f.width = desc.texture.width; f.height = desc.texture.height;
    const int result = submit(&f);
    ++calls;
    if (result == 1) {
        cmd->barrier(work, api::resource_usage::unordered_access, api::resource_usage::copy_source);
        cmd->barrier(color, api::resource_usage::copy_source, api::resource_usage::copy_dest);
        cmd->copy_resource(work, color);
        cmd->barrier(color, api::resource_usage::copy_dest, api::resource_usage::render_target);
    } else cmd->barrier(color, api::resource_usage::copy_source, api::resource_usage::render_target);
    queue->flush_immediate_command_list();
    const int done = wait(queue->get_native());
    if (done == 0) {
        if (result == 1) ++completed;
        device->destroy_resource_view(view);
        device->destroy_resource(work);
    }
    if (done != 0 || result < 0 || (calls >= 10 && completed == 0)) failed = true;
    if (calls <= 5 || now - reported >= 5000 || failed) {
        reported = now;
        log::message(log::level::info, "XP12 Vulkan NR: call=%u recorded=%d queue-result=%d completed-composites=%u failed=%d. Estimated motion; inspect visual output separately.", calls, result, done, completed, failed);
    }
}
}
