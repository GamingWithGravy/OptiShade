#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace optishade::vulkan_present_observation {

constexpr uint32_t Abi = 2;
constexpr std::size_t MaxWaits = 32;
constexpr std::size_t MaxSwapchains = 8;

struct ChainResult {
    uint64_t swapchain = 0;
    uint32_t imageIndex = 0;
    int32_t result = 0;
    uint64_t generation = 0;
};

// Fixed-size cross-DLL snapshot of the exact VkPresentInfoKHR supplied to the
// downstream driver. This is diagnostic evidence, not NR admission proof.
struct Snapshot {
    uint32_t size = sizeof(Snapshot);
    uint32_t abi = Abi;
    uint64_t queue = 0;
    int32_t globalResult = 0;
    uint32_t waitCount = 0;
    uint32_t swapchainCount = 0;
    uint32_t capturedWaitCount = 0;
    uint32_t capturedSwapchainCount = 0;
    uint32_t perSwapchainResultsKnown = 0;
    uint32_t hasPNext = 0;
    uint32_t truncated = 0;
    uint32_t valid = 0;
    uint64_t device = 0;
    std::array<uint64_t, MaxWaits> waits{};
    std::array<ChainResult, MaxSwapchains> chains{};
};

template <typename Handle>
inline uint64_t HandleValue(Handle handle) {
    if constexpr (std::is_pointer_v<Handle>)
        return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(handle));
    else
        return static_cast<uint64_t>(handle);
}

// Compatible with Vulkan's VkPresentInfoKHR field layout from either GLAD or
// the vendored Vulkan headers. Called after vkQueuePresentKHR returns, while
// the caller-owned pResults array and local rewritten structure are still live.
template <typename Queue, typename PresentInfo>
inline bool Capture(Queue queue, const PresentInfo* info, int32_t globalResult,
                    Snapshot& snapshot) {
    snapshot = {};
    snapshot.queue = HandleValue(queue);
    snapshot.globalResult = globalResult;
    if (!info || !snapshot.queue) return false;

    snapshot.waitCount = info->waitSemaphoreCount;
    snapshot.swapchainCount = info->swapchainCount;
    snapshot.perSwapchainResultsKnown = info->pResults != nullptr;
    snapshot.hasPNext = info->pNext != nullptr;
    snapshot.truncated = snapshot.waitCount > MaxWaits || snapshot.swapchainCount > MaxSwapchains;

    bool valid = (snapshot.waitCount == 0 || info->pWaitSemaphores != nullptr) &&
        (snapshot.swapchainCount == 0 || (info->pSwapchains != nullptr && info->pImageIndices != nullptr));
    const auto waitCount = std::min<std::size_t>(snapshot.waitCount, MaxWaits);
    const auto swapchainCount = std::min<std::size_t>(snapshot.swapchainCount, MaxSwapchains);
    if (valid) {
        for (std::size_t i = 0; i < waitCount; ++i)
            snapshot.waits[i] = HandleValue(info->pWaitSemaphores[i]);
        for (std::size_t i = 0; i < swapchainCount; ++i) {
            snapshot.chains[i] = {HandleValue(info->pSwapchains[i]), info->pImageIndices[i],
                info->pResults ? static_cast<int32_t>(info->pResults[i]) : globalResult};
            valid &= snapshot.chains[i].swapchain != 0;
        }
    }
    snapshot.capturedWaitCount = static_cast<uint32_t>(valid ? waitCount : 0);
    snapshot.capturedSwapchainCount = static_cast<uint32_t>(valid ? swapchainCount : 0);
    snapshot.valid = valid;
    return valid;
}

using Observer = void (*)(const Snapshot* snapshot);

} // namespace optishade::vulkan_present_observation
