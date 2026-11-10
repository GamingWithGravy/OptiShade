#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace optishade::vulkan_submit_observation {

constexpr uint32_t Abi = 1;
constexpr std::size_t MaxBatches = 8;
constexpr std::size_t MaxSemaphores = 20;
constexpr std::size_t MaxCommands = 20;

enum class Api : uint32_t { Legacy = 1, Synchronization2 = 2 };
enum class Source : uint32_t { Application = 1, ReShadeImmediate = 2, ReShadeQueueHelper = 3, PresentSynchronization = 4, OptiShadeMenu = 5 };

struct SemaphoreEntry {
    uint64_t handle = 0;
    uint64_t value = 0;
    uint64_t stageMask = 0;
    uint32_t deviceIndex = 0;
    uint32_t hasPNext = 0;
};

struct Batch {
    uint32_t waitCount = 0;
    uint32_t signalCount = 0;
    uint32_t commandCount = 0;
    uint32_t waitStart = 0;
    uint32_t signalStart = 0;
    uint32_t commandStart = 0;
    uint32_t capturedWaitCount = 0;
    uint32_t capturedSignalCount = 0;
    uint32_t capturedCommandCount = 0;
    uint32_t hasPNext = 0;
};

// Bounded cross-module observation of the submit structures passed to Vulkan.
// It is diagnostic evidence; it does not certify semaphore dependencies.
struct Snapshot {
    uint32_t size = sizeof(Snapshot);
    uint32_t abi = Abi;
    uint32_t api = 0;
    uint32_t source = 0;
    uint64_t queue = 0;
    uint64_t fence = 0;
    int32_t result = 0;
    uint32_t submitCount = 0;
    uint32_t batchCount = 0;
    uint32_t waitCount = 0;
    uint32_t signalCount = 0;
    uint32_t commandCount = 0;
    uint32_t capturedWaitCount = 0;
    uint32_t capturedSignalCount = 0;
    uint32_t capturedCommandCount = 0;
    uint32_t hasPNext = 0;
    uint32_t truncated = 0;
    uint32_t valid = 0;
    std::array<Batch, MaxBatches> batches{};
    std::array<SemaphoreEntry, MaxSemaphores> waits{};
    std::array<SemaphoreEntry, MaxSemaphores> signals{};
    std::array<uint64_t, MaxCommands> commands{};
};

template <typename Handle>
inline uint64_t HandleValue(Handle handle) {
    if constexpr (std::is_pointer_v<Handle>)
        return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(handle));
    else
        return static_cast<uint64_t>(handle);
}

inline uint64_t HandleValue(std::nullptr_t) { return 0; }

inline uint32_t SaturatingAdd(uint32_t left, uint32_t right) {
    return right > UINT32_MAX - left ? UINT32_MAX : left + right;
}

template <typename Queue, typename SubmitInfo, typename Fence>
inline bool CaptureLegacy(Queue queue, const SubmitInfo* submits, uint32_t submitCount,
                          Fence fence, int32_t result, Source source, Snapshot& snapshot) {
    snapshot = {};
    snapshot.api = static_cast<uint32_t>(Api::Legacy);
    snapshot.source = static_cast<uint32_t>(source);
    snapshot.queue = HandleValue(queue);
    snapshot.fence = HandleValue(fence);
    snapshot.result = result;
    snapshot.submitCount = submitCount;
    bool valid = snapshot.queue != 0 && (submitCount == 0 || submits != nullptr);
    if (!valid) { snapshot.valid = 0; return false; }

    snapshot.batchCount = static_cast<uint32_t>(std::min<std::size_t>(submitCount, MaxBatches));
    snapshot.truncated = submitCount > MaxBatches;
    for (uint32_t i = 0; i < snapshot.batchCount; ++i) {
        const auto& info = submits[i];
        auto& batch = snapshot.batches[i];
        batch.waitCount = info.waitSemaphoreCount;
        batch.signalCount = info.signalSemaphoreCount;
        batch.commandCount = info.commandBufferCount;
        batch.waitStart = snapshot.capturedWaitCount;
        batch.signalStart = snapshot.capturedSignalCount;
        batch.commandStart = snapshot.capturedCommandCount;
        batch.hasPNext = info.pNext != nullptr;
        snapshot.hasPNext |= batch.hasPNext;
        snapshot.waitCount = SaturatingAdd(snapshot.waitCount, batch.waitCount);
        snapshot.signalCount = SaturatingAdd(snapshot.signalCount, batch.signalCount);
        snapshot.commandCount = SaturatingAdd(snapshot.commandCount, batch.commandCount);

        if ((batch.waitCount && (!info.pWaitSemaphores || !info.pWaitDstStageMask)) ||
            (batch.signalCount && !info.pSignalSemaphores) ||
            (batch.commandCount && !info.pCommandBuffers)) {
            valid = false;
            continue;
        }
        for (uint32_t j = 0; j < batch.waitCount; ++j) {
            if (snapshot.capturedWaitCount == MaxSemaphores) { snapshot.truncated = 1; break; }
            snapshot.waits[snapshot.capturedWaitCount++] = {
                HandleValue(info.pWaitSemaphores[j]), 0, info.pWaitDstStageMask[j], 0, 0};
            ++batch.capturedWaitCount;
        }
        for (uint32_t j = 0; j < batch.signalCount; ++j) {
            if (snapshot.capturedSignalCount == MaxSemaphores) { snapshot.truncated = 1; break; }
            snapshot.signals[snapshot.capturedSignalCount++] = {HandleValue(info.pSignalSemaphores[j]), 0, 0, 0, 0};
            ++batch.capturedSignalCount;
        }
        for (uint32_t j = 0; j < batch.commandCount; ++j) {
            if (snapshot.capturedCommandCount == MaxCommands) { snapshot.truncated = 1; break; }
            snapshot.commands[snapshot.capturedCommandCount++] = HandleValue(info.pCommandBuffers[j]);
            ++batch.capturedCommandCount;
        }
    }
    snapshot.valid = valid;
    return valid;
}

