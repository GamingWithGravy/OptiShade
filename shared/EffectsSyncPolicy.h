#pragma once
#include "EffectsBridge.h"
#include <map>
#include <algorithm>
#include <vector>
#include <string>
#include <cstring>

// Logical settings only. Caller serializes access; no device objects or handles
// can cross targets. A target is an entire projection family, never one eye.
namespace osfx::sync {
enum class Role { Desktop, Headset, Separate, Secondary };
enum class State : uint32_t { Absent, Pending, Loading, Failed, Submitted, Bypassed, Separate, Inactive };
struct Look {
 uint64_t revision=0, reload=0;
 std::string preset;
 bool enabled=true, performance=false;
 std::vector<Command> edits;
 std::vector<std::string> loads;
};
struct Target {
 uint64_t generation=0, selected=0, staged=0, applied=0, reload=0, frames=0, completed=0, heartbeat=0;
 Role role=Role::Secondary;
 State state=State::Pending;
 bool replay=false;
};
class Policy {
 uint64_t serial=0;
public:
 Look look;
 std::map<uintptr_t,Target> targets;
 static bool eligible(Role role) { return role==Role::Desktop || role==Role::Headset; }
 Target& attach(uintptr_t key,Role role) {
  auto [it,inserted]=targets.try_emplace(key);
  if(inserted){it->second.generation=++serial;it->second.role=role;it->second.state=eligible(role)?State::Pending:State::Separate;}
  return it->second;
 }
 void retire(uintptr_t key){targets.erase(key);}
 void seed(const char* preset,bool enabled,bool performance) {
  if(look.revision)return;
  look.preset=preset;look.enabled=enabled;look.performance=performance;look.revision=look.reload=1;
 }
 bool can_edit(const Command& c) const {
  if(c.kind!=Uniform&&c.kind!=Technique)return true;
  if(look.edits.size()<512)return true;
  for(const auto& e:look.edits)if(e.kind==c.kind&&!strcmp(e.effect,c.effect)&&!strcmp(e.name,c.name))return true;
  return false;
 }
 void commit(const Command& c) {
  switch(c.kind){
  case Preset:case HotSwapPreset:look.preset=c.path;look.edits.clear();look.loads.clear();++look.reload;break;
  case SaveAs:look.preset=c.path;[[fallthrough]];
  case Save:case Discard:look.edits.clear();look.loads.clear();++look.reload;break;
  case Load:if(look.loads.size()<128&&std::find(look.loads.begin(),look.loads.end(),c.effect)==look.loads.end())look.loads.emplace_back(c.effect);++look.reload;break;
  case Reload:++look.reload;break;
  case Effects:look.enabled=c.enabled!=0;break;
  case PerformanceMode:look.performance=c.enabled!=0;++look.reload;break;
  case Technique:case Uniform:{
   for(auto& e:look.edits)if(e.kind==c.kind&&!strcmp(e.effect,c.effect)&&!strcmp(e.name,c.name)){e=c;++look.revision;return;}
   if(!can_edit(c))return;
   look.edits.push_back(c);break;
  }
  default:return;
  }
  ++look.revision;
 }
 bool acknowledge(uintptr_t key,uint64_t generation,uint64_t revision,bool loading,bool valid,bool rendered,bool enabled,uint64_t now) {
  auto it=targets.find(key);if(it==targets.end()||it->second.generation!=generation)return false;
  auto& t=it->second;t.heartbeat=now;++t.frames;
  if(!eligible(t.role))return false;
  t.selected=look.revision;
  if(t.replay||revision!=look.revision||t.staged!=revision){t.state=State::Pending;return false;}
  if(loading){t.state=State::Loading;return false;}
  if(!valid){t.state=State::Failed;return false;}
  if(!enabled){t.state=State::Bypassed;t.applied=revision;return true;}
  if(!rendered){t.state=State::Pending;return false;}
  t.state=State::Submitted;t.applied=revision;t.completed=t.frames;return true;
 }
};
}
