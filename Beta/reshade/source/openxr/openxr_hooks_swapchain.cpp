/*
 * Copyright (C) 2023 Patrick Mours
 * SPDX-License-Identifier: BSD-3-Clause OR MIT
 */

#include "openxr_hooks.hpp"
#include "openxr_impl_swapchain.hpp"
#include "runtime_manager.hpp"
#include "../../../shared/VrProjection.h"
#include "d3d11/d3d11_device.hpp"
#include "d3d11/d3d11_device_context.hpp"
#include "d3d12/d3d12_device.hpp"
#include "d3d12/d3d12_command_queue.hpp"
#include "opengl/opengl_impl_device_context.hpp"
#include "opengl/opengl_impl_type_convert.hpp"
#include "vulkan/vulkan_hooks.hpp"
#include "vulkan/vulkan_impl_device.hpp"
#include "vulkan/vulkan_impl_command_queue.hpp"
#include "dll_log.hpp"
#include "com_utils.hpp"
#include "hook_manager.hpp"
#include "lockfree_linear_map.hpp"
#include <deque>
#include <cstring>
#include <algorithm> // std::find, std::find_if

#define XR_USE_GRAPHICS_API_D3D11
#define XR_USE_GRAPHICS_API_D3D12
#define XR_USE_GRAPHICS_API_OPENGL
#define XR_USE_GRAPHICS_API_VULKAN
#include <openxr/openxr_platform.h>

struct openxr_session
{
	const XrGeneratedDispatchTable *dispatch_table = nullptr;
	reshade::openxr::swapchain_impl *swapchain_impl = nullptr;
    std::vector<XrSwapchain> chains;
};
struct openxr_swapchain
{
	const XrGeneratedDispatchTable *dispatch_table = nullptr;
	XrSwapchainCreateFlags create_flags = 0;
	std::vector<reshade::api::resource> surface_images;
	std::deque<uint32_t> acquired_index;
	uint32_t last_released_index = 0;
    XrSession session=XR_NULL_HANDLE;
    bool pending=false;
};