template <typename Queue, typename SubmitInfo2, typename Fence>
inline bool CaptureSubmit2(Queue queue, const SubmitInfo2* submits, uint32_t submitCount,
                           Fence fence, int32_t result, Source source, Snapshot& snapshot) {
    snapshot = {};
    snapshot.api = static_cast<uint32_t>(Api::Synchronization2);
    snapshot.source = static_cast<uint32_t>(source);
    snapshot.queue = HandleValue(queue);
    snapshot.fence = HandleValue(fence);
    snapshot.result = result;
    snapshot.submitCount = submitCount;
    bool valid = snapshot.queue != 0 && (submitCount == 0 || submits != nullptr);
    if (!valid) { snapshot.valid = 0; return false; }

    snapshot.batchCount = static_cast<uint32_t>(std::min<std::size_t>(submitCount, MaxBatches));
    snapshot.truncated = submitCount > MaxBatches;
    for (uint32_t i = 0; i < snapshot.batchCount; ++i) {
        const auto& info = submits[i];
        auto& batch = snapshot.batches[i];
        batch.waitCount = info.waitSemaphoreInfoCount;
        batch.signalCount = info.signalSemaphoreInfoCount;
        batch.commandCount = info.commandBufferInfoCount;
        batch.waitStart = snapshot.capturedWaitCount;
        batch.signalStart = snapshot.capturedSignalCount;
        batch.commandStart = snapshot.capturedCommandCount;
        batch.hasPNext = info.pNext != nullptr;
        snapshot.hasPNext |= batch.hasPNext;
        snapshot.waitCount = SaturatingAdd(snapshot.waitCount, batch.waitCount);
        snapshot.signalCount = SaturatingAdd(snapshot.signalCount, batch.signalCount);
        snapshot.commandCount = SaturatingAdd(snapshot.commandCount, batch.commandCount);
        if ((batch.waitCount && !info.pWaitSemaphoreInfos) ||
            (batch.signalCount && !info.pSignalSemaphoreInfos) ||
            (batch.commandCount && !info.pCommandBufferInfos)) {
            valid = false;
            continue;
        }
        for (uint32_t j = 0; j < batch.waitCount; ++j) {
            if (snapshot.capturedWaitCount == MaxSemaphores) { snapshot.truncated = 1; break; }
            const auto& item = info.pWaitSemaphoreInfos[j];
            snapshot.waits[snapshot.capturedWaitCount++] = {HandleValue(item.semaphore), item.value,
                item.stageMask, item.deviceIndex, item.pNext != nullptr};
            snapshot.hasPNext |= item.pNext != nullptr;
            ++batch.capturedWaitCount;
        }
        for (uint32_t j = 0; j < batch.signalCount; ++j) {
            if (snapshot.capturedSignalCount == MaxSemaphores) { snapshot.truncated = 1; break; }
            const auto& item = info.pSignalSemaphoreInfos[j];
            snapshot.signals[snapshot.capturedSignalCount++] = {HandleValue(item.semaphore), item.value,
                item.stageMask, item.deviceIndex, item.pNext != nullptr};
            snapshot.hasPNext |= item.pNext != nullptr;
            ++batch.capturedSignalCount;
        }
        for (uint32_t j = 0; j < batch.commandCount; ++j) {
            if (snapshot.capturedCommandCount == MaxCommands) { snapshot.truncated = 1; break; }
            const auto& item = info.pCommandBufferInfos[j];
            snapshot.commands[snapshot.capturedCommandCount++] = HandleValue(item.commandBuffer);
            snapshot.hasPNext |= item.pNext != nullptr;
            ++batch.capturedCommandCount;
        }
    }
    snapshot.valid = valid;
    return valid;
}

using Observer = void (*)(const Snapshot* snapshot);

} // namespace optishade::vulkan_submit_observation
