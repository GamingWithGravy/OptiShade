#include <cstdint>
#include <cstring>
#include <cstdio>
#include <iostream>
#include <iterator>

using ULONGLONG = uint64_t;
using DWORD = uint32_t;
using BOOL = int;
constexpr BOOL FALSE = 0;
struct Window { DWORD pid = 73; bool visible = true, minimized = false; const char* name = "game"; };
using HWND = Window*;
static ULONGLONG clockTick = 10000;
static ULONGLONG GetTickCount64() { return clockTick; }
static DWORD GetCurrentProcessId() { return 73; }
static void GetWindowThreadProcessId(HWND window, DWORD* pid) { *pid = window ? window->pid : 0; }
static bool IsWindow(HWND window) { return window != nullptr; }
static bool IsWindowVisible(HWND window) { return window && window->visible; }
static bool IsIconic(HWND window) { return window && window->minimized; }
static int GetClassNameA(HWND window, char* value, size_t bytes) {
    if (!window) return 0;
    std::snprintf(value, bytes, "%s", window->name); return 1;
}
#if !defined(_WIN32)
template<size_t N> static int strcpy_s(char (&target)[N], const char* value) {
    std::snprintf(target, N, "%s", value); return 0;
}
#endif
struct ID3D11Device {};
struct ID3D10Device {};
struct IDXGISwapChain { int GetFullscreenState(BOOL* fullscreen, void*) { *fullscreen = FALSE; return 0; } };
static bool SUCCEEDED(int result) { return result >= 0; }
namespace reshade::api {
enum class device_api { d3d10, d3d11, vulkan, opengl };
struct effect_technique { uint64_t handle = 0; };
struct device {
    void* native = nullptr; device_api api = device_api::d3d11;
    uint64_t get_native() const { return reinterpret_cast<uint64_t>(native); }
    device_api get_api() const { return api; }
};
struct effect_runtime {
    device* hardware = nullptr; Window window{}; effect_technique technique{}; IDXGISwapChain chain{};
    device* get_device() const { return hardware; }
    void* get_hwnd() { return &window; }
    uint64_t get_native() { return reinterpret_cast<uint64_t>(&chain); }
    effect_technique find_technique(const char*, const char*) const { return technique; }
};
}
static constexpr const char* kEffectFile = "DLSS5_Feed.fx";
static constexpr const char* kTechnique = "DLSS5_Feed";
static struct { int enabled = 1, guide_source = 0; } g_cfg;
static struct {
    reshade::api::effect_runtime* runtime = nullptr;
    reshade::api::effect_technique technique{};
    bool need_reset = false, is_vulkan = false, is_d3d10 = false;
    ID3D11Device* dev = nullptr; ID3D10Device* d10_dev = nullptr;
    reshade::api::device* rs_dev = nullptr;
} g;
static bool g_cast_fullscreen = false;
static unsigned controlStarts = 0, handleResolves = 0;
static void StartLegacyControl() { ++controlStarts; }
static void DetectSmoothMotion() {}
static void FeedResolveDbghelp() {}
template<typename... T> static void Log(const char*, T...) {}
// ReShade's technique lookup is the event boundary. Core mode has no feed
// effect; the original ResolveHandles likewise clears g.technique in this mode.
static void ResolveHandles(reshade::api::effect_runtime* runtime) {
    ++handleResolves; g.technique = g_cfg.guide_source == 0 ? reshade::api::effect_technique{} : runtime->technique;
}

// PRODUCTION_RUNTIME_OWNER

