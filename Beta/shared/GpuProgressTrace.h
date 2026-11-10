#pragma once
#include <d3d12.h>
#include "ReadinessTrace.h"
#include <wrl/client.h>
#include <array>
#include <algorithm>
#include <mutex>
#include <thread>
#include <condition_variable>
#include <functional>
#include <string>
#include <vector>

namespace optishade {
// Private diagnostic build: bounded history, no CPU fence waits, and no game
// resources retained. Polling is independent of the renderer's event lock.
class GpuProgressTrace {
 struct Entry {
  uint64_t serial=0,tick=0,frame=0,value=0;
  std::string stage;
  Microsoft::WRL::ComPtr<ID3D12Fence> fence;
 };
 std::array<Entry,256> history{};
 std::mutex mutex;
 std::condition_variable cv;
 std::thread worker;
 std::function<void(const std::string&)> sink;
 uint64_t sequence=0;
 bool stopping=false;
 void Run() {
  uint64_t lastDump=0, lastReadinessSequence=0;
  for(;;) {
   std::vector<Entry> snapshot;
   {
    std::unique_lock lock(mutex);
    if(cv.wait_for(lock,std::chrono::milliseconds(250),[this]{return stopping;}))return;
    for(const auto& e:history)if(e.serial)snapshot.push_back(e);
   }
   const auto now=GetTickCount64(); bool stalled=false;
   for(const auto& e:snapshot)if(e.fence&&now-e.tick>=1500) {
    const auto completed=e.fence->GetCompletedValue();
    if(completed==UINT64_MAX||completed<e.value)stalled=true;
   }
   if(now-lastDump<5000)continue;
   lastDump=now;
   optishade::readiness::Snapshot decisions;
   if(optishade::readiness::State().Read(decisions)&&decisions.sequence!=lastReadinessSequence){
    sink("READINESS_AT_DECISION " + optishade::readiness::Report(decisions));
    lastReadinessSequence=decisions.sequence;
   }
   sink(stalled?"SNAPSHOT pending GPU checkpoint older than 1500ms (not a diagnosis)":"SNAPSHOT progress");
   // Serial ordering makes ring wrap explicit and keeps the final submission
   // history available even when the game thread never returns from Present.
   std::sort(snapshot.begin(),snapshot.end(),[](const Entry&a,const Entry&b){return a.serial<b.serial;});
   auto first=stalled?0:(snapshot.size()>12?snapshot.size()-12:0);
   for(size_t i=first;i<snapshot.size();++i) {
    const auto& e=snapshot[i];
    sink("seq="+std::to_string(e.serial)+" frame="+std::to_string(e.frame)+" ageMs="+std::to_string(now-e.tick)+" "+e.stage+
      " fence="+std::to_string(reinterpret_cast<uintptr_t>(e.fence.Get()))+" target="+std::to_string(e.value)+
      " completedAtDump="+(e.fence?std::to_string(e.fence->GetCompletedValue()):"NA"));
   }
  }
 }
public:
 explicit GpuProgressTrace(std::function<void(const std::string&)> output):sink(std::move(output)){}
 ~GpuProgressTrace(){Stop();}
 void Record(uint64_t frame,std::string stage,ID3D12Fence* fence=nullptr,uint64_t value=0) {
  std::lock_guard lock(mutex);if(stopping)return;
  auto& e=history[sequence%history.size()];e={++sequence,GetTickCount64(),frame,value,std::move(stage),fence};
  if(!worker.joinable())worker=std::thread([this]{Run();});
 }
 void Stop(){ {std::lock_guard lock(mutex);stopping=true;}cv.notify_all();if(worker.joinable())worker.join(); }
};
}
