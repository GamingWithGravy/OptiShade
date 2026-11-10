// OptiShade additions, GPL-3.0-or-later.
#pragma once
// X-Plane 12 camera record: the contract between the OptiShade camera plugin
// (writer) and OptiShade's Vulkan guide path in ReShade (reader). One header
// for both sides. See MDs/Reconstruction/XP12_CAMERA_MOTION_PLAN.md.
//
// The plugin and ReShade live in the same X-Plane process. A named mapping
// keyed by process id lets the reader find the record without knowing which
// "win.xpl" module wrote it; nothing leaves the process.
//
// Each sample is a seqlock: the writer makes `sequence` odd, writes, then makes
// it even. A reader copies the sample and keeps it only when `sequence` was
// the same even value before and after. The reader never blocks or waits.
#include <atomic>
#include <cstdint>
#include <cstring>

namespace optishade::xp12camera {

inline constexpr uint32_t kMagic = 0x4358534Fu; // "OSXC"
inline constexpr uint32_t kVersion = 1;

// Where in X-Plane's frame the matrices were read. P0 publishes both so the
// spike can measure which one belongs to the frame that gets presented.
enum Source : uint32_t { FlightLoop = 0, WindowPhase = 1, SourceCount = 2 };

enum Flags : uint32_t {
    ExternalView = 1u << 0,
    Paused = 1u << 1,
};

struct Sample {
    std::atomic<uint64_t> sequence;
    uint64_t count;       // samples published from this source
    uint64_t qpc;         // QueryPerformanceCounter when read
    uint64_t simFrame;    // plugin-side frame counter shared by both sources
    double world[16];     // sim/graphics/view/world_matrix (column-major, as X-Plane gives it)
    double projection[16];// sim/graphics/view/projection_matrix_3d
    int32_t width, height;// sim/graphics/view/window_width/height
    int32_t viewType;     // sim/graphics/view/view_type
    uint32_t flags;
    float fovDegrees;
    uint32_t reserved[3];
};

struct Record {
    uint32_t magic, version, size, pid;
    uint64_t processBirth; // GetProcessTimes creation time, rules out a recycled pid
    uint64_t qpcFrequency;
    uint32_t pluginVersion, reserved0;
    Sample samples[SourceCount];
};
static_assert(sizeof(std::atomic<uint64_t>) == 8, "lock-free 64-bit sequence required");

inline const wchar_t* kMappingPrefix = L"Local\\OptiShadeXp12Camera-";

// Plain copy of a sample (without the atomic) for the reader.
struct Snapshot {
    uint64_t count, qpc, simFrame;
    double world[16], projection[16];
    int32_t width, height, viewType;
    uint32_t flags;
    float fovDegrees;
};

inline void Publish(Sample& s, const Snapshot& v) {
    const auto start = s.sequence.load(std::memory_order_relaxed) | 1u; // odd: writing
    s.sequence.store(start, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);
    s.count = v.count; s.qpc = v.qpc; s.simFrame = v.simFrame;
    std::memcpy(s.world, v.world, sizeof(s.world));
    std::memcpy(s.projection, v.projection, sizeof(s.projection));
    s.width = v.width; s.height = v.height; s.viewType = v.viewType; s.flags = v.flags; s.fovDegrees = v.fovDegrees;
    s.sequence.store(start + 1, std::memory_order_release); // even: complete
}

// Bounded, non-blocking read. False means "no complete sample right now".
inline bool Read(const Sample& s, Snapshot& out, unsigned attempts = 3) {
    for (unsigned i = 0; i < attempts; ++i) {
        const auto before = s.sequence.load(std::memory_order_acquire);
        if (before & 1u) continue;
        out.count = s.count; out.qpc = s.qpc; out.simFrame = s.simFrame;
        std::memcpy(out.world, s.world, sizeof(out.world));
        std::memcpy(out.projection, s.projection, sizeof(out.projection));
        out.width = s.width; out.height = s.height; out.viewType = s.viewType; out.flags = s.flags; out.fovDegrees = s.fovDegrees;
        std::atomic_thread_fence(std::memory_order_acquire);
        if (s.sequence.load(std::memory_order_relaxed) == before && before != 0) return true;
    }
    return false;
}

inline bool Valid(const Record& r, uint32_t pid, uint64_t birth) {
    return r.magic == kMagic && r.version == kVersion && r.size == sizeof(Record) && r.pid == pid && r.processBirth == birth;
}

}
