// OptiShade output association and lifetime policy. GPL-3.0-or-later.
#pragma once
#include <cstdint>
#include <map>
#include <vector>
#include <algorithm>
namespace optishade::mfg::output {
struct Key { uint64_t route=0; uint32_t view=0; bool operator<(const Key& b)const{return route<b.route||(route==b.route&&view<b.view);} bool operator==(const Key& b)const{return route==b.route&&view==b.view;} };
struct Ticket {Key key{};uint64_t viewGeneration=0,target=0,targetGeneration=0,epoch=0;};
enum class State:uint32_t {Missing=0,Bound=1,Ambiguous=2,Retiring=3,Restart=4};
struct Snapshot {State state=State::Missing;Ticket owner{};uint64_t accepted=0,saved=0,acceptedTick=0,sampleTick=0;uint32_t frames=0;};
// Caller serializes access. No GPU resources, COM references, focus/window-size
// guesses or frame-generation implementation are owned by this policy.
class Owner {
 struct View {uint64_t generation=1,device=0,buffer=0;bool enabled=false,retiring=false,restart=false;};
 struct Target {uint64_t device=0,generation=1,tick=0;std::vector<uint64_t> buffers;};
 std::map<Key,View> views;std::map<uint64_t,Target> targets;Snapshot result;uint64_t epoch=1;
 bool same(const Ticket&a,const Ticket&b)const{return a.key==b.key&&a.viewGeneration==b.viewGeneration&&a.target==b.target&&a.targetGeneration==b.targetGeneration;}
 void invalidate(State state,const Ticket& next={}){if(result.state!=state||!same(result.owner,next)){result={};result.state=state;result.owner=next;result.owner.epoch=++epoch;}}
public:
 Ticket Begin(Key key){auto&v=views[key];if(result.state==State::Bound&&result.owner.key==key&&result.owner.viewGeneration==v.generation)return result.owner;return {key,v.generation};}
 bool Current(const Ticket&t)const{auto i=views.find(t.key);if(i==views.end()||i->second.generation!=t.viewGeneration||i->second.retiring||i->second.restart)return false;if(t.target){auto target=targets.find(t.target);if(target==targets.end()||target->second.generation!=t.targetGeneration)return false;}return true;}
 void Options(const Ticket&t,bool enabled){if(Current(t))views[t.key].enabled=enabled;}
 void Tag(const Ticket&t,uint64_t device,uint64_t buffer){if(Current(t)){auto&v=views[t.key];v.device=device;v.buffer=buffer;}}
 void Present(uint64_t target,uint64_t device,std::vector<uint64_t> buffers,uint64_t tick){if(!target||!device||buffers.empty())return;auto&i=targets[target];std::sort(buffers.begin(),buffers.end());if(i.device!=device||i.buffers!=buffers){++i.generation;i.device=device;i.buffers=std::move(buffers);}i.tick=tick;Read(tick);}
 void Destroy(uint64_t target){targets.erase(target);if(result.owner.target==target)invalidate(State::Missing);}
 void Retire(const Ticket&t){auto i=views.find(t.key);if(i!=views.end()&&i->second.generation==t.viewGeneration){i->second.retiring=true;if(result.owner.key==t.key)invalidate(State::Retiring);}}
 void Released(const Ticket&t,bool providerCompleted){auto i=views.find(t.key);if(i==views.end()||i->second.generation!=t.viewGeneration)return;auto&v=i->second;if(!providerCompleted){v.restart=true;v.retiring=false;invalidate(State::Restart);return;}const auto next=v.generation+1;v={};v.generation=next;if(result.state!=State::Bound||result.owner.key==t.key)invalidate(State::Missing);}
 Snapshot Read(uint64_t now){
  Ticket candidate;unsigned count=0;bool retiring=false,restart=false;
  for(auto&[key,v]:views){retiring|=v.retiring;restart|=v.restart;if(!v.enabled||v.retiring||v.restart||!v.device||!v.buffer)continue;
   for(auto&[id,t]:targets){if(t.device!=v.device||now<t.tick||now-t.tick>2000||std::find(t.buffers.begin(),t.buffers.end(),v.buffer)==t.buffers.end())continue;candidate={key,v.generation,id,t.generation};++count;}}
  // Uniqueness is of an actual FG backbuffer-to-present association, never of
  // enumerated GPUs/windows. Multiple FG outputs need an explicit host role;
  // do not choose whichever callback happened to arrive first.
  if(count==1)invalidate(State::Bound,candidate);else invalidate(count>1?State::Ambiguous:restart?State::Restart:retiring?State::Retiring:State::Missing);
  auto s=result;if(!s.sampleTick||now<s.sampleTick||now-s.sampleTick>2000){s.frames=0;s.sampleTick=0;}return s;
 }
 Ticket OwnerTicket(uint64_t now){return Read(now).owner;}
 bool Owns(const Ticket&t,uint64_t now){auto s=Read(now);return s.state==State::Bound&&Current(t)&&same(t,s.owner)&&t.epoch==s.owner.epoch;}
 bool Acknowledge(const Ticket&t,uint64_t revision,uint64_t saved,uint64_t now){if(!Owns(t,now))return false;result.accepted=revision;result.saved=saved;result.acceptedTick=now;return true;}
 bool Sample(const Ticket&t,uint32_t frames,uint64_t now){if(!Owns(t,now))return false;result.frames=frames;result.sampleTick=now;return true;}
};
}
