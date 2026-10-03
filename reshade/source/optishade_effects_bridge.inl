#include "../../shared/SnapshotRequest.h"
#include "../../shared/PresetHotSwapPolicy.h"
#include "../../shared/PresetTechniquePolicy.h"
// OptiShade additions, GPL-3.0-or-later. Upstream runtime remains BSD-3-Clause.
#include "../../shared/EffectsBridge.h"
#include "../../shared/EffectReadiness.h"
#include "../../shared/VulkanOwnerBridge.h"
#include <mutex>
#include <deque>
#include "../../shared/EffectsSyncPolicy.h"
namespace osfx_impl {
static std::mutex lock;
static osfx::Snapshot snapshot{};
static uint64_t heartbeat=0;
static std::deque<osfx::Command> pending;
static std::deque<std::pair<std::string,uint64_t>> enableAfterLoad;
static std::deque<osfx::Command> edits;
static reshade::api::effect_runtime* owner=nullptr;
static uint64_t serial=0;
static osfx::sync::Policy delivery;
static int requestedVrLink=-1;
static int VrLink(){std::lock_guard guard(lock);return requestedVrLink;}
static optishade::capture::Lifecycle capture;
static uint64_t CaptureRequestLocked(){
 if(!owner || !heartbeat || GetTickCount64()-heartbeat>10000)return 0;
 auto id=capture.request(snapshot.generation,GetTickCount64());
 if(id)reshade::log::message(reshade::log::level::info,"SnapShot request=%llu generation=%llu accepted",id,snapshot.generation);
 return id;
}
static void SnapshotComplete(uint64_t id,bool ok,const std::string& path){
 std::lock_guard guard(lock);
 if(capture.finish(id,ok,GetTickCount64())){
  strncpy_s(capture.status.detail,path.c_str(),_TRUNCATE);
  ++snapshot.snapshotSerial;snapshot.snapshotOK=ok;strncpy_s(snapshot.snapshotPath,path.c_str(),_TRUNCATE);
  reshade::log::message(reshade::log::level::info,"SnapShot request=%llu completed ok=%u",id,ok);
 }
}
static uint64_t TakeSnapshotRequest(reshade::api::effect_runtime* runtime){
 std::lock_guard guard(lock);if(owner!=runtime)return 0;
 return capture.take(snapshot.generation,GetTickCount64());
}
static bool SnapshotStage(uint64_t id,optishade::capture::Stage stage,uint32_t width,uint32_t height){
 std::lock_guard guard(lock);
 if(!capture.advance(id,stage,GetTickCount64()))return false;
 capture.status.width=width;capture.status.height=height;
 reshade::log::message(reshade::log::level::info,"SnapShot request=%llu stage=%u size=%ux%u",id,static_cast<unsigned>(stage),width,height);
 return true;
}
// Publication and cancellation are serialized. A cancelled worker may finish
// encoding its private partial file, but can never publish it as a saved shot.
static bool SnapshotPublish(uint64_t id,const std::filesystem::path& temporary,const std::filesystem::path& final){
 std::lock_guard guard(lock);capture.expire(GetTickCount64());
 if(!capture.active(id))return false;
 if(!MoveFileExW(temporary.c_str(),final.c_str(),MOVEFILE_WRITE_THROUGH)){
  capture.status.error=GetLastError();return false;
 }
 if(!optishade::snapshot::receipt(final,g_target_executable_path.parent_path())){
  std::error_code ec;std::filesystem::remove(final,ec);
  capture.status.error=ec ? ec.value() : ERROR_WRITE_FAULT;return false;
 }
 // Mark saved while holding the same lock as Cancel: publication won the race.
 capture.status.stage=optishade::capture::Stage::Saved;capture.status.updated=GetTickCount64();
 strncpy_s(capture.status.detail,final.u8string().c_str(),_TRUNCATE);
 ++snapshot.snapshotSerial;snapshot.snapshotOK=1;strncpy_s(snapshot.snapshotPath,final.u8string().c_str(),_TRUNCATE);
 reshade::log::message(reshade::log::level::info,"SnapShot request=%llu atomic publication and receipt complete",id);
 return true;
}
static bool requested=true;
static char inspected[128]="";
static bool ApplyEdit(reshade::api::effect_runtime* runtime,const osfx::Command& c,bool performanceMode){
 bool ok=true;switch(c.kind){
  case osfx::Technique:{if(performanceMode){ok=false;break;}auto t=runtime->find_technique(c.effect,c.name);if(t.handle)runtime->set_technique_state(t,c.enabled!=0);else ok=false;break;}
  case osfx::Uniform:{if(performanceMode){ok=false;break;}auto u=runtime->find_uniform_variable(c.effect,c.name);if(!u.handle){ok=false;break;}reshade::api::format type;uint32_t rows,columns,array;runtime->get_uniform_variable_type(u,&type,&rows,&columns,&array);auto n=std::min<uint32_t>(16,rows*columns*std::max(1u,array));if(c.count!=n){ok=false;break;}if((type==reshade::api::format::r32_float||type==reshade::api::format::r16_float))runtime->set_uniform_value_float(u,c.value,n);else if((type==reshade::api::format::r32_sint||type==reshade::api::format::r16_sint)){int32_t v[16]{};for(unsigned i=0;i<n;i++)v[i]=(int32_t)c.value[i];runtime->set_uniform_value_int(u,v,n);}else if((type==reshade::api::format::r32_uint||type==reshade::api::format::r16_uint)){uint32_t v[16]{};for(unsigned i=0;i<n;i++)v[i]=(uint32_t)std::max(0.f,c.value[i]);runtime->set_uniform_value_uint(u,v,n);}else{bool v[16]{};for(unsigned i=0;i<n;i++)v[i]=c.value[i]!=0;runtime->set_uniform_value_bool(u,v,n);}break;}
 default:ok=false;break;
 }return ok;
}
static bool Ready(reshade::api::effect_runtime* runtime,bool compileOK){
 if(!compileOK)return false;
 char path[1024]{};size_t n=sizeof(path);runtime->get_current_preset_path(path,&n);
 auto preset=std::filesystem::u8path(path);std::error_code ec;
 if(!std::filesystem::is_regular_file(preset,ec)||ec)return false;
 osfx::sync::Look expectedLook;{std::lock_guard guard(lock);auto it=delivery.targets.find(reinterpret_cast<uintptr_t>(runtime));if(it!=delivery.targets.end()&&osfx::sync::Policy::eligible(it->second.role))expectedLook=delivery.look;}
 if(!expectedLook.preset.empty()&&(!std::filesystem::equivalent(preset,std::filesystem::u8path(expectedLook.preset),ec)||ec))return false;
 std::vector<std::string> expected;auto& ini=reshade::ini_file::load_cache(preset);
 if(!ini.has({},"Techniques"))return false;
 ini.get({},"Techniques",expected);
 std::vector<optishade::preset::Technique> compiled;
 runtime->enumerate_techniques(nullptr,[](auto* r,reshade::api::effect_technique t,void* data){
  auto& list=*static_cast<std::vector<optishade::preset::Technique>*>(data);
  if(list.size()>=osfx::MaxTechniques)return;
  char effect[128]{},name[128]{};size_t n=sizeof(effect);r->get_technique_effect_name(t,effect,&n);n=sizeof(name);r->get_technique_name(t,name,&n);
  list.push_back({effect,name,r->get_technique_state(t)});
 },&compiled);
 for(auto& technique:compiled)for(const auto& edit:expectedLook.edits)
  if(edit.kind==osfx::Technique&&technique.effect==edit.effect&&technique.name==edit.name){
   if(technique.enabled!=(edit.enabled!=0))return false;
   technique.enabled=true; // Intentional disabling is a satisfied requested edit.
  }
 auto audit=optishade::preset::audit(expected,compiled,true,compiled.size()>=osfx::MaxTechniques,true,false);
 // Disabled techniques can be an intentional unsaved edit. Every referenced
 // technique must still resolve on this runtime; rendering is checked separately.
 return audit.missing.empty();
}
static void Reset(reshade::api::effect_runtime* runtime){
 std::lock_guard guard(lock);auto it=delivery.targets.find(reinterpret_cast<uintptr_t>(runtime));
 if(it!=delivery.targets.end()){auto role=it->second.role;delivery.retire(it->first);delivery.attach(reinterpret_cast<uintptr_t>(runtime),role);}
}
// One invocation is one full desktop image or XR projection family. Calls use
// only this runtime's handles, on its own render thread, outside the bridge lock.
static bool CanRender(reshade::api::effect_runtime* runtime){std::lock_guard guard(lock);auto it=delivery.targets.find(reinterpret_cast<uintptr_t>(runtime));return it==delivery.targets.end()||!osfx::sync::Policy::eligible(it->second.role)||(!it->second.replay&&it->second.staged==delivery.look.revision);}
static bool Follow(reshade::api::effect_runtime* runtime,bool loading,bool& performanceMode){
 osfx::sync::Look desired;osfx::sync::Target target;
 const auto key=reinterpret_cast<uintptr_t>(runtime);
 {std::lock_guard guard(lock);target=delivery.targets.at(key);if(loading||!osfx::sync::Policy::eligible(target.role)||!delivery.look.revision||(target.staged==delivery.look.revision&&!target.replay))return false;desired=delivery.look;}
 if(!osfx::sync::Policy::eligible(target.role)||!desired.revision||loading)return false;
 if(target.staged==desired.revision&&!target.replay)return false;
 if(target.reload!=desired.reload){
  bool reload=performanceMode!=desired.performance;performanceMode=desired.performance;
  if(!desired.preset.empty())runtime->set_current_preset_path(desired.preset.c_str());
  for(const auto& effect:desired.loads)runtime->reload_effect_next_frame(effect.c_str());
  runtime->set_effects_state(desired.enabled);
  std::lock_guard guard(lock);auto& t=delivery.targets.at(key);
  if(t.generation==target.generation){t.reload=desired.reload;t.staged=0;t.replay=true;t.state=osfx::sync::State::Loading;}
  return reload;
 }
 bool ok=true;
 for(const auto& c:desired.edits)ok=ApplyEdit(runtime,c,performanceMode)&&ok;
 runtime->set_effects_state(desired.enabled);
 {std::lock_guard guard(lock);auto& t=delivery.targets.at(key);if(t.generation==target.generation){t.staged=desired.revision;t.replay=false;t.state=ok?osfx::sync::State::Pending:osfx::sync::State::Failed;}}
 return false;
}
static void Remember(const osfx::Command& c){
 std::lock_guard guard(lock);for(auto& edit:edits)if(edit.kind==c.kind&&!strcmp(edit.effect,c.effect)&&!strcmp(edit.name,c.name)){edit=c;snapshot.dirty=1;return;}
 if(edits.size()<512)edits.push_back(c);snapshot.dirty=1;
}
static void OnEffectsReloaded(reshade::api::effect_runtime* runtime){std::lock_guard guard(lock);auto it=delivery.targets.find(reinterpret_cast<uintptr_t>(runtime));if(it!=delivery.targets.end())it->second.replay=true;if(owner==runtime&&pending.size()+edits.size()<=576)pending.insert(pending.begin(),edits.begin(),edits.end());}
static void Retire(reshade::api::effect_runtime* runtime){std::lock_guard guard(lock);delivery.retire(reinterpret_cast<uintptr_t>(runtime));if(owner==runtime){owner=nullptr;capture.cancel(capture.status.request,GetTickCount64());pending.clear();enableAfterLoad.clear();std::memset(&snapshot,0,sizeof(snapshot));}}
static bool Pump(reshade::api::effect_runtime* runtime,bool loading,bool& performanceMode,bool vr,bool linked,const std::string& configName){
 if(!vr && runtime->get_device() && runtime->get_device()->get_api()==reshade::api::device_api::vulkan) {
  if(!OptiShadeIsOwnedVulkanWindow(runtime->get_hwnd()))return false;
  std::lock_guard guard(lock);if(owner && owner!=runtime){capture.cancel(capture.status.request,GetTickCount64());owner=nullptr;pending.clear();enableAfterLoad.clear();edits.clear();}
 }
 std::deque<osfx::Command> work;
 const auto key=reinterpret_cast<uintptr_t>(runtime);
 {std::lock_guard guard(lock);
  auto role=vr?(linked?osfx::sync::Role::Headset:osfx::sync::Role::Separate):osfx::sync::Role::Desktop;
  // Named secondary runtime configs are pop-outs/auxiliary sessions, not proof
  // of an independent intended image. Do not broadcast to them or a mirror.
  if(configName!=(vr?"ReShadeVR":"ReShade") && !(!vr&&runtime->get_device()&&runtime->get_device()->get_api()==reshade::api::device_api::vulkan&&OptiShadeIsOwnedVulkanWindow(runtime->get_hwnd())))role=osfx::sync::Role::Secondary;
  auto previous=delivery.targets.find(key);
  if(previous!=delivery.targets.end()&&previous->second.role!=role){
   delivery.retire(key);
   if(owner==runtime){snapshot.rejected+=static_cast<uint32_t>(pending.size());pending.clear();enableAfterLoad.clear();
    edits.clear();if(osfx::sync::Policy::eligible(role))edits.assign(delivery.look.edits.begin(),delivery.look.edits.end());
    snapshot.dirty=!edits.empty();snapshot.generation=++serial;capture.cancel(capture.status.request,GetTickCount64());}
  }
  auto& t=delivery.attach(key,role);
  if(role==osfx::sync::Role::Secondary)return false;
  if(!owner){owner=runtime;std::memset(&snapshot,0,sizeof(snapshot));snapshot.version=osfx::Version;snapshot.generation=++serial;
   char path[1024]{};size_t n=sizeof(path);runtime->get_current_preset_path(path,&n);
   if(osfx::sync::Policy::eligible(role)){delivery.seed(path,runtime->get_effects_state(),performanceMode);edits.assign(delivery.look.edits.begin(),delivery.look.edits.end());}
   else edits.clear();snapshot.dirty=!edits.empty();
  }
 }
 {std::lock_guard guard(lock);auto& t=delivery.targets.at(key);if(osfx::sync::Policy::eligible(t.role)&&!delivery.look.revision){char path[1024]{};size_t n=sizeof(path);runtime->get_current_preset_path(path,&n);delivery.seed(path,runtime->get_effects_state(),performanceMode);}}
 const bool followReload=Follow(runtime,loading,performanceMode);
 {std::lock_guard guard(lock);if(owner!=runtime||loading||followReload)return followReload;work.swap(pending);}

 // Finish requested activation on the render thread even if the menu has been closed.
 for(auto it=enableAfterLoad.begin();it!=enableAfterLoad.end();){
  uint32_t found=0;runtime->enumerate_techniques(it->first.c_str(),[](auto* r,reshade::api::effect_technique t,void* data){
   r->set_technique_state(t,true);osfx::Command c{};c.kind=osfx::Technique;c.enabled=1;size_t n=sizeof(c.effect);r->get_technique_effect_name(t,c.effect,&n);n=sizeof(c.name);r->get_technique_name(t,c.name,&n);Remember(c);{std::lock_guard guard(lock);auto it=delivery.targets.find(reinterpret_cast<uintptr_t>(r));if(it!=delivery.targets.end()&&osfx::sync::Policy::eligible(it->second.role))delivery.commit(c);}++*static_cast<uint32_t*>(data);
  },&found);
  if(found || GetTickCount64()-it->second>=120000)it=enableAfterLoad.erase(it);else ++it;
 }
 bool reload=false;
 while(!work.empty()){
  auto c=work.front();work.pop_front();
  bool ok=true;
  {std::lock_guard guard(lock);if(!delivery.can_edit(c)){++snapshot.rejected;continue;}}
  switch(c.kind){
  case osfx::TakeSnapshot:ok=false;break;
  case osfx::LinkVR:{std::lock_guard guard(lock);if(snapshot.dirty){ok=false;break;}requestedVrLink=c.enabled?1:0;break;} // Capture bypasses the cosmetic command queue.
  case osfx::PerformanceMode:{bool dirty;{std::lock_guard guard(lock);dirty=snapshot.dirty!=0;}if(dirty&&c.enabled){ok=false;break;}performanceMode=c.enabled!=0;reload=true;break;}
  case osfx::Effects:runtime->set_effects_state(c.enabled!=0);break;
  case osfx::Reload:reload=true;break;
  case osfx::Load:if(performanceMode){ok=false;break;}runtime->reload_effect_next_frame(c.effect);if(c.enabled)enableAfterLoad.emplace_back(c.effect,GetTickCount64());break;
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
  case osfx::Technique:case osfx::Uniform:ok=ApplyEdit(runtime,c,performanceMode);break;
  default:ok=false;
  }
  if(ok&&(c.kind==osfx::Uniform||c.kind==osfx::Technique))Remember(c);
  std::lock_guard guard(lock);if(ok){
   ++snapshot.applied;auto& t=delivery.targets.at(key);if(osfx::sync::Policy::eligible(t.role))delivery.commit(c);t.staged=delivery.look.revision;t.reload=delivery.look.reload;t.state=osfx::sync::State::Pending;
  }else ++snapshot.rejected;
  if(reload||c.kind==osfx::Preset||c.kind==osfx::HotSwapPreset||c.kind==osfx::SaveAs||c.kind==osfx::Discard){pending.insert(pending.begin(),work.begin(),work.end());break;} // Handle invalidation must finish before more edits.
 }
 return reload;
}
static void Publish(reshade::api::effect_runtime* runtime,bool loading,bool compileOK,bool rendered,bool performanceMode){
 bool needsAudit=false,previousFailed=false;
 {std::lock_guard guard(lock);auto it=delivery.targets.find(reinterpret_cast<uintptr_t>(runtime));
  previousFailed=it!=delivery.targets.end()&&it->second.state==osfx::sync::State::Failed;
  needsAudit=!previousFailed&&it!=delivery.targets.end()&&it->second.state!=osfx::sync::State::Submitted&&it->second.state!=osfx::sync::State::Bypassed;
 }
 const bool valid=!previousFailed&&!loading&&compileOK&&(!needsAudit||Ready(runtime,compileOK));
 std::lock_guard guard(lock);
 const auto key=reinterpret_cast<uintptr_t>(runtime);auto it=delivery.targets.find(key);
 if(it!=delivery.targets.end()){
  auto& t=it->second;const auto before=t.state;
  delivery.acknowledge(key,t.generation,t.staged,loading,valid&&t.state!=osfx::sync::State::Failed,rendered,runtime->get_effects_state(),GetTickCount64());
  if(before!=t.state)reshade::log::message(reshade::log::level::info,"OptiShade FX delivery role=%u generation=%llu selected=%llu applied=%llu state=%u submittedFrame=%llu",static_cast<unsigned>(t.role),t.generation,t.selected,t.applied,static_cast<unsigned>(t.state),t.completed);
 }
 snapshot.desktop={};snapshot.headset={};
 for(const auto& item:delivery.targets){const auto& t=item.second;
  if(t.role==osfx::sync::Role::Secondary)continue;
  auto& d=t.role==osfx::sync::Role::Desktop?snapshot.desktop:snapshot.headset;
  d={t.generation,delivery.look.revision,t.applied,t.frames,t.completed,static_cast<uint32_t>(t.role==osfx::sync::Role::Separate?osfx::sync::State::Separate:(t.heartbeat&&GetTickCount64()-t.heartbeat>5000?osfx::sync::State::Inactive:t.state))};
 }
 if(owner!=runtime)return;
 heartbeat=GetTickCount64();
 snapshot.performanceMode=performanceMode;snapshot.connected=1;snapshot.loading=loading;snapshot.compileOK=compileOK;snapshot.enabled=runtime->get_effects_state();++snapshot.frames;if(rendered)++snapshot.effectFrames;
 if(loading){snapshot.techniques=snapshot.uniforms=0;snapshot.presetState=0;snapshot.presetReport[0]=0;return;}
 // Publish the active preset every frame, even with the overlay closed. Only throttle the expensive effect lists.
size_t presetSize=sizeof(snapshot.preset);runtime->get_current_preset_path(snapshot.preset,&presetSize);snapshot.preset[1023]=0;
if(!requested||snapshot.frames%6!=0)return;requested=false;
 snapshot.techniques=snapshot.uniforms=snapshot.truncated=0;size_t size=sizeof(snapshot.preset);runtime->get_current_preset_path(snapshot.preset,&size);snapshot.preset[1023]=0;
 runtime->enumerate_techniques(nullptr,[](auto* r,reshade::api::effect_technique t,void*){if(snapshot.techniques==osfx::MaxTechniques){snapshot.truncated=1;return;}auto& out=snapshot.technique[snapshot.techniques++];size_t n=sizeof(out.name);r->get_technique_name(t,out.name,&n);n=sizeof(out.effect);r->get_technique_effect_name(t,out.effect,&n);out.name[127]=out.effect[127]=0;out.enabled=r->get_technique_state(t);},nullptr);
 std::vector<std::string> expected;
 const auto presetPath=std::filesystem::u8path(snapshot.preset);std::error_code presetError;
 const bool presetReadable=std::filesystem::is_regular_file(presetPath,presetError)&&!presetError&&reshade::ini_file::load_cache(presetPath).has({},"Techniques");
 if(presetReadable)reshade::ini_file::load_cache(presetPath).get({},"Techniques",expected);
 std::vector<optishade::preset::Technique> compiled;compiled.reserve(snapshot.techniques);
 for(uint32_t i=0;i<snapshot.techniques;++i){const auto& t=snapshot.technique[i];compiled.push_back({t.effect,t.name,t.enabled!=0});}
 auto audit=optishade::preset::audit(expected,compiled,compileOK,snapshot.truncated!=0,snapshot.enabled!=0,snapshot.dirty!=0);
 snapshot.presetState=static_cast<uint32_t>(presetReadable?audit.state:optishade::preset::State::Unknown);
 snapshot.presetRequested=audit.requested;snapshot.presetApplied=audit.applied;snapshot.presetMissing=static_cast<uint32_t>(audit.missing.size());
 std::string report;for(const auto& missing:audit.missing){if(!report.empty())report+="; ";report+=missing;}
 if(report.size()>=sizeof(snapshot.presetReport))report.resize(sizeof(snapshot.presetReport)-5),report+=" ...";
 strncpy_s(snapshot.presetReport,report.c_str(),_TRUNCATE);
 runtime->enumerate_uniform_variables(inspected[0]?inspected:nullptr,[](auto* r,reshade::api::effect_uniform_variable u,void*){
   char source[64]{};size_t n=sizeof(source);if(r->get_annotation_string_from_uniform_variable(u,"source",source,&n)&&source[0])return;
   if(snapshot.uniforms==osfx::MaxUniforms){snapshot.truncated=1;return;}auto& out=snapshot.uniform[snapshot.uniforms++];out={};n=sizeof(out.name);r->get_uniform_variable_name(u,out.name,&n);n=sizeof(out.effect);r->get_uniform_variable_effect_name(u,out.effect,&n);n=sizeof(out.label);r->get_annotation_string_from_uniform_variable(u,"ui_label",out.label,&n);out.name[127]=out.effect[127]=out.label[127]=0;
   reshade::api::format type;uint32_t rows,columns,array;r->get_uniform_variable_type(u,&type,&rows,&columns,&array);out.count=std::min<uint32_t>(16,rows*columns*std::max(1u,array));
   out.hasRange=r->get_annotation_float_from_uniform_variable(u,"ui_min",&out.minimum,1)&&r->get_annotation_float_from_uniform_variable(u,"ui_max",&out.maximum,1)&&out.maximum>out.minimum;
   if((type==reshade::api::format::r32_float||type==reshade::api::format::r16_float)){out.type=0;r->get_uniform_value_float(u,out.value,out.count);}else if((type==reshade::api::format::r32_sint||type==reshade::api::format::r16_sint)){out.type=1;int32_t v[16]{};r->get_uniform_value_int(u,v,out.count);for(unsigned i=0;i<out.count;i++)out.value[i]=(float)v[i];}else if((type==reshade::api::format::r32_uint||type==reshade::api::format::r16_uint)){out.type=2;uint32_t v[16]{};r->get_uniform_value_uint(u,v,out.count);for(unsigned i=0;i<out.count;i++)out.value[i]=(float)v[i];}else{out.type=3;bool v[16]{};r->get_uniform_value_bool(u,v,out.count);for(unsigned i=0;i<out.count;i++)out.value[i]=v[i]?1.f:0.f;}
 },nullptr);
}
}
extern "C" __declspec(dllexport) bool OptiShadeEffectsRead(osfx::Snapshot* out,uint32_t bytes){if(!out||bytes!=sizeof(*out))return false;std::lock_guard guard(osfx_impl::lock);osfx_impl::requested=true;*out=osfx_impl::snapshot;return out->connected!=0 && optishade::fxready::alive(GetTickCount64(),osfx_impl::heartbeat);}
extern "C" __declspec(dllexport) bool OptiShadeEffectsSend(const osfx::Command* in,uint32_t bytes){if(!in||bytes!=sizeof(*in)||in->version!=osfx::Version||in->count>16)return false;std::lock_guard guard(osfx_impl::lock);if(!osfx_impl::owner||in->generation!=osfx_impl::snapshot.generation||osfx_impl::pending.size()>=64)return false;if(in->kind==osfx::TakeSnapshot)return osfx_impl::CaptureRequestLocked()!=0;auto c=*in;c.effect[127]=c.name[127]=c.path[1023]=0;if(c.kind==osfx::Preset||c.kind==osfx::HotSwapPreset){while(!osfx_impl::pending.empty()&&(osfx_impl::pending.back().kind==osfx::Preset||osfx_impl::pending.back().kind==osfx::HotSwapPreset))osfx_impl::pending.pop_back();}osfx_impl::pending.push_back(c);return true;}


extern "C" __declspec(dllexport) uint64_t OptiShadeSnapshotRequest(){std::lock_guard guard(osfx_impl::lock);return osfx_impl::CaptureRequestLocked();}
extern "C" __declspec(dllexport) bool OptiShadeSnapshotRead(optishade::capture::Status* out,uint32_t bytes){
 if(!out||bytes!=sizeof(*out))return false;std::lock_guard guard(osfx_impl::lock);
 osfx_impl::capture.expire(GetTickCount64());*out=osfx_impl::capture.status;return true;
}
extern "C" __declspec(dllexport) bool OptiShadeSnapshotCancel(uint64_t id){std::lock_guard guard(osfx_impl::lock);return osfx_impl::capture.cancel(id,GetTickCount64());}
