/*
 * Copyright (C) 2014 Patrick Mours
 * SPDX-License-Identifier: BSD-3-Clause OR MIT
 */

#include "vulkan_hooks.hpp"
#include "vulkan_impl_device.hpp"
#include "vulkan_impl_command_queue.hpp"
#include "vulkan_impl_swapchain.hpp"
#include "vulkan_impl_type_convert.hpp"
#include "dll_log.hpp"
#include "addon_manager.hpp"
#include "runtime_manager.hpp"
#include "lockfree_linear_map.hpp"
#include "optishade_route_owner.hpp"
#include "../../../shared/VulkanOverlayBridge.h"
#include "../../../shared/VulkanOwnerBridge.h"
#include <mutex>
#include "../../../shared/OverlayCallbacks.h"
#include "../../../shared/OverlayPreparation.h"
#include <algorithm> // std::fill_n, std::sort, std::unique
#include <unordered_map>
#include <vector>

#define vk device_impl->_dispatch_table

extern thread_local bool g_in_dxgi_runtime;

extern lockfree_linear_map<VkSurfaceKHR, HWND, 16> g_vulkan_surfaces;
extern lockfree_linear_map<void *, reshade::vulkan::device_impl *, 8> g_vulkan_devices;

static optishade::overlay::Callbacks<VkQueue,osvk::PrepareOverlay,osvk::DrawOverlay> optishade_callbacks;
extern "C" __declspec(dllexport) bool OptiShadeVulkanSetCallbacks(uint32_t version,VkQueue queue,osvk::PrepareOverlay prepare,osvk::DrawOverlay draw)
{
 if(version!=osvk::CallbackVersion)return false;
 if(!queue&&!prepare&&!draw){optishade_callbacks.Clear();return true;}
 if(!queue||!prepare||!draw)return false;
 const auto device=g_vulkan_devices.at(dispatch_key_from_handle(queue));
 if(!device)return false;
 const auto q=device->get_private_data_for_object<VK_OBJECT_TYPE_QUEUE,true>(queue);
 if(!q||q!=device->_primary_graphics_queue)return false;
 optishade_callbacks.Set(queue,prepare,draw);return true;
}

static thread_local VkQueue optishade_overlay_queue = VK_NULL_HANDLE;
static thread_local osvk::DrawOverlay optishade_overlay_draw = nullptr;

// vkQueuePresentKHR has no completion fence. ReShade's immediate command list
// rotates its signal semaphores by command-buffer slot, which is not a proof
// that the presentation engine has finished waiting on the previous slot.
// Keep a terminal semaphore per actual swapchain image instead: reacquiring
// that image is the Vulkan-guaranteed point at which its previous present wait
// has completed. State is keyed by the native swapchain handle so oldSwapchain
// generations can coexist until the application destroys each one.
struct OptiShadePresentTerminalSet
{
	VkDevice device = VK_NULL_HANDLE;
	std::vector<VkSemaphore> byImage;
	std::vector<VkFence> presentFenceByImage;
	std::vector<bool> presentFencePending;
	std::vector<bool> deferByImageUntilDeviceDestroy;
	std::vector<VkSemaphore> deferredUntilDeviceDestroy;
	bool disabled = false;
};
static constexpr size_t OptiShadeMaxRetiredPresentSemaphores = 64;
static std::mutex optishade_present_terminal_mutex;
static std::unordered_map<VkSwapchainKHR, OptiShadePresentTerminalSet> optishade_present_terminal_sets;
static std::unordered_map<VkDevice, bool> optishade_maintenance_present_devices;

void OptiShadeVulkanSetMaintenancePresentFencesEnabled(VkDevice device, bool enabled)
{
	std::lock_guard guard(optishade_present_terminal_mutex);
	if (device != VK_NULL_HANDLE)
		optishade_maintenance_present_devices[device] = enabled;
}

void OptiShadeVulkanForgetMaintenancePresentDevice(VkDevice device)
{
	std::lock_guard guard(optishade_present_terminal_mutex);
	optishade_maintenance_present_devices.erase(device);
	// Vulkan destroys child objects with the device. Drop any stale bookkeeping
	// if a non-conforming application skipped vkDestroySwapchainKHR.
	for (auto it = optishade_present_terminal_sets.begin(); it != optishade_present_terminal_sets.end(); )
		if (it->second.device == device) it = optishade_present_terminal_sets.erase(it);
		else ++it;
}

