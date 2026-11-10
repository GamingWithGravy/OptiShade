// OptiShade additions, GPL-3.0-or-later.
// XP12 camera record reader, P0 spike: observe and log only. Nothing here
// changes rendering or NR. See MDs/Reconstruction/XP12_CAMERA_MOTION_PLAN.md.
//
// Every 300 presents it logs, per source (flight loop / window phase), how
// many presents saw a new sample, the same sample again or skipped samples,
// how old the newest sample was at present, and whether the window-phase
// matrices equal this frame's or the previous frame's flight-loop matrices.
// That tells P1 which sample belongs to the presented frame.
#include "../../xplane-camera/include/Xp12CameraRecord.h"
#include <cstring>
#include <string>

namespace osxpcam {
using namespace optishade::xp12camera;

struct Stats {
    unsigned fresh = 0, repeated = 0, skipped = 0, missing = 0;
    double ageSum = 0, ageMax = 0;
};

struct Reader {
    HANDLE mapping = nullptr;
    const Record* record = nullptr;
    ULONGLONG nextOpen = 0;
    uint64_t pid = 0, birth = 0, presents = 0;
    uint64_t lastCount[SourceCount] = {};
    double lastFlightWorld[16] = {}, previousFlightWorld[16] = {};
    bool haveFlight = false, havePrevious = false;
    Stats stats[SourceCount];
    unsigned windowMatchesCurrent = 0, windowMatchesPrevious = 0, windowMatchesNeither = 0, compared = 0;
};

inline bool IsXPlane() {
    static const bool xplane = [] {
        wchar_t path[MAX_PATH]{};
        if (!GetModuleFileNameW(nullptr, path, MAX_PATH)) return false;
        const wchar_t* leaf = wcsrchr(path, L'\\');
        return _wcsicmp(leaf ? leaf + 1 : path, L"X-Plane.exe") == 0;
    }();
    return xplane;
}

inline uint64_t Birth() {
    FILETIME created{}, exited{}, kernel{}, user{};
    return GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)
        ? (uint64_t(created.dwHighDateTime) << 32) | created.dwLowDateTime : 0;
}

inline bool Open(Reader& r) {
    if (r.record) return true;
    const ULONGLONG now = GetTickCount64();
    if (now < r.nextOpen) return false;
    r.nextOpen = now + 2000;
    r.pid = GetCurrentProcessId(); r.birth = Birth();
    const std::wstring name = std::wstring(kMappingPrefix) + std::to_wstring(r.pid);
    // Each distinct failure is logged once, so a silent miss can be diagnosed.
    static unsigned logged = 0;
    const auto once = [&](unsigned bit, const char* what, DWORD error) {
        if (logged & bit) return; logged |= bit;
        reshade::log::message(reshade::log::level::warning, "XP12 camera: record not readable yet: %s (error %lu, pid %llu)", what, error, (unsigned long long)r.pid);
    };
    HANDLE mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, name.c_str());
    if (!mapping) { once(1, "no shared record (camera plugin not publishing)", GetLastError()); return false; }
    auto* view = static_cast<const Record*>(MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, sizeof(Record)));
    if (!view) { once(2, "record could not be mapped", GetLastError()); CloseHandle(mapping); return false; }
    if (!Valid(*view, uint32_t(r.pid), r.birth)) {
        if (!(logged & 4)) {
            logged |= 4;
            reshade::log::message(reshade::log::level::warning,
                "XP12 camera: record identity mismatch: magic=%08X/%08X version=%u/%u size=%u/%u pid=%u/%llu birth=%llu/%llu",
                view->magic, kMagic, view->version, kVersion, view->size, unsigned(sizeof(Record)), view->pid, (unsigned long long)r.pid,
                (unsigned long long)view->processBirth, (unsigned long long)r.birth);
        }
        UnmapViewOfFile(view);
        CloseHandle(mapping);
        return false;
    }
    r.mapping = mapping; r.record = view;
    reshade::log::message(reshade::log::level::info, "XP12 camera: record found (plugin v%u, record v%u); observing only, NR unchanged",
        view->pluginVersion, view->version);
    return true;
}

