// OptiShade GPL-3.0-or-later. The legacy consumer borrows the same core guides
// as native NR. This bridge owns no GPU resources, histories or presentation.
#include "../../shared/LegacyNrGuideBridge.h"
namespace oslegacy {
using namespace optishade::legacy;
struct Lease {
 HMODULE module=nullptr;NeedsGuides request=nullptr;SubmitGuides submit=nullptr;SubmitCoreSource source=nullptr;
 Lease(){
#if RESHADE_ADDON
  for(const auto& info:reshade::addon_loaded_info){
   if(!info.handle)continue;
   auto abi=reinterpret_cast<GuideAbi>(GetProcAddress(static_cast<HMODULE>(info.handle),"OptiShadeLegacyNrGuideAbi"));
   if(!abi)continue;
   HMODULE hold=nullptr;
   if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(abi),&hold))continue;
   auto needs=reinterpret_cast<NeedsGuides>(GetProcAddress(hold,"OptiShadeLegacyNrNeedsGuides"));
   auto feed=reinterpret_cast<SubmitGuides>(GetProcAddress(hold,"OptiShadeLegacyNrSubmitGuides"));
   auto raw=reinterpret_cast<SubmitCoreSource>(GetProcAddress(hold,"OptiShadeLegacyNrSubmitCoreSource"));
   if(abi()!=GuideVersion||!needs||!feed||!raw){FreeLibrary(hold);continue;}
   // A duplicate consumer is an ownership conflict, not a choice of whichever
   // module happened to be enumerated last.
   if(module){FreeLibrary(hold);FreeLibrary(module);module=nullptr;request=nullptr;submit=nullptr;source=nullptr;return;}
   module=hold;request=needs;submit=feed;source=raw;
  }
#endif
 }
 ~Lease(){if(module)FreeLibrary(module);}
 Lease(const Lease&)=delete;Lease& operator=(const Lease&)=delete;
};
static bool RequiresGuides(reshade::api::effect_runtime* runtime){
 Lease lease;return lease.request&&lease.request(runtime);
}
static void RunSource(reshade::api::effect_runtime* runtime,reshade::api::command_list* cmd,
                      reshade::api::resource_view color,reshade::api::resource_view depth,
                      reshade::api::color_space space,bool reversed,bool logarithmic,float multiplier,bool upsideDown){
 Lease lease;if(!lease.request||!lease.request(runtime)||runtime->get_device()->get_api()!=reshade::api::device_api::d3d10)return;
 auto* device=runtime->get_device();const auto colorResource=device->get_resource_from_view(color),depthResource=device->get_resource_from_view(depth);
 if(!colorResource.handle||!depthResource.handle)return;
 const auto cd=device->get_resource_desc(colorResource),dd=device->get_resource_desc(depthResource);
 const optishade::format_view::DepthMeaning depthMeaning{
  optishade::format_view::DepthEncoding::DeviceZ,reversed,logarithmic,upsideDown,multiplier};
 const optishade::format_view::ViewIdentity view{reinterpret_cast<uint64_t>(runtime),0,0,1,false,true};
 const auto input=osformat::Inspect(cd,device->get_resource_view_desc(color),dd,
  device->get_resource_view_desc(depth),space,depthMeaning,view);
 if(input.reason!=optishade::format_view::Reason::Ready)return;
 CoreSourceFrame frame;frame.runtime=reinterpret_cast<uint64_t>(runtime);frame.commandList=reinterpret_cast<uint64_t>(cmd);
 frame.colorView=color.handle;frame.sourceDepthView=depth.handle;frame.width=cd.texture.width;frame.height=cd.texture.height;
 frame.depthWidth=dd.texture.width;frame.depthHeight=dd.texture.height;frame.reversed=reversed?1u:0u;
 frame.logarithmic=logarithmic?1u:0u;frame.upsideDown=upsideDown?1u:0u;frame.multiplier=multiplier;
 frame.sdr=space==reshade::api::color_space::srgb_nonlinear||space==reshade::api::color_space::unknown?1u:0u;
 if(ValidCoreSource(frame,reinterpret_cast<uint64_t>(runtime),reinterpret_cast<uint64_t>(cmd)))lease.source(&frame);
}
static void Run(reshade::api::effect_runtime* runtime,reshade::api::command_list* cmd,
                reshade::api::resource_view rtv,const osguide::Frame& guides){
 Lease lease;if(!lease.request||!lease.request(runtime))return;
 const auto desc=runtime->get_device()->get_resource_desc(runtime->get_device()->get_resource_from_view(rtv));
 GuideFrame frame;frame.runtime=reinterpret_cast<uint64_t>(runtime);frame.commandList=reinterpret_cast<uint64_t>(cmd);
 frame.colorView=rtv.handle;frame.depthView=guides.depthView.handle;frame.motionView=guides.motionView.handle;
 frame.preparedColorView=guides.colorView.handle;
 frame.generation=guides.generation;frame.width=desc.texture.width;frame.height=desc.texture.height;
 frame.ready=guides.ready?1u:0u;frame.provenance=GuideProvenance::CoreEstimated;
 lease.submit(&frame);
}
}
