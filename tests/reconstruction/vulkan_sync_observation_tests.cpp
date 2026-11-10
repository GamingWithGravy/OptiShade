#include <vulkan/vulkan.h>
#include "VulkanSyncObservation.h"
#include <cassert>
#include <cstdint>
#include <iostream>
#include <type_traits>

using namespace optishade::vulkan_sync_observation;

int main() {
    static_assert(std::is_trivially_copyable_v<Event>);
    assert(Abi == 1);
    assert(HandleValue(nullptr) == 0);

    VkDevice device = reinterpret_cast<VkDevice>(static_cast<uintptr_t>(0x1234));
    VkSemaphore semaphore = reinterpret_cast<VkSemaphore>(static_cast<uintptr_t>(0x5678));
    VkFence fence = reinterpret_cast<VkFence>(static_cast<uintptr_t>(0x9abc));
    assert(HandleValue(device) == 0x1234);
    assert(HandleValue(semaphore) == 0x5678);
    assert(HandleValue(fence) == 0x9abc);

    Event createSemaphore{};
    createSemaphore.objectType = static_cast<uint32_t>(Object::Semaphore);
    createSemaphore.action = static_cast<uint32_t>(Action::Create);
    createSemaphore.device = HandleValue(device);
    createSemaphore.object = HandleValue(semaphore);
    createSemaphore.timeline = 1;
    createSemaphore.initialValue = 7;
    createSemaphore.exportHandleTypes = 3;
    createSemaphore.valid = 1;
    assert(createSemaphore.size == sizeof(Event) && createSemaphore.abi == Abi);
    assert(createSemaphore.objectType == static_cast<uint32_t>(Object::Semaphore));
    assert(createSemaphore.action == static_cast<uint32_t>(Action::Create));
    assert(createSemaphore.timeline == 1 && createSemaphore.initialValue == 7);
    assert(createSemaphore.exportHandleTypes == 3 && createSemaphore.valid);

    Event destroySemaphore{};
    destroySemaphore.objectType = static_cast<uint32_t>(Object::Semaphore);
    destroySemaphore.action = static_cast<uint32_t>(Action::Destroy);
    destroySemaphore.device = HandleValue(device);
    destroySemaphore.object = HandleValue(semaphore);
    destroySemaphore.valid = 1;
    assert(destroySemaphore.object == createSemaphore.object);
    assert(destroySemaphore.action != createSemaphore.action);

    Event createFence{};
    createFence.objectType = static_cast<uint32_t>(Object::Fence);
    createFence.action = static_cast<uint32_t>(Action::Create);
    createFence.device = HandleValue(device);
    createFence.object = HandleValue(fence);
    createFence.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    createFence.valid = 1;
    Event destroyFence{};
    destroyFence.objectType = static_cast<uint32_t>(Object::Fence);
    destroyFence.action = static_cast<uint32_t>(Action::Destroy);
    destroyFence.device = HandleValue(device);
    destroyFence.object = HandleValue(fence);
    destroyFence.valid = 1;
    assert(createFence.flags == VK_FENCE_CREATE_SIGNALED_BIT);
    assert(createFence.object == destroyFence.object);

    std::cout << "Vulkan semaphore/fence lifecycle event ABI, handle identity and timeline metadata passed.\n";
}