inline void Flush(Reader& r) {
    static const char* names[SourceCount] = { "flight-loop", "window-phase" };
    for (unsigned s = 0; s < SourceCount; ++s) {
        const auto& st = r.stats[s];
        const unsigned seen = st.fresh + st.repeated + st.skipped;
        reshade::log::message(reshade::log::level::info,
            "XP12 camera timing: source=%s presents=%llu fresh=%u repeated=%u skipped=%u missing=%u ageAvgMs=%.2f ageMaxMs=%.2f",
            names[s], (unsigned long long)r.presents, st.fresh, st.repeated, st.skipped, st.missing,
            seen ? st.ageSum / seen : 0.0, st.ageMax);
    }
    reshade::log::message(reshade::log::level::info,
        "XP12 camera alignment: compared=%u windowEqualsThisFlightLoop=%u windowEqualsPreviousFlightLoop=%u neither=%u (static camera counts as both)",
        r.compared, r.windowMatchesCurrent, r.windowMatchesPrevious, r.windowMatchesNeither);
    for (auto& st : r.stats) st = {};
    r.compared = r.windowMatchesCurrent = r.windowMatchesPrevious = r.windowMatchesNeither = 0;
}

// Called once per present on the Vulkan runtime. Cheap: two bounded copies.
inline void Observe(reshade::api::effect_runtime* runtime) {
    if (!runtime || runtime->get_device()->get_api() != reshade::api::device_api::vulkan || !IsXPlane()) return;
    static Reader reader;
    Reader& r = reader;
    static bool announced = false;
    if (!announced) { announced = true; reshade::log::message(reshade::log::level::info, "XP12 camera: observer active on runtime %p", runtime); }
    if (!Open(r)) return;
    LARGE_INTEGER now{}; QueryPerformanceCounter(&now);
    const double toMs = r.record->qpcFrequency ? 1000.0 / double(r.record->qpcFrequency) : 0.0;
    ++r.presents;
    Snapshot snap[SourceCount]{};
    bool ok[SourceCount]{};
    for (unsigned s = 0; s < SourceCount; ++s) {
        ok[s] = Read(r.record->samples[s], snap[s]);
        auto& st = r.stats[s];
        if (!ok[s]) { ++st.missing; continue; }
        const uint64_t delta = snap[s].count - r.lastCount[s];
        if (r.lastCount[s] == 0 || delta == 1) ++st.fresh; else if (delta == 0) ++st.repeated; else ++st.skipped;
        r.lastCount[s] = snap[s].count;
        const double age = (double(now.QuadPart) - double(snap[s].qpc)) * toMs;
        st.ageSum += age; if (age > st.ageMax) st.ageMax = age;
    }
    if (ok[FlightLoop]) {
        if (!r.haveFlight || std::memcmp(r.lastFlightWorld, snap[FlightLoop].world, sizeof(r.lastFlightWorld)) != 0) {
            if (r.haveFlight) { std::memcpy(r.previousFlightWorld, r.lastFlightWorld, sizeof(r.previousFlightWorld)); r.havePrevious = true; }
            std::memcpy(r.lastFlightWorld, snap[FlightLoop].world, sizeof(r.lastFlightWorld)); r.haveFlight = true;
        }
    }
    if (ok[WindowPhase] && r.haveFlight && r.havePrevious) {
        ++r.compared;
        const bool current = std::memcmp(snap[WindowPhase].world, r.lastFlightWorld, sizeof(r.lastFlightWorld)) == 0;
        const bool previous = std::memcmp(snap[WindowPhase].world, r.previousFlightWorld, sizeof(r.previousFlightWorld)) == 0;
        if (current) ++r.windowMatchesCurrent;
        if (previous) ++r.windowMatchesPrevious;
        if (!current && !previous) ++r.windowMatchesNeither;
    }
    if (r.presents % 300 == 0) Flush(r);
}
}
