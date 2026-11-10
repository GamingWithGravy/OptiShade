/*
 * Copyright (C) 2022 Patrick Mours
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include "openxr_impl_swapchain.hpp"
#include "../../../shared/ViewFamily.h"
#include "dll_log.hpp"
#include "addon_manager.hpp"
#include "runtime_manager.hpp"
#include <algorithm> // std::max

reshade::openxr::swapchain_impl::swapchain_impl(api::device *device, api::command_queue *graphics_queue, XrSession session) :
	api_object_impl(session),
	_device(device),
	_graphics_queue(graphics_queue)
{
	create_effect_runtime(this, graphics_queue, true);
}

reshade::openxr::swapchain_impl::~swapchain_impl()
{
	on_reset();

	destroy_effect_runtime(this);
}

reshade::api::device *reshade::openxr::swapchain_impl::get_device()
{
	return _device;
}

reshade::api::resource reshade::openxr::swapchain_impl::get_back_buffer(uint32_t index)
{
	if (_swapchain_images != nullptr)
		return (*_swapchain_images)[index];

	assert(index == 0);

	return _side_by_side_texture;
}

uint32_t reshade::openxr::swapchain_impl::get_back_buffer_count() const
{
	return _swapchain_images != nullptr ? static_cast<uint32_t>(_swapchain_images->size()) : 1;
}

uint32_t reshade::openxr::swapchain_impl::get_current_back_buffer_index() const
{
	assert(_swapchain_images != nullptr || _swap_index == 0);

	return _swap_index;
}

reshade::api::rect reshade::openxr::swapchain_impl::get_view_rect(uint32_t index, uint32_t view_count) const
{
	if(view_count!=_view_count||index>=_view_count)return {};
    const auto& r=_view_regions[index];
    return {static_cast<int32_t>(r.left),static_cast<int32_t>(r.top),static_cast<int32_t>(r.right),static_cast<int32_t>(r.bottom)};
}
reshade::api::subresource_box reshade::openxr::swapchain_impl::get_view_subresource_box(uint32_t index, uint32_t view_count) const
{
    return view_count==_view_count&&index<_view_count?_view_regions[index]:api::subresource_box{};
}

void reshade::openxr::swapchain_impl::on_init()
{
	// Created in 'on_present' below
	assert(_side_by_side_texture != 0 || _swapchain_images != nullptr);

#if RESHADE_ADDON
	invoke_addon_event<addon_event::init_swapchain>(this, false);
#endif

	init_effect_runtime(this);
}
void reshade::openxr::swapchain_impl::on_reset()
{
	if (_side_by_side_texture == 0 && _swapchain_images == nullptr)
		return;

	reset_effect_runtime(this);

#if RESHADE_ADDON
	invoke_addon_event<addon_event::destroy_swapchain>(this, false);
#endif

	_device->destroy_resource(_side_by_side_texture);
	_side_by_side_texture = {};
	_swapchain_images = nullptr;
	_swap_index = 0;
}

void reshade::openxr::swapchain_impl::on_present(uint32_t view_count, const api::resource *view_textures, const api::subresource_box *view_boxes, const uint32_t *view_layers, const std::vector<api::resource> *swapchain_images, uint32_t swap_index)
{
	if(view_count==0 || view_count>16 || !view_textures || !view_boxes || !view_layers)return;
    std::array<optishade::views::View,16> family{};
    for(uint32_t i=0;i<view_count;++i){
        const auto desc=_device->get_resource_desc(view_textures[i]);
        if(desc.type!=api::resource_type::texture_2d||desc.texture.samples!=1||desc.texture.levels!=1)return;
        if(i && api::format_to_typeless(desc.texture.format)!=api::format_to_typeless(_device->get_resource_desc(view_textures[0]).texture.format))return;
        const auto& b=view_boxes[i];
        family[i]={view_textures[i].handle,desc.texture.width,desc.texture.height,desc.texture.depth_or_layers,view_layers[i],b.left,b.top,b.right,b.bottom};
    }
    optishade::views::Layout familyLayout;
    if(!optishade::views::Build(family.data(),view_count,familyLayout))return;
    _view_count=view_count;
    for(uint32_t i=0;i<view_count;++i){const auto& r=familyLayout.packed[i];_view_regions[i]={r.left,r.top,0,r.right,r.bottom,1};}

	uint64_t layout=view_count;
	for(uint32_t i=0;i<view_count;++i)for(auto v:{view_boxes[i].left,view_boxes[i].top,view_boxes[i].right,view_boxes[i].bottom,view_layers[i]})layout=(layout^v)*1099511628211ull;
	if(layout!=_observation_layout && _observation_changes<32){
		_observation_layout=layout;++_observation_changes;
		reshade::log::message(reshade::log::level::info,"OptiShade OpenXR projection family session=%llu API=%u views=%u layout=%u",static_cast<unsigned long long>(get_native()),static_cast<unsigned>(_device->get_api()),view_count,_observation_changes);
		for(uint32_t i=0;i<view_count;++i)reshade::log::message(reshade::log::level::info,"OptiShade OpenXR projection view=%u rect=%u,%u,%u,%u arrayLayer=%u",i,view_boxes[i].left,view_boxes[i].top,view_boxes[i].right,view_boxes[i].bottom,view_layers[i]);
	}
	const api::resource_desc source_desc = _device->get_resource_desc(view_textures[0]);

	if (source_desc.texture.samples > 1)
		return;

	uint32_t target_width = 0;
	uint32_t region_height = 0;
	for (uint32_t i = 0; i < view_count; ++i)
	{
		target_width += view_boxes[i].width();
		region_height = std::max(region_height, view_boxes[i].height());
	}

	if (target_width == 0 || region_height == 0)
		return;

	// OpenXR's D3D12 contract requires color swapchain images to be in
	// RENDER_TARGET state when released to the runtime. Keep that state even
	// when post-processing runs after xrReleaseSwapchainImage; restoring to
	// PIXEL_SHADER_RESOURCE can leave the compositor (or another API layer)
	// consuming the image in an invalid state.
	const auto before_state = _device->get_api() == api::device_api::d3d12 ? api::resource_usage::render_target : api::resource_usage::copy_source;

	api::command_list *const cmd_list = _graphics_queue->get_immediate_command_list();

	// Check if input is alreay a usable side-by-side texture, in which case no copy is needed
	if (swapchain_images != nullptr && familyLayout.direct &&
		source_desc.texture.width == target_width &&
		source_desc.texture.height == region_height &&
		(source_desc.usage & (api::resource_usage::render_target | api::resource_usage::copy_source)) == (api::resource_usage::render_target | api::resource_usage::copy_source))
	{
		if (swapchain_images != _swapchain_images)
		{
			on_reset();

			_swapchain_images = swapchain_images;

			on_init();
		}

		_swap_index = swap_index;

		assert(view_textures[0] == get_current_back_buffer());
		cmd_list->barrier(view_textures[0], before_state, api::resource_usage::present);

#if RESHADE_ADDON
		invoke_addon_event<addon_event::present>(_graphics_queue, this, nullptr, nullptr, 0, nullptr);
#endif

		present_effect_runtime(this);

		cmd_list->barrier(view_textures[0], api::resource_usage::present, before_state);
	}
	else
	{
		const api::resource_desc target_desc = _side_by_side_texture != 0 ? _device->get_resource_desc(_side_by_side_texture) : api::resource_desc();

		if (_swapchain_images != nullptr ||
			target_width != target_desc.texture.width ||
			region_height != target_desc.texture.height ||
			api::format_to_typeless(source_desc.texture.format) != api::format_to_typeless(target_desc.texture.format))
		{
			reshade::log::message(reshade::log::level::info, "Resizing runtime %p in VR to %ux%u ...", this, target_width, region_height);

			on_reset();

			// Only make format typeless for format variants that support sRGB, so to not break format variants that can be either unorm or float
			const api::format format = (
				source_desc.texture.format == api::format::r8g8b8a8_unorm ||
				source_desc.texture.format == api::format::r8g8b8a8_unorm_srgb ||
				source_desc.texture.format == api::format::b8g8r8a8_unorm ||
				source_desc.texture.format == api::format::b8g8r8a8_unorm_srgb) ? api::format_to_typeless(source_desc.texture.format) : source_desc.texture.format;

			if (!_device->create_resource(
					api::resource_desc(target_width, region_height, 1, 1, format, 1, api::memory_heap::default_, api::resource_usage::render_target | api::resource_usage::copy_source | api::resource_usage::copy_dest),
					nullptr, api::resource_usage::general, &_side_by_side_texture))
			{
				reshade::log::message(reshade::log::level::error, "Failed to create region texture!");
				return;
			}

			_device->set_resource_name(_side_by_side_texture, "ReShade side-by-side texture");

			on_init();
		}

		cmd_list->barrier(_side_by_side_texture, api::resource_usage::general, api::resource_usage::copy_dest);

        // Resource barriers are whole-image operations. Stereo array slices
        // share one image, so transition each image once, not once per eye.
        const auto firstImage=[&](uint32_t i){for(uint32_t j=0;j<i;++j)if(view_textures[j]==view_textures[i])return false;return true;};
        for(uint32_t i=0;i<view_count;++i)if(firstImage(i))cmd_list->barrier(view_textures[i],before_state,api::resource_usage::copy_source);
		// Copy source textures into side-by-side texture
		for (uint32_t i = 0; i < view_count; ++i)
		{

			const api::subresource_box dest_box = get_view_subresource_box(i, view_count);
			cmd_list->copy_texture_region(view_textures[i], view_layers[i], &view_boxes[i], _side_by_side_texture, 0, &dest_box, api::filter_mode::min_mag_mip_point);
		}

		cmd_list->barrier(_side_by_side_texture, api::resource_usage::copy_dest, api::resource_usage::present);

#if RESHADE_ADDON
		invoke_addon_event<addon_event::present>(_graphics_queue, this, nullptr, nullptr, 0, nullptr);
#endif

		present_effect_runtime(this);

		cmd_list->barrier(_side_by_side_texture, api::resource_usage::present, api::resource_usage::copy_source);

        for(uint32_t i=0;i<view_count;++i)if(firstImage(i))cmd_list->barrier(view_textures[i],api::resource_usage::copy_source,api::resource_usage::copy_dest);
		for (uint32_t i = 0; i < view_count; ++i)
		{

			const api::subresource_box dest_box = get_view_subresource_box(i, view_count);
			cmd_list->copy_texture_region(_side_by_side_texture, 0, &dest_box, view_textures[i], view_layers[i], &view_boxes[i], api::filter_mode::min_mag_mip_point);


		}

        for(uint32_t i=0;i<view_count;++i)if(firstImage(i))cmd_list->barrier(view_textures[i],api::resource_usage::copy_dest,before_state);
		cmd_list->barrier(_side_by_side_texture, api::resource_usage::copy_source, api::resource_usage::general);
	}

	_graphics_queue->flush_immediate_command_list();
}
