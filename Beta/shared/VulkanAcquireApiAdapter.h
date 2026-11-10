// OptiShade additions, GPL-3.0-or-later.
// Bounded conversion of real Vulkan submission structures into the inactive
// CPU-only acquire-dependency model. This adapter is not called by runtime hooks.
#pragma once

#include "VulkanAcquireDependency.h"
#include "../optiscaler/external/vulkan/include/vulkan/vulkan.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace optishade::vulkan_sync::api_adapter {

template <typename Handle>
inline uint64_t HandleValue(Handle handle) {
    if constexpr (std::is_pointer_v<Handle>)
        return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(handle));
    else
        return static_cast<uint64_t>(handle);
}

inline Result FromVkResult(VkResult result) {
    switch (result) {
    case VK_SUCCESS: return Result::Success;
    case VK_SUBOPTIMAL_KHR: return Result::Suboptimal;
    case VK_TIMEOUT: return Result::Timeout;
    case VK_NOT_READY: return Result::NotReady;
    case VK_ERROR_OUT_OF_DATE_KHR: return Result::OutOfDate;
    default: return Result::Failure;
    }
}

using IsBinarySemaphore = bool (*)(VkDevice device, VkSemaphore semaphore, void* context);
using ResolveImage = bool (*)(VkDevice device, VkSwapchainKHR swapchain, uint32_t index,
                              Image& image, void* context);
using ResolveTerminal = uint64_t (*)(const Image& image, void* context);

struct SubmitSnapshot {
    std::array<Batch, MaxSubmitBatches> batches{};
    std::array<std::array<Wait, MaxBatchSemaphores>, MaxSubmitBatches> waits{};
    std::array<std::array<Signal, MaxBatchSemaphores>, MaxSubmitBatches> signals{};
    std::size_t count = 0;
    bool valid = false;
};

inline void InitializeBatch(SubmitSnapshot& snapshot, std::size_t index, uint64_t queue, Api api) {
    auto& batch = snapshot.batches[index];
    batch.queue = queue;
    batch.api = api;
    batch.waits = snapshot.waits[index].data();
    batch.signals = snapshot.signals[index].data();
}

inline bool CaptureLegacySubmit(VkQueue queue, const VkSubmitInfo* submits, uint32_t count,
                                VkDevice device, IsBinarySemaphore isBinary, void* context,
                                SubmitSnapshot& snapshot) {
    snapshot = {};
    snapshot.count = count;
    const auto queueId = HandleValue(queue);
    bool valid = queueId != 0 && (count == 0 || submits != nullptr) && count <= MaxSubmitBatches;
    if (count > MaxSubmitBatches || (count && !submits)) {
        snapshot.valid = false;
        return false;
    }
    for (uint32_t i = 0; i < count; ++i) {
        const auto& source = submits[i];
        InitializeBatch(snapshot, i, queueId, Api::Legacy);
        auto& batch = snapshot.batches[i];
        batch.unsupportedPNext = source.pNext != nullptr;
        batch.waitCount = source.waitSemaphoreCount;
        batch.signalCount = source.signalSemaphoreCount;
        valid &= (source.waitSemaphoreCount == 0 || (source.pWaitSemaphores && source.pWaitDstStageMask));
        valid &= source.signalSemaphoreCount == 0 || source.pSignalSemaphores;
        valid &= source.waitSemaphoreCount <= MaxBatchSemaphores && source.signalSemaphoreCount <= MaxBatchSemaphores;
        if (source.waitSemaphoreCount > MaxBatchSemaphores || source.signalSemaphoreCount > MaxBatchSemaphores)
            continue;
        for (uint32_t w = 0; w < source.waitSemaphoreCount && source.pWaitSemaphores && source.pWaitDstStageMask; ++w) {
            const auto semaphore = source.pWaitSemaphores[w];
            const bool binary = isBinary && isBinary(device, semaphore, context);
            snapshot.waits[i][w] = {HandleValue(semaphore), binary,
                static_cast<uint64_t>(source.pWaitDstStageMask[w])};
            valid &= binary;
        }
        for (uint32_t s = 0; s < source.signalSemaphoreCount && source.pSignalSemaphores; ++s) {
            const auto semaphore = source.pSignalSemaphores[s];
            const bool binary = isBinary && isBinary(device, semaphore, context);
            snapshot.signals[i][s] = {HandleValue(semaphore), binary, AllCommandsStage};
            valid &= binary;
        }
        valid &= !batch.unsupportedPNext;
    }
    snapshot.valid = valid;
    return valid;
}

