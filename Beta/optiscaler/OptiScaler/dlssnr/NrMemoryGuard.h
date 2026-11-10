// OptiShade additions, GPL-3.0-or-later.
#pragma once
// When NR's memory guard may stop NR, and when it may try again.
//
// The guard only refuses new model allocations. A running NR is never stopped
// for memory: going over the Windows budget pages memory out (stutter), it does
// not fail, and stopping a running NR on a card near its limit turned NR off and
// on every few seconds, which testers saw as flicker. Retries wait for the same
// free memory the refused allocation needed, and wait longer after each refusal.
#include <algorithm>
#include <cstdint>

namespace optishade::nr::memory_guard {
inline constexpr uint64_t kMiB = 1024ull * 1024;
inline constexpr uint64_t kMinimumHeadroom = 128 * kMiB;

// Free memory a model stack of this size needs before it is allocated.
inline uint64_t ModelReserve(uint32_t workWidth, uint32_t workHeight, uint32_t passes) {
    return (256 * kMiB + uint64_t(workWidth) * workHeight * 64ull) * std::max(1u, passes);
}

// A rebuild releases the models it replaces, and their memory is already in the
// usage figure, so only growth needs new room.
inline uint64_t RequiredFree(uint64_t newReserve, uint64_t replacedReserve) {
    return newReserve > replacedReserve ? newReserve - replacedReserve : 0;
}

inline bool Admits(uint64_t budget, uint64_t usage, uint64_t required) {
    if (!budget || !required) return true;
    const uint64_t free = budget > usage ? budget - usage : 0;
    return free >= required;
}

// Sampled once a second while NR is paused for memory.
class Recovery {
    uint64_t required_ = 0, healthySince_ = 0, last_ = 0;
    unsigned refusals_ = 0;
    bool healthy_ = false, sampled_ = false;

  public:
    static constexpr uint64_t kWaitsMs[3] = {3000, 10000, 30000};
    // A refused allocation: wait for its requirement, longer each time.
    void Refused(uint64_t required) {
        required_ = required; refusals_ = std::min(refusals_ + 1, 3u);
        healthy_ = sampled_ = false; healthySince_ = last_ = 0;
    }
    // An allocation passed: the next refusal starts from the shortest wait.
    void Admitted() { refusals_ = 0; }
    // The user asked for NR again: forget the history.
    void Manual() { required_ = 0; refusals_ = 0; healthy_ = sampled_ = false; healthySince_ = last_ = 0; }
    uint64_t WaitMs() const { return kWaitsMs[std::max(1u, refusals_) - 1]; }
    uint64_t Required() const { return std::max(required_, kMinimumHeadroom); }
    bool Due(uint64_t now) {
        if (sampled_ && now >= last_ && now - last_ < 1000) return false;
        last_ = now; sampled_ = true; return true;
    }
    // True once free memory has covered the requirement for the whole wait.
    bool Observe(uint64_t now, bool valid, uint64_t budget, uint64_t usage) {
        if (!valid || !budget || !Admits(budget, usage, Required())) { healthy_ = false; return false; }
        if (!healthy_ || now < healthySince_) { healthy_ = true; healthySince_ = now; return false; }
        return now - healthySince_ >= WaitMs();
    }
};
}
