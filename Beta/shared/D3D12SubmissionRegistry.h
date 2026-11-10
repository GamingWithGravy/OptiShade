#pragma once
#include "D3D12FrameContext.h"
#include <mutex>
#include <unordered_map>
#include <vector>
#include <algorithm>
namespace optishade::route {
// A reusable COM pointer is not a recording identity. Every successful Reset
// gets a new generation; submitted recordings retain their own completion fence.
class SubmissionRegistry {
 const bool explicitRecordingsOnly;
 struct Timeline {
  Microsoft::WRL::ComPtr<ID3D12CommandQueue> queue;
  Microsoft::WRL::ComPtr<ID3D12Fence> fence;
  uint64_t value=0;
 };
 struct Completion {
  Microsoft::WRL::ComPtr<ID3D12Fence> fence;
  uint64_t value=0;
 };
 struct Entry {
  Microsoft::WRL::ComPtr<IUnknown> command;
  Microsoft::WRL::ComPtr<ID3D12CommandQueue> queue;
  Microsoft::WRL::ComPtr<ID3D12Fence> fence;
  uint64_t epoch=0,device=0,value=0,generation=0;
  RecordingPhase phase=RecordingPhase::Unknown;
  std::vector<Completion> consumers;
  bool unresolved=false;
 };
 std::mutex mutex;
 std::unordered_map<uint64_t,Entry> recordings,submitted;
 std::unordered_map<uint64_t,Timeline> timelines;
 uint64_t epoch=0,generation=0;
 std::unordered_map<uint64_t,uint32_t> pins;
 static bool Completed(const Completion& c){
  const auto value=c.fence->GetCompletedValue();return value!=UINT64_MAX&&value>=c.value;
 }
 void PruneTimelines(){
  // A completed timeline is only a signal allocator, not a recording lease.
  // Entries retain their own fence references and replay/retirement evidence.
  // Never recycle pending, failed-signal or device-removed timelines.
  for(auto i=timelines.begin();i!=timelines.end();){
   const auto value=i->second.fence->GetCompletedValue();
   if(value!=UINT64_MAX&&value>=i->second.value)i=timelines.erase(i);else ++i;
  }
 }
 void Prune(){
  // Completed command objects are not an ever-growing identity cache. Keep
  // exact generation evidence while an input frame holds a lease.
  if(recordings.size()>=1024)for(auto i=recordings.begin();i!=recordings.end();)
   if(Finished(i->second)&&!pins.count(i->second.generation))i=recordings.erase(i);else ++i;
  if(submitted.size()>=2048)for(auto i=submitted.begin();i!=submitted.end();){
   auto current=recordings.find(reinterpret_cast<uint64_t>(i->second.command.Get()));
   if(!pins.count(i->first)&&(Finished(i->second)||i->second.phase==RecordingPhase::Abandoned)&&
      (current==recordings.end()||current->second.generation!=i->first))i=submitted.erase(i);else ++i;
  }
 }
 static bool Finished(const Entry& e){
  if(e.unresolved||e.consumers.empty())return false;
  for(const auto& c:e.consumers){auto v=c.fence->GetCompletedValue();if(v==UINT64_MAX||v<c.value)return false;}
  return true;
 }
 static bool Identity(ID3D12CommandList* cmd,Microsoft::WRL::ComPtr<IUnknown>& key,uint64_t& device){
  if(!cmd||cmd->GetType()!=D3D12_COMMAND_LIST_TYPE_DIRECT)return false;
  Microsoft::WRL::ComPtr<ID3D12Device> d;if(FAILED(cmd->GetDevice(IID_PPV_ARGS(&d))))return false;
  auto owner=ReShadeDeviceIdentity(d.Get());key=ReShadeObjectIdentity(cmd);device=reinterpret_cast<uint64_t>(owner.Get());return key&&device;
 }
 static void Describe(const Entry& e,SubmissionResult& out,bool retainFence){
  out.command=reinterpret_cast<uint64_t>(e.command.Get());out.device=e.device;out.generation=e.generation;out.phase=e.phase;
  out.queue=reinterpret_cast<uint64_t>(e.queue.Get());out.epoch=e.epoch;out.completed=Finished(e);
  if(e.queue)e.queue->AddRef();
  if(retainFence&&e.fence){out.fence=reinterpret_cast<uint64_t>(e.fence.Get());out.fenceValue=e.value;e.fence->AddRef();}
 }
public:
 explicit SubmissionRegistry(bool explicitOnly=false):explicitRecordingsOnly(explicitOnly){}
 bool Recording(ID3D12CommandList* command,SubmissionResult& out,bool reset=false){
  Microsoft::WRL::ComPtr<IUnknown> key;uint64_t device=0;if(!Identity(command,key,device))return false;
  std::lock_guard guard(mutex);Prune();auto id=reinterpret_cast<uint64_t>(key.Get());auto i=recordings.find(id);
  if(explicitRecordingsOnly&&reset&&i==recordings.end())return true; // No NR resource references this game recording.
  if(i==recordings.end()||reset){
   if(i==recordings.end()&&recordings.size()>=1024)return false;
   if(i!=recordings.end()){
    if(!submitted.count(i->second.generation)&&submitted.size()>=2048)return false;
    auto old=i->second;if(old.phase!=RecordingPhase::Submitted&&!old.unresolved)old.phase=RecordingPhase::Abandoned;
    submitted[old.generation]=std::move(old);
   }
   Entry e;e.command=key;e.device=device;e.generation=++generation;e.phase=RecordingPhase::Recording;
   i=recordings.insert_or_assign(id,std::move(e)).first;
  }
  if(i->second.phase!=RecordingPhase::Recording)return false;
  Describe(i->second,out,false);return true;
 }
 bool Close(ID3D12CommandList* command){
  Microsoft::WRL::ComPtr<IUnknown> key;uint64_t device=0;if(!Identity(command,key,device))return false;
  std::lock_guard guard(mutex);Prune();auto id=reinterpret_cast<uint64_t>(key.Get());auto i=recordings.find(id);
  if(i==recordings.end()){
   if(explicitRecordingsOnly)return true;
   if(recordings.size()>=1024)return false;
   Entry e;e.command=key;e.device=device;e.generation=++generation;e.phase=RecordingPhase::Closed;
   recordings.emplace(id,std::move(e));return true;
  }
  if(i->second.phase!=RecordingPhase::Recording)return false;
  i->second.phase=RecordingPhase::Closed;return true;
 }
 bool Observe(ID3D12CommandQueue* queue,ID3D12CommandList* command){
  if(!queue||queue->GetDesc().Type!=D3D12_COMMAND_LIST_TYPE_DIRECT)return false;
  Microsoft::WRL::ComPtr<IUnknown> key;uint64_t device=0;if(!Identity(command,key,device))return false;
  Microsoft::WRL::ComPtr<ID3D12Device> a;if(FAILED(queue->GetDevice(IID_PPV_ARGS(&a))))return false;
  if(device!=reinterpret_cast<uint64_t>(ReShadeDeviceIdentity(a.Get()).Get()))return false;
  auto queueKey=ReShadeObjectIdentity(queue);if(!queueKey)return false;
  std::lock_guard guard(mutex);Prune();auto commandId=reinterpret_cast<uint64_t>(key.Get());auto r=recordings.find(commandId);
  if(explicitRecordingsOnly&&r==recordings.end())return true; // No completion signal for unrelated game work.
  // Execute has already happened. Every failure below invalidates previous
  // completion evidence for this exact generation, even after a successful replay.
  auto unresolved=[&]{if(r!=recordings.end()){
   r->second.unresolved=true;
   if(auto old=submitted.find(r->second.generation);old!=submitted.end())old->second.unresolved=true;
  }return false;};
  if(r!=recordings.end()&&r->second.phase==RecordingPhase::Recording)return unresolved();
  if((submitted.size()>=2048&&(r==recordings.end()||!submitted.count(r->second.generation)))||
     (r==recordings.end()&&recordings.size()>=1024))return unresolved();
  auto id=reinterpret_cast<uint64_t>(queueKey.Get());auto found=timelines.find(id);
  if(found==timelines.end()){
   if(timelines.size()>=16)PruneTimelines();
   if(timelines.size()>=16)return unresolved();
   Timeline timeline;timeline.queue=queue;
   if(FAILED(a->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&timeline.fence))))return unresolved();
   found=timelines.emplace(id,std::move(timeline)).first;
  }
  auto& timeline=found->second;if(timeline.value==UINT64_MAX-1)return unresolved();
  auto value=++timeline.value;if(FAILED(queue->Signal(timeline.fence.Get(),value)))return unresolved();
  Entry e;if(r!=recordings.end())e=r->second;else {e.command=key;e.device=device;e.generation=++generation;}
  // Completed consumers no longer constrain this replay. Keep unresolved
  // consumers from other queues: the newest queue alone is not retirement.
  e.consumers.erase(std::remove_if(e.consumers.begin(),e.consumers.end(),Completed),e.consumers.end());
  bool merged=false;
  for(auto& consumer:e.consumers)if(consumer.fence==timeline.fence){consumer.value=value;merged=true;break;}
  if(!merged)e.consumers.push_back({timeline.fence,value}); // bounded by the 16 queue timelines
  e.queue=queue;e.fence=timeline.fence;e.epoch=++epoch;e.value=value;e.phase=RecordingPhase::Submitted;
  submitted[e.generation]=e;recordings[commandId]=e;return true;
 }
 bool Pin(ID3D12CommandList* command,uint64_t expected,bool acquire){
  auto key=ReShadeObjectIdentity(command);if(!key||!expected)return false;std::lock_guard guard(mutex);
  auto current=recordings.find(reinterpret_cast<uint64_t>(key.Get()));auto old=submitted.find(expected);
  if(!((current!=recordings.end()&&current->second.generation==expected)||
       (old!=submitted.end()&&old->second.command==key)))return false;
  auto p=pins.find(expected);
  if(acquire){if(p==pins.end()&&pins.size()>=2048)return false;++pins[expected];return true;}
  if(p==pins.end())return false;if(--p->second==0)pins.erase(p);return true;
 }
 bool Query(ID3D12CommandList* command,SubmissionResult& out,uint64_t expectedGeneration=0){
  auto key=ReShadeObjectIdentity(command);if(!key)return false;std::lock_guard guard(mutex);
  if(expectedGeneration){auto i=submitted.find(expectedGeneration);if(i==submitted.end()||i->second.command!=key||i->second.unresolved)return false;
   for(const auto& c:i->second.consumers)if(c.fence!=i->second.fence){auto v=c.fence->GetCompletedValue();if(v==UINT64_MAX||v<c.value)return false;}
   Describe(i->second,out,true);return true;}
  auto i=recordings.find(reinterpret_cast<uint64_t>(key.Get()));if(i==recordings.end())return false;
  Describe(i->second,out,false);return true;
 }
 // Retirement is stronger than completion: a game list cannot replay this
 // generation after a successful Reset. Private lists must be explicitly retired
 // by their sole owner. Failed/unknown signals are never proof of retirement.
 bool Retired(ID3D12CommandList* command,uint64_t expected){
  auto key=ReShadeObjectIdentity(command);if(!key||!expected)return false;
  std::lock_guard guard(mutex);auto current=recordings.find(reinterpret_cast<uint64_t>(key.Get()));
  if(current!=recordings.end()&&current->second.generation==expected)return false;
  auto old=submitted.find(expected);if(old==submitted.end()||old->second.command!=key||old->second.unresolved)return false;
  return old->second.phase==RecordingPhase::Abandoned||Finished(old->second);
 }
 // Read-only state of one generation for diagnostics and bounded rebuild
 // decisions. 'current' means the list has not been Reset since this generation.
 bool Inspect(ID3D12CommandList* command,uint64_t expected,RecordingPhase& phase,bool& finished,bool& unresolved,bool& current){
  phase=RecordingPhase::Unknown;finished=false;unresolved=false;current=false;
  auto key=ReShadeObjectIdentity(command);if(!key||!expected)return false;
  std::lock_guard guard(mutex);auto live=recordings.find(reinterpret_cast<uint64_t>(key.Get()));
  const Entry* e=nullptr;
  if(live!=recordings.end()&&live->second.generation==expected){e=&live->second;current=true;}
  else if(auto old=submitted.find(expected);old!=submitted.end()&&old->second.command==key)e=&old->second;
  if(!e)return false;
  phase=e->phase;finished=Finished(*e);unresolved=e->unresolved;return true;
 }
 bool RetirePrivate(ID3D12CommandList* command){
  auto key=ReShadeObjectIdentity(command);if(!key)return false;std::lock_guard guard(mutex);
  auto current=recordings.find(reinterpret_cast<uint64_t>(key.Get()));if(current==recordings.end())return true;
  auto e=current->second;
  if(!submitted.count(e.generation)&&submitted.size()>=2048)return false;
  if(e.phase!=RecordingPhase::Submitted&&!e.unresolved)e.phase=RecordingPhase::Abandoned;
  submitted[e.generation]=std::move(e);recordings.erase(current);return true;
 }
 void Clear(){
  // Retiring a presentation owner does not cancel submitted GPU work. Keep
  // exact generation fences available to holders of old producer resources.
  std::lock_guard guard(mutex);
  // Unsubmitted recordings may still execute or Reset after a resize.
  // Preserve them until those actual lifecycle events establish retirement.
  Prune(); // Owner retirement is not a command-list Reset or GPU completion.
 }
};
}
