#pragma once
#include "SimulatorRoute.h"
#include "D3D12SubmissionRegistry.h"
#include "SimulatorRouteHost.h"
#include <memory>
#include <vector>
#include <algorithm>
namespace optishade::nr_lifetime {
// Distinct from presentation evidence: all NR recordings (including XP12's
// private D3D12 bridge) use this same exact-generation lifetime service.
inline route::SubmissionRegistry& Registry(){return route::Owned<route::SubmissionRegistry,16>();}
inline void Reset(ID3D12CommandList* cmd){route::SubmissionResult out;if(Registry().Query(cmd,out)){
 if(out.queue)reinterpret_cast<IUnknown*>(out.queue)->Release();Registry().Recording(cmd,out,true);
}}
inline void Closed(ID3D12CommandList* cmd){route::SubmissionResult out;if(Registry().Query(cmd,out)){
 if(out.queue)reinterpret_cast<IUnknown*>(out.queue)->Release();Registry().Close(cmd);
}}
inline void Submitted(ID3D12CommandQueue* queue,ID3D12CommandList* cmd){route::SubmissionResult out;if(Registry().Query(cmd,out)){
 if(out.queue)reinterpret_cast<IUnknown*>(out.queue)->Release();Registry().Observe(queue,cmd);
}}
// Only call when the sole engine owner relinquishes a private command list.
// Game recordings must instead receive their real successful Reset event.
inline void RetirePrivate(ID3D12CommandList* cmd){Registry().RetirePrivate(cmd);}
class Lease {
 Microsoft::WRL::ComPtr<ID3D12CommandList> command;
 uint64_t generation=0;
public:
 Lease(ID3D12CommandList* c,uint64_t g):command(c),generation(g){}
 ~Lease(){Registry().Pin(command.Get(),generation,false);}
 bool Ready()const{return Registry().Retired(command.Get(),generation);}
 // CPU readback requires both retirement (no replay can write it again) and
 // successful completion. An abandoned, never-submitted list is safe to free,
 // but its readback contents must never be mapped as a captured frame.
 bool Completed()const{
  if(!Ready())return false;
  route::SubmissionResult out{};
  const bool known=Registry().Query(command.Get(),out,generation);
  const bool completed=known&&out.generation==generation&&out.phase==route::RecordingPhase::Submitted&&out.completed;
  if(out.queue)reinterpret_cast<IUnknown*>(out.queue)->Release();
  if(out.fence)reinterpret_cast<IUnknown*>(out.fence)->Release();
  return completed;
 }
 uint64_t Generation()const{return generation;}
 // Why a lease is still pending. Only FinishedNotReset has no GPU work in
 // flight: the game may still replay it, so its resources must stay alive.
 enum class Wait{Retired,InFlight,FinishedNotReset,Unsubmitted,Unresolved,Unknown};
 Wait State()const{
  if(Ready())return Wait::Retired;
  route::RecordingPhase phase;bool finished=false,unresolved=false,current=false;
  if(!Registry().Inspect(command.Get(),generation,phase,finished,unresolved,current))return Wait::Unknown;
  if(unresolved)return Wait::Unresolved;
  if(phase==route::RecordingPhase::Submitted)return finished?Wait::FinishedNotReset:Wait::InFlight;
  if(phase==route::RecordingPhase::Recording||phase==route::RecordingPhase::Closed)return Wait::Unsubmitted;
  return Wait::Unknown;
 }
};
using Use=std::shared_ptr<Lease>;
inline Use Capture(ID3D12CommandList* cmd){
 route::SubmissionResult out;
 if(!Registry().Recording(cmd,out)||!out.generation)return {};
 if(out.queue)reinterpret_cast<IUnknown*>(out.queue)->Release();
 if(!Registry().Pin(cmd,out.generation,true))return {};
 return std::make_shared<Lease>(cmd,out.generation);
}
class Uses {
public:
 std::vector<Use> items;
 void Collect(){std::erase_if(items,[](const Use& u){return u->Ready();});}
 bool Add(const Use& use){Collect();for(const auto& u:items)if(u->Generation()==use->Generation())return true;if(items.size()>=256)return false;items.push_back(use);return true;}
 bool Ready(){Collect();return items.empty();}
};
inline Uses& Active(){return route::OutputOwned<Uses,17>();}
struct Held {Use use;std::vector<Microsoft::WRL::ComPtr<IUnknown>> objects;};
inline std::vector<Held>& HeldObjects(){return route::OutputOwned<std::vector<Held>,24>();}
struct HeldSnapshot {size_t groups=0,objects=0,pending=0;};
inline HeldSnapshot SnapshotHeld(){
 HeldSnapshot out;const auto& held=HeldObjects();out.groups=held.size();
 for(const auto& item:held){out.objects+=item.objects.size();if(!item.use||!item.use->Ready())++out.pending;}
 return out;
}
inline void Collect(){auto& held=HeldObjects();std::erase_if(held,[](const Held& h){return !h.use||h.use->Ready();});}
inline void Hold(Use use,std::vector<Microsoft::WRL::ComPtr<IUnknown>> objects){
 if(use&&!use->Ready())HeldObjects().push_back({std::move(use),std::move(objects)});
}
}