static bool CreateOptiShadePresentTerminalSet(VkDevice device, VkSwapchainKHR swapchain, uint32_t image_count,
	PFN_vkCreateSemaphore create_semaphore, PFN_vkDestroySemaphore destroy_semaphore,
	PFN_vkCreateFence create_fence, PFN_vkDestroyFence destroy_fence)
{
	if (device == VK_NULL_HANDLE || swapchain == VK_NULL_HANDLE || image_count == 0 || image_count > 64 ||
		create_semaphore == nullptr || destroy_semaphore == nullptr || create_fence == nullptr || destroy_fence == nullptr)
		return false;

	OptiShadePresentTerminalSet created{};
	created.device = device;
	try
	{
		created.byImage.resize(image_count, VK_NULL_HANDLE);
		created.presentFenceByImage.resize(image_count, VK_NULL_HANDLE);
		created.presentFencePending.resize(image_count, false);
		created.deferByImageUntilDeviceDestroy.resize(image_count, false);
		created.deferredUntilDeviceDestroy.reserve(OptiShadeMaxRetiredPresentSemaphores);
		{
			std::lock_guard guard(optishade_present_terminal_mutex);
			const auto enabled = optishade_maintenance_present_devices.find(device);
			if (enabled == optishade_maintenance_present_devices.end() || !enabled->second)
				return false;
		}
		const VkSemaphoreCreateInfo create_info{ VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
		for (uint32_t i = 0; i < image_count; ++i)
			if (create_semaphore(device, &create_info, nullptr, &created.byImage[i]) != VK_SUCCESS || created.byImage[i] == VK_NULL_HANDLE)
			{
				for (const VkSemaphore semaphore : created.byImage)
					if (semaphore != VK_NULL_HANDLE) destroy_semaphore(device, semaphore, nullptr);
				return false;
			}
		VkFenceCreateInfo fence_info{ VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
		fence_info.flags = VK_FENCE_CREATE_SIGNALED_BIT;
		for (uint32_t i = 0; i < image_count; ++i)
			if (create_fence(device, &fence_info, nullptr, &created.presentFenceByImage[i]) != VK_SUCCESS || created.presentFenceByImage[i] == VK_NULL_HANDLE)
			{
				for (const VkFence fence : created.presentFenceByImage)
					if (fence != VK_NULL_HANDLE) destroy_fence(device, fence, nullptr);
				for (const VkSemaphore semaphore : created.byImage)
					if (semaphore != VK_NULL_HANDLE) destroy_semaphore(device, semaphore, nullptr);
				return false;
			}
		std::unique_lock guard(optishade_present_terminal_mutex);
		const auto inserted = optishade_present_terminal_sets.try_emplace(swapchain);
		if (!inserted.second)
		{
			guard.unlock();
			for (const VkFence fence : created.presentFenceByImage)
				if (fence != VK_NULL_HANDLE) destroy_fence(device, fence, nullptr);
			for (const VkSemaphore semaphore : created.byImage)
				if (semaphore != VK_NULL_HANDLE) destroy_semaphore(device, semaphore, nullptr);
			return false;
		}
		inserted.first->second.device = device;
		inserted.first->second.byImage.swap(created.byImage);
		inserted.first->second.presentFenceByImage.swap(created.presentFenceByImage);
		inserted.first->second.presentFencePending.swap(created.presentFencePending);
		inserted.first->second.deferByImageUntilDeviceDestroy.swap(created.deferByImageUntilDeviceDestroy);
		inserted.first->second.deferredUntilDeviceDestroy.swap(created.deferredUntilDeviceDestroy);
		return true;
	}
	catch (...)
	{
		for (const VkFence fence : created.presentFenceByImage)
			if (fence != VK_NULL_HANDLE) destroy_fence(device, fence, nullptr);
		for (const VkSemaphore semaphore : created.byImage)
			if (semaphore != VK_NULL_HANDLE) destroy_semaphore(device, semaphore, nullptr);
		return false;
	}
}

static void DestroyOptiShadePresentTerminalSet(VkSwapchainKHR swapchain, PFN_vkWaitForFences wait_for_fences,
	PFN_vkDestroyFence destroy_fence, PFN_vkDestroySemaphore destroy_semaphore)
{
	OptiShadePresentTerminalSet retired{};
	{
		std::lock_guard guard(optishade_present_terminal_mutex);
		const auto found = optishade_present_terminal_sets.find(swapchain);
		if (found == optishade_present_terminal_sets.end()) return;
		retired = std::move(found->second);
		optishade_present_terminal_sets.erase(found);
	}
	std::vector<bool> safe_to_destroy(retired.byImage.size(), true);
	for (size_t i = 0; i < retired.presentFenceByImage.size(); ++i)
	{
		if (retired.deferByImageUntilDeviceDestroy[i]) safe_to_destroy[i] = false;
		if (retired.presentFencePending[i])
		{
			if (wait_for_fences == nullptr || wait_for_fences(retired.device, 1, &retired.presentFenceByImage[i], VK_TRUE, UINT64_MAX) != VK_SUCCESS)
				safe_to_destroy[i] = false;
		}
		if (destroy_fence != nullptr && retired.presentFenceByImage[i] != VK_NULL_HANDLE && safe_to_destroy[i])
			destroy_fence(retired.device, retired.presentFenceByImage[i], nullptr);
	}
	if (destroy_semaphore != nullptr)
	{
		for (size_t i = 0; i < retired.byImage.size(); ++i)
			if (retired.byImage[i] != VK_NULL_HANDLE && safe_to_destroy[i]) destroy_semaphore(retired.device, retired.byImage[i], nullptr);
		// A semaphore whose present was rejected before it was queued may still
		// have a pending relay signal. Leave those few error-path objects to device
		// destruction rather than risk destroying a pending synchronization object.
	}
}

static bool IsVulkanPresentOperationQueued(VkResult result)
{
	if (result >= VK_SUCCESS || result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_ERROR_SURFACE_LOST_KHR)
		return true;
#if VK_EXT_full_screen_exclusive
	if (result == VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT) return true;
#endif
#if VK_EXT_present_timing
	if (result == VK_ERROR_PRESENT_TIMING_QUEUE_FULL_EXT) return true;
#endif
	return false;
}

static void RetireOptiShadePresentTerminalsAfterFailure(uint32_t swapchain_count, const VkSwapchainKHR *swapchains,
	const uint32_t *image_indices, const std::vector<VkSemaphore> &submitted_semaphores,
	const std::vector<VkFence> &present_fences, VkResult present_result, const VkResult *per_swapchain_results,
	bool present_fence_attached, PFN_vkCreateSemaphore create_semaphore, PFN_vkDestroySemaphore destroy_semaphore,
	PFN_vkCreateFence create_fence, PFN_vkDestroyFence destroy_fence, PFN_vkWaitForFences wait_for_fences)
{
	if (swapchains == nullptr || image_indices == nullptr || submitted_semaphores.size() != swapchain_count ||
		present_fences.size() != swapchain_count || create_semaphore == nullptr || destroy_semaphore == nullptr)
		return;

	for (uint32_t i = 0; i < swapchain_count; ++i)
	{
		const VkResult item_result = per_swapchain_results != nullptr ? per_swapchain_results[i] : present_result;
		const bool queued = IsVulkanPresentOperationQueued(item_result);
		if (present_fence_attached && queued && item_result >= VK_SUCCESS)
		{
			std::lock_guard guard(optishade_present_terminal_mutex);
			const auto found = optishade_present_terminal_sets.find(swapchains[i]);
			if (found != optishade_present_terminal_sets.end() && image_indices[i] < found->second.presentFencePending.size())
				found->second.presentFencePending[image_indices[i]] = true;
			continue;
		}

		VkDevice device = VK_NULL_HANDLE;
		{
			std::lock_guard guard(optishade_present_terminal_mutex);
			const auto found = optishade_present_terminal_sets.find(swapchains[i]);
			if (found == optishade_present_terminal_sets.end() || image_indices[i] >= found->second.byImage.size() ||
				found->second.byImage[image_indices[i]] != submitted_semaphores[i])
				continue;
			device = found->second.device;
		}
		const bool safe_to_destroy_old_semaphore = present_fence_attached && queued && wait_for_fences != nullptr &&
			wait_for_fences(device, 1, &present_fences[i], VK_TRUE, UINT64_MAX) == VK_SUCCESS;
		VkSemaphore replacement_semaphore = VK_NULL_HANDLE;
		const VkSemaphoreCreateInfo semaphore_info{ VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
		if (create_semaphore(device, &semaphore_info, nullptr, &replacement_semaphore) != VK_SUCCESS)
			replacement_semaphore = VK_NULL_HANDLE;
		VkFence replacement_fence = VK_NULL_HANDLE;
		if (present_fence_attached && !queued && create_fence != nullptr)
		{
			VkFenceCreateInfo fence_info{ VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
			fence_info.flags = VK_FENCE_CREATE_SIGNALED_BIT;
			if (create_fence(device, &fence_info, nullptr, &replacement_fence) != VK_SUCCESS)
				replacement_fence = VK_NULL_HANDLE;
		}

		VkSemaphore semaphore_to_destroy = VK_NULL_HANDLE;
		VkFence fence_to_destroy = VK_NULL_HANDLE;
		{
			std::lock_guard guard(optishade_present_terminal_mutex);
			const auto found = optishade_present_terminal_sets.find(swapchains[i]);
			if (found == optishade_present_terminal_sets.end() || image_indices[i] >= found->second.byImage.size() ||
				found->second.byImage[image_indices[i]] != submitted_semaphores[i])
			{
				if (replacement_semaphore != VK_NULL_HANDLE) destroy_semaphore(device, replacement_semaphore, nullptr);
				if (replacement_fence != VK_NULL_HANDLE) destroy_fence(device, replacement_fence, nullptr);
				continue;
			}
			auto &set = found->second;
			const uint32_t image = image_indices[i];
			set.presentFencePending[image] = present_fence_attached && queued && !safe_to_destroy_old_semaphore;
			if (!safe_to_destroy_old_semaphore)
			{
				if (set.deferredUntilDeviceDestroy.size() < OptiShadeMaxRetiredPresentSemaphores)
					set.deferredUntilDeviceDestroy.push_back(set.byImage[image]);
				else
					set.deferByImageUntilDeviceDestroy[image] = true;
			}
			else
				semaphore_to_destroy = set.byImage[image];
			if (replacement_semaphore != VK_NULL_HANDLE)
				set.byImage[image] = replacement_semaphore;
			else
			{
				set.byImage[image] = VK_NULL_HANDLE;
				set.disabled = true;
			}
			if (present_fence_attached && !queued)
			{
				set.presentFencePending[image] = false;
				if (replacement_fence != VK_NULL_HANDLE)
				{
					fence_to_destroy = set.presentFenceByImage[image];
					set.presentFenceByImage[image] = replacement_fence;
				}
				else
					set.disabled = true;
			}
			if (!present_fence_attached || !safe_to_destroy_old_semaphore)
				set.disabled = true;
		}
		if (semaphore_to_destroy != VK_NULL_HANDLE) destroy_semaphore(device, semaphore_to_destroy, nullptr);
		if (fence_to_destroy != VK_NULL_HANDLE) destroy_fence(device, fence_to_destroy, nullptr);
	}
}

static bool GetOptiShadePresentTerminalSemaphores(uint32_t swapchain_count, const VkSwapchainKHR *swapchains,
	const uint32_t *image_indices, std::vector<VkSemaphore> &semaphores, std::vector<VkFence> &present_fences)
{
	if (swapchain_count == 0 || swapchain_count > 64 || swapchains == nullptr || image_indices == nullptr)
		return false;
	try
	{
		semaphores.clear();
		present_fences.clear();
		semaphores.reserve(swapchain_count);
		present_fences.reserve(swapchain_count);
		std::lock_guard guard(optishade_present_terminal_mutex);
		for (uint32_t i = 0; i < swapchain_count; ++i)
		{
			const auto found = optishade_present_terminal_sets.find(swapchains[i]);
			if (found == optishade_present_terminal_sets.end() || found->second.disabled || image_indices[i] >= found->second.byImage.size() ||
				found->second.byImage[image_indices[i]] == VK_NULL_HANDLE ||
				found->second.presentFenceByImage[image_indices[i]] == VK_NULL_HANDLE)
			{
				semaphores.clear();
				present_fences.clear();
				return false;
			}
			semaphores.push_back(found->second.byImage[image_indices[i]]);
			present_fences.push_back(found->second.presentFenceByImage[image_indices[i]]);
		}
		return true;
	}
	catch (...)
	{
		semaphores.clear();
		present_fences.clear();
		return false;
	}
}

extern "C" __declspec(dllexport) bool OptiShadeVulkanSetOverlay(uint32_t version, VkQueue queue, osvk::DrawOverlay draw)
{
	optishade_overlay_queue = VK_NULL_HANDLE;
	optishade_overlay_draw = nullptr;
	if (version != osvk::Version || !queue)
		return false;
	if (!draw)
		return true;
	const auto device = g_vulkan_devices.at(dispatch_key_from_handle(queue));
	if (!device)
		return false;
	const auto queue_impl = device->get_private_data_for_object<VK_OBJECT_TYPE_QUEUE, true>(queue);
	if (!queue_impl || queue_impl != device->_primary_graphics_queue)
		return false;
	optishade_overlay_queue = queue;
	optishade_overlay_draw = draw;
	return true;
}

#if RESHADE_ADDON
extern void create_default_view(reshade::vulkan::device_impl *device_impl, VkImage image);
extern void destroy_default_view(reshade::vulkan::device_impl *device_impl, VkImage image);
#endif

#if VK_KHR_swapchain
VkResult VKAPI_CALL vkCreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR *pCreateInfo, const VkAllocationCallbacks *pAllocator, VkSwapchainKHR *pSwapchain)
{
	reshade::log::message(reshade::log::level::info, "Redirecting vkCreateSwapchainKHR(device = %p, pCreateInfo = %p, pAllocator = %p, pSwapchain = %p) ...", device, pCreateInfo, pAllocator, pSwapchain);

	reshade::vulkan::device_impl *const device_impl = g_vulkan_devices.at(dispatch_key_from_handle(device));
	RESHADE_VULKAN_GET_DEVICE_DISPATCH_PTR(CreateSwapchainKHR, device_impl);

	assert(pCreateInfo != nullptr && pSwapchain != nullptr);

	VkSwapchainCreateInfoKHR create_info = *pCreateInfo;

	std::vector<VkFormat> format_list;
	VkImageFormatListCreateInfo format_list_info;
	std::vector<uint32_t> queue_family_list;

	// Only have to enable additional features if there is a graphics queue, since ReShade will not run otherwise
	if (device_impl->_primary_graphics_queue != nullptr)
	{
		// Add required usage flags to create info
		create_info.imageUsage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;

#if VK_KHR_swapchain_mutable_format
		// Add required format variants, so e.g. both linear and sRGB views can be created for the swap chain images
		format_list.push_back(reshade::vulkan::convert_format(reshade::api::format_to_default_typed(reshade::vulkan::convert_format(create_info.imageFormat), 0)));
		format_list.push_back(reshade::vulkan::convert_format(reshade::api::format_to_default_typed(reshade::vulkan::convert_format(create_info.imageFormat), 1)));

		// Only have to make format mutable if they are actually different
		if (format_list[0] != format_list[1])
			create_info.flags |= VK_SWAPCHAIN_CREATE_MUTABLE_FORMAT_BIT_KHR;

		// Patch the format list in the create info of the application
		if (const auto existing_format_list_info = find_in_structure_chain<VkImageFormatListCreateInfo>(
				pCreateInfo->pNext, VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO))
		{
			format_list.insert(format_list.end(), existing_format_list_info->pViewFormats, existing_format_list_info->pViewFormats + existing_format_list_info->viewFormatCount);

			// Remove duplicates from the list (since the new formats may have already been added by the application)
			std::sort(format_list.begin(), format_list.end());
			format_list.erase(std::unique(format_list.begin(), format_list.end()), format_list.end());

			const_cast<VkImageFormatListCreateInfo *>(existing_format_list_info)->viewFormatCount = static_cast<uint32_t>(format_list.size());
			const_cast<VkImageFormatListCreateInfo *>(existing_format_list_info)->pViewFormats = format_list.data();
		}
		else if (format_list[0] != format_list[1])
		{
			format_list_info = { VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO };
			format_list_info.pNext = create_info.pNext;
			format_list_info.viewFormatCount = static_cast<uint32_t>(format_list.size());
			format_list_info.pViewFormats = format_list.data();

			create_info.pNext = &format_list_info;
		}
#endif

		// Add required queue family indices, so images can be used on the graphics queue
		if (create_info.imageSharingMode == VK_SHARING_MODE_CONCURRENT)
		{
			queue_family_list.reserve(create_info.queueFamilyIndexCount + 1);
			queue_family_list.push_back(device_impl->_primary_graphics_queue_family_index);

			for (uint32_t i = 0; i < create_info.queueFamilyIndexCount; ++i)
				if (create_info.pQueueFamilyIndices[i] != device_impl->_primary_graphics_queue_family_index)
					queue_family_list.push_back(create_info.pQueueFamilyIndices[i]);

			create_info.queueFamilyIndexCount = static_cast<uint32_t>(queue_family_list.size());
			create_info.pQueueFamilyIndices = queue_family_list.data();
		}
	}

	// Dump swap chain description
	{
		const char *format_string = nullptr;
		switch (create_info.imageFormat)
		{
		case VK_FORMAT_UNDEFINED:
			format_string = "VK_FORMAT_UNDEFINED";
			break;
		case VK_FORMAT_R8G8B8A8_UNORM:
			format_string = "VK_FORMAT_R8G8B8A8_UNORM";
			break;
		case VK_FORMAT_R8G8B8A8_SRGB:
			format_string = "VK_FORMAT_R8G8B8A8_SRGB";
			break;
		case VK_FORMAT_B8G8R8A8_UNORM:
			format_string = "VK_FORMAT_B8G8R8A8_UNORM";
			break;
		case VK_FORMAT_B8G8R8A8_SRGB:
			format_string = "VK_FORMAT_B8G8R8A8_SRGB";
			break;
		case VK_FORMAT_A2B10G10R10_UNORM_PACK32:
			format_string = "VK_FORMAT_A2B10G10R10_UNORM_PACK32";
			break;
		case VK_FORMAT_A2R10G10B10_UNORM_PACK32:
			format_string = "VK_FORMAT_A2R10G10B10_UNORM_PACK32";
			break;
		case VK_FORMAT_R16G16B16A16_UNORM:
			format_string = "VK_FORMAT_R16G16B16A16_UNORM";
			break;
		case VK_FORMAT_R16G16B16A16_SFLOAT:
			format_string = "VK_FORMAT_R16G16B16A16_SFLOAT";
			break;
		}

		const char *color_space_string = nullptr;
		switch (create_info.imageColorSpace)
		{
		case VK_COLOR_SPACE_SRGB_NONLINEAR_KHR:
			color_space_string = "VK_COLOR_SPACE_SRGB_NONLINEAR_KHR";
			break;
#if VK_EXT_swapchain_colorspace
		case VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT:
			color_space_string = "VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT";
			break;
		case VK_COLOR_SPACE_BT2020_LINEAR_EXT:
			color_space_string = "VK_COLOR_SPACE_BT2020_LINEAR_EXT";
			break;
		case VK_COLOR_SPACE_HDR10_ST2084_EXT:
			color_space_string = "VK_COLOR_SPACE_HDR10_ST2084_EXT";
			break;
		case VK_COLOR_SPACE_HDR10_HLG_EXT:
			color_space_string = "VK_COLOR_SPACE_HDR10_HLG_EXT";
			break;
#endif
		}

		reshade::log::message(reshade::log::level::info, "> Dumping swap chain description:");
		reshade::log::message(reshade::log::level::info, "  +-----------------------------------------+-----------------------------------------+");
		reshade::log::message(reshade::log::level::info, "  | Parameter                               | Value                                   |");
		reshade::log::message(reshade::log::level::info, "  +-----------------------------------------+-----------------------------------------+");
		reshade::log::message(reshade::log::level::info, "  | flags                                   |"                               " %-#39x |", static_cast<unsigned int>(create_info.flags));
		reshade::log::message(reshade::log::level::info, "  | surface                                 |"                                " %-39p |", create_info.surface);
		reshade::log::message(reshade::log::level::info, "  | minImageCount                           |"                                " %-39u |", create_info.minImageCount);
		if (format_string != nullptr)
		reshade::log::message(reshade::log::level::info, "  | imageFormat                             |"                                " %-39s |", format_string);
		else
		reshade::log::message(reshade::log::level::info, "  | imageFormat                             |"                                " %-39d |", static_cast<int>(create_info.imageFormat));
		if (color_space_string != nullptr)
		reshade::log::message(reshade::log::level::info, "  | imageColorSpace                         |"                                " %-39s |", color_space_string);
		else
		reshade::log::message(reshade::log::level::info, "  | imageColorSpace                         |"                                " %-39d |", static_cast<int>(create_info.imageColorSpace));
		reshade::log::message(reshade::log::level::info, "  | imageExtent                             |"            " %-19u"            " %-19u |", create_info.imageExtent.width, create_info.imageExtent.height);
		reshade::log::message(reshade::log::level::info, "  | imageArrayLayers                        |"                                " %-39u |", create_info.imageArrayLayers);
		reshade::log::message(reshade::log::level::info, "  | imageUsage                              |"                               " %-#39x |", static_cast<unsigned int>(create_info.imageUsage));
		reshade::log::message(reshade::log::level::info, "  | imageSharingMode                        |"                                " %-39d |", static_cast<int>(create_info.imageSharingMode));
		reshade::log::message(reshade::log::level::info, "  | queueFamilyIndexCount                   |"                                " %-39u |", create_info.queueFamilyIndexCount);
		reshade::log::message(reshade::log::level::info, "  | preTransform                            |"                               " %-#39x |", static_cast<unsigned int>(create_info.preTransform));
		reshade::log::message(reshade::log::level::info, "  | compositeAlpha                          |"                               " %-#39x |", static_cast<unsigned int>(create_info.compositeAlpha));
		reshade::log::message(reshade::log::level::info, "  | presentMode                             |"                                " %-39d |", static_cast<int>(create_info.presentMode));
		reshade::log::message(reshade::log::level::info, "  | clipped                                 |"                                " %-39s |", create_info.clipped ? "true" : "false");
		reshade::log::message(reshade::log::level::info, "  | oldSwapchain                            |"                                " %-39p |", create_info.oldSwapchain);
		reshade::log::message(reshade::log::level::info, "  +-----------------------------------------+-----------------------------------------+");
	}

	// Look up window handle from surface
	HWND const hwnd = g_vulkan_surfaces.at(create_info.surface);

#if RESHADE_ADDON
	reshade::api::swapchain_desc desc = {};
	desc.back_buffer.type = reshade::api::resource_type::texture_2d;
	desc.back_buffer.texture.width = create_info.imageExtent.width;
	desc.back_buffer.texture.height = create_info.imageExtent.height;
	assert(create_info.imageArrayLayers <= std::numeric_limits<uint16_t>::max());
	desc.back_buffer.texture.depth_or_layers = static_cast<uint16_t>(create_info.imageArrayLayers);
	desc.back_buffer.texture.levels = 1;
	desc.back_buffer.texture.format = reshade::vulkan::convert_format(create_info.imageFormat);
	desc.back_buffer.texture.samples = 1;
	desc.back_buffer.heap = reshade::api::memory_heap::default_;
	reshade::vulkan::convert_image_usage_flags_to_usage(create_info.imageUsage, desc.back_buffer.usage);

	desc.back_buffer_count = create_info.minImageCount;
	desc.present_mode = static_cast<uint32_t>(create_info.presentMode);
	desc.present_flags = create_info.flags;
	desc.sync_interval = create_info.presentMode == VK_PRESENT_MODE_IMMEDIATE_KHR ? 0 : UINT32_MAX;
	desc.color_space = reshade::vulkan::convert_color_space(create_info.imageColorSpace);

#if VK_EXT_full_screen_exclusive
	// Optionally change fullscreen state
	VkSurfaceFullScreenExclusiveInfoEXT fullscreen_info;
	if (const auto existing_fullscreen_info = find_in_structure_chain<VkSurfaceFullScreenExclusiveInfoEXT>(
			pCreateInfo->pNext, VK_STRUCTURE_TYPE_SURFACE_FULL_SCREEN_EXCLUSIVE_INFO_EXT))
	{
		fullscreen_info = *existing_fullscreen_info;

		desc.fullscreen_state = existing_fullscreen_info->fullScreenExclusive == VK_FULL_SCREEN_EXCLUSIVE_ALLOWED_EXT;
	}
	else
	{
		fullscreen_info = { VK_STRUCTURE_TYPE_SURFACE_FULL_SCREEN_EXCLUSIVE_INFO_EXT, const_cast<void *>(create_info.pNext) };
		fullscreen_info.fullScreenExclusive = VK_FULL_SCREEN_EXCLUSIVE_DEFAULT_EXT;
	}
#endif

	if (reshade::invoke_addon_event<reshade::addon_event::create_swapchain>(reshade::api::device_api::vulkan, desc, hwnd))
	{
		create_info.imageFormat = reshade::vulkan::convert_format(desc.back_buffer.texture.format);
		create_info.imageColorSpace = reshade::vulkan::convert_color_space(desc.color_space);
		create_info.imageExtent.width = desc.back_buffer.texture.width;
		create_info.imageExtent.height = desc.back_buffer.texture.height;
		create_info.imageArrayLayers = desc.back_buffer.texture.depth_or_layers;
		reshade::vulkan::convert_usage_to_image_usage_flags(desc.back_buffer.usage, create_info.imageUsage);

		create_info.minImageCount = desc.back_buffer_count;
		create_info.presentMode = static_cast<VkPresentModeKHR>(desc.present_mode);
		create_info.flags = static_cast<uint32_t>(desc.present_flags);

#if VK_EXT_full_screen_exclusive
		if (desc.fullscreen_state)
		{
			if (fullscreen_info.fullScreenExclusive != VK_FULL_SCREEN_EXCLUSIVE_APPLICATION_CONTROLLED_EXT)
			{
				fullscreen_info.fullScreenExclusive = VK_FULL_SCREEN_EXCLUSIVE_ALLOWED_EXT;

				create_info.pNext = &fullscreen_info;
			}
		}
		else
		{
			if (fullscreen_info.fullScreenExclusive == VK_FULL_SCREEN_EXCLUSIVE_ALLOWED_EXT)
			{
				fullscreen_info.fullScreenExclusive = VK_FULL_SCREEN_EXCLUSIVE_APPLICATION_CONTROLLED_EXT;

				create_info.pNext = &fullscreen_info;
			}
		}
#endif

		if (desc.sync_interval == 0)
			create_info.presentMode = VK_PRESENT_MODE_IMMEDIATE_KHR;

		// Remove format list info if format was overridden
		if (const auto existing_format_list_info = find_in_structure_chain<VkImageFormatListCreateInfo>(
				create_info.pNext, VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO))
		{
			if (const VkFormat *const formats_begin = existing_format_list_info->pViewFormats, *const formats_end = existing_format_list_info->pViewFormats + existing_format_list_info->viewFormatCount;
				std::find(formats_begin, formats_end, create_info.imageFormat) == formats_end)
			{
				const_cast<VkImageFormatListCreateInfo *>(existing_format_list_info)->viewFormatCount = 0;
			}
		}
	}
#endif

	// Unregister object from old swap chain so that a call to 'vkDestroySwapchainKHR' won't reset the effect runtime again
	reshade::vulkan::object_data<VK_OBJECT_TYPE_SWAPCHAIN_KHR> *swapchain_impl = nullptr;
	if (create_info.oldSwapchain != VK_NULL_HANDLE)
		swapchain_impl = device_impl->get_private_data_for_object<VK_OBJECT_TYPE_SWAPCHAIN_KHR>(create_info.oldSwapchain);

	if (nullptr != swapchain_impl)
	{
		// Reuse the existing effect runtime if this swap chain was not created from scratch, but reset it before initializing again below
		reshade::reset_effect_runtime(swapchain_impl);

		// Get back buffer images of old swap chain
		uint32_t num_images = 0;
		vk.GetSwapchainImagesKHR(device, swapchain_impl->_orig, &num_images, nullptr);
		temp_mem<VkImage, 3> swapchain_images(num_images);
		vk.GetSwapchainImagesKHR(device, swapchain_impl->_orig, &num_images, swapchain_images.p);

#if RESHADE_ADDON
		reshade::invoke_addon_event<reshade::addon_event::destroy_swapchain>(swapchain_impl, false);
#endif

		for (uint32_t i = 0; i < num_images; ++i)
		{
#if RESHADE_ADDON
			destroy_default_view(device_impl, swapchain_images[i]);
#endif

			device_impl->unregister_object<VK_OBJECT_TYPE_IMAGE>(swapchain_images[i]);
		}

		device_impl->unregister_object<VK_OBJECT_TYPE_SWAPCHAIN_KHR, false>(swapchain_impl->_orig);
	}

	assert(!g_in_dxgi_runtime);
	g_in_dxgi_runtime = true;
	const VkResult result = trampoline(device, &create_info, pAllocator, pSwapchain);
	g_in_dxgi_runtime = false;
	if (result < VK_SUCCESS)
	{
		reshade::log::message(reshade::log::level::warning, "vkCreateSwapchainKHR failed with error code %d.", static_cast<int>(result));
		return result;
	}
	optishade::reshade_vulkan_owner::Swapchain(
		optishade::reshade_vulkan_owner::Value(device),
		optishade::reshade_vulkan_owner::Value(create_info.surface),
		optishade::reshade_vulkan_owner::Value(*pSwapchain), hwnd);

	if (nullptr == swapchain_impl)
	{
		swapchain_impl = new reshade::vulkan::object_data<VK_OBJECT_TYPE_SWAPCHAIN_KHR>(device_impl, *pSwapchain, create_info, hwnd);

		reshade::create_effect_runtime(swapchain_impl, device_impl->_primary_graphics_queue);
	}
	else
	{
		swapchain_impl->_orig = *pSwapchain;
		swapchain_impl->_create_info = create_info;
		swapchain_impl->_create_info.pNext = nullptr; // Clear out structure chain pointer, since it becomes invalid once leaving the current scope
		swapchain_impl->_hwnd = hwnd;
	}

	device_impl->register_object<VK_OBJECT_TYPE_SWAPCHAIN_KHR>(swapchain_impl->_orig, swapchain_impl);

	// Get back buffer images of new swap chain
	uint32_t num_images = 0;
	vk.GetSwapchainImagesKHR(device, swapchain_impl->_orig, &num_images, nullptr);
	temp_mem<VkImage, 3> swapchain_images(num_images);
	vk.GetSwapchainImagesKHR(device, swapchain_impl->_orig, &num_images, swapchain_images.p);

	// Add swap chain images to the image list
	for (uint32_t i = 0; i < num_images; ++i)
	{
		reshade::vulkan::object_data<VK_OBJECT_TYPE_IMAGE> &image_data = *device_impl->register_object<VK_OBJECT_TYPE_IMAGE>(swapchain_images[i]);
		image_data.create_info = { VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO };
		image_data.create_info.imageType = VK_IMAGE_TYPE_2D;
		image_data.create_info.format = create_info.imageFormat;
		image_data.create_info.extent = { create_info.imageExtent.width, create_info.imageExtent.height, 1 };
		image_data.create_info.mipLevels = 1;
		image_data.create_info.arrayLayers = create_info.imageArrayLayers;
		image_data.create_info.samples = VK_SAMPLE_COUNT_1_BIT;
		image_data.create_info.usage = create_info.imageUsage;
		image_data.create_info.sharingMode = create_info.imageSharingMode;
		image_data.create_info.initialLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

		// See https://registry.khronos.org/vulkan/specs/latest/man/html/vkCreateSwapchainKHR.html#_description
		if ((create_info.flags & VK_SWAPCHAIN_CREATE_SPLIT_INSTANCE_BIND_REGIONS_BIT_KHR) != 0)
			image_data.create_info.flags |= VK_IMAGE_CREATE_SPLIT_INSTANCE_BIND_REGIONS_BIT;
		if ((create_info.flags & VK_SWAPCHAIN_CREATE_PROTECTED_BIT_KHR) != 0)
			image_data.create_info.flags |= VK_IMAGE_CREATE_PROTECTED_BIT;
#if VK_KHR_swapchain_mutable_format
		if ((create_info.flags & VK_SWAPCHAIN_CREATE_MUTABLE_FORMAT_BIT_KHR) != 0)
			image_data.create_info.flags |= VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT | VK_IMAGE_CREATE_EXTENDED_USAGE_BIT;
#endif
	}

	if (device_impl->_primary_graphics_queue != nullptr &&
		!CreateOptiShadePresentTerminalSet(device, swapchain_impl->_orig, num_images,
			vk.CreateSemaphore, vk.DestroySemaphore, vk.CreateFence, vk.DestroyFence))
		reshade::log::message(reshade::log::level::warning,
			"Could not allocate per-image Vulkan present semaphores for swapchain %p; the original ReShade present chain remains active.", swapchain_impl->_orig);

#if RESHADE_ADDON
	reshade::invoke_addon_event<reshade::addon_event::init_swapchain>(swapchain_impl, false);

	// Create default views for swap chain images (do this after the 'init_swapchain' event, so that the images are known to add-ons)
	for (uint32_t i = 0; i < num_images; ++i)
		create_default_view(device_impl, swapchain_images[i]);

#if VK_EXT_full_screen_exclusive
	if (fullscreen_info.fullScreenExclusive != VK_FULL_SCREEN_EXCLUSIVE_DEFAULT_EXT)
	{
		if (const auto fullscreen_win32_info = find_in_structure_chain<VkSurfaceFullScreenExclusiveWin32InfoEXT>(
				create_info.pNext, VK_STRUCTURE_TYPE_SURFACE_FULL_SCREEN_EXCLUSIVE_WIN32_INFO_EXT))
			swapchain_impl->hmonitor = fullscreen_win32_info->hmonitor;

		reshade::invoke_addon_event<reshade::addon_event::set_fullscreen_state>(swapchain_impl, fullscreen_info.fullScreenExclusive == VK_FULL_SCREEN_EXCLUSIVE_ALLOWED_EXT, swapchain_impl->hmonitor);
	}
#endif
#endif

	reshade::init_effect_runtime(swapchain_impl);

#if RESHADE_VERBOSE_LOG
	reshade::log::message(reshade::log::level::debug, "Returning Vulkan swap chain %p.", *pSwapchain);
#endif
	return result;
}
void     VKAPI_CALL vkDestroySwapchainKHR(VkDevice device, VkSwapchainKHR swapchain, const VkAllocationCallbacks *pAllocator)
{
	reshade::log::message(reshade::log::level::info, "Redirecting vkDestroySwapchainKHR(device = %p, swapchain = %p, pAllocator = %p) ...", device, swapchain, pAllocator);

	if (swapchain == VK_NULL_HANDLE)
		return;
	optishade::reshade_vulkan_owner::Erase(optishade::route::VulkanEvent::EraseChain,
		optishade::reshade_vulkan_owner::Value(swapchain));

	reshade::vulkan::device_impl *const device_impl = g_vulkan_devices.at(dispatch_key_from_handle(device));
	RESHADE_VULKAN_GET_DEVICE_DISPATCH_PTR(DestroySwapchainKHR, device_impl);

	// Remove swap chain from global list
	reshade::vulkan::object_data<VK_OBJECT_TYPE_SWAPCHAIN_KHR> *const swapchain_impl = device_impl->get_private_data_for_object<VK_OBJECT_TYPE_SWAPCHAIN_KHR, true>(swapchain);
	if (swapchain_impl != nullptr)
	{
		reshade::reset_effect_runtime(swapchain_impl);

		// Get back buffer images of old swap chain
		uint32_t num_images = 0;
		vk.GetSwapchainImagesKHR(device, swapchain, &num_images, nullptr);
		temp_mem<VkImage, 3> swapchain_images(num_images);
		vk.GetSwapchainImagesKHR(device, swapchain, &num_images, swapchain_images.p);

#if RESHADE_ADDON
		reshade::invoke_addon_event<reshade::addon_event::destroy_swapchain>(swapchain_impl, false);
#endif

		for (uint32_t i = 0; i < num_images; ++i)
		{
#if RESHADE_ADDON
			destroy_default_view(device_impl, swapchain_images[i]);
#endif

			device_impl->unregister_object<VK_OBJECT_TYPE_IMAGE>(swapchain_images[i]);
		}

		reshade::destroy_effect_runtime(swapchain_impl);
	}

	device_impl->unregister_object<VK_OBJECT_TYPE_SWAPCHAIN_KHR, false>(swapchain);

	delete swapchain_impl;

	trampoline(device, swapchain, pAllocator);
	// The application owns swapchain-use synchronization and must not destroy a
	// swapchain while its present operations are outstanding. Retire our matching
	// per-image terminal semaphores only with that same swapchain generation.
	DestroyOptiShadePresentTerminalSet(swapchain, vk.WaitForFences, vk.DestroyFence, vk.DestroySemaphore);
}

VkResult VKAPI_CALL vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *pPresentInfo)
{
	assert(pPresentInfo != nullptr);

	VkPresentInfoKHR present_info = *pPresentInfo;
	if (pPresentInfo->swapchainCount != 0 && pPresentInfo->pSwapchains != nullptr && pPresentInfo->pImageIndices != nullptr)
	{
		std::vector<uint64_t> route_chains;
		route_chains.reserve(pPresentInfo->swapchainCount);
		for (uint32_t i = 0; i < pPresentInfo->swapchainCount; ++i)
			route_chains.push_back(optishade::reshade_vulkan_owner::Value(pPresentInfo->pSwapchains[i]));
		optishade::reshade_vulkan_owner::Present(
			optishade::reshade_vulkan_owner::Value(queue), pPresentInfo->swapchainCount,
			route_chains.data(), pPresentInfo->pImageIndices);
	}
	// Snapshot first; never invoke cross-DLL UI code under a queue/registration lock.
	const auto overlay_callbacks=optishade_callbacks.For(queue);



	reshade::vulkan::device_impl *const device_impl = g_vulkan_devices.at(dispatch_key_from_handle(queue));
	reshade::vulkan::object_data<VK_OBJECT_TYPE_QUEUE> *const queue_impl = device_impl->get_private_data_for_object<VK_OBJECT_TYPE_QUEUE>(queue);

	const bool present_from_secondary_queue = device_impl->_primary_graphics_queue != nullptr && device_impl->_primary_graphics_queue != queue_impl;
	if (present_from_secondary_queue)
		std::lock(queue_impl->_mutex, device_impl->_primary_graphics_queue->_mutex);
	else
		queue_impl->_mutex.lock();

	// Make the game's present waits available before runtime callbacks: the
	// XP12 NR bridge can submit Vulkan commands from inside present_effect_runtime.
	temp_mem<VkPipelineStageFlags> wait_stages(present_info.waitSemaphoreCount);
	std::fill_n(wait_stages.p, present_info.waitSemaphoreCount, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
	VkSubmitInfo submit_info { VK_STRUCTURE_TYPE_SUBMIT_INFO };
	submit_info.waitSemaphoreCount = present_info.waitSemaphoreCount;
	submit_info.pWaitSemaphores = present_info.pWaitSemaphores;
	submit_info.pWaitDstStageMask = wait_stages.p;
	queue_impl->set_external_present_wait_info(&submit_info);

	for (uint32_t i = 0; i < pPresentInfo->swapchainCount; ++i)
	{
		reshade::vulkan::object_data<VK_OBJECT_TYPE_SWAPCHAIN_KHR> *const swapchain_impl = device_impl->get_private_data_for_object<VK_OBJECT_TYPE_SWAPCHAIN_KHR>(pPresentInfo->pSwapchains[i]);

		// 'vkAcquireNextImageKHR' may be called for the next frame before this frame was presented (e.g. in DOOM Eternal), so correct swap index must be obtained from the present info
		swapchain_impl->_swap_index = pPresentInfo->pImageIndices[i];

#if RESHADE_ADDON
#if VK_KHR_incremental_present
		uint32_t dirty_rect_count = 0;
		temp_mem<reshade::api::rect, 16> dirty_rects;

		const auto present_regions = find_in_structure_chain<VkPresentRegionsKHR>(pPresentInfo->pNext, VK_STRUCTURE_TYPE_PRESENT_REGIONS_KHR);
		if (present_regions != nullptr)
		{
			assert(present_regions->swapchainCount == pPresentInfo->swapchainCount);

			dirty_rect_count = present_regions->pRegions[i].rectangleCount;
			if (dirty_rect_count > 16)
				dirty_rects.p = new reshade::api::rect[dirty_rect_count];

			const VkRectLayerKHR *const rects = present_regions->pRegions[i].pRectangles;

			for (uint32_t k = 0; k < dirty_rect_count; ++k)
			{
				dirty_rects[k] = {
					rects[k].offset.x,
					rects[k].offset.y,
					rects[k].offset.x + static_cast<int32_t>(rects[k].extent.width),
					rects[k].offset.y + static_cast<int32_t>(rects[k].extent.height)
				};
			}
		}
#endif

#if VK_KHR_display_swapchain
		reshade::api::rect source_rect, dest_rect;

		const auto display_present_info = find_in_structure_chain<VkDisplayPresentInfoKHR>(pPresentInfo->pNext, VK_STRUCTURE_TYPE_DISPLAY_PRESENT_INFO_KHR);
		if (display_present_info != nullptr)
		{
			source_rect = {
				display_present_info->srcRect.offset.x,
				display_present_info->srcRect.offset.y,
				display_present_info->srcRect.offset.x + static_cast<int32_t>(display_present_info->srcRect.extent.width),
				display_present_info->srcRect.offset.y + static_cast<int32_t>(display_present_info->srcRect.extent.height)
			};
			dest_rect = {
				display_present_info->dstRect.offset.x,
				display_present_info->dstRect.offset.y,
				display_present_info->dstRect.offset.x + static_cast<int32_t>(display_present_info->dstRect.extent.width),
				display_present_info->dstRect.offset.y + static_cast<int32_t>(display_present_info->dstRect.extent.height)
			};
		}

		reshade::invoke_addon_event<reshade::addon_event::present>(
			queue_impl,
			swapchain_impl,
			display_present_info != nullptr ? &source_rect : nullptr,
			display_present_info != nullptr ? &dest_rect : nullptr,
#else
		reshade::invoke_addon_event<reshade::addon_event::present>(
			queue_impl,
			swapchain_impl,
			nullptr,
			nullptr,
#endif
#if VK_KHR_incremental_present
			dirty_rect_count,
			dirty_rect_count != 0 ? dirty_rects.p : nullptr);
#else
			0, nullptr);
#endif
#endif

		reshade::present_effect_runtime(swapchain_impl);
	}

	// Synchronize immediate command list flush
	{
		queue_impl->flush_immediate_command_list(&submit_info);

		// If the application is presenting with a different queue than rendering, synchronize these two queues
		if (present_from_secondary_queue)
		{
			if (const auto present_config = find_in_structure_chain<VkBaseInStructure>(
					pPresentInfo, static_cast<VkStructureType>(1000613000) /* VK_STRUCTURE_TYPE_SET_PRESENT_CONFIG_NV */))
			{
				assert(queue_impl->present_batch <= 1);
				queue_impl->present_batch = *reinterpret_cast<const uint32_t *>(present_config + 1);
			}
			else if (queue_impl->present_batch > 1)
			{
				queue_impl->present_batch--;

				if (submit_info.waitSemaphoreCount != 0)
				{
					// RTX Remix calls present with the same semaphores to wait on for all generated frames, which will already be signaled by the first present in the batch
					// Signal them on the present queue again, so that the graphics queue waits for the generated frames too
					submit_info.signalSemaphoreCount = submit_info.waitSemaphoreCount;
					submit_info.pSignalSemaphores = submit_info.pWaitSemaphores;
					const VkResult submit_result = vk.QueueSubmit(queue, 1, &submit_info, VK_NULL_HANDLE);
					optishade::vulkan_submit_observation::Snapshot submission{};
					optishade::vulkan_submit_observation::CaptureLegacy(queue, &submit_info, 1, VK_NULL_HANDLE,
						static_cast<int32_t>(submit_result), optishade::vulkan_submit_observation::Source::PresentSynchronization, submission);
					OptiShadeVulkanNotifySubmit(submission);
					submit_info.signalSemaphoreCount = 0;
					submit_info.pSignalSemaphores = nullptr;
				}
			}
			else if (submit_info.pWaitSemaphores == present_info.pWaitSemaphores)
			{
				// Games doing present from compute may process the swap chain image on the compute queue before presenting, so ensure this work has completed before executing work on the graphics queue
				queue_impl->wait_and_signal(&submit_info);
			}

			// This can deadlock on the GPU if the application submitted a semaphore wait to the graphics queue before this call, for which it submits the corresponding signal to the present queue only after this call
			// E.g. happens with DLSS Frame Generation
			device_impl->_primary_graphics_queue->flush_immediate_command_list(&submit_info);
		}

		// This points into vkQueuePresentKHR's stack frame and must not escape it.
		queue_impl->set_external_present_wait_info(nullptr);

		// Override wait semaphores based on the last queue submit
		present_info.waitSemaphoreCount = submit_info.waitSemaphoreCount;
		present_info.pWaitSemaphores = submit_info.pWaitSemaphores;
	}

	// Build the menu after the effects pass, as in the working beta. Preparing
	// earlier records overlay render passes while effects are still being built
	// and polls per-image fences before the effects queue has been flushed.
	// Unlike the beta, release BOTH queue locks during preparation: font uploads
	// and effects-control calls may re-enter this layer. The game wait semaphores
	// were consumed only by the effects flush; submission below uses its outputs.
	const bool overlayPreparationRequired=overlay_callbacks.prepare!=nullptr;
	bool overlayPreparationSucceeded=false;
	if (overlayPreparationRequired)
	{
		overlayPreparationSucceeded=optishade::overlay::PrepareOutsideQueueLocks(queue_impl->_mutex,
			present_from_secondary_queue ? &device_impl->_primary_graphics_queue->_mutex : nullptr,
			[&]() noexcept -> bool { return overlay_callbacks.prepare(queue, pPresentInfo); });
		if(!overlayPreparationSucceeded)
			reshade::log::message(reshade::log::level::warning,"OptiShade Vulkan menu preparation callback failed.");
	}

	RESHADE_VULKAN_GET_DEVICE_DISPATCH_PTR(QueuePresentKHR, device_impl);
	// Effects have been submitted and present_info contains their completion
	// semaphore. Keep queue locks held and submit UI through the downstream driver
	// entry point; no recursive layer/add-on submission or ImGui context sharing.
	if (overlay_callbacks.draw)
	{
		const bool submitted=optishade::overlay::DrawIfPrepared(overlayPreparationRequired,overlayPreparationSucceeded,
			[&]() noexcept { return overlay_callbacks.draw(queue,&present_info,vk.QueueSubmit); });
		if(overlayPreparationSucceeded && !submitted)
			reshade::log::message(reshade::log::level::warning,"OptiShade Vulkan menu submission failed.");
	}
	else if (optishade_overlay_queue == queue && optishade_overlay_draw)
	{
		const auto draw = optishade_overlay_draw;
		optishade_overlay_draw = nullptr;
		optishade_overlay_queue = VK_NULL_HANDLE;
		if (!draw(queue, &present_info, vk.QueueSubmit))
			reshade::log::message(reshade::log::level::warning, "OptiShade Vulkan overlay submission failed.");
	}

	// ReShade's command-buffer fences do not prove that the presentation engine
	// has consumed its present-wait semaphore. Relay the final wait chain through
	// per-image terminal semaphores and maintenance1 present fences. If the driver
	// cannot provide explicit presentation completion, the original chain remains
	// untouched. Batched RTX Remix and device-group presents remain excluded.
	std::vector<VkSemaphore> terminal_semaphores;
	std::vector<VkFence> terminal_present_fences;
	bool terminal_relay_submitted = false;
	bool terminal_present_fence_attached = false;
	VkSwapchainPresentFenceInfoEXT terminal_present_fence_info{ VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT };
	const bool unsupported_device_group_present = find_in_structure_chain<VkDeviceGroupPresentInfoKHR>(
		present_info.pNext, VK_STRUCTURE_TYPE_DEVICE_GROUP_PRESENT_INFO_KHR) != nullptr;
	const bool application_present_fence = find_in_structure_chain<VkSwapchainPresentFenceInfoEXT>(
		present_info.pNext, VK_STRUCTURE_TYPE_SWAPCHAIN_PRESENT_FENCE_INFO_EXT) != nullptr;
	const bool protected_queue = (static_cast<uint32_t>(queue_impl->get_type()) & VK_QUEUE_PROTECTED_BIT) != 0;
	if (present_info.waitSemaphoreCount != 0 && queue_impl->present_batch <= 1 &&
		!unsupported_device_group_present && !protected_queue && !application_present_fence &&
		GetOptiShadePresentTerminalSemaphores(present_info.swapchainCount, present_info.pSwapchains,
			present_info.pImageIndices, terminal_semaphores, terminal_present_fences))
	{
		try
		{
			bool previous_present_complete = true;
			for (const VkFence fence : terminal_present_fences)
				if (vk.WaitForFences(device_impl->_orig, 1, &fence, VK_TRUE, UINT64_MAX) != VK_SUCCESS)
				{
					previous_present_complete = false;
					break;
				}
			if (!previous_present_complete)
				throw "previous Vulkan present fence did not complete";
			std::vector<VkPipelineStageFlags> relay_wait_stages(present_info.waitSemaphoreCount, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
			VkSubmitInfo relay_info{ VK_STRUCTURE_TYPE_SUBMIT_INFO };
			relay_info.waitSemaphoreCount = present_info.waitSemaphoreCount;
			relay_info.pWaitSemaphores = present_info.pWaitSemaphores;
			relay_info.pWaitDstStageMask = relay_wait_stages.data();
			relay_info.signalSemaphoreCount = static_cast<uint32_t>(terminal_semaphores.size());
			relay_info.pSignalSemaphores = terminal_semaphores.data();
			const VkResult relay_result = vk.QueueSubmit(queue, 1, &relay_info, VK_NULL_HANDLE);
			optishade::vulkan_submit_observation::Snapshot relay_observation{};
			optishade::vulkan_submit_observation::CaptureLegacy(queue, &relay_info, 1, VK_NULL_HANDLE,
				static_cast<int32_t>(relay_result), optishade::vulkan_submit_observation::Source::PresentSynchronization,
				relay_observation);
			OptiShadeVulkanNotifySubmit(relay_observation);
			if (relay_result == VK_SUCCESS)
			{
				present_info.waitSemaphoreCount = static_cast<uint32_t>(terminal_semaphores.size());
				present_info.pWaitSemaphores = terminal_semaphores.data();
				terminal_relay_submitted = true;
				if (vk.ResetFences(device_impl->_orig, static_cast<uint32_t>(terminal_present_fences.size()), terminal_present_fences.data()) == VK_SUCCESS)
				{
					terminal_present_fence_info.pNext = present_info.pNext;
					terminal_present_fence_info.swapchainCount = static_cast<uint32_t>(terminal_present_fences.size());
					terminal_present_fence_info.pFences = terminal_present_fences.data();
					present_info.pNext = &terminal_present_fence_info;
					terminal_present_fence_attached = true;
				}
				else
					reshade::log::message(reshade::log::level::warning,
						"Vulkan present-fence reset failed; using the relay output once and retiring it after presentation.");
			}
			else
				reshade::log::message(reshade::log::level::warning,
					"Vulkan per-image present relay submission failed with VkResult %d; preserving the existing present wait chain.",
					static_cast<int>(relay_result));
		}
		catch (...)
		{
			reshade::log::message(reshade::log::level::warning,
				"Vulkan per-image present relay could not allocate its wait-stage list; preserving the existing present wait chain.");
		}
	}
	else if (present_info.waitSemaphoreCount != 0 && !unsupported_device_group_present && !protected_queue && queue_impl->present_batch <= 1 && !application_present_fence)
	{
		reshade::log::message(reshade::log::level::warning,
			"Vulkan per-image present relay is unavailable for this swapchain batch; preserving the existing present wait chain.");
	}
	assert(!g_in_dxgi_runtime);
	g_in_dxgi_runtime = true;
	const VkResult result = trampoline(queue, &present_info);
	g_in_dxgi_runtime = false;
	if (terminal_relay_submitted)
		RetireOptiShadePresentTerminalsAfterFailure(present_info.swapchainCount, present_info.pSwapchains,
			present_info.pImageIndices, terminal_semaphores, terminal_present_fences, result, present_info.pResults,
			terminal_present_fence_attached, vk.CreateSemaphore, vk.DestroySemaphore, vk.CreateFence, vk.DestroyFence, vk.WaitForFences);
	optishade::vulkan_present_observation::Snapshot downstream_present{};
	optishade::vulkan_present_observation::Capture(queue, &present_info, static_cast<int32_t>(result), downstream_present);

#if RESHADE_ADDON
	if (result >= VK_SUCCESS && reshade::has_addon_event<reshade::addon_event::finish_present>())
	{
		for (uint32_t i = 0; i < pPresentInfo->swapchainCount; ++i)
		{
			reshade::vulkan::swapchain_impl *const swapchain_impl = device_impl->get_private_data_for_object<VK_OBJECT_TYPE_SWAPCHAIN_KHR>(pPresentInfo->pSwapchains[i]);

			reshade::invoke_addon_event<reshade::addon_event::finish_present>(queue_impl, swapchain_impl);
		}
	}
#endif

	if (present_from_secondary_queue)
		device_impl->_primary_graphics_queue->_mutex.unlock();
	queue_impl->_mutex.unlock();
	// Hand the exact post-effects wait list and final pResults to OptiShade only
	// after releasing ReShade's queue locks; the callback may persist diagnostics.
	OptiShadeVulkanNotifyPresent(downstream_present);

	return result;
}
#endif

#if VK_EXT_full_screen_exclusive
VkResult VKAPI_CALL vkAcquireFullScreenExclusiveModeEXT(VkDevice device, VkSwapchainKHR swapchain)
{
	reshade::vulkan::device_impl *const device_impl = g_vulkan_devices.at(dispatch_key_from_handle(device));
	RESHADE_VULKAN_GET_DEVICE_DISPATCH_PTR(AcquireFullScreenExclusiveModeEXT, device_impl);

#if RESHADE_ADDON
	if (reshade::vulkan::object_data<VK_OBJECT_TYPE_SWAPCHAIN_KHR> *const swapchain_impl = device_impl->get_private_data_for_object<VK_OBJECT_TYPE_SWAPCHAIN_KHR, true>(swapchain))
		if (reshade::invoke_addon_event<reshade::addon_event::set_fullscreen_state>(swapchain_impl, true, swapchain_impl->hmonitor))
			return VK_SUCCESS;
#endif

	return trampoline(device, swapchain);
}
VkResult VKAPI_CALL vkReleaseFullScreenExclusiveModeEXT(VkDevice device, VkSwapchainKHR swapchain)
{
	reshade::vulkan::device_impl *const device_impl = g_vulkan_devices.at(dispatch_key_from_handle(device));
	RESHADE_VULKAN_GET_DEVICE_DISPATCH_PTR(ReleaseFullScreenExclusiveModeEXT, device_impl);

#if RESHADE_ADDON
	if (reshade::vulkan::object_data<VK_OBJECT_TYPE_SWAPCHAIN_KHR> *const swapchain_impl = device_impl->get_private_data_for_object<VK_OBJECT_TYPE_SWAPCHAIN_KHR, true>(swapchain))
		if (reshade::invoke_addon_event<reshade::addon_event::set_fullscreen_state>(swapchain_impl, false, swapchain_impl->hmonitor))
			return VK_SUCCESS;
#endif

	return trampoline(device, swapchain);
}
#endif
