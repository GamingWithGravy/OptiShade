// OptiShade additions, GPL-3.0-or-later.
// OptiShade camera plugin for X-Plane 12 (P0 spike: publish only).
//
// Reads the camera matrices X-Plane already exposes as datarefs and publishes
// them for OptiShade's Vulkan guide path in this same process. It never writes
// datarefs, preferences or files, draws nothing, and stays idle unless
// OptiShade's ReShade is loaded. See MDs/Reconstruction/XP12_CAMERA_MOTION_PLAN.md.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <string>
#include <XPLMDataAccess.h>
#include <XPLMDisplay.h>
#include <XPLMPlugin.h>
#include <XPLMProcessing.h>
#include <XPLMUtilities.h>
#include "Xp12CameraRecord.h"

namespace {
using namespace optishade::xp12camera;
constexpr uint32_t kPluginVersion = 1;

HANDLE mapping = nullptr;
Record* record = nullptr;
uint64_t simFrame = 0, counts[SourceCount] = {};
float nextCheck = 0;
XPLMDataRef worldRef, projectionRef, widthRef, heightRef, viewTypeRef, externalRef, pausedRef, fovRef;

void Log(const std::string& text) { XPLMDebugString(("OptiShade camera: " + text + "\n").c_str()); }

uint64_t ProcessBirth() {
    FILETIME created{}, exited{}, kernel{}, user{};
    return GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)
        ? (uint64_t(created.dwHighDateTime) << 32) | created.dwLowDateTime : 0;
}

// Only publish into a process where OptiShade's ReShade can read it.
bool Attach() {
    if (record) return true;
    if (!GetModuleHandleW(L"ReShade64.dll")) return false;
    const std::wstring name = std::wstring(kMappingPrefix) + std::to_wstring(GetCurrentProcessId());
    mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(Record), name.c_str());
    if (!mapping) { Log("shared record unavailable, error " + std::to_string(GetLastError())); return false; }
    if (GetLastError() == ERROR_ALREADY_EXISTS) { Log("another camera record already exists in this process; staying idle"); CloseHandle(mapping); mapping = nullptr; return false; }
    record = static_cast<Record*>(MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(Record)));
    if (!record) { CloseHandle(mapping); mapping = nullptr; return false; }
    LARGE_INTEGER frequency{}; QueryPerformanceFrequency(&frequency);
    record->pid = GetCurrentProcessId(); record->processBirth = ProcessBirth();
    record->qpcFrequency = uint64_t(frequency.QuadPart); record->pluginVersion = kPluginVersion;
    record->size = sizeof(Record); record->version = kVersion;
    std::atomic_thread_fence(std::memory_order_release);
    record->magic = kMagic; // last: readers check it first
    Log("publishing camera record v" + std::to_string(kVersion) + " (flight loop and window phase samples)");
    return true;
}

void Detach() {
    if (record) { record->magic = 0; UnmapViewOfFile(record); record = nullptr; }
    if (mapping) { CloseHandle(mapping); mapping = nullptr; }
}

void Sample(Source source) {
    if (!record) return;
    Snapshot v{};
    float m[16]{};
    if (XPLMGetDatavf(worldRef, m, 0, 16) != 16) return;
    for (int i = 0; i < 16; ++i) v.world[i] = m[i];
    if (XPLMGetDatavf(projectionRef, m, 0, 16) != 16) return;
    for (int i = 0; i < 16; ++i) v.projection[i] = m[i];
    LARGE_INTEGER now{}; QueryPerformanceCounter(&now);
    v.qpc = uint64_t(now.QuadPart); v.simFrame = simFrame; v.count = ++counts[source];
    v.width = XPLMGetDatai(widthRef); v.height = XPLMGetDatai(heightRef); v.viewType = XPLMGetDatai(viewTypeRef);
    v.flags = (XPLMGetDatai(externalRef) ? ExternalView : 0u) | (XPLMGetDatai(pausedRef) ? Paused : 0u);
    v.fovDegrees = XPLMGetDataf(fovRef);
    Publish(record->samples[source], v);
    if (v.count == 1)
        Log(std::string("first ") + (source == FlightLoop ? "flight-loop" : "window-phase") + " sample published, " +
            std::to_string(v.width) + "x" + std::to_string(v.height) + " view " + std::to_string(v.viewType));
}

float OnFlightLoop(float elapsed, float, int, void*) {
    if (!record) {
        nextCheck -= elapsed;
        if (nextCheck <= 0) { nextCheck = 1.0f; Attach(); }
        return -1.0f;
    }
    ++simFrame;
    Sample(FlightLoop);
    return -1.0f; // every frame
}

int OnWindowPhase(XPLMDrawingPhase, int, void*) { Sample(WindowPhase); return 1; }
}

PLUGIN_API int XPluginStart(char* name, char* signature, char* description) {
    strcpy_s(name, 256, "OptiShade Camera");
    strcpy_s(signature, 256, "optishade.camera");
    strcpy_s(description, 256, "Publishes X-Plane camera matrices to OptiShade NR in this process. Read-only.");
    worldRef = XPLMFindDataRef("sim/graphics/view/world_matrix");
    projectionRef = XPLMFindDataRef("sim/graphics/view/projection_matrix_3d");
    widthRef = XPLMFindDataRef("sim/graphics/view/window_width");
    heightRef = XPLMFindDataRef("sim/graphics/view/window_height");
    viewTypeRef = XPLMFindDataRef("sim/graphics/view/view_type");
    externalRef = XPLMFindDataRef("sim/graphics/view/view_is_external");
    pausedRef = XPLMFindDataRef("sim/time/paused");
    fovRef = XPLMFindDataRef("sim/graphics/view/field_of_view_deg");
    if (!worldRef || !projectionRef || !widthRef || !heightRef || !viewTypeRef || !externalRef || !pausedRef || !fovRef) {
        Log("required camera datarefs not found; disabled");
        return 0;
    }
    return 1;
}

PLUGIN_API void XPluginStop() {}

PLUGIN_API int XPluginEnable() {
    XPLMRegisterFlightLoopCallback(OnFlightLoop, -1.0f, nullptr);
    XPLMRegisterDrawCallback(OnWindowPhase, xplm_Phase_Window, 0, nullptr);
    return 1;
}

PLUGIN_API void XPluginDisable() {
    XPLMUnregisterFlightLoopCallback(OnFlightLoop, nullptr);
    XPLMUnregisterDrawCallback(OnWindowPhase, xplm_Phase_Window, 0, nullptr);
    Detach();
}

PLUGIN_API void XPluginReceiveMessage(XPLMPluginID, int, void*) {}
