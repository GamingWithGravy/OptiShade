#pragma once
#include "SimulatorRoute.h"
#include "D3D12FrameContext.h"
#include "ReadinessTrace.h"
#include <vector>
#include <array>
#include <utility>
#include <chrono>
#include <thread>
#include <algorithm>
namespace optishade::route {
using ProducerRecording=std::pair<Microsoft::WRL::ComPtr<ID3D12CommandList>,uint64_t>;
// Resource tags replace dependencies; the caller separately retains lifetime leases.
inline std::vector<ProducerRecording> ActiveProducerRecordings(const std::array<ProducerRecording,4>& inputs){
 std::vector<ProducerRecording> result;
 for(const auto& p:inputs)if(p.first&&p.second&&std::find(result.begin(),result.end(),p)==result.end())result.push_back(p);
 return result;
}
inline bool OrderProducerRecordings(ID3D12CommandQueue* nr,uint64_t device,
 const std::vector<ProducerRecording>& recordings,SubmissionCall query,bool completedCrossQueueOnly=false,unsigned readinessBudgetUs=0){
 using Outcome=optishade::readiness::Outcome;
 optishade::readiness::Capture capture;
 capture.value.device=device;capture.value.consumerQueue=reinterpret_cast<uint64_t>(nr);
 capture.value.completionOnly=completedCrossQueueOnly;
 capture.value.budgetUs=(std::min)(readinessBudgetUs,8000u);
 if(!nr||!device||!query||nr->GetDesc().Type!=D3D12_COMMAND_LIST_TYPE_DIRECT)return capture.Finish(Outcome::InvalidConsumer,false);
 Microsoft::WRL::ComPtr<ID3D12Device> actual;
 if(FAILED(nr->GetDevice(IID_PPV_ARGS(&actual)))||reinterpret_cast<uint64_t>(ReShadeDeviceIdentity(actual.Get()).Get())!=device)return capture.Finish(Outcome::WrongDevice,false);
 struct Completion {Microsoft::WRL::ComPtr<ID3D12Fence> fence;uint64_t value;optishade::readiness::Dependency* evidence;};
 std::vector<Completion> completions;
 // Preserve Test40's single 8 ms maximum for BOTH submission observation and
 // readiness. Diagnostics neither extend it nor add reverse GPU dependencies.
 const auto deadline=std::chrono::steady_clock::now()+std::chrono::microseconds(capture.value.budgetUs);
 for(const auto& p:recordings){
  SubmissionRequest r;r.event=SubmissionEvent::Query;r.command=reinterpret_cast<uint64_t>(p.first.Get());r.generation=p.second;
  auto* evidence=capture.Add(r.command,r.generation);
  SubmissionResult out;
  for(;;){
   out=SubmissionResult{};
   if(query(&r,sizeof(r),&out,sizeof(out)))break;
   if(!completedCrossQueueOnly||!p.second||std::chrono::steady_clock::now()>=deadline)return capture.Finish(Outcome::MissingSubmission,false);
   // Inspect current state only to justify retrying the SAME generation. Its
   // queue/fence is never admitted as this frame's completion evidence.
   SubmissionRequest current=r;current.generation=0;SubmissionResult state;
   const bool known=query(&current,sizeof(current),&state,sizeof(state));
   Microsoft::WRL::ComPtr<ID3D12CommandQueue> inspectedQueue;inspectedQueue.Attach(reinterpret_cast<ID3D12CommandQueue*>(state.queue));
   Microsoft::WRL::ComPtr<ID3D12Fence> inspectedFence;inspectedFence.Attach(reinterpret_cast<ID3D12Fence*>(state.fence));
   if(evidence)evidence->phase=unsigned(state.phase);
   if(!known||state.generation!=p.second||state.device!=device||
      (state.phase!=RecordingPhase::Recording&&state.phase!=RecordingPhase::Closed&&state.phase!=RecordingPhase::Submitted))return capture.Finish(Outcome::ChangedRecording,false);
   std::this_thread::yield();
  }
  Microsoft::WRL::ComPtr<ID3D12CommandQueue> producer;producer.Attach(reinterpret_cast<ID3D12CommandQueue*>(out.queue));
  Microsoft::WRL::ComPtr<ID3D12Fence> fence;fence.Attach(reinterpret_cast<ID3D12Fence*>(out.fence));
  if(evidence){evidence->submissionEpoch=out.epoch;evidence->queue=out.queue;evidence->fence=out.fence;evidence->required=out.fenceValue;evidence->phase=unsigned(out.phase);}
  if(out.phase!=RecordingPhase::Submitted||out.device!=device||!fence||!out.fenceValue)return capture.Finish(Outcome::InvalidContract,false);
  if(completedCrossQueueOnly){
   if(!producer)return capture.Finish(Outcome::InvalidContract,false);
   const auto completed=fence->GetCompletedValue();
   if(evidence){evidence->completedAtCheck=completed;evidence->checkedAtUs=optishade::readiness::NowUs();evidence->completionSampled=true;}
   if(completed==UINT64_MAX)return capture.Finish(Outcome::DeviceRemoved,false);
   const bool cross=ReShadeObjectIdentity(producer.Get())!=ReShadeObjectIdentity(nr);
   if(evidence)evidence->crossQueue=cross;
   if(cross)completions.push_back({fence,out.fenceValue,evidence});
   // Same native queue remains FIFO after observed submission. This is ordering,
   // not proof that its GPU work completed or that a generated frame appeared.
  }else completions.push_back({fence,out.fenceValue,evidence});
 }
 if(completedCrossQueueOnly){
  for(;;){
   bool ready=true;
   for(const auto& c:completions){
    const auto value=c.fence->GetCompletedValue();
    if(c.evidence){c.evidence->completedAtCheck=value;c.evidence->checkedAtUs=optishade::readiness::NowUs();c.evidence->completionSampled=true;}
    if(value==UINT64_MAX)return capture.Finish(Outcome::DeviceRemoved,false);
    if(value<c.value)ready=false;
   }
   if(ready)return capture.Finish(completions.empty()?Outcome::SameQueueOrdered:Outcome::Ready,true);
   if(std::chrono::steady_clock::now()>=deadline)return capture.Finish(Outcome::Deadline,false);
   std::this_thread::yield();
  }
 }
 for(const auto& c:completions)if(FAILED(nr->Wait(c.fence.Get(),c.value)))return capture.Finish(Outcome::WaitFailed,false);
 return capture.Finish(Outcome::WaitEnqueued,true);
}
}
