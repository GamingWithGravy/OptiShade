/*
 * Copyright (C) 2024 Patrick Mours
 * SPDX-License-Identifier: BSD-3-Clause OR MIT
 */

#if defined(RESHADE_API_LIBRARY_EXPORT) && RESHADE_GUI && RESHADE_ADDON

#include "dll_log.hpp"
#include "optishade_cockpit_controls.hpp"
#include "imgui_function_table_19250.hpp"
#include "imgui_function_table_19222.hpp"
#include "imgui_function_table_19191.hpp"
#include "imgui_function_table_19180.hpp"
#include "imgui_function_table_19040.hpp"
#include "imgui_function_table_19000.hpp"
#include "imgui_function_table_18971.hpp"
#include "imgui_function_table_18600.hpp"

extern const imgui_function_table_19250 init_imgui_function_table_19250();
#if RESHADE_ADDON >= 2
extern const imgui_function_table_19222 init_imgui_function_table_19222();
extern const imgui_function_table_19191 init_imgui_function_table_19191();
extern const imgui_function_table_19180 init_imgui_function_table_19180();
extern const imgui_function_table_19040 init_imgui_function_table_19040();
extern const imgui_function_table_19000 init_imgui_function_table_19000();
extern const imgui_function_table_18971 init_imgui_function_table_18971();
extern const imgui_function_table_18600 init_imgui_function_table_18600();
#endif

// Force initialization order (has to happen in a single translation unit to be well defined by declaration order) from newest to oldest, so that older function tables can reference newer ones
const imgui_function_table_19250 g_imgui_function_table_19250 = init_imgui_function_table_19250();
#if RESHADE_ADDON >= 2
const imgui_function_table_19222 g_imgui_function_table_19222 = init_imgui_function_table_19222();
const imgui_function_table_19191 g_imgui_function_table_19191 = init_imgui_function_table_19191();
const imgui_function_table_19180 g_imgui_function_table_19180 = init_imgui_function_table_19180();
const imgui_function_table_19040 g_imgui_function_table_19040 = init_imgui_function_table_19040();
const imgui_function_table_19000 g_imgui_function_table_19000 = init_imgui_function_table_19000();
const imgui_function_table_18971 g_imgui_function_table_18971 = init_imgui_function_table_18971();
const imgui_function_table_18600 g_imgui_function_table_18600 = init_imgui_function_table_18600();
#endif

// Wrappers are inert except while the official cockpit callback is being polled.
static const imgui_function_table_19250 cockpit_table=[] {
 auto t=g_imgui_function_table_19250;
 t.Checkbox=[](const char* label,bool* v){return oscockpit::active?oscockpit::Check(label,v):g_imgui_function_table_19250.Checkbox(label,v);};
 t.SliderInt=[](const char* label,int* v,int lo,int hi,const char* format,ImGuiSliderFlags flags){return oscockpit::active?oscockpit::Slider(label,v,lo,hi):g_imgui_function_table_19250.SliderInt(label,v,lo,hi,format,flags);};
 t.Button=[](const char* label,const ImVec2& size){return oscockpit::active?std::strcmp(label,"Copy report")==0:g_imgui_function_table_19250.Button(label,size);};
 t.SetClipboardText=[](const char* value){if(oscockpit::active){if(value)strncpy_s(oscockpit::active->state.report,value,_TRUNCATE);}else g_imgui_function_table_19250.SetClipboardText(value);};
 // Upstream's report section also draws a foreground probe crosshair. Keep
 // all adapter drawing clipped to its off-screen window during hidden polling.
 t.GetForegroundDrawList=[](ImGuiViewport* viewport){return oscockpit::active?ImGui::GetWindowDrawList():g_imgui_function_table_19250.GetForegroundDrawList(viewport);};
 t.TreeNode=[](const char* label){if(oscockpit::active){ImGui::TreePush(label);return true;}return g_imgui_function_table_19250.TreeNode(label);};
 return t;
}();
extern "C" __declspec(dllexport) bool OptiShadeCockpitRead(optishade::cockpit::Snapshot* out,uint32_t bytes){
 if(!out||bytes!=sizeof(*out))return false;
 std::lock_guard guard(oscockpit::mutex);oscockpit::requestedAt=oscockpit::Now();*out=oscockpit::published;
 return out->available&&oscockpit::requestedAt-oscockpit::sampledAt<1500;
}
extern "C" __declspec(dllexport) bool OptiShadeCockpitSend(const optishade::cockpit::Command* in,uint32_t bytes){
 if(!in||bytes!=sizeof(*in)||!optishade::cockpit::Valid(*in))return false;
 std::lock_guard guard(oscockpit::mutex);
 if(!oscockpit::published.available||in->generation!=oscockpit::published.generation||oscockpit::pending.field||
    in->sequence<=oscockpit::published.applied||oscockpit::Now()-oscockpit::sampledAt>=1500)return false;
 oscockpit::pending=*in;return true;
}

extern "C" __declspec(dllexport) const void *ReShadeGetImGuiFunctionTable(uint32_t version)
{
	if (version == 19250)
		return &cockpit_table;
#if RESHADE_ADDON >= 2
	if (version == 19220 || version == 19222)
		return &g_imgui_function_table_19222;
	if (version == 19190 || version == 19191)
		return &g_imgui_function_table_19191;
	if (version == 19180)
		return &g_imgui_function_table_19180;
	if (version == 19040)
		return &g_imgui_function_table_19040;
	if (version >= 19000 && version < 19040)
		return &g_imgui_function_table_19000;
	if (version == 18971)
		return &g_imgui_function_table_18971;
	if (version == 18600)
		return &g_imgui_function_table_18600;
#endif

	reshade::log::message(reshade::log::level::error, "Failed to retrieve ImGui function table, because the requested ImGui version (%u) is not supported.", version);
	return nullptr;
}

#endif