inline bool CaptureSubmit2(VkQueue queue, const VkSubmitInfo2* submits, uint32_t count,
                           VkDevice device, IsBinarySemaphore isBinary, void* context,
                           SubmitSnapshot& snapshot) {
    snapshot = {};
    snapshot.count = count;
    const auto queueId = HandleValue(queue);
    bool valid = queueId != 0 && (count == 0 || submits != nullptr) && count <= MaxSubmitBatches;
    if (count > MaxSubmitBatches || (count && !submits)) {
        snapshot.valid = false;
        return false;
    }
    for (uint32_t i = 0; i < count; ++i) {
        const auto& source = submits[i];
        InitializeBatch(snapshot, i, queueId, Api::Synchronization2);
        auto& batch = snapshot.batches[i];
        batch.unsupportedPNext = source.pNext != nullptr || source.flags != 0;
        batch.waitCount = source.waitSemaphoreInfoCount;
        batch.signalCount = source.signalSemaphoreInfoCount;
        valid &= (source.waitSemaphoreInfoCount == 0 || source.pWaitSemaphoreInfos != nullptr);
        valid &= (source.signalSemaphoreInfoCount == 0 || source.pSignalSemaphoreInfos != nullptr);
        valid &= source.waitSemaphoreInfoCount <= MaxBatchSemaphores && source.signalSemaphoreInfoCount <= MaxBatchSemaphores;
        if (source.waitSemaphoreInfoCount > MaxBatchSemaphores || source.signalSemaphoreInfoCount > MaxBatchSemaphores)
            continue;
        for (uint32_t w = 0; w < source.waitSemaphoreInfoCount && source.pWaitSemaphoreInfos; ++w) {
            const auto& info = source.pWaitSemaphoreInfos[w];
            const bool binary = isBinary && isBinary(device, info.semaphore, context);
            snapshot.waits[i][w] = {HandleValue(info.semaphore), binary,
                static_cast<uint64_t>(info.stageMask)};
            batch.unsupportedPNext |= info.pNext != nullptr || info.value != 0 || info.deviceIndex != 0;
            valid &= binary;
        }
        for (uint32_t s = 0; s < source.signalSemaphoreInfoCount && source.pSignalSemaphoreInfos; ++s) {
            const auto& info = source.pSignalSemaphoreInfos[s];
            const bool binary = isBinary && isBinary(device, info.semaphore, context);
            snapshot.signals[i][s] = {HandleValue(info.semaphore), binary,
                static_cast<uint64_t>(info.stageMask)};
            batch.unsupportedPNext |= info.pNext != nullptr || info.value != 0 || info.deviceIndex != 0;
            valid &= binary;
        }
        valid &= !batch.unsupportedPNext;
    }
    snapshot.valid = valid;
    return valid;
}

inline StateResult ApplySubmitResult(AcquireDependencyTracker& tracker, VkDevice device,
                                     VkResult result, const SubmitSnapshot& snapshot) {
    const auto translated = FromVkResult(result);
    if (translated != Result::Success)
        return tracker.ObserveSubmit(HandleValue(device), translated, nullptr, snapshot.count);
    // A successful but unsupported call may have consumed any visible wait.
    // Passing captured batches (with unsupportedPNext retained) lets the model
    // quarantine visible handles; oversized calls quarantine all device proof.
    if (snapshot.count > MaxSubmitBatches)
        return tracker.ObserveSubmit(HandleValue(device), translated, nullptr, snapshot.count);
    return tracker.ObserveSubmit(HandleValue(device), translated, snapshot.batches.data(), snapshot.count);
}

inline StateResult ObserveAcquireResult(AcquireDependencyTracker& tracker, VkDevice device,
                                        VkSwapchainKHR swapchain, uint32_t imageIndex,
                                        VkSemaphore semaphore, VkFence fence, VkResult result,
                                        ResolveImage resolveImage, void* context,
                                        IsBinarySemaphore isBinary) {
    const auto translated = FromVkResult(result);
    if (translated != Result::Success && translated != Result::Suboptimal)
        return StateResult::IgnoredResult;
    Image image{};
    const bool identityResolved = resolveImage && resolveImage(device, swapchain, imageIndex, image, context) &&
        image.device == HandleValue(device) && image.swapchain == HandleValue(swapchain) && image.index == imageIndex;
    const bool semaphoreKnownBinary = semaphore == VK_NULL_HANDLE || (isBinary && isBinary(device, semaphore, context));
    if (!identityResolved || !semaphoreKnownBinary || (!semaphore && !fence))
        return tracker.ObserveUnmodelledAcquire(HandleValue(device), translated,
            HandleValue(semaphore), HandleValue(fence));
    const auto token = tracker.RecordAcquire(image, translated, HandleValue(semaphore), HandleValue(fence));
    return token ? StateResult::Recorded : tracker.ObserveUnmodelledAcquire(HandleValue(device), translated,
        HandleValue(semaphore), HandleValue(fence));
}

