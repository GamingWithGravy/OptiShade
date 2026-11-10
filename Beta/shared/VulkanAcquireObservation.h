#pragma once

#include <cstdint>
#include <type_traits>

namespace optishade::vulkan_acquire_observation {

constexpr uint32_t Abi = 2;
constexpr int32_t SuboptimalResult = 1000001003;
enum class Api : uint32_t { Legacy = 1, DeviceGroup = 2 };

struct Snapshot {
    uint32_t size = sizeof(Snapshot);
    uint32_t abi = Abi;
    uint32_t api = 0;
    uint32_t imageIndexValid = 0;
    uint32_t deviceMask = 0;
    uint32_t hasPNext = 0;
    int32_t result = 0;
    uint64_t device = 0;
    uint64_t swapchain = 0;
    uint64_t swapchainGeneration = 0;
    uint64_t timeout = 0;
    uint64_t semaphore = 0;
    uint64_t fence = 0;
    uint32_t imageIndex = 0;
};

template <typename Handle>
inline uint64_t HandleValue(Handle handle) {
    if constexpr (std::is_pointer_v<Handle>)
        return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(handle));
    else
        return static_cast<uint64_t>(handle);
}

template <typename Device, typename Swapchain, typename Semaphore, typename Fence>
inline bool CaptureLegacy(Device device, Swapchain swapchain, uint64_t timeout,
                          Semaphore semaphore, Fence fence, const uint32_t* imageIndex,
                          int32_t result, Snapshot& snapshot) {
    snapshot = {};
    snapshot.api = static_cast<uint32_t>(Api::Legacy);
    snapshot.device = HandleValue(device);
    snapshot.swapchain = HandleValue(swapchain);
    snapshot.timeout = timeout;
    snapshot.semaphore = HandleValue(semaphore);
    snapshot.fence = HandleValue(fence);
    snapshot.result = result;
    snapshot.imageIndexValid = imageIndex != nullptr && (result == 0 || result == SuboptimalResult);
    if (snapshot.imageIndexValid) snapshot.imageIndex = *imageIndex;
    return snapshot.device != 0 && snapshot.swapchain != 0;
}

template <typename Device, typename AcquireInfo>
inline bool CaptureDeviceGroup(Device device, const AcquireInfo* info,
                               const uint32_t* imageIndex, int32_t result,
                               Snapshot& snapshot) {
    snapshot = {};
    snapshot.api = static_cast<uint32_t>(Api::DeviceGroup);
    snapshot.device = HandleValue(device);
    snapshot.result = result;
    if (!info) return false;
    snapshot.swapchain = HandleValue(info->swapchain);
    snapshot.timeout = info->timeout;
    snapshot.semaphore = HandleValue(info->semaphore);
    snapshot.fence = HandleValue(info->fence);
    snapshot.deviceMask = info->deviceMask;
    snapshot.hasPNext = info->pNext != nullptr;
    snapshot.imageIndexValid = imageIndex != nullptr && (result == 0 || result == SuboptimalResult);
    if (snapshot.imageIndexValid) snapshot.imageIndex = *imageIndex;
    return snapshot.device != 0 && snapshot.swapchain != 0;
}

} // namespace optishade::vulkan_acquire_observation
