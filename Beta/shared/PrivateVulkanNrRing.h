#pragma once
#include "PrivateVulkanNrBridge.h"
#include <memory>
#include <string>
namespace optishade::vknr {
// Each slot owns the whole cross-API transaction. A completed fence, not frame
// age or a CPU wait, permits reuse. Shared NR device/queue serialize model work.
class PrivateVulkanNrRing {
 struct Slot {std::unique_ptr<PrivateD3D12Bridge> bridge;uint64_t ticket=0;};
 std::array<Slot,4> slots;unsigned next=0,last=0;bool submitted=false;
 std::string reason="Preparing Vulkan/D3D12 bridge";
public:
 using Evaluate=PrivateD3D12Bridge::Evaluate;
 bool Init(VkPhysicalDevice pd,VkDevice d,VkQueue q,uint32_t family,uint32_t w,uint32_t h){
  for(unsigned i=0;i<slots.size();++i){auto& s=slots[i];s.bridge=std::make_unique<PrivateD3D12Bridge>();
   if(!s.bridge->Init(pd,d,q,family,w,h,i?slots[0].bridge->Device():nullptr,i?slots[0].bridge->Queue():nullptr)){reason=s.bridge->Reason();return false;}
  }reason="Neural model warming up";return true;
 }
 bool Matches(VkDevice d,VkQueue q,uint32_t w,uint32_t h)const{return slots[0].bridge&&slots[0].bridge->Matches(d,q,w,h);}
 uint32_t Mismatch(VkDevice d,VkQueue q,uint32_t w,uint32_t h)const{return slots[0].bridge?slots[0].bridge->Mismatch(d,q,w,h):16u;}
 bool OwnsDevice(VkDevice d)const{return slots[0].bridge&&slots[0].bridge->OwnsDevice(d);}
 bool ReadyToRetire()const{for(const auto& s:slots)if(s.bridge&&!s.bridge->ReadyToRetire())return false;return true;}
 bool RetireCompletedRecordings(){
  if(!ReadyToRetire())return false;
  for(auto& s:slots)if(s.bridge&&!s.bridge->RetireCompletedRecording())return false;
  return true;
 }
 template<class Complete> void Collect(Complete complete){for(auto& s:slots)if(s.ticket&&s.bridge->ReadyToRetire()){complete(s.ticket,reinterpret_cast<uint64_t>(s.bridge->Queue()));s.ticket=0;}}
 int Run(const osvtaa::Frame& frame,Evaluate evaluate,void* context){
  submitted=false;
  for(unsigned count=0;count<slots.size();++count){unsigned i=(next+count)%slots.size();auto& s=slots[i];
   if(!s.bridge||!s.bridge->ReadyToRetire()||s.ticket)continue;
   last=i;next=(i+1)%slots.size();auto result=s.bridge->Run(frame,evaluate,context);submitted=s.bridge->Submitted();reason=s.bridge->Reason();
   if(result==1&&frame.observationTicket)s.ticket=*frame.observationTicket;
   return result;
  }reason="Waiting for GPU completion of in-flight NR frames";return 0;
 }
 bool Submitted()const{return submitted;}
 const char* Reason()const{return reason.c_str();}
 ID3D12Device* Device()const{return slots[0].bridge->Device();}
 ID3D12CommandQueue* Queue()const{return slots[0].bridge->Queue();}
 ID3D12GraphicsCommandList* Commands()const{return slots[last].bridge->Commands();}
};
}
