// OptiShade additions, GPL-3.0-or-later.
#pragma once
// One line a minute with the game's memory, so a report can show whether memory
// climbed before a crash ("are there memory leaks with OptiShade?" after SU7 CTDs
// could not be answered from any log). Read-only Windows/DXGI queries; nothing is
// allocated per frame and no game object is touched.
#include <windows.h>
#include <psapi.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <atomic>
#include <cstdint>

namespace optishade::memory {
constexpr ULONGLONG kSampleIntervalMs = 60000;

struct Sample {
    uint64_t privateMB = 0, workingSetMB = 0, commitMB = 0, commitLimitMB = 0, availableRamMB = 0;
    uint64_t vramUsageMB = 0, vramBudgetMB = 0;
    bool vram = false;
};

// The game's own video memory on its largest adapter. The adapter is found once
// and kept (as the NR memory guard does): CreateDXGIFactory1 is hooked by
// OptiScaler and ReShade, and running it every minute from Present re-entered
// both hooks and logged each time. A released D3D12 device is never used.
inline bool QueryVram(uint64_t& usage, uint64_t& budget) {
    // Never destroyed: no Release during process exit after DXGI may be gone.
    static auto& cached = *new Microsoft::WRL::ComPtr<IDXGIAdapter3>();
    DXGI_QUERY_VIDEO_MEMORY_INFO info{};
    if (cached && SUCCEEDED(cached->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info))) {
        usage = info.CurrentUsage; budget = info.Budget; return true;
    }
    cached.Reset(); // lost or never found: look again at the next sample
    Microsoft::WRL::ComPtr<IDXGIFactory4> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return false;
    SIZE_T largest = 0;
    Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
    for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; ++i, adapter.Reset()) {
        DXGI_ADAPTER_DESC1 desc{};
        if (FAILED(adapter->GetDesc1(&desc)) || (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) || desc.DedicatedVideoMemory <= largest) continue;
        Microsoft::WRL::ComPtr<IDXGIAdapter3> adapter3;
        if (FAILED(adapter.As(&adapter3)) || FAILED(adapter3->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info))) continue;
        largest = desc.DedicatedVideoMemory; usage = info.CurrentUsage; budget = info.Budget; cached = adapter3;
    }
    return cached != nullptr;
}

inline Sample Take() {
    Sample s;
    PROCESS_MEMORY_COUNTERS_EX process{};
    if (GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&process), sizeof(process))) {
        s.privateMB = process.PrivateUsage >> 20;
        s.workingSetMB = process.WorkingSetSize >> 20;
    }
    MEMORYSTATUSEX system{}; system.dwLength = sizeof(system);
    if (GlobalMemoryStatusEx(&system)) {
        s.commitLimitMB = system.ullTotalPageFile >> 20;
        s.commitMB = (system.ullTotalPageFile - system.ullAvailPageFile) >> 20;
        s.availableRamMB = system.ullAvailPhys >> 20;
    }
    uint64_t usage = 0, budget = 0;
    if ((s.vram = QueryVram(usage, budget))) { s.vramUsageMB = usage >> 20; s.vramBudgetMB = budget >> 20; }
    return s;
}

// Called on each real Present; samples at most once a minute.
inline void SampleOnPresent() {
    static std::atomic<ULONGLONG> last{0};
    const auto now = GetTickCount64();
    auto previous = last.load(std::memory_order_relaxed);
    if (previous && now - previous < kSampleIntervalMs) return;
    if (!last.compare_exchange_strong(previous, now)) return;
    const auto s = Take();
    LOG_INFO("Memory sample: pid={} tick={} privateMB={} workingSetMB={} commitMB={} commitLimitMB={} availableRamMB={} vramMB={} vramBudgetMB={}",
             GetCurrentProcessId(), now, s.privateMB, s.workingSetMB, s.commitMB, s.commitLimitMB, s.availableRamMB,
             s.vram ? s.vramUsageMB : 0, s.vram ? s.vramBudgetMB : 0);
}
} // namespace optishade::memory
