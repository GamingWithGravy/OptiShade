/*
 * Copyright (C) 2024 Patrick Mours
 * SPDX-License-Identifier: BSD-3-Clause
 */

#pragma once

#include "reshade_api_device.hpp"

namespace reshade
{
 struct VrNrView {
  api::resource color{},depth{};
  uint32_t colorLayer=0,depthLayer=0,view=0,count=0;
  api::subresource_box colorBox{},depthBox{};
  bool reversed=false;
  uint64_t identity=0;
 };
 bool vr_nr_requested();
 // Tells OptiShade NR a headset frame was presented (once per xrEndFrame).
 void vr_frame_presented();
 void process_vr_nr(api::swapchain*,const VrNrView*,uint32_t);
	void create_effect_runtime(api::swapchain *swapchain, api::command_queue *graphics_queue, bool vr = false);
	void destroy_effect_runtime(api::swapchain *swapchain);

	void init_effect_runtime(api::swapchain *swapchain);
	void reset_effect_runtime(api::swapchain *swapchain);
	void present_effect_runtime(api::swapchain *swapchain);
}
