#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <mutex>

namespace optishade
{
enum class UpscalerApi : uint32_t { Dx11 = 11, Dx12 = 12, Vulkan = 13 };

inline uint64_t UpscalerFailureKey(UpscalerApi api, uint32_t handle)
{
    return (uint64_t(api) << 32) | handle;
}

struct UpscalerFailureNotice
{
    bool notify = false;
    uint64_t failures = 0;
    bool overflow = false;
};

// This observes results only: it must never replace backend errors, suppress
// evaluation, change render settings or force recreation. Storage is bounded,
// including when callers report more live feature identities than expected.
template<size_t Capacity = 64, unsigned MaxNoticesPerWindow = 8>
class UpscalerFailureGate
{
    static_assert(Capacity > 0 && MaxNoticesPerWindow > 0);
    struct Slot
    {
        uint64_t key = 0, failures = 0, notifiedAt = 0;
        bool occupied = false, notified = false;
    };
    std::array<Slot, Capacity> slots {};
    Slot overflow;
    std::mutex mutex;
    uint64_t windowStartedAt = 0;
    unsigned windowNotices = 0;
    bool windowStarted = false;

    static void Increment(uint64_t& value)
    {
        if (value != (std::numeric_limits<uint64_t>::max)()) ++value;
    }

public:
    static constexpr uint64_t ReminderMs = 10000;

    UpscalerFailureNotice Observe(uint64_t key, bool succeeded, uint64_t now)
    {
        std::lock_guard<std::mutex> lock(mutex);
        Slot* found = nullptr;
        Slot* free = nullptr;
        for (auto& slot : slots)
        {
            if (slot.occupied && slot.key == key) { found = &slot; break; }
            if (!slot.occupied && !free) free = &slot;
        }
        if (succeeded)
        {
            if (found) *found = {};
            return {};
        }
        if (!found && free)
        {
            *free = {};
            free->occupied = true;
            free->key = key;
            found = free;
        }
        const bool full = found == nullptr;
        auto& state = found ? *found : overflow;
        Increment(state.failures);
        UpscalerFailureNotice notice {false, state.failures, full};
        if (state.notified && (now < state.notifiedAt || now - state.notifiedAt < ReminderMs)) return notice;

        // Per-feature recovery/recreation cannot bypass a process-wide budget.
        // The overflow bucket also shares this budget, without evicting a live slot.
        if (!windowStarted || (now >= windowStartedAt && now - windowStartedAt >= ReminderMs))
        {
            windowStarted = true;
            windowStartedAt = now;
            windowNotices = 0;
        }
        if (windowNotices >= MaxNoticesPerWindow) return notice;
        ++windowNotices;
        state.notified = true;
        state.notifiedAt = now;
        notice.notify = true;
        return notice;
    }

    void Retire(uint64_t key)
    {
        // Retiring one identity cannot erase another identity's failure episode
        // or reset the aggregate overflow/rate budget.
        (void) Observe(key, true, 0);
    }
};

inline UpscalerFailureGate<>& UpscalerFailureNotices()
{
    static UpscalerFailureGate<> gate;
    return gate;
}
}