inline StateResult ObserveAcquireInfoResult(AcquireDependencyTracker& tracker, VkDevice device,
                                            const VkAcquireNextImageInfoKHR* info,
                                            uint32_t imageIndex, VkResult result,
                                            ResolveImage resolveImage, void* context,
                                            IsBinarySemaphore isBinary) {
    if (!info) return StateResult::InvalidIdentity;
    const auto translated = FromVkResult(result);
    if (translated != Result::Success && translated != Result::Suboptimal)
        return StateResult::IgnoredResult;
    if (info->pNext != nullptr || info->deviceMask != 1)
        return tracker.ObserveUnmodelledAcquire(HandleValue(device), translated,
            HandleValue(info->semaphore), HandleValue(info->fence));
    return ObserveAcquireResult(tracker, device, info->swapchain, imageIndex, info->semaphore,
        info->fence, result, resolveImage, context, isBinary);
}

// Observe one fence at a time. For vkWaitForFences(waitAll = VK_FALSE), the
// caller must query each fence independently and pass only that fence's result.
inline StateResult ObserveFenceStatus(AcquireDependencyTracker& tracker, VkDevice device,
                                     VkFence fence, VkResult result) {
    return tracker.ObserveFence(HandleValue(device), HandleValue(fence), FromVkResult(result));
}
inline void ObserveFenceResetResult(AcquireDependencyTracker& tracker, VkDevice device,
                                   VkFence fence, VkResult result) {
    tracker.ObserveFenceReset(HandleValue(device), HandleValue(fence), FromVkResult(result));
}

struct PresentSnapshot {
    std::array<PresentItem, MaxPresentImages> items{};
    std::array<PresentWait, MaxBatchSemaphores> waits{};
    std::size_t itemCount = 0;
    std::size_t waitCount = 0;
    bool perResultsKnown = false;
    bool unsupportedPNext = false;
    bool deviceGroup = false;
    bool valid = false;
};

// Capture after the original vkQueuePresentKHR returns so optional pResults
// values are final. The application structure is read only and never rewritten.
inline bool CapturePresentResult(VkDevice device, const VkPresentInfoKHR* info, VkResult globalResult,
                                 ResolveImage resolveImage, ResolveTerminal resolveTerminal,
                                 IsBinarySemaphore isBinary, void* context,
                                 PresentSnapshot& snapshot) {
    snapshot = {};
    if (!info) return false;
    snapshot.itemCount = info->swapchainCount;
    snapshot.waitCount = info->waitSemaphoreCount;
    snapshot.perResultsKnown = info->pResults != nullptr;
    snapshot.unsupportedPNext = info->pNext != nullptr;
    snapshot.deviceGroup = false;
    bool valid = HandleValue(device) != 0 && info->swapchainCount != 0 &&
        info->swapchainCount <= MaxPresentImages &&
        info->waitSemaphoreCount <= MaxBatchSemaphores &&
        (!info->swapchainCount || (info->pSwapchains && info->pImageIndices)) &&
        (!info->waitSemaphoreCount || info->pWaitSemaphores);
    if (info->waitSemaphoreCount > MaxBatchSemaphores || info->swapchainCount > MaxPresentImages) {
        snapshot.valid = false;
        return false;
    }
    for (uint32_t w = 0; w < info->waitSemaphoreCount && info->pWaitSemaphores; ++w) {
        const auto semaphore = info->pWaitSemaphores[w];
        const bool binary = isBinary && isBinary(device, semaphore, context);
        snapshot.waits[w] = {HandleValue(semaphore), binary};
        valid &= binary;
    }
    for (uint32_t i = 0; i < info->swapchainCount && info->pSwapchains && info->pImageIndices; ++i) {
        auto& item = snapshot.items[i];
        valid &= resolveImage && resolveImage(device, info->pSwapchains[i], info->pImageIndices[i], item.image, context);
        valid &= item.image.device == HandleValue(device) &&
            item.image.swapchain == HandleValue(info->pSwapchains[i]) && item.image.index == info->pImageIndices[i];
        item.terminalSemaphore = resolveTerminal ? resolveTerminal(item.image, context) : 0;
        item.result = info->pResults ? FromVkResult(info->pResults[i]) : FromVkResult(globalResult);
        valid &= item.terminalSemaphore != 0;
    }
    snapshot.valid = valid && !snapshot.unsupportedPNext;
    return snapshot.valid;
}

inline StateResult ApplyPresentResult(AcquireDependencyTracker& tracker, VkDevice device,
                                      VkResult globalResult, const PresentSnapshot& snapshot) {
    if (snapshot.itemCount > MaxPresentImages || snapshot.waitCount > MaxBatchSemaphores)
        return tracker.ObservePresent(HandleValue(device), FromVkResult(globalResult), nullptr,
            snapshot.itemCount, nullptr, snapshot.waitCount, snapshot.perResultsKnown,
            snapshot.unsupportedPNext, snapshot.deviceGroup);
    return tracker.ObservePresent(HandleValue(device), FromVkResult(globalResult),
        snapshot.items.data(), snapshot.itemCount, snapshot.waits.data(), snapshot.waitCount,
        snapshot.perResultsKnown, snapshot.unsupportedPNext, snapshot.deviceGroup);
}

} // namespace optishade::vulkan_sync::api_adapter
