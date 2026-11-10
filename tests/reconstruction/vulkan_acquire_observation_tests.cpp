#include "VulkanAcquireObservation.h"
#include <vulkan/vulkan.h>
#include <cassert>
#include <cstdint>

using namespace optishade::vulkan_acquire_observation;

int main() {
    const auto device = reinterpret_cast<VkDevice>(uintptr_t{1});
    const auto swapchain = reinterpret_cast<VkSwapchainKHR>(uintptr_t{2});
    const auto semaphore = reinterpret_cast<VkSemaphore>(uintptr_t{3});
    const auto fence = reinterpret_cast<VkFence>(uintptr_t{4});
    uint32_t index = 9;
    Snapshot snapshot;
    assert(Abi == 2 && snapshot.swapchainGeneration == 0);

    assert(CaptureLegacy(device, swapchain, 1234, semaphore, fence, &index, VK_SUCCESS, snapshot));
    assert(snapshot.api == static_cast<uint32_t>(Api::Legacy));
    assert(snapshot.device == HandleValue(device) && snapshot.swapchain == HandleValue(swapchain));
    assert(snapshot.timeout == 1234 && snapshot.semaphore == HandleValue(semaphore));
    assert(snapshot.fence == HandleValue(fence) && snapshot.imageIndexValid && snapshot.imageIndex == 9);
    assert(CaptureLegacy(device, swapchain, UINT64_MAX, VkSemaphore{}, VkFence{}, &index,
        VK_SUBOPTIMAL_KHR, snapshot));
    assert(snapshot.imageIndexValid && snapshot.imageIndex == 9);
    assert(CaptureLegacy(device, swapchain, UINT64_MAX, semaphore, fence, &index, VK_TIMEOUT, snapshot));
    assert(!snapshot.imageIndexValid);

    VkAcquireNextImageInfoKHR info{VK_STRUCTURE_TYPE_ACQUIRE_NEXT_IMAGE_INFO_KHR};
    info.swapchain = swapchain; info.timeout = 5678; info.semaphore = semaphore;
    info.fence = fence; info.deviceMask = 3;
    assert(CaptureDeviceGroup(device, &info, &index, VK_SUCCESS, snapshot));
    assert(snapshot.api == static_cast<uint32_t>(Api::DeviceGroup));
    assert(snapshot.deviceMask == 3 && snapshot.timeout == 5678 && snapshot.imageIndexValid);
    info.pNext = &info;
    assert(CaptureDeviceGroup(device, &info, &index, VK_ERROR_OUT_OF_DATE_KHR, snapshot));
    assert(snapshot.hasPNext && !snapshot.imageIndexValid);
    assert(!CaptureDeviceGroup(device, static_cast<const VkAcquireNextImageInfoKHR*>(nullptr),
        &index, VK_SUCCESS, snapshot));
}
