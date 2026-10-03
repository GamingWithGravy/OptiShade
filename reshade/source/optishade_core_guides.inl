// Original OptiShade core prerequisites, GPL-3.0-or-later.
// Owned by the runtime, independent of cosmetic effects and their compiler.
#include "../res/shaders/optishade_guides.generated.h"
#include "../../shared/GuideHistory.h"
namespace osguide {
using namespace reshade;
struct Frame {
 api::resource sourceDepth{}, depth{}, motion{};
 api::resource_view depthView{}, motionView{};
 uint64_t generation=0;
 bool ready=false;
 const char* reason="Core guides not requested";
};
struct Context {
 api::effect_runtime* runtime=nullptr;
 api::device* device=nullptr;
 api::command_queue* queue=nullptr;
 api::resource resources[6]{}; // colour, previous, current, coarse motion, depth, motion
 api::resource_view srv[6]{}, uav[6]{};
 api::pipeline_layout layout{};
 api::pipeline pipeline[3]{};
 
 
 
 uint32_t width=0,height=0;
 api::format format=api::format::unknown;
 uint64_t generation=0,last=0;
 bool warm=false,failed=false;
 optishade::guides::History history;
};
static std::array<Context,8> contexts{};
static std::mutex mutex;
static uint64_t generations=0;
static void Release(Context& c) {
 if(c.queue)c.queue->wait_idle(); // Only on retirement/reconfiguration, never for timing.
 if(c.device){
  for(auto p:c.pipeline)if(p.handle)c.device->destroy_pipeline(p);


  if(c.layout.handle)c.device->destroy_pipeline_layout(c.layout);
  for(unsigned i=0;i<6;i++){
   if(c.srv[i].handle)c.device->destroy_resource_view(c.srv[i]);
   if(c.uav[i].handle)c.device->destroy_resource_view(c.uav[i]);
   if(c.resources[i].handle)c.device->destroy_resource(c.resources[i]);
  }
 }
 c={};
}
static void Retire(api::effect_runtime* runtime) {
 std::lock_guard guard(mutex);for(auto& c:contexts)if(c.runtime==runtime)Release(c);
}
static bool Allocate(Context& c,api::effect_runtime* runtime,const api::resource_desc& source) {
 c.runtime=runtime;c.device=runtime->get_device();c.queue=runtime->get_command_queue();
 c.width=source.texture.width;c.height=source.texture.height;c.format=source.texture.format;c.generation=++generations;
 const unsigned w=c.width,h=c.height;
 for(unsigned i=0;i<6;i++){
  const bool coarse=i>=1&&i<=3;
  const auto format=i==0?api::format_to_default_typed(c.format,0):i<=2?api::format::r16g16b16a16_float:i==4?api::format::r32_float:api::format::r16g16_float;
  auto usage=api::resource_usage::shader_resource|api::resource_usage::copy_source|api::resource_usage::copy_dest;
  if(i>=2)usage|=api::resource_usage::unordered_access;
  api::resource_desc desc(coarse?(w+3)/4:w,coarse?(h+3)/4:h,1,1,format,1,api::memory_heap::default_,usage);
  if(!c.device->create_resource(desc,nullptr,api::resource_usage::shader_resource,&c.resources[i]))return false;
  if(!c.device->create_resource_view(c.resources[i],api::resource_usage::shader_resource,api::resource_view_desc(format),&c.srv[i]))return false;
  if(i>=2&&!c.device->create_resource_view(c.resources[i],api::resource_usage::unordered_access,api::resource_view_desc(format),&c.uav[i]))return false;
 }
 const bool vk=c.device->get_api()==api::device_api::vulkan;
 api::pipeline_layout_param params[3];
 api::descriptor_range ranges[2]={{0,0,0,5,api::shader_stage::compute,1,api::descriptor_type::shader_resource_view},
                                  {5,0,0,4,api::shader_stage::compute,1,api::descriptor_type::unordered_access_view}};
 params[0].type=api::pipeline_layout_param_type::push_descriptors_with_ranges;
 params[0].descriptor_table={vk?2u:1u,ranges};
 if(vk){params[1]=api::constant_range{0,0,0,8,api::shader_stage::compute};}
 else{
  // D3D12 push updates allocate a fresh transient table each call. Separate
  // SRV/UAV root parameters prevent the second update discarding the first.
  ranges[1].binding=0;
  params[1].type=api::pipeline_layout_param_type::push_descriptors_with_ranges;
  params[1].descriptor_table={1,ranges+1};
  params[2]=api::constant_range{0,0,0,8,api::shader_stage::compute};
 }
 if(!c.device->create_pipeline_layout(vk?2:3,params,&c.layout))return false;

 const unsigned char* code[3]={vk?shaders::Prepare_spirv:shaders::Prepare_dxil,vk?shaders::Estimate_spirv:shaders::Estimate_dxil,vk?shaders::Resolve_spirv:shaders::Resolve_dxil};
 const size_t bytes[3]={vk?sizeof(shaders::Prepare_spirv):sizeof(shaders::Prepare_dxil),vk?sizeof(shaders::Estimate_spirv):sizeof(shaders::Estimate_dxil),vk?sizeof(shaders::Resolve_spirv):sizeof(shaders::Resolve_dxil)};
 const char* names[3]={"Prepare","Estimate","Resolve"};
 for(unsigned i=0;i<3;i++){
  api::shader_desc shader{code[i],bytes[i],names[i]};
  api::pipeline_subobject sub{api::pipeline_subobject_type::compute_shader,1,&shader};
  if(!c.device->create_pipeline(c.layout,1,&sub,&c.pipeline[i]))return false;
 }
 return true;
}
static Frame Run(api::effect_runtime* runtime,api::command_list* cmd,api::resource_view rtv,api::resource_view sceneDepth,
                 api::color_space space,bool reversed,bool logarithmic,float multiplier) {
 std::lock_guard guard(mutex);Frame result{};
 auto* device=runtime->get_device();auto* queue=runtime->get_command_queue();
 const auto api=device->get_api();
 if(api!=api::device_api::d3d12&&api!=api::device_api::vulkan){result.reason="Core guides require D3D12 or Vulkan";return result;}
 if(cmd!=queue->get_immediate_command_list()){result.reason="Core guides require the owning immediate command list";return result;}
 if(space!=api::color_space::srgb_nonlinear&&space!=api::color_space::unknown){result.reason="Core guides require SDR output";return result;}
 if(!sceneDepth.handle){result.reason="No real scene depth binding";return result;}
 const auto color=device->get_resource_from_view(rtv);result.sourceDepth=device->get_resource_from_view(sceneDepth);
 if(!color.handle||!result.sourceDepth.handle){result.reason="Current colour/depth resource unavailable";return result;}
 const auto cd=device->get_resource_desc(color),dd=device->get_resource_desc(result.sourceDepth);
 if(cd.type!=api::resource_type::texture_2d||dd.type!=api::resource_type::texture_2d||cd.texture.width<64||cd.texture.height<64||
    cd.texture.width>5120||cd.texture.height>2160||cd.texture.width!=dd.texture.width||cd.texture.height!=dd.texture.height||
    cd.texture.samples!=1||dd.texture.samples!=1||cd.texture.depth_or_layers!=1||dd.texture.depth_or_layers!=1||cd.texture.levels!=1){
  result.reason="Scene depth/output extent, sample or view contract does not match";return result;
 }
 const auto typed=api::format_to_default_typed(cd.texture.format,0);
 if(typed!=api::format::r8g8b8a8_unorm&&typed!=api::format::b8g8r8a8_unorm){result.reason="Core guides require SDR RGBA8/BGRA8";return result;}
 Context* c=nullptr;for(auto& item:contexts)if(item.runtime==runtime){c=&item;break;}
 if(!c)for(auto& item:contexts)if(!item.runtime){c=&item;break;}
 if(!c){result.reason="Core guide runtime capacity reached";return result;}
 if(c->runtime&&(c->width!=cd.texture.width||c->height!=cd.texture.height||c->format!=cd.texture.format))Release(*c);
 if(!c->runtime){
  if(!Allocate(*c,runtime,cd)){
   Release(*c);c->runtime=runtime;c->width=cd.texture.width;c->height=cd.texture.height;c->format=cd.texture.format;c->failed=true;
   result.reason="Core guide allocation/pipeline creation failed; resize or retry after disabling NR";return result;
  }
  log::message(log::level::info,"Core guides v1: created generation=%llu extent=%ux%u; original estimated-motion provider",c->generation,c->width,c->height);
 }
 result.generation=c->generation;
 if(c->failed){result.reason="Core guide allocation failed; disable NR before retrying";return result;}
 uint64_t fg=0;
 if(api==api::device_api::d3d12)for(const auto* name:{L"winmm.dll",L"dxgi.dll",L"d3d12.dll",L"version.dll",L"dbghelp.dll",L"wininet.dll",L"winhttp.dll",L"OptiScaler.dll"})
  if(auto module=GetModuleHandleW(name))if(auto key=reinterpret_cast<uint64_t(*)()>(GetProcAddress(module,"OptiShadeTaaHistoryKey"))){fg=key();break;}
 const auto now=GetTickCount64();
 if(!std::isfinite(multiplier)||multiplier<=0){c->warm=false;result.reason="Invalid scene depth multiplier";return result;}
 if(c->history.Observe(reversed,logarithmic,multiplier,fg,now)){c->warm=false;c->generation=++generations;}
 c->last=now;result.generation=c->generation;
 struct Constants{uint32_t width,height,warm,reversed,logarithmic;float multiplier;uint32_t pad0,pad1;} values{c->width,c->height,c->warm?1u:0u,reversed?1u:0u,logarithmic?1u:0u,multiplier,0,0};
 cmd->barrier(color,api::resource_usage::render_target,api::resource_usage::copy_source);
 cmd->barrier(c->resources[0],api::resource_usage::shader_resource,api::resource_usage::copy_dest);
 cmd->copy_resource(color,c->resources[0]);
 cmd->barrier(c->resources[0],api::resource_usage::copy_dest,api::resource_usage::shader_resource);
 cmd->barrier(color,api::resource_usage::copy_source,api::resource_usage::render_target);
 api::resource_view srvs[]={c->srv[0],sceneDepth,c->srv[1],c->srv[2],c->srv[3]};
 api::resource_view uavs[]={c->uav[2],c->uav[3],c->uav[4],c->uav[5]};
 const bool vk=device->get_api()==api::device_api::vulkan;
 cmd->push_constants(api::shader_stage::compute,c->layout,vk?1:2,0,8,&values);
 api::descriptor_table_update writes[]={{{},0,0,5,api::descriptor_type::shader_resource_view,srvs},
                                       {{},vk?5u:0u,0,4,api::descriptor_type::unordered_access_view,uavs}};
 cmd->push_descriptors(api::shader_stage::compute,c->layout,0,writes[0]);
 cmd->push_descriptors(api::shader_stage::compute,c->layout,vk?0:1,writes[1]);

 for(unsigned pass=0;pass<3;pass++){
  const unsigned first=pass+2,last=pass==2?5:first;
  for(unsigned i=first;i<=last;i++)cmd->barrier(c->resources[i],api::resource_usage::shader_resource,api::resource_usage::unordered_access);
  cmd->bind_pipeline(api::pipeline_stage::compute_shader,c->pipeline[pass]);
  cmd->dispatch(pass==2?(c->width+7)/8:((c->width+3)/4+7)/8,pass==2?(c->height+7)/8:((c->height+3)/4+7)/8,1);
  for(unsigned i=first;i<=last;i++)cmd->barrier(c->resources[i],api::resource_usage::unordered_access,api::resource_usage::shader_resource);
 }
 cmd->barrier(c->resources[2],api::resource_usage::shader_resource,api::resource_usage::copy_source);
 cmd->barrier(c->resources[1],api::resource_usage::shader_resource,api::resource_usage::copy_dest);
 cmd->copy_resource(c->resources[2],c->resources[1]);
 cmd->barrier(c->resources[1],api::resource_usage::copy_dest,api::resource_usage::shader_resource);
 cmd->barrier(c->resources[2],api::resource_usage::copy_source,api::resource_usage::shader_resource);
 result.depth=c->resources[4];result.motion=c->resources[5];result.depthView=c->srv[4];result.motionView=c->srv[5];
 result.ready=c->warm;c->warm=true;result.reason=result.ready?"Core estimated guides ready":"Core guide history warming up";
 return result;
}
}
