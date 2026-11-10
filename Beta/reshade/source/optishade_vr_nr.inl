// Original Fusion Engine OpenXR per-eye producer. Only owned, unreleased
// projection images reach this function. No desktop depth or cosmetic FX input.
#include "../../shared/VrProjection.h"
namespace osvrnr {
using namespace reshade;
struct Eye {
 api::effect_runtime* runtime=nullptr;uint32_t view=0;uint64_t identity=0;
 api::resource color{},depth{};api::resource_view rtv{},srv{};
 api::format cf=api::format::unknown,df=api::format::unknown;
 uint32_t width=0,height=0;bool failed=false,quarantined=false;
};
static std::array<Eye,32> eyes{};
static std::mutex eyeMutex;
static void Reason(const char* message){static ULONGLONG last=0;const auto now=GetTickCount64();if(!last||now-last>=5000){last=now;log::message(log::level::info,"OptiShade OpenXR NR: %s",message);}}
static bool Release(Eye& e){if(e.quarantined)return false;if(!e.runtime)return true;auto* d=e.runtime->get_device();if(!osguide::Drain(d,e.runtime->get_command_queue())){e.quarantined=true;e.failed=true;return false;}
 if(e.rtv.handle)d->destroy_resource_view(e.rtv);if(e.srv.handle)d->destroy_resource_view(e.srv);
 if(e.color.handle)d->destroy_resource(e.color);if(e.depth.handle)d->destroy_resource(e.depth);e={};return true;}
static void Retire(api::effect_runtime* r){std::lock_guard guard(eyeMutex);for(auto& e:eyes)if(e.runtime==r)Release(e);}
static void Run(api::effect_runtime* r,const VrNrView* views,uint32_t count){
 std::lock_guard guard(eyeMutex);
 if(!views||!count||count>16||!vr_nr_requested()||r->get_device()->get_api()!=api::device_api::d3d12)return;
 ostaa::Submit submit=nullptr;
 for(const auto* name:{L"winmm.dll",L"dxgi.dll",L"d3d12.dll",L"version.dll",L"dbghelp.dll",L"wininet.dll",L"winhttp.dll",L"OptiScaler.dll"})
  if(auto module=GetModuleHandleW(name))if(auto fn=reinterpret_cast<ostaa::Submit>(GetProcAddress(module,"OptiShadeTaaSubmit"))){submit=fn;break;}
 if(!submit)return;
 auto* device=r->get_device();auto* queue=r->get_command_queue();auto* cmd=queue->get_immediate_command_list();
 const auto refuse=[&](const char* reason){Reason(reason);ostaa::Frame f;f.runtime=reinterpret_cast<uint64_t>(r);f.queue=reinterpret_cast<void*>(queue->get_native());f.viewCount=count;f.projection=1;f.reason=reason;
  {std::lock_guard guard(osguide::mutex);for(const auto& g:osguide::contexts)if(g.runtime==r&&g.view==0){f.generation=g.generation;break;}if(!f.generation)f.generation=++osguide::generations;}
  submit(&f);
 };
 // Family admission happens before modifying either eye. Depth subrect copies
 // are not legal for depth/stencil D3D12 sources: require the complete eye slice.
 for(uint32_t i=0;i<count;++i){const auto& v=views[i];if(!v.color.handle||!v.depth.handle||v.view!=i||v.count!=count){refuse("Waiting for matching owned OpenXR projection depth for every eye");return;}
  const auto c=device->get_resource_desc(v.color),d=device->get_resource_desc(v.depth);
  const auto cf=api::format_to_default_typed(c.texture.format,0);
  const auto& cb=v.colorBox;const auto& db=v.depthBox;
  if(const auto* reason=optishade::vr::Pair({c.texture.width,c.texture.height,c.texture.depth_or_layers,v.colorLayer,cb.left,cb.top,cb.right,cb.bottom},
      {d.texture.width,d.texture.height,d.texture.depth_or_layers,v.depthLayer,db.left,db.top,db.right,db.bottom})){refuse(reason);return;}
  if(c.type!=api::resource_type::texture_2d||d.type!=api::resource_type::texture_2d||c.texture.samples!=1||d.texture.samples!=1||c.texture.levels!=1||d.texture.levels!=1||
   (cf!=api::format::r8g8b8a8_unorm&&cf!=api::format::b8g8r8a8_unorm)||
   (d.texture.format!=api::format::d32_float&&d.texture.format!=api::format::d16_unorm&&d.texture.format!=api::format::d24_unorm_s8_uint)){refuse("Projection NR requires single-sample SDR colour and D16/D24/D32 depth");return;}
 }
 for(uint32_t i=0;i<count;++i){const auto& v=views[i];auto c=device->get_resource_desc(v.color),d=device->get_resource_desc(v.depth);
  const auto cf=api::format_to_default_typed(c.texture.format,0);Eye* e=nullptr;
  for(auto& item:eyes)if(item.runtime==r&&item.view==i){e=&item;break;}
  if(!e)for(auto& item:eyes)if(!item.runtime&&!item.quarantined){e=&item;break;}if(!e)return;
  if(e->runtime&&(e->width!=d.texture.width||e->height!=d.texture.height||e->cf!=cf||e->df!=d.texture.format||e->identity!=v.identity)){
   if(!Release(*e)){Reason("OpenXR GPU retirement failed; restart required");return;}std::lock_guard guard(osguide::mutex);for(auto& g:osguide::contexts)if(g.runtime==r&&g.view==i)if(!osguide::Release(g)){Reason("OpenXR guide retirement failed; restart required");return;}
  }
  if(!e->runtime){e->runtime=r;e->view=i;e->identity=v.identity;e->width=d.texture.width;e->height=d.texture.height;e->cf=cf;e->df=d.texture.format;
   const auto df=d.texture.format==api::format::d32_float?api::format::r32_typeless:d.texture.format==api::format::d16_unorm?api::format::r16_typeless:api::format::r24_g8_typeless;
   const auto sf=d.texture.format==api::format::d32_float?api::format::r32_float:d.texture.format==api::format::d16_unorm?api::format::r16_unorm:api::format::r24_unorm_x8_uint;
   api::resource_desc cd(e->width,e->height,1,1,cf,1,api::memory_heap::default_,api::resource_usage::render_target|api::resource_usage::copy_source|api::resource_usage::copy_dest);
   api::resource_desc dd(e->width,e->height,1,1,df,1,api::memory_heap::default_,api::resource_usage::shader_resource|api::resource_usage::copy_dest);
   e->failed=!device->create_resource(cd,nullptr,api::resource_usage::render_target,&e->color)||!device->create_resource(dd,nullptr,api::resource_usage::shader_resource,&e->depth)||
    !device->create_resource_view(e->color,api::resource_usage::render_target,api::resource_view_desc(cf),&e->rtv)||!device->create_resource_view(e->depth,api::resource_usage::shader_resource,api::resource_view_desc(sf),&e->srv);
   log::message(log::level::info,"OptiShade OpenXR NR eye=%u extent=%ux%u allocated=%u; independent estimated motion",i,e->width,e->height,!e->failed);
  }
  if(e->failed){refuse("OpenXR NR eye resource allocation failed; restart required");return;}
  cmd->barrier(v.color,api::resource_usage::render_target,api::resource_usage::copy_source);
  cmd->barrier(e->color,api::resource_usage::render_target,api::resource_usage::copy_dest);
  cmd->copy_texture_region(v.color,v.colorLayer,&v.colorBox,e->color,0,nullptr,api::filter_mode::min_mag_mip_point);
  cmd->barrier(e->color,api::resource_usage::copy_dest,api::resource_usage::render_target);
  cmd->barrier(v.color,api::resource_usage::copy_source,api::resource_usage::render_target);
  cmd->barrier(v.depth,api::resource_usage::depth_stencil_write,api::resource_usage::copy_source);
  cmd->barrier(e->depth,api::resource_usage::shader_resource,api::resource_usage::copy_dest);
  cmd->copy_texture_region(v.depth,v.depthLayer,nullptr,e->depth,0,nullptr,api::filter_mode::min_mag_mip_point);
  cmd->barrier(e->depth,api::resource_usage::copy_dest,api::resource_usage::shader_resource);
  cmd->barrier(v.depth,api::resource_usage::copy_source,api::resource_usage::depth_stencil_write);
  const auto guides=osguide::Run(r,cmd,e->rtv,e->srv,api::color_space::srgb_nonlinear,v.reversed,false,1.0f,i,true,false,count,v.identity);
  queue->flush_immediate_command_list();
  ostaa::Frame f;f.runtime=reinterpret_cast<uint64_t>(r);f.generation=guides.generation;f.view=i;f.viewCount=count;f.projection=1;f.reason=guides.reason;
  f.queue=reinterpret_cast<void*>(queue->get_native());f.color=reinterpret_cast<void*>(e->color.handle);f.depth=reinterpret_cast<void*>(guides.depth.handle);f.motion=reinterpret_cast<void*>(guides.motion.handle);f.providerReady=guides.ready;
  submit(&f);
  cmd->barrier(e->color,api::resource_usage::render_target,api::resource_usage::copy_source);
  cmd->barrier(v.color,api::resource_usage::render_target,api::resource_usage::copy_dest);
  cmd->copy_texture_region(e->color,0,nullptr,v.color,v.colorLayer,&v.colorBox,api::filter_mode::min_mag_mip_point);
  cmd->barrier(v.color,api::resource_usage::copy_dest,api::resource_usage::render_target);
  cmd->barrier(e->color,api::resource_usage::copy_source,api::resource_usage::render_target);
 }
 queue->flush_immediate_command_list();
}
}