static lockfree_linear_map<XrSession, openxr_session, 16> s_openxr_sessions;
extern lockfree_linear_map<XrInstance, openxr_instance, 16> g_openxr_instances;
static lockfree_linear_map<XrSwapchain, openxr_swapchain, 16> s_openxr_swapchains;
// Delay only an extension-free release while the private NR producer is active.
// Drain before acquire/destroy/end-frame so the runtime never sees our writes
// after ownership has transferred. Other release-extension chains pass through.
static XrResult flush_release(XrSwapchain chain){auto& d=s_openxr_swapchains.at(chain);if(!d.pending)return XR_SUCCESS;
 XrSwapchainImageReleaseInfo info{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
 auto result=d.dispatch_table->ReleaseSwapchainImage(chain,&info);
 if(XR_SUCCEEDED(result)){d.pending=false;if(!d.acquired_index.empty())d.acquired_index.pop_front();}return result;
}
static XrResult flush_session(XrSession session){for(auto chain:s_openxr_sessions.at(session).chains){auto r=flush_release(chain);if(XR_FAILED(r))return r;}return XR_SUCCESS;}

static const char *session_state_name(XrSessionState state)
{
	switch (state)
	{
	case XR_SESSION_STATE_IDLE: return "IDLE";
	case XR_SESSION_STATE_READY: return "READY";
	case XR_SESSION_STATE_SYNCHRONIZED: return "SYNCHRONIZED";
	case XR_SESSION_STATE_VISIBLE: return "VISIBLE";
	case XR_SESSION_STATE_FOCUSED: return "FOCUSED";
	case XR_SESSION_STATE_STOPPING: return "STOPPING";
	case XR_SESSION_STATE_LOSS_PENDING: return "LOSS_PENDING";
	case XR_SESSION_STATE_EXITING: return "EXITING";
	default: return "UNKNOWN";
	}
}

XrResult XRAPI_CALL xrPollEvent(XrInstance instance, XrEventDataBuffer *eventData)
{
	RESHADE_OPENXR_GET_DISPATCH_PTR(PollEvent);
	const XrResult result = trampoline(instance, eventData);
	if (XR_SUCCEEDED(result) && eventData != nullptr && eventData->type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED)
	{
		const auto *state = reinterpret_cast<const XrEventDataSessionStateChanged *>(eventData);
		reshade::log::message(reshade::log::level::info,
			"OpenXR session state: %s (%d); session=%" PRIx64 "; runtimeTime=%" PRId64,
			session_state_name(state->state), static_cast<int>(state->state), state->session, static_cast<int64_t>(state->time));
	}
	else if (XR_FAILED(result))
	{
		reshade::log::message(reshade::log::level::warning, "OpenXR xrPollEvent failed with error code %d.", static_cast<int>(result));
	}
	return result;
}

XrResult XRAPI_CALL xrBeginSession(XrSession session, const XrSessionBeginInfo *beginInfo)
{
	const openxr_session &data = s_openxr_sessions.at(session);
	RESHADE_OPENXR_GET_DISPATCH_PTR_FROM(BeginSession, data.dispatch_table);
	const int viewConfiguration = beginInfo != nullptr ? static_cast<int>(beginInfo->primaryViewConfigurationType) : 0;
	reshade::log::message(reshade::log::level::info, "OpenXR xrBeginSession requested: session=%" PRIx64 "; viewConfiguration=%d", session, viewConfiguration);
	const XrResult result = trampoline(session, beginInfo);
	reshade::log::message(XR_SUCCEEDED(result) ? reshade::log::level::info : reshade::log::level::warning,
		"OpenXR xrBeginSession result=%d; session=%" PRIx64, static_cast<int>(result), session);
	return result;
}

XrResult XRAPI_CALL xrEndSession(XrSession session)
{
	const openxr_session &data = s_openxr_sessions.at(session);
	RESHADE_OPENXR_GET_DISPATCH_PTR_FROM(EndSession, data.dispatch_table);
	reshade::log::message(reshade::log::level::info, "OpenXR xrEndSession requested: session=%" PRIx64, session);
	const XrResult result = trampoline(session);
	reshade::log::message(XR_SUCCEEDED(result) ? reshade::log::level::info : reshade::log::level::warning,
		"OpenXR xrEndSession result=%d; session=%" PRIx64, static_cast<int>(result), session);
	return result;
}


XrResult XRAPI_CALL xrCreateSession(XrInstance instance, const XrSessionCreateInfo *pCreateInfo, XrSession *pSession)
{
	reshade::log::message(reshade::log::level::info, "Redirecting xrCreateSession(instance = %" PRIx64 ", pCreateInfo = %p, pSession = %p) ...", instance, pCreateInfo, pSession);

	assert(pCreateInfo != nullptr && pSession != nullptr);

	const XrGeneratedDispatchTable &dispatch_table = g_openxr_instances.at(instance).dispatch_table;
	RESHADE_OPENXR_GET_DISPATCH_PTR_FROM(CreateSession, &dispatch_table);

	const XrResult result = trampoline(instance, pCreateInfo, pSession);
	if (XR_FAILED(result))
	{
		reshade::log::message(reshade::log::level::warning, "xrCreateSession failed with error code %d.", static_cast<int>(result));
		return result;
	}

	auto enum_view_configurations = dispatch_table.EnumerateViewConfigurations;
	assert(enum_view_configurations != nullptr);

	uint32_t num_view_configurations = 0;
	enum_view_configurations(instance, pCreateInfo->systemId, num_view_configurations, &num_view_configurations, nullptr);
	std::vector<XrViewConfigurationType> view_configurations(num_view_configurations);
	enum_view_configurations(instance, pCreateInfo->systemId, num_view_configurations, &num_view_configurations, view_configurations.data());

	reshade::openxr::swapchain_impl *swapchain_impl = nullptr;

	if (std::find(view_configurations.begin(), view_configurations.end(), XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) != view_configurations.end())
	{
		// Initialize OpenVR hooks, in case this OpenXR instance is using the SteamVR runtime, so that the VR dashboard overlay can be added
		extern void check_and_init_openvr_hooks();
		check_and_init_openvr_hooks();

		if (const auto binding_d3d11 = find_in_structure_chain<XrGraphicsBindingD3D11KHR>(pCreateInfo, XR_TYPE_GRAPHICS_BINDING_D3D11_KHR))
		{
			if (const auto device_proxy = get_private_pointer_d3dx<D3D11Device>(binding_d3d11->device))
			{
				swapchain_impl = new reshade::openxr::swapchain_impl(device_proxy, device_proxy->_immediate_context, *pSession);
			}
			else
			{
				reshade::log::message(reshade::log::level::warning, "Skipping OpenXR session because it was created without a proxy Direct3D 11 device.");
			}
		}
		else
		if (const auto binding_d3d12 = find_in_structure_chain<XrGraphicsBindingD3D12KHR>(pCreateInfo, XR_TYPE_GRAPHICS_BINDING_D3D12_KHR))
		{
			if (const auto device_proxy = get_private_pointer_d3dx<D3D12Device>(binding_d3d12->device))
			{
				if (com_ptr<D3D12CommandQueue> command_queue_proxy;
					SUCCEEDED(binding_d3d12->queue->QueryInterface(&command_queue_proxy)))
				{
					swapchain_impl = new reshade::openxr::swapchain_impl(device_proxy, command_queue_proxy.get(), *pSession);
				}
			}
			else
			{
				reshade::log::message(reshade::log::level::warning, "Skipping OpenXR session because it was created without a proxy Direct3D 12 device.");
			}
		}
		else
		if (const auto binding_opengl = find_in_structure_chain<XrGraphicsBindingOpenGLWin32KHR>(pCreateInfo, XR_TYPE_GRAPHICS_BINDING_OPENGL_WIN32_KHR))
		{
			extern thread_local reshade::opengl::device_context_impl *g_opengl_context;

			if (g_opengl_context != nullptr)
			{
				assert(reinterpret_cast<HGLRC>(g_opengl_context->get_native()) == binding_opengl->hGLRC);

				swapchain_impl = new reshade::openxr::swapchain_impl(g_opengl_context->get_device(), g_opengl_context, *pSession);
			}
			else
			{
				reshade::log::message(reshade::log::level::warning, "Skipping OpenXR session because it was created without an OpenGL context current.");
			}
		}
		else
		if (const auto binding_vulkan = find_in_structure_chain<XrGraphicsBindingVulkanKHR>(pCreateInfo, XR_TYPE_GRAPHICS_BINDING_VULKAN_KHR))
		{
			extern lockfree_linear_map<void *, reshade::vulkan::device_impl *, 8> g_vulkan_devices;

			if (reshade::vulkan::device_impl *const device = g_vulkan_devices.at(dispatch_key_from_handle(binding_vulkan->device)))
			{
				VkQueue queue_handle = VK_NULL_HANDLE;
				device->_dispatch_table.GetDeviceQueue(binding_vulkan->device, binding_vulkan->queueFamilyIndex, binding_vulkan->queueIndex, &queue_handle);
				assert(queue_handle != VK_NULL_HANDLE);

				if (const auto queue_it = std::find_if(device->_queues.cbegin(), device->_queues.cend(),
						[queue_handle](reshade::vulkan::command_queue_impl *queue) { return queue->_orig == queue_handle; });
					queue_it != device->_queues.cend())
				{
					swapchain_impl = new reshade::openxr::swapchain_impl(device, *queue_it, *pSession);
				}
			}
			else
			{
				reshade::log::message(reshade::log::level::warning, "Skipping OpenXR session because it was created without a known Vulkan device.");
			}
		}
	}
	else
	{
		reshade::log::message(reshade::log::level::warning, "Skipping OpenXR session because the system does not support the stereo view configuration.");
	}

	s_openxr_sessions.emplace(*pSession, openxr_session { &dispatch_table, swapchain_impl });

#if RESHADE_VERBOSE_LOG
	reshade::log::message(reshade::log::level::debug, "Returning OpenXR session %" PRIx64 ".", *pSession);
#endif
	return result;
}

XrResult XRAPI_CALL xrDestroySession(XrSession session)
{
	reshade::log::message(reshade::log::level::info, "Redirecting xrDestroySession(session = %" PRIx64 ") ...", session);

	assert(session != XR_NULL_HANDLE);

	const openxr_session &data = s_openxr_sessions.at(session);
	RESHADE_OPENXR_GET_DISPATCH_PTR_FROM(DestroySession, data.dispatch_table);

	if(auto result=flush_session(session);XR_FAILED(result))return result;
	delete data.swapchain_impl;

	s_openxr_sessions.erase(session);

	return trampoline(session);
}

XrResult XRAPI_CALL xrCreateSwapchain(XrSession session, const XrSwapchainCreateInfo *pCreateInfo, XrSwapchain *pSwapchain)
{
	reshade::log::message(reshade::log::level::info, "Redirecting xrCreateSwapchain(session = %" PRIx64 ", pCreateInfo = %p, pSwapchain = %p) ...", session, pCreateInfo, pSwapchain);

	const openxr_session &data = s_openxr_sessions.at(session);
	RESHADE_OPENXR_GET_DISPATCH_PTR_FROM(CreateSwapchain, data.dispatch_table);

	assert(pCreateInfo != nullptr && pSwapchain != nullptr);

	XrSwapchainCreateInfo create_info = *pCreateInfo;
	// Add required usage flags to create info
	create_info.usageFlags |= XR_SWAPCHAIN_USAGE_TRANSFER_SRC_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT | XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT;

	// Dump swap chain description
	{
		reshade::log::message(reshade::log::level::info, "> Dumping swap chain description:");
		reshade::log::message(reshade::log::level::info, "  +-----------------------------------------+-----------------------------------------+");
		reshade::log::message(reshade::log::level::info, "  | Parameter                               | Value                                   |");
		reshade::log::message(reshade::log::level::info, "  +-----------------------------------------+-----------------------------------------+");
		reshade::log::message(reshade::log::level::info, "  | createFlags                             |"                               " %-#39x |", static_cast<unsigned int>(create_info.createFlags));
		reshade::log::message(reshade::log::level::info, "  | usageFlags                              |"                               " %-#39x |", static_cast<unsigned int>(create_info.usageFlags));
		reshade::log::message(reshade::log::level::info, "  | format                                  |"                              " %-39lld |", create_info.format);
		reshade::log::message(reshade::log::level::info, "  | sampleCount                             |"                                " %-39u |", create_info.sampleCount);
		reshade::log::message(reshade::log::level::info, "  | width                                   |"                                " %-39u |", create_info.width);
		reshade::log::message(reshade::log::level::info, "  | height                                  |"                                " %-39u |", create_info.height);
		reshade::log::message(reshade::log::level::info, "  | faceCount                               |"                                " %-39u |", create_info.faceCount);
		reshade::log::message(reshade::log::level::info, "  | arraySize                               |"                                " %-39u |", create_info.arraySize);
		reshade::log::message(reshade::log::level::info, "  | mipCount                                |"                                " %-39u |", create_info.mipCount);
		reshade::log::message(reshade::log::level::info, "  +-----------------------------------------+-----------------------------------------+");
	}

	const XrResult result = trampoline(session, &create_info, pSwapchain);
	if (XR_FAILED(result))
	{
		reshade::log::message(reshade::log::level::warning, "xrCreateSwapchain failed with error code %d.", static_cast<int>(result));
		return result;
	}

	std::vector<reshade::api::resource> images;

	if (data.swapchain_impl != nullptr)
	{
		auto enum_swapchain_images = data.dispatch_table->EnumerateSwapchainImages;
		assert(enum_swapchain_images != nullptr);

		uint32_t num_images = 0;
		enum_swapchain_images(*pSwapchain, num_images, &num_images, nullptr);
		images.reserve(num_images);

		switch (data.swapchain_impl->get_device()->get_api())
		{
		case reshade::api::device_api::d3d11:
			{
				std::vector<XrSwapchainImageD3D11KHR> images_d3d11(num_images, { XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR });
				enum_swapchain_images(*pSwapchain, num_images, &num_images, reinterpret_cast<XrSwapchainImageBaseHeader *>(images_d3d11.data()));
				for (const XrSwapchainImageD3D11KHR &image_d3d11 : images_d3d11)
					images.push_back({ reinterpret_cast<uintptr_t>(image_d3d11.texture) });
			}
			break;
		case reshade::api::device_api::d3d12:
			{
				std::vector<XrSwapchainImageD3D12KHR> images_d3d12(num_images, { XR_TYPE_SWAPCHAIN_IMAGE_D3D12_KHR });
				enum_swapchain_images(*pSwapchain, num_images, &num_images, reinterpret_cast<XrSwapchainImageBaseHeader *>(images_d3d12.data()));
				for (const XrSwapchainImageD3D12KHR &image_d3d12 : images_d3d12)
					images.push_back({ reinterpret_cast<uintptr_t>(image_d3d12.texture) });
			}
			break;
		case reshade::api::device_api::opengl:
			{
				std::vector<XrSwapchainImageOpenGLKHR> images_opengl(num_images, { XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_KHR });
				enum_swapchain_images(*pSwapchain, num_images, &num_images, reinterpret_cast<XrSwapchainImageBaseHeader *>(images_opengl.data()));
				for (const XrSwapchainImageOpenGLKHR &image_opengl : images_opengl)
					images.push_back(reshade::opengl::make_resource_handle(GL_TEXTURE_2D, image_opengl.image));
			}
			break;
		case reshade::api::device_api::vulkan:
			{
				std::vector<XrSwapchainImageVulkanKHR> images_vulkan(num_images, { XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR });
				enum_swapchain_images(*pSwapchain, num_images, &num_images, reinterpret_cast<XrSwapchainImageBaseHeader *>(images_vulkan.data()));
				for (const XrSwapchainImageVulkanKHR &image_vulkan : images_vulkan)
					images.push_back({ (uint64_t)image_vulkan.image });
			}
			break;
		}
	}

	auto& created=s_openxr_swapchains.emplace(*pSwapchain, openxr_swapchain { data.dispatch_table, create_info.createFlags, std::move(images) });
    created.session=session;s_openxr_sessions.at(session).chains.push_back(*pSwapchain);

#if RESHADE_VERBOSE_LOG
	reshade::log::message(reshade::log::level::debug, "Returning OpenXR swap chain %" PRIx64 ".", *pSwapchain);
#endif
	return result;
}

XrResult XRAPI_CALL xrDestroySwapchain(XrSwapchain swapchain)
{
	reshade::log::message(reshade::log::level::info, "Redirecting xrDestroySwapchain(swapchain = %" PRIx64 ") ...", swapchain);

	const openxr_swapchain &data = s_openxr_swapchains.at(swapchain);
	RESHADE_OPENXR_GET_DISPATCH_PTR_FROM(DestroySwapchain, data.dispatch_table);

	if(auto result=flush_release(swapchain);XR_FAILED(result))return result;
    if(auto* owner=s_openxr_sessions.at(data.session).swapchain_impl)reshade::process_vr_nr(owner,nullptr,0);
    auto& chains=s_openxr_sessions.at(data.session).chains;chains.erase(std::remove(chains.begin(),chains.end(),swapchain),chains.end());
	s_openxr_swapchains.erase(swapchain);

	return trampoline(swapchain);
}

XrResult XRAPI_CALL xrAcquireSwapchainImage(XrSwapchain swapchain, const XrSwapchainImageAcquireInfo *pAcquireInfo, uint32_t *pIndex)
{
	openxr_swapchain &data = s_openxr_swapchains.at(swapchain);
	RESHADE_OPENXR_GET_DISPATCH_PTR_FROM(AcquireSwapchainImage, data.dispatch_table);

	if(auto result=flush_release(swapchain);XR_FAILED(result))return result;
	const XrResult result = trampoline(swapchain, pAcquireInfo, pIndex);
	if (XR_FAILED(result))
		return result;

	data.acquired_index.push_back(*pIndex);

	return result;
}

XrResult XRAPI_CALL xrReleaseSwapchainImage(XrSwapchain swapchain, const XrSwapchainImageReleaseInfo *pReleaseInfo)
{
	openxr_swapchain &data = s_openxr_swapchains.at(swapchain);
	RESHADE_OPENXR_GET_DISPATCH_PTR_FROM(ReleaseSwapchainImage, data.dispatch_table);

    const auto& session=s_openxr_sessions.at(data.session);
    if(!(data.create_flags&(XR_SWAPCHAIN_CREATE_STATIC_IMAGE_BIT|XR_SWAPCHAIN_CREATE_PROTECTED_CONTENT_BIT))&&!data.pending&&!data.acquired_index.empty()&&pReleaseInfo&&pReleaseInfo->type==XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO&&!pReleaseInfo->next&&session.swapchain_impl&&
       session.swapchain_impl->get_device()->get_api()==reshade::api::device_api::d3d12&&reshade::vr_nr_requested()){
      data.last_released_index=data.acquired_index.front();data.pending=true;return XR_SUCCESS;
    }
    if(auto result=flush_release(swapchain);XR_FAILED(result))return result;
	const XrResult result = trampoline(swapchain, pReleaseInfo);
	if (XR_FAILED(result))
		return result;

	// 'xrReleaseSwapchainImage' releases the last image from 'xrWaitSwapchainImage', which will implicitly wait on the oldest acquired swapchain image which has not yet been successfully waited on
	if(!data.acquired_index.empty()){data.last_released_index = data.acquired_index.front();
	data.acquired_index.pop_front();}

	return result;
}

XrResult XRAPI_CALL xrEndFrame(XrSession session, const XrFrameEndInfo *frameEndInfo)
{
	const openxr_session &data = s_openxr_sessions.at(session);
	reshade::vr_frame_presented();

	if (data.swapchain_impl != nullptr)
	{
		for (uint32_t layer_index = 0; layer_index < frameEndInfo->layerCount; ++layer_index)
		{
			if (frameEndInfo->layers[layer_index]->type == XR_TYPE_COMPOSITION_LAYER_PROJECTION)
			{
				const XrCompositionLayerProjection *const layer = reinterpret_cast<const XrCompositionLayerProjection *>(frameEndInfo->layers[layer_index]);

				if(!layer->viewCount||layer->viewCount>16||!layer->views)continue;
				uint32_t view_count = 0;
				temp_mem<reshade::api::resource, 2> view_textures(layer->viewCount);
				temp_mem<reshade::api::subresource_box, 2> view_boxes(layer->viewCount);
				temp_mem<uint32_t, 2> view_layers(layer->viewCount);
				const std::vector<reshade::api::resource> *swapchain_images = nullptr;
				uint32_t swap_index = 0;

				assert(layer->viewCount != 0);

				for (; view_count < layer->viewCount; ++view_count)
				{
					XrSwapchainSubImage const &sub_image = layer->views[view_count].subImage;

					const openxr_swapchain &swapchain = s_openxr_swapchains.at(sub_image.swapchain);

					if ((swapchain.create_flags & (XR_SWAPCHAIN_CREATE_STATIC_IMAGE_BIT|XR_SWAPCHAIN_CREATE_PROTECTED_CONTENT_BIT)) != 0)
						break; // Cannot apply effects to a static image, since it would just stack on top of the previous result every frame

                    if(swapchain.last_released_index>=swapchain.surface_images.size() || sub_image.imageRect.offset.x<0 || sub_image.imageRect.offset.y<0 || sub_image.imageRect.extent.width<=0 || sub_image.imageRect.extent.height<=0 || int64_t(sub_image.imageRect.offset.x)+sub_image.imageRect.extent.width>INT32_MAX || int64_t(sub_image.imageRect.offset.y)+sub_image.imageRect.extent.height>INT32_MAX)break;
					view_textures[view_count] = swapchain.surface_images[swapchain.last_released_index];

					assert(sub_image.imageRect.offset.x >= 0 && sub_image.imageRect.offset.y >= 0 && sub_image.imageRect.extent.width >= 0 && sub_image.imageRect.extent.height >= 0);

					reshade::api::subresource_box &view_box = view_boxes[view_count];
					view_box.left = static_cast<uint32_t>(sub_image.imageRect.offset.x);
					view_box.top = static_cast<uint32_t>(sub_image.imageRect.offset.y);
					view_box.front = 0;
					view_box.right = static_cast<uint32_t>(sub_image.imageRect.offset.x + sub_image.imageRect.extent.width);
					view_box.bottom = static_cast<uint32_t>(sub_image.imageRect.offset.y + sub_image.imageRect.extent.height);
					view_box.back = 1;

					view_layers[view_count] = sub_image.imageArrayIndex;

					swapchain_images = &swapchain.surface_images;
					if (view_textures[view_count] != view_textures[0] || view_layers[view_count] != view_layers[0])
						swapchain_images = nullptr;
					swap_index = swapchain.last_released_index;
				}

				if (view_count == layer->viewCount)
				{
					bool held=true,matched=true;std::vector<reshade::VrNrView> nr(view_count);
                    for(uint32_t eye=0;eye<view_count;++eye){const auto& projection=layer->views[eye];
                     const auto& color=s_openxr_swapchains.at(projection.subImage.swapchain);held &= color.pending;
                     const XrCompositionLayerDepthInfoKHR* depth=nullptr;
                     for(auto* next=reinterpret_cast<const XrBaseInStructure*>(projection.next);next;next=next->next)
                      if(next->type==XR_TYPE_COMPOSITION_LAYER_DEPTH_INFO_KHR){depth=reinterpret_cast<const XrCompositionLayerDepthInfoKHR*>(next);break;}
                     if(!depth||!optishade::vr::Range(depth->minDepth,depth->maxDepth,depth->nearZ,depth->farZ)){matched=false;continue;}
                     const auto& source=s_openxr_swapchains.at(depth->subImage.swapchain);const auto& box=depth->subImage.imageRect;
                     if(source.session!=session||!source.pending||source.last_released_index>=source.surface_images.size()||box.offset.x<0||box.offset.y<0||box.extent.width<=0||box.extent.height<=0||int64_t(box.offset.x)+box.extent.width>INT32_MAX||int64_t(box.offset.y)+box.extent.height>INT32_MAX){matched=false;continue;}
                     auto& out=nr[eye];out.color=view_textures[eye];out.depth=source.surface_images[source.last_released_index];out.colorLayer=view_layers[eye];out.depthLayer=depth->subImage.imageArrayIndex;
                     out.colorBox=view_boxes[eye];out.depthBox={uint32_t(box.offset.x),uint32_t(box.offset.y),0,uint32_t(box.offset.x+box.extent.width),uint32_t(box.offset.y+box.extent.height),1};
                     out.view=eye;out.count=view_count;out.reversed=depth->nearZ>depth->farZ;out.identity=uint64_t(projection.subImage.swapchain)^(uint64_t(depth->subImage.swapchain)*1099511628211ull);
                     for(auto coordinate:{out.colorLayer,out.depthLayer,out.colorBox.left,out.colorBox.top,out.colorBox.right,out.colorBox.bottom})out.identity=(out.identity^coordinate)*1099511628211ull;
                     for(float projectionValue:{projection.fov.angleLeft,projection.fov.angleRight,projection.fov.angleUp,projection.fov.angleDown,depth->nearZ,depth->farZ}){uint32_t bits=0;std::memcpy(&bits,&projectionValue,sizeof(bits));out.identity=(out.identity^bits)*1099511628211ull;}
                    }
                    if(held)reshade::process_vr_nr(data.swapchain_impl,nr.data(),view_count);
                    else if(reshade::vr_nr_requested()){static thread_local ULONGLONG last=0;auto now=GetTickCount64();if(!last||now-last>=5000){last=now;reshade::log::message(reshade::log::level::info,"OptiShade OpenXR NR waiting: ownedColor=%u matchedProjectionDepth=%u views=%u",held,matched,view_count);}}
                    if(!held){if(auto result=flush_session(session);XR_FAILED(result))return result;}
                    data.swapchain_impl->on_present(view_count, view_textures.p, view_boxes.p, view_layers.p, swapchain_images, swap_index);
					break;
				}
			}
		}
	}

	if(auto result=flush_session(session);XR_FAILED(result))return result;
	RESHADE_OPENXR_GET_DISPATCH_PTR_FROM(EndFrame, data.dispatch_table);
	return trampoline(session, frameEndInfo);
}
