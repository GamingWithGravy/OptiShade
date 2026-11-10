#include "VulkanAcquireApiAdapter.h"

#include <cassert>

using namespace optishade::vulkan_sync;
using namespace optishade::vulkan_sync::api_adapter;

static bool IsFixtureBinary(VkDevice, VkSemaphore semaphore, void*) {
    return HandleValue(semaphore) != 777;
}

struct SwapchainFixture { uint64_t generation = 1; uint64_t terminal = 0; };
static bool ResolveFixtureImage(VkDevice device, VkSwapchainKHR swapchain, uint32_t index,
                               Image& image, void* context) {
    const auto* fixture = static_cast<const SwapchainFixture*>(context);
    if (!fixture || !device || !swapchain || !fixture->generation) return false;
    image = {HandleValue(device), HandleValue(swapchain), fixture->generation, index};
    return true;
}
static uint64_t ResolveFixtureTerminal(const Image&, void* context) {
    const auto* fixture = static_cast<const SwapchainFixture*>(context);
    return fixture ? fixture->terminal : 0;
}

int main() {
    const auto device = reinterpret_cast<VkDevice>(uintptr_t{1});
    const auto queue = reinterpret_cast<VkQueue>(uintptr_t{2});
    const auto semAcquire = reinterpret_cast<VkSemaphore>(uintptr_t{101});
    const auto semMiddle = reinterpret_cast<VkSemaphore>(uintptr_t{102});
    const auto semTerminal = reinterpret_cast<VkSemaphore>(uintptr_t{103});
    const VkPipelineStageFlags all = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;

    AcquireDependencyTracker legacyTracker;
    const Image legacyImage{HandleValue(device), 50, 3, 1};
    assert(legacyTracker.RecordAcquire(legacyImage, Result::Success, HandleValue(semAcquire), 0) != 0);
    VkSemaphore wait0[]{semAcquire};
    VkPipelineStageFlags stage0[]{all};
    VkSemaphore signal0[]{semMiddle};
    VkSubmitInfo first{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    first.waitSemaphoreCount = 1; first.pWaitSemaphores = wait0; first.pWaitDstStageMask = stage0;
    first.signalSemaphoreCount = 1; first.pSignalSemaphores = signal0;
    VkSemaphore wait1[]{semMiddle};
    VkPipelineStageFlags stage1[]{all};
    VkSemaphore signal1[]{semTerminal};
    VkSubmitInfo second{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    second.waitSemaphoreCount = 1; second.pWaitSemaphores = wait1; second.pWaitDstStageMask = stage1;
    second.signalSemaphoreCount = 1; second.pSignalSemaphores = signal1;
    VkSubmitInfo legacySubmits[]{first, second};
    SubmitSnapshot legacySnapshot;
    assert(CaptureLegacySubmit(queue, legacySubmits, 2, device, IsFixtureBinary, nullptr, legacySnapshot));
    assert(legacySnapshot.count == 2 && legacySnapshot.valid);
    assert(legacySnapshot.batches[0].queue == HandleValue(queue));
    assert(legacySnapshot.batches[0].waits[0].stageMask == AllCommandsStage);
    assert(legacySnapshot.batches[1].waits[0].semaphore == HandleValue(semMiddle));
    assert(ApplySubmitResult(legacyTracker, device, VK_ERROR_DEVICE_LOST, legacySnapshot) == StateResult::IgnoredResult);
    assert(legacyTracker.HasSemaphoreDependency(legacyImage, HandleValue(semAcquire)));
    assert(ApplySubmitResult(legacyTracker, device, VK_SUCCESS, legacySnapshot) == StateResult::Recorded);
    assert(legacyTracker.HasSemaphoreDependency(legacyImage, HandleValue(semTerminal)));

    // Unknown pNext content is preserved as unsupported. If the real call
    // succeeds, the visible acquire token is quarantined rather than reused.
    AcquireDependencyTracker pNextTracker;
    const Image pNextImage{HandleValue(device), 51, 3, 0};
    assert(pNextTracker.RecordAcquire(pNextImage, Result::Success, HandleValue(semAcquire), 0) != 0);
    VkProtectedSubmitInfo protectedInfo{VK_STRUCTURE_TYPE_PROTECTED_SUBMIT_INFO};
    first.pNext = &protectedInfo;
    SubmitSnapshot pNextSnapshot;
    assert(!CaptureLegacySubmit(queue, &first, 1, device, IsFixtureBinary, nullptr, pNextSnapshot));
    assert(ApplySubmitResult(pNextTracker, device, VK_SUCCESS, pNextSnapshot) == StateResult::InvalidIdentity);
    assert(!pNextTracker.HasSemaphoreDependency(pNextImage, HandleValue(semAcquire)));
    first.pNext = nullptr;

    // A semaphore absent from the binary-type authority cannot be promoted
    // into a binary synchronization proof.
    const auto unknownSemaphore = reinterpret_cast<VkSemaphore>(uintptr_t{777});
    VkSemaphore unknownWait[]{unknownSemaphore};
    first.waitSemaphoreCount = 1; first.pWaitSemaphores = unknownWait; first.pWaitDstStageMask = stage0;
    SubmitSnapshot unknownSnapshot;
    assert(!CaptureLegacySubmit(queue, &first, 1, device, IsFixtureBinary, nullptr, unknownSnapshot));

    // Sync2 stage masks, values, device indices and per-entry pNext are read
    // from their real Vulkan structures. Timeline and device-group semantics
    // remain disallowed by the proof model.
    AcquireDependencyTracker sync2Tracker;
    const auto sync2Acquire = reinterpret_cast<VkSemaphore>(uintptr_t{110});
    const auto sync2Signal = reinterpret_cast<VkSemaphore>(uintptr_t{111});
    const Image sync2Image{HandleValue(device), 52, 5, 2};
    assert(sync2Tracker.RecordAcquire(sync2Image, Result::Success, HandleValue(sync2Acquire), 0) != 0);
    VkSemaphoreSubmitInfo sync2Wait{VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO};
    sync2Wait.semaphore = sync2Acquire; sync2Wait.stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
    VkSemaphoreSubmitInfo sync2Output{VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO};
    sync2Output.semaphore = sync2Signal; sync2Output.stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
    VkSubmitInfo2 sync2{VK_STRUCTURE_TYPE_SUBMIT_INFO_2};
    sync2.waitSemaphoreInfoCount = 1; sync2.pWaitSemaphoreInfos = &sync2Wait;
    sync2.signalSemaphoreInfoCount = 1; sync2.pSignalSemaphoreInfos = &sync2Output;
    SubmitSnapshot sync2Snapshot;
    assert(CaptureSubmit2(queue, &sync2, 1, device, IsFixtureBinary, nullptr, sync2Snapshot));
    assert(sync2Snapshot.batches[0].api == Api::Synchronization2);
    assert(sync2Snapshot.batches[0].signals[0].stageMask == AllCommandsStage);
    assert(ApplySubmitResult(sync2Tracker, device, VK_SUCCESS, sync2Snapshot) == StateResult::Recorded);
    assert(sync2Tracker.HasSemaphoreDependency(sync2Image, HandleValue(sync2Signal)));

    AcquireDependencyTracker timelineTracker;
    const Image timelineImage{HandleValue(device), 53, 5, 0};
    assert(timelineTracker.RecordAcquire(timelineImage, Result::Success, HandleValue(sync2Acquire), 0) != 0);
    sync2Wait.value = 1;
    SubmitSnapshot timelineSnapshot;
    assert(!CaptureSubmit2(queue, &sync2, 1, device, IsFixtureBinary, nullptr, timelineSnapshot));
    assert(timelineSnapshot.batches[0].unsupportedPNext);
    assert(ApplySubmitResult(timelineTracker, device, VK_SUCCESS, timelineSnapshot) == StateResult::InvalidIdentity);
    assert(!timelineTracker.HasSemaphoreDependency(timelineImage, HandleValue(sync2Acquire)));

    sync2Wait.value = 0; sync2Wait.deviceIndex = 1;
    SubmitSnapshot deviceGroupSnapshot;
    assert(!CaptureSubmit2(queue, &sync2, 1, device, IsFixtureBinary, nullptr, deviceGroupSnapshot));
    sync2Wait.deviceIndex = 0;

    assert(FromVkResult(VK_SUBOPTIMAL_KHR) == Result::Suboptimal);
    assert(FromVkResult(VK_TIMEOUT) == Result::Timeout);
    assert(FromVkResult(VK_ERROR_OUT_OF_DATE_KHR) == Result::OutOfDate);
    assert(FromVkResult(VK_ERROR_UNKNOWN) == Result::Failure);

    // Acquire/present translation uses actual Vulkan structures and preserves
    // per-swapchain results. Unsupported acquire and present pNext semantics
    // invalidate evidence rather than being flattened into the model.
    const auto chain = reinterpret_cast<VkSwapchainKHR>(uintptr_t{50});
    const auto acquired = reinterpret_cast<VkSemaphore>(uintptr_t{120});
    const auto terminal = reinterpret_cast<VkSemaphore>(uintptr_t{121});
    const auto reshadeCompletion = reinterpret_cast<VkSemaphore>(uintptr_t{122});
    SwapchainFixture swapchainFixture{3, HandleValue(terminal)};
    AcquireDependencyTracker apiTracker;
    const Image apiImage{HandleValue(device), HandleValue(chain), 3, 4};
    assert(ObserveAcquireResult(apiTracker, device, chain, 4, acquired, VK_NULL_HANDLE,
        VK_SUBOPTIMAL_KHR, ResolveFixtureImage, &swapchainFixture, IsFixtureBinary) == StateResult::Recorded);
    VkSemaphore apiWaits[]{acquired};
    VkPipelineStageFlags apiWaitStages[]{VK_PIPELINE_STAGE_ALL_COMMANDS_BIT};
    VkSemaphore apiSignals[]{terminal};
    VkSubmitInfo apiRelay{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    apiRelay.waitSemaphoreCount=1; apiRelay.pWaitSemaphores=apiWaits; apiRelay.pWaitDstStageMask=apiWaitStages;
    apiRelay.signalSemaphoreCount=1; apiRelay.pSignalSemaphores=apiSignals;
    SubmitSnapshot apiRelaySnapshot;
    assert(CaptureLegacySubmit(queue, &apiRelay, 1, device, IsFixtureBinary, nullptr, apiRelaySnapshot));
    assert(ApplySubmitResult(apiTracker, device, VK_SUCCESS, apiRelaySnapshot) == StateResult::Recorded);
    VkSemaphore presentWaits[]{terminal};
    VkPipelineStageFlags effectWaitStages[]{VK_PIPELINE_STAGE_ALL_COMMANDS_BIT};
    VkSemaphore effectSignals[]{reshadeCompletion};
    VkSubmitInfo reshadeEffects{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    reshadeEffects.waitSemaphoreCount=1; reshadeEffects.pWaitSemaphores=presentWaits;
    reshadeEffects.pWaitDstStageMask=effectWaitStages;
    reshadeEffects.signalSemaphoreCount=1; reshadeEffects.pSignalSemaphores=effectSignals;
    SubmitSnapshot reshadeEffectsSnapshot;
    assert(CaptureLegacySubmit(queue, &reshadeEffects, 1, device, IsFixtureBinary, nullptr, reshadeEffectsSnapshot));
    assert(ApplySubmitResult(apiTracker, device, VK_SUCCESS, reshadeEffectsSnapshot) == StateResult::Recorded);
    swapchainFixture.terminal=HandleValue(reshadeCompletion);

    // ReShade consumes the game's terminal semaphore in its effects submit,
    // then replaces the final present wait with its own completion semaphore.
    // The observer must capture the wait list actually passed downstream.
    presentWaits[0]=reshadeCompletion;
    VkSwapchainKHR presentChains[]{chain};
    uint32_t presentIndices[]{4};
    VkResult perChainResults[]{VK_SUBOPTIMAL_KHR};
    VkPresentInfoKHR present{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    present.waitSemaphoreCount=1; present.pWaitSemaphores=presentWaits;
    present.swapchainCount=1; present.pSwapchains=presentChains; present.pImageIndices=presentIndices;
    present.pResults=perChainResults;
    PresentSnapshot presentSnapshot;
    assert(CapturePresentResult(device, &present, VK_SUCCESS, ResolveFixtureImage,
        ResolveFixtureTerminal, IsFixtureBinary, &swapchainFixture, presentSnapshot));
    assert(presentSnapshot.perResultsKnown && presentSnapshot.items[0].result == Result::Suboptimal);
    assert(presentSnapshot.waitCount == 1 && presentSnapshot.waits[0].semaphore == HandleValue(reshadeCompletion));
    assert(ApplyPresentResult(apiTracker, device, VK_SUCCESS, presentSnapshot) == StateResult::Recorded);
    assert(!apiTracker.HasSemaphoreDependency(apiImage, HandleValue(terminal)));

    const auto presentProtected = VkProtectedSubmitInfo{VK_STRUCTURE_TYPE_PROTECTED_SUBMIT_INFO};
    present.pNext = &presentProtected;
    assert(!CapturePresentResult(device, &present, VK_SUCCESS, ResolveFixtureImage,
        ResolveFixtureTerminal, IsFixtureBinary, &swapchainFixture, presentSnapshot));
    assert(ApplyPresentResult(apiTracker, device, VK_SUCCESS, presentSnapshot) == StateResult::InvalidIdentity);
    present.pNext = nullptr;

    AcquireDependencyTracker acquire2Tracker;
    const auto acquire2Semaphore = reinterpret_cast<VkSemaphore>(uintptr_t{130});
    VkAcquireNextImageInfoKHR acquire2{VK_STRUCTURE_TYPE_ACQUIRE_NEXT_IMAGE_INFO_KHR};
    acquire2.swapchain=chain; acquire2.semaphore=acquire2Semaphore; acquire2.deviceMask=1;
    assert(ObserveAcquireInfoResult(acquire2Tracker, device, &acquire2, 5, VK_SUCCESS,
        ResolveFixtureImage, &swapchainFixture, IsFixtureBinary) == StateResult::Recorded);
    acquire2.pNext=&presentProtected;
    assert(ObserveAcquireInfoResult(acquire2Tracker, device, &acquire2, 6, VK_SUCCESS,
        ResolveFixtureImage, &swapchainFixture, IsFixtureBinary) == StateResult::InvalidIdentity);
    assert(!acquire2Tracker.HasSemaphoreDependency({HandleValue(device),HandleValue(chain),3,6},
        HandleValue(acquire2Semaphore)));

    AcquireDependencyTracker fenceTracker;
    const auto acquireFence = reinterpret_cast<VkFence>(uintptr_t{140});
    const Image fenceImage{HandleValue(device),HandleValue(chain),3,7};
    assert(fenceTracker.RecordAcquire(fenceImage,Result::Success,0,HandleValue(acquireFence)) != 0);
    assert(ObserveFenceStatus(fenceTracker,device,acquireFence,VK_NOT_READY) == StateResult::IgnoredResult);
    assert(ObserveFenceStatus(fenceTracker,device,acquireFence,VK_SUCCESS) == StateResult::Recorded);
    ObserveFenceResetResult(fenceTracker,device,acquireFence,VK_ERROR_DEVICE_LOST);
    assert(fenceTracker.HasObservedFenceProof(fenceImage));
    ObserveFenceResetResult(fenceTracker,device,acquireFence,VK_SUCCESS);
    assert(fenceTracker.HasObservedFenceProof(fenceImage));

    return 0;
}
