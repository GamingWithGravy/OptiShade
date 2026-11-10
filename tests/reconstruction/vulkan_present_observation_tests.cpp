#include "VulkanPresentObservation.h"

#include <vulkan/vulkan.h>
#include <cassert>
#include <cstdint>

using namespace optishade::vulkan_present_observation;

int main() {
    const auto queue = reinterpret_cast<VkQueue>(uintptr_t{1});
    const auto firstWait = reinterpret_cast<VkSemaphore>(uintptr_t{101});
    const auto rewrittenWait = reinterpret_cast<VkSemaphore>(uintptr_t{202});
    const auto firstSwapchain = reinterpret_cast<VkSwapchainKHR>(uintptr_t{301});
    const auto secondSwapchain = reinterpret_cast<VkSwapchainKHR>(uintptr_t{302});
    VkSemaphore waits[]{rewrittenWait};
    VkSwapchainKHR swapchains[]{firstSwapchain, secondSwapchain};
    uint32_t imageIndices[]{4, 7};
    VkResult perSwapchain[]{VK_SUCCESS, VK_SUBOPTIMAL_KHR};
    VkPresentInfoKHR present{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    present.waitSemaphoreCount = 1;
    present.pWaitSemaphores = waits;
    present.swapchainCount = 2;
    present.pSwapchains = swapchains;
    present.pImageIndices = imageIndices;
    present.pResults = perSwapchain;

    Snapshot snapshot;
    assert(Abi == 2 && snapshot.device == 0 && snapshot.chains[0].generation == 0);
    assert(Capture(queue, &present, VK_SUCCESS, snapshot));
    assert(snapshot.valid && snapshot.perSwapchainResultsKnown);
    assert(snapshot.queue == HandleValue(queue));
    assert(snapshot.waitCount == 1 && snapshot.capturedWaitCount == 1);
    assert(snapshot.waits[0] == HandleValue(rewrittenWait));
    assert(snapshot.waits[0] != HandleValue(firstWait));
    assert(snapshot.swapchainCount == 2 && snapshot.capturedSwapchainCount == 2);
    assert(snapshot.chains[0].swapchain == HandleValue(firstSwapchain));
    assert(snapshot.chains[0].imageIndex == 4 && snapshot.chains[0].result == VK_SUCCESS);
    assert(snapshot.chains[1].swapchain == HandleValue(secondSwapchain));
    assert(snapshot.chains[1].imageIndex == 7 && snapshot.chains[1].result == VK_SUBOPTIMAL_KHR);

    present.pResults = nullptr;
    assert(Capture(queue, &present, VK_ERROR_OUT_OF_DATE_KHR, snapshot));
    assert(!snapshot.perSwapchainResultsKnown);
    assert(snapshot.chains[0].result == VK_ERROR_OUT_OF_DATE_KHR);
    assert(snapshot.chains[1].result == VK_ERROR_OUT_OF_DATE_KHR);

    present.pNext = &present;
    assert(Capture(queue, &present, VK_SUCCESS, snapshot));
    assert(snapshot.hasPNext); // Capture records, but does not interpret, extensions.
    present.pNext = nullptr;

    VkSemaphore tooManyWaits[MaxWaits + 1]{};
    present.waitSemaphoreCount = static_cast<uint32_t>(MaxWaits + 1);
    present.pWaitSemaphores = tooManyWaits;
    assert(Capture(queue, &present, VK_SUCCESS, snapshot));
    assert(snapshot.truncated);
    assert(snapshot.waitCount == MaxWaits + 1 && snapshot.capturedWaitCount == MaxWaits);

    present.pWaitSemaphores = nullptr;
    assert(!Capture(queue, &present, VK_SUCCESS, snapshot));
    assert(!snapshot.valid && snapshot.capturedWaitCount == 0);
}
