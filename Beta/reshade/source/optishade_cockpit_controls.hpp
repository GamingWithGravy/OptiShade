// OptiShade additions, GPL-3.0-or-later.
// The official binary's registered settings callback remains the authority.
// Adapt ONLY the pinned 1.92.5 callback while polling it on its normal UI thread.
// Never share an ImGui context with OptiScaler (it uses another ImGui ABI).
#pragma once
#include "../../shared/CockpitControls.h"
#include <mutex>
#include <cstring>
#include <chrono>
namespace oscockpit {
using namespace optishade::cockpit;
inline std::mutex mutex;
inline Snapshot published;
inline Command pending;
inline uint64_t requestedAt=0, sampledAt=0, nextGeneration=0;
inline uintptr_t owner=0;
inline uint64_t Now(){return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();}
struct Poll {Snapshot state;Command command;};
inline thread_local Poll* active=nullptr;
inline bool Wanted(){std::lock_guard guard(mutex);const auto now=Now();return requestedAt&&now-requestedAt<1500&&now-sampledAt>=200;}
inline void Missing(){std::lock_guard guard(mutex);published.available=0;published.fields=0;pending={};owner=0;sampledAt=Now();}
inline bool SupportedReport(const char* report){
 if(!report)return false;
 // Release numbers are not an interface contract. Require the official report
 // identity and a numeric release header; End also requires every known control.
 constexpr const char* prefix="Glass Cockpit DLSS Fix ";
 if(std::strncmp(report,prefix,std::strlen(prefix))!=0)return false;
 const char* p=report+std::strlen(prefix);
 for(int part=0;part<3;++part){
  if(*p<'0'||*p>'9')return false;
  while(*p>='0'&&*p<='9')++p;
  if(part<2&&*p++!='.')return false;
 }
 return *p=='\n';
}
inline Poll Begin(uintptr_t current){
 std::lock_guard guard(mutex);if(owner!=current){owner=current;published={};published.generation=++nextGeneration;pending={};}
 Poll p;p.state.generation=published.generation;p.state.applied=published.applied;p.command=pending;pending={};return p;
}
inline void End(Poll& p){
 p.state.available=p.state.fields==All&&p.state.smoothing<=100&&p.state.glass<=100&&SupportedReport(p.state.report);
 std::lock_guard guard(mutex);published=p.state;sampledAt=Now();
}
inline bool Edit(uint32_t field,uint32_t& value){
 if(!active)return false;
 active->state.fields|=field;
 const auto& c=active->command;
 if(c.field!=field||c.generation!=active->state.generation)return false;
 value=c.value;active->state.applied=c.sequence;return true;
}
inline bool Check(const char* label,bool* v){
 uint32_t field=std::strcmp(label,"Fix enabled  (Ctrl+Shift+F9)")==0?Enabled:
 std::strcmp(label,"Green tint on fixed screens  (Ctrl+Shift+F11)")==0?Tint:
 (std::strcmp(label,"Flip jitter direction  (Ctrl+Shift+F10)")==0||std::strcmp(label,"Flip jitter direction")==0)?Flipped:0;
 if(!field)return false;
 uint32_t value=*v?1:0;const bool edit=Edit(field,value);*v=value!=0;
 auto& s=active->state;if(field==Enabled)s.enabled=value;else if(field==Tint)s.tint=value;else s.flipped=value;return edit;
}
inline bool Slider(const char* label,int* v,int lo=0,int hi=100){
 const uint32_t field=std::strcmp(label,"Line smoothing")==0?Smoothing:std::strcmp(label,"Glass layer")==0?Glass:0;
 if(!field||lo!=0||(field==Smoothing?(hi!=50&&hi!=100):hi!=100))return false;uint32_t value=static_cast<uint32_t>(*v);const bool edit=Edit(field,value);*v=static_cast<int>(value);
 if(field==Smoothing)active->state.smoothing=value;else active->state.glass=value;return edit;
}
}
