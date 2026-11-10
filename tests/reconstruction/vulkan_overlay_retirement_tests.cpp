#include "VulkanOverlayRetirement.h"

#include <cassert>
#include <vector>

struct MockRetiredFrameResources
{
    optishade::vkoverlay::FenceState fence;
    unsigned commandPool;
    unsigned fenceHandle;
    unsigned vertexBuffer;
    unsigned vertexMemory;
    unsigned indexBuffer;
    unsigned indexMemory;
};

int main()
{
    using optishade::vkoverlay::DecideAcquiredImageFence;
    using optishade::vkoverlay::FenceDecision;
    using optishade::vkoverlay::FenceState;
    using optishade::vkoverlay::MaxRetiredFrameResources;

    assert(DecideAcquiredImageFence(FenceState::Signaled, false, 0) == FenceDecision::Proceed);
    assert(DecideAcquiredImageFence(FenceState::Signaled, true, 0) == FenceDecision::Proceed);
    assert(DecideAcquiredImageFence(FenceState::NotReady, false, 0) == FenceDecision::Defer);
    assert(DecideAcquiredImageFence(FenceState::NotReady, true, 0) == FenceDecision::ReplaceResources);
    assert(DecideAcquiredImageFence(FenceState::NotReady, true, MaxRetiredFrameResources) == FenceDecision::Defer);
    assert(DecideAcquiredImageFence(FenceState::Error, false, 0) == FenceDecision::DisableOverlay);
    assert(DecideAcquiredImageFence(FenceState::Error, true, 0) == FenceDecision::DisableOverlay);

    std::vector<MockRetiredFrameResources> retired{
        {FenceState::NotReady, 1, 2, 3, 4, 5, 6},
        {FenceState::Error, 7, 8, 9, 10, 11, 12},
    };
    unsigned destroyedBundles = 0;
    unsigned destroyedBufferHandles = 0;
    const auto destroy = [&](MockRetiredFrameResources& resources) {
        assert(resources.commandPool != 0 && resources.fenceHandle != 0);
        assert(resources.vertexBuffer != 0 && resources.vertexMemory != 0);
        assert(resources.indexBuffer != 0 && resources.indexMemory != 0);
        ++destroyedBundles;
        destroyedBufferHandles += 4;
    };
    assert(optishade::vkoverlay::ReapCompletedResources(retired,
        [](const MockRetiredFrameResources& resources) { return resources.fence; }, destroy) == 0);
    assert(retired.size() == 2 && destroyedBundles == 0);
    retired[0].fence = FenceState::Signaled;
    assert(optishade::vkoverlay::ReapCompletedResources(retired,
        [](const MockRetiredFrameResources& resources) { return resources.fence; }, destroy) == 1);
    assert(retired.size() == 1 && destroyedBundles == 1 && destroyedBufferHandles == 4);
    retired[0].fence = FenceState::Signaled;
    assert(optishade::vkoverlay::ReapCompletedResources(retired,
        [](const MockRetiredFrameResources& resources) { return resources.fence; }, destroy) == 1);
    assert(retired.empty() && destroyedBundles == 2 && destroyedBufferHandles == 8);
}
