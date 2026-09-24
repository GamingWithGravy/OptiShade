#include "../../shared/PresetHotSwapPolicy.h"
// OptiShade additions, GPL-3.0-or-later. Upstream runtime remains BSD-3-Clause.
#include "../../shared/EffectsBridge.h"
#include <mutex>
#include <deque>
namespace osfx_impl {
static std::mutex lock;
static osfx::Snapshot snapshot{};
static std::deque<osfx::Command> pending;
static std::deque<std::pair<std::string,uint32_t>> enableAfterLoad;
static std::deque<osfx::Command> edits;
static reshade::api::effect_runtime* owner=nullptr;
static uint64_t serial=0;
static bool requested=true;
static char inspected[128]="";
static void Remember(const osfx::Command& c){
 std::lock_guard guard(lock);for(auto& edit:edits)if(edit.kind==c.kind&&!strcmp(edit.effect,c.effect)&&!strcmp(edit.name,c.name)){edit=c;snapshot.dirty=1;return;}
 edits.push_back(c);snapshot.dirty=1;
}
static void OnEffectsReloaded(reshade::api::effect_runtime* runtime){std::lock_guard guard(lock);if(owner==runtime)pending.insert(pending.begin(),edits.begin(),edits.end());}
static void Retire(reshade::api::effect_runtime* runtime){std::lock_guard guard(lock);if(owner==runtime){owner=nullptr;pending.clear();enableAfterLoad.clear();edits.clear();std::memset(&snapshot,0,sizeof(snapshot));}}
static bool Pump(reshade::api::effect_runtime* runtime,bool loading,bool& performanceMode){
 std::deque<osfx::Command> work;
 {std::lock_guard guard(lock);if(owner&&owner!=runtime)return false;if(!owner){owner=runtime;std::memset(&snapshot,0,sizeof(snapshot));snapshot.version=osfx::Version;snapshot.generation=++serial;pending.clear();enableAfterLoad.clear();edits.clear();}if(loading)return false;work.swap(pending);}
 // Finish requested activation on the render thread even if the menu has been closed.
 for(auto it=enableAfterLoad.begin();it!=enableAfterLoad.end();){
  uint32_t found=0;runtime->enumerate_techniques(it->first.c_str(),[](auto* r,reshade::api::effect_technique t,void* data){
   r->set_technique_state(t,true);osfx::Command c{};c.kind=osfx::Technique;c.enabled=1;size_t n=sizeof(c.effect);r->get_technique_effect_name(t,c.effect,&n);n=sizeof(c.name);r->get_technique_name(t,c.name,&n);Remember(c);++*static_cast<uint32_t*>(data);
  },&found);
  if(found||++it->second>1800)it=enableAfterLoad.erase(it);else ++it;
 }
 bool reload=false;
 while(!work.empty()){
  auto c=work.front();work.pop_front();
  bool ok=true;
  switch(c.kind){
  case osfx::PerformanceMode:{bool dirty;{std::lock_guard guard(lock);dirty=snapshot.dirty!=0;}if(dirty&&c.enabled){ok=false;break;}performanceMode=c.enabled!=0;reload=true;break;}
  case osfx::Effects:runtime->set_effects_state(c.enabled!=0);break;
  case osfx::Reload:reload=true;break;
  case osfx::Load:if(performanceMode){ok=false;break;}runtime->reload_effect_next_frame(c.effect);if(c.enabled)enableAfterLoad.emplace_back(c.effect,0);break;
  case osfx::Inspect:strcpy_s(inspected,c.effect);break;
  case osfx::Save:
  case osfx::SaveAs:{
   if(performanceMode){std::lock_guard guard(lock);++snapshot.saveSerial;snapshot.saveOK=0;ok=false;break;}
   char current[1024]{};size_t length=sizeof(current);runtime->get_current_preset_path(current,&length);
   auto path=std::filesystem::u8path(c.kind==osfx::Save?current:c.path);std::error_code ec;
   ok=path.is_absolute()&&path.extension()==L".ini"&&std::filesystem::is_directory(path.parent_path(),ec);
   // Save-as creates a new file; overwriting an existing look uses Save current instead.
   if(ok&&c.kind==osfx::SaveAs)ok=!std::filesystem::exists(path,ec)&&!ec;
   if(ok){runtime->export_current_preset((c.kind==osfx::Save)?current:c.path);if(reshade::ini_file::find_cache(path))ok=reshade::ini_file::flush_cache(path);ok=ok&&std::filesystem::is_regular_file(path,ec)&&std::filesystem::file_size(path,ec)>0&&!ec;}
   if(ok&&c.kind==osfx::SaveAs)runtime->set_current_preset_path(c.path);
   {std::lock_guard guard(lock);++snapshot.saveSerial;snapshot.saveOK=ok;if(ok){snapshot.dirty=0;edits.clear();}strncpy_s(snapshot.savePath,c.kind==osfx::Save?current:c.path,_TRUNCATE);}
   break;
  }
  case osfx::Discard:{
   char current[1024]{};size_t n=sizeof(current);runtime->get_current_preset_path(current,&n);auto path=std::filesystem::u8path(current);std::error_code ec;
   ok=std::filesystem::is_regular_file(path,ec);
   if(ok){enableAfterLoad.clear();{std::lock_guard guard(lock);edits.clear();snapshot.dirty=0;}reshade::ini_file::clear_cache(path);runtime->set_current_preset_path(current);}break;
  }
  case osfx::HotSwapPreset:{bool dirty;{std::lock_guard guard(lock);dirty=snapshot.dirty!=0;}if(!optishade::hotswap::may_switch(true,loading,dirty)){ok=false;break;}} [[fallthrough]];
  case osfx::Preset:{std::error_code ec;auto path=std::filesystem::u8path(c.path);if(_wcsicmp(path.extension().c_str(),L".ini")==0&&std::filesystem::is_regular_file(path,ec)){enableAfterLoad.clear();{std::lock_guard guard(lock);edits.clear();snapshot.dirty=0;}runtime->set_current_preset_path(c.path);}else ok=false;break;}
  case osfx::Technique:{if(performanceMode){ok=false;break;}auto t=runtime->find_technique(c.effect,c.name);if(t.handle)runtime->set_technique_state(t,c.enabled!=0);else ok=false;break;}
  case osfx::Uniform:{if(performanceMode){ok=false;break;}auto u=runtime->find_uniform_variable(c.effect,c.name);if(!u.handle){ok=false;break;}reshade::api::format type;uint32_t rows,columns,array;runtime->get_uniform_variable_type(u,&type,&rows,&columns,&array);auto n=std::min<uint32_t>(16,rows*columns*std::max(1u,array));if(c.count!=n){ok=false;break;}if((type==reshade::api::format::r32_float||type==reshade::api::format::r16_float))runtime->set_uniform_value_float(u,c.value,n);else if((type==reshade::api::format::r32_sint||type==reshade::api::format::r16_sint)){int32_t v[16]{};for(unsigned i=0;i<n;i++)v[i]=(int32_t)c.value[i];runtime->set_uniform_value_int(u,v,n);}else if((type==reshade::api::format::r32_uint||type==reshade::api::format::r16_uint)){uint32_t v[16]{};for(unsigned i=0;i<n;i++)v[i]=(uint32_t)std::max(0.f,c.value[i]);runtime->set_uniform_value_uint(u,v,n);}else{bool v[16]{};for(unsigned i=0;i<n;i++)v[i]=c.value[i]!=0;runtime->set_uniform_value_bool(u,v,n);}break;}
  default:ok=false;
  }
  if(ok&&(c.kind==osfx::Uniform||c.kind==osfx::Technique))Remember(c);
  std::lock_guard guard(lock);if(ok)++snapshot.applied;else ++snapshot.rejected;
  if(reload||c.kind==osfx::Preset||c.kind==osfx::HotSwapPreset||c.kind==osfx::SaveAs||c.kind==osfx::Discard){pending.insert(pending.begin(),work.begin(),work.end());break;} // Handle invalidation must finish before more edits.
 }
 return reload;
}
static void Publish(reshade::api::effect_runtime* runtime,bool loading,bool compileOK,bool rendered,bool performanceMode){
 std::lock_guard guard(lock);if(owner!=runtime)return;
 snapshot.performanceMode=performanceMode;snapshot.connected=1;snapshot.loading=loading;snapshot.compileOK=compileOK;snapshot.enabled=runtime->get_effects_state();++snapshot.frames;if(rendered)++snapshot.effectFrames;
 if(loading){snapshot.techniques=snapshot.uniforms=0;return;}
 // Publish the active preset every frame, even with the overlay closed. Only throttle the expensive effect lists.
size_t presetSize=sizeof(snapshot.preset);runtime->get_current_preset_path(snapshot.preset,&presetSize);snapshot.preset[1023]=0;
if(!requested||snapshot.frames%6!=0)return;requested=false;
 snapshot.techniques=snapshot.uniforms=snapshot.truncated=0;size_t size=sizeof(snapshot.preset);runtime->get_current_preset_path(snapshot.preset,&size);snapshot.preset[1023]=0;
 runtime->enumerate_techniques(nullptr,[](auto* r,reshade::api::effect_technique t,void*){if(snapshot.techniques==osfx::MaxTechniques){snapshot.truncated=1;return;}auto& out=snapshot.technique[snapshot.techniques++];size_t n=sizeof(out.name);r->get_technique_name(t,out.name,&n);n=sizeof(out.effect);r->get_technique_effect_name(t,out.effect,&n);out.name[127]=out.effect[127]=0;out.enabled=r->get_technique_state(t);},nullptr);
 runtime->enumerate_uniform_variables(inspected[0]?inspected:nullptr,[](auto* r,reshade::api::effect_uniform_variable u,void*){
   char source[64]{};size_t n=sizeof(source);if(r->get_annotation_string_from_uniform_variable(u,"source",source,&n)&&source[0])return;
   if(snapshot.uniforms==osfx::MaxUniforms){snapshot.truncated=1;return;}auto& out=snapshot.uniform[snapshot.uniforms++];out={};n=sizeof(out.name);r->get_uniform_variable_name(u,out.name,&n);n=sizeof(out.effect);r->get_uniform_variable_effect_name(u,out.effect,&n);n=sizeof(out.label);r->get_annotation_string_from_uniform_variable(u,"ui_label",out.label,&n);out.name[127]=out.effect[127]=out.label[127]=0;
   reshade::api::format type;uint32_t rows,columns,array;r->get_uniform_variable_type(u,&type,&rows,&columns,&array);out.count=std::min<uint32_t>(16,rows*columns*std::max(1u,array));
   out.hasRange=r->get_annotation_float_from_uniform_variable(u,"ui_min",&out.minimum,1)&&r->get_annotation_float_from_uniform_variable(u,"ui_max",&out.maximum,1)&&out.maximum>out.minimum;
   if((type==reshade::api::format::r32_float||type==reshade::api::format::r16_float)){out.type=0;r->get_uniform_value_float(u,out.value,out.count);}else if((type==reshade::api::format::r32_sint||type==reshade::api::format::r16_sint)){out.type=1;int32_t v[16]{};r->get_uniform_value_int(u,v,out.count);for(unsigned i=0;i<out.count;i++)out.value[i]=(float)v[i];}else if((type==reshade::api::format::r32_uint||type==reshade::api::format::r16_uint)){out.type=2;uint32_t v[16]{};r->get_uniform_value_uint(u,v,out.count);for(unsigned i=0;i<out.count;i++)out.value[i]=(float)v[i];}else{out.type=3;bool v[16]{};r->get_uniform_value_bool(u,v,out.count);for(unsigned i=0;i<out.count;i++)out.value[i]=v[i]?1.f:0.f;}
 },nullptr);
}
}
extern "C" __declspec(dllexport) bool OptiShadeEffectsRead(osfx::Snapshot* out,uint32_t bytes){if(!out||bytes!=sizeof(*out))return false;std::lock_guard guard(osfx_impl::lock);osfx_impl::requested=true;*out=osfx_impl::snapshot;return out->connected!=0;}
extern "C" __declspec(dllexport) bool OptiShadeEffectsSend(const osfx::Command* in,uint32_t bytes){if(!in||bytes!=sizeof(*in)||in->version!=osfx::Version||in->count>16)return false;std::lock_guard guard(osfx_impl::lock);if(!osfx_impl::owner||in->generation!=osfx_impl::snapshot.generation||osfx_impl::pending.size()>=64)return false;auto c=*in;c.effect[127]=c.name[127]=c.path[1023]=0;osfx_impl::pending.push_back(c);return true;}

