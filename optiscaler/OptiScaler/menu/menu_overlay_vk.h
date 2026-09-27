#pragma once

#include "SysUtils.h"
#include <vulkan/vulkan.hpp>

namespace MenuOverlayVk
{
void CreateSwapchain(VkDevice device, VkPhysicalDevice pd, VkInstance instance, HWND hwnd,
                     const VkSwapchainCreateInfoKHR* pCreateInfo, const VkAllocationCallbacks* pAllocator,
                     VkSwapchainKHR* pSwapchain);
bool CanDrawAfterEffects(VkQueue queue, const VkPresentInfoKHR* pPresentInfo);
bool QueuePresent(VkQueue queue, VkPresentInfoKHR* pPresentInfo, PFN_vkQueueSubmit submit = nullptr);
void DestroyVulkanObjects(bool shutdown);
} // namespace MenuOverlayVk