static unsigned checks = 0, failed = 0;
static void Check(bool value, const char* reason) {
    ++checks;
    if (!value) { ++failed; std::cerr << "FAIL: " << reason << '\n'; }
}
static void Reset() {
    g = {}; g_cfg.enabled = 1; g_cfg.guide_source = 0; g_runtime_count = 0;
    for (auto& slot : g_runtimes) slot = {};
    g_bound_last_render = 0; handleResolves = 0; controlStarts = 0;
}
int main() {
    ID3D11Device firstNative{}, otherNative{};
    reshade::api::device first{&firstNative}, other{&otherNative};
    reshade::api::effect_runtime runtime[8]{};
    for (auto& item : runtime) item.hardware = &first;

    Reset();
    for (unsigned i = 0; i < 6; ++i) Check(TrackRuntime(&runtime[i]) != nullptr, "six live runtimes are admitted");
    const auto* sixth = FindRuntime(&runtime[5]);
    Check(TrackRuntime(&runtime[6]) == nullptr, "capacity refuses a seventh runtime without recycling a live owner");
    Check(g_runtime_count == 6, "refusal preserves the live count");
    for (unsigned i = 0; i < 6; ++i) Check(FindRuntime(&runtime[i]) != nullptr, "capacity preserves each original runtime");
    Check(FindRuntime(&runtime[5]) == sixth, "capacity preserves the sixth record location");
    Check(!LegacyCandidateRuntime(&runtime[6]), "refused runtime cannot publish metadata or prepare a worker");
    Check(TrackRuntime(&runtime[5]) != nullptr && g_runtime_count == 6, "existing registration can refresh at capacity");
    UntrackRuntime(&runtime[2]);
    Check(g_runtime_count == 5 && FindRuntime(&runtime[2]) == nullptr, "retirement frees only the named slot");
    Check(TrackRuntime(&runtime[6]) != nullptr && g_runtime_count == 6, "new runtime can use retired capacity");

    Reset(); runtime[0].technique = {}; runtime[1].technique = {42};
    OnInitEffectRuntime(&runtime[0]); g_bound_last_render = clockTick;
    Check(g.runtime == &runtime[0], "core mode binds its first runtime");
    const auto coreResolves = handleResolves;
    OnInitEffectRuntime(&runtime[1]);
    Check(g.runtime == &runtime[0] && handleResolves == coreResolves, "old external technique cannot steal a core owner during init");
    OnReloadedEffects(&runtime[1]);
    Check(g.runtime == &runtime[0] && handleResolves == coreResolves, "old external technique cannot steal a core owner during reload");
    Check(LegacyCandidateRuntime(&runtime[0]), "main core owner remains an eligible candidate after secondary events");
    OnReloadedEffects(&runtime[0]);
    Check(g.runtime == &runtime[0] && handleResolves == coreResolves + 1 && g.need_reset, "core owner's own reload still refreshes its guides");

    Reset(); g_cfg.guide_source = 1;
    OnInitEffectRuntime(&runtime[0]); OnInitEffectRuntime(&runtime[1]);
    Check(g.runtime == &runtime[1] && g.technique.handle == 42, "explicit external mode retains technique-driven init adoption");
    Reset(); g_cfg.guide_source = 1;
    OnInitEffectRuntime(&runtime[0]); OnReloadedEffects(&runtime[1]);
    Check(g.runtime == &runtime[1] && g.technique.handle == 42, "explicit external mode retains technique-driven reload adoption");

    Reset(); g_cfg.enabled = 0;
    OnInitEffectRuntime(&runtime[0]);
    Check(FindRuntime(&runtime[0]) != nullptr, "saved Off still registers read-only runtime identity");
    Check(g.runtime == nullptr && handleResolves == 0, "saved Off does not bind/feed through init");
    Check(LegacyCandidateRuntime(&runtime[0]), "saved Off permits the later current-session Auto preparation");
    Check(!LegacyCandidateRuntime(&runtime[7]), "unregistered outputs cannot bypass the bounded registry");

    Reset();
    for (unsigned i = 0; i < 6; ++i) OnInitEffectRuntime(&runtime[i]);
    const auto held = g.runtime; const auto heldResolves = handleResolves;
    OnInitEffectRuntime(&runtime[6]); OnReloadedEffects(&runtime[7]);
    Check(g.runtime == held && handleResolves == heldResolves, "init/reload callers both honor registration refusal");
    Check(FindRuntime(&runtime[6]) == nullptr && FindRuntime(&runtime[7]) == nullptr, "refused callbacks leave no partial registrations");
    Check(g_runtime_count == 6, "refused callbacks preserve the bounded registry count");
    for (unsigned i = 0; i < 6; ++i) Check(FindRuntime(&runtime[i]) != nullptr, "refused callbacks retain every existing output");

    Reset(); TrackRuntime(&runtime[0]);
    runtime[0].window.visible = false;
    Check(!LegacyCandidateRuntime(&runtime[0]), "hidden output remains ineligible");
    runtime[0].window.visible = true; runtime[0].window.minimized = true;
    Check(!LegacyCandidateRuntime(&runtime[0]), "minimized output remains ineligible");
    runtime[0].window.minimized = false; runtime[0].window.pid = 9;
    Check(!LegacyCandidateRuntime(&runtime[0]), "foreign process window remains ineligible");
    runtime[0].window.pid = GetCurrentProcessId();
    Check(LegacyCandidateRuntime(&runtime[0]), "visible owned registered window is eligible");
    runtime[1].window.name = "NvPresentProxy"; TrackRuntime(&runtime[1]);
    Check(!LegacyCandidateRuntime(&runtime[1]), "known present proxy remains ineligible");
    runtime[1].window.name = "game";

    // The pre-existing device compatibility check remains the single check
    // for bound resources; registration metadata does not create another owner.
    g.dev = &firstNative;
    runtime[2].hardware = &other; TrackRuntime(&runtime[2]);
    Check(RuntimeDeviceCompatible(FindRuntime(&runtime[0])), "same-device external adoption check remains available");
    Check(!RuntimeDeviceCompatible(FindRuntime(&runtime[2])), "different-device external adoption remains refused");
    std::cout << checks << " production legacy runtime ownership checks; " << failed << " failed. CPU callback/registry scope only.\n";
    return failed ? 1 : 0;
}
