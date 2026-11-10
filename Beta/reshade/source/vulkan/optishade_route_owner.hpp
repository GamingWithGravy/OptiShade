#pragma once

#include "../../../shared/SimulatorRouteHost.h"
#include "../../../shared/XPlaneWindowIdentity.h"

#include <type_traits>

namespace optishade::reshade_vulkan_owner {

template <typename Handle>
inline uint64_t Value(Handle handle) noexcept {
    if constexpr (std::is_pointer_v<Handle>)
        return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(handle));
    else
        return static_cast<uint64_t>(handle);
}

inline bool Active() noexcept {
    return route::CurrentSimulator() == route::Simulator::XPlane12;
}

inline bool Send(route::VulkanRequest& request) noexcept {
    if (!Active()) return false;
    const auto& adapter = route::Current();
    if (!adapter.vulkan) return false;
    route::VulkanResult result;
    return adapter.vulkan(&request, sizeof(request), &result, sizeof(result));
}

inline void Surface(uint64_t instance, uint64_t surface, HWND window) noexcept {
    route::VulkanRequest request;
    request.event = route::VulkanEvent::Surface;
    request.a = instance;
    request.b = surface;
    request.c = Value(window);
    Send(request);
}

inline void Swapchain(uint64_t device, uint64_t surface, uint64_t swapchain, HWND window) noexcept {
    route::VulkanRequest request;
    request.event = route::VulkanEvent::Swapchain;
    request.a = device;
    request.b = surface;
    request.c = swapchain;
    request.eligible = window::IsXPlaneMainWindow(window);
    route::VulkanRequest lookup;
    lookup.event = route::VulkanEvent::Lookup;
    const auto& adapter = route::Current();
    if (Active() && adapter.vulkan) {
        route::VulkanResult result;
        if (adapter.vulkan(&lookup, sizeof(lookup), &result, sizeof(result)))
            request.alive = result.owner.chain != 0 && IsWindow(reinterpret_cast<HWND>(result.owner.window));
    }
    Send(request);
}

inline void Queue(uint64_t device, uint64_t queue, uint32_t family, bool graphics) noexcept {
    route::VulkanRequest request;
    request.event = route::VulkanEvent::Queue;
    request.a = device;
    request.b = queue;
    request.family = family;
    request.graphics = graphics;
    Send(request);
}

inline void Present(uint64_t queue, uint32_t count, const uint64_t* chains,
                    const uint32_t* images) noexcept {
    route::VulkanRequest request;
    request.event = route::VulkanEvent::Present;
    request.a = queue;
    request.count = count;
    request.chains = chains;
    request.images = images;
    request.imageCount = UINT32_MAX;
    Send(request);
}

inline void Erase(route::VulkanEvent event, uint64_t handle) noexcept {
    route::VulkanRequest request;
    request.event = event;
    request.a = handle;
    Send(request);
}

} // namespace optishade::reshade_vulkan_owner
