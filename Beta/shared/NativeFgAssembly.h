#pragma once
#include <array>
#include <cstdint>
#include <mutex>
#include <memory>
#include <cstring>
#include "D3D12FrameContext.h"
#include "OutputLifecycle.h"
#include <d3d12.h>
#include <wrl/client.h>
namespace optishade::route {
struct ProducerIdentity {
 uint64_t owner=0,generation=0,device=0;uint32_t frame=0,view=0;
 bool operator==(const ProducerIdentity& b)const{return owner==b.owner&&generation==b.generation&&device==b.device&&frame==b.frame&&view==b.view;}
};
struct ProducerResource {
 ID3D12Resource* resource=nullptr;
 ID3D12CommandList* command=nullptr;
 uint64_t recording=0;
 uint32_t state=0,lifecycle=0,left=0,top=0,width=0,height=0;
};
struct ProducerFrame {
 ProducerIdentity identity;
 std::array<ProducerResource,4> resources{}; // HUD-less, output, depth, motion
 std::array<unsigned char,1024> constants{};uint32_t constantBytes=0;
 uint64_t ticket=0;OutputTicket health{};
};
enum class AssemblyEvent:uint32_t {Resource,Constants,Publish,Retire,Observe,Health,Begin};
struct AssemblyRequest {uint32_t size=sizeof(AssemblyRequest),abi=4;AssemblyEvent event{};ProducerIdentity identity;uint32_t index=0;ProducerResource resource;const void* constants=nullptr;uint32_t constantBytes=0;uint64_t ticket=0;OutputStage stage{};int64_t result=0;bool success=true;};
using AssemblyCall=bool(*)(const AssemblyRequest*,uint32_t,ProducerFrame*,uint32_t);
// The route retains COM identities and publishes one immutable frame. Host
// pointers to temporary Streamline structs never cross a call boundary.
class NativeFgAssembly {
 struct Slot {
  ProducerFrame frame;
  std::array<Microsoft::WRL::ComPtr<ID3D12Resource>,4> resources;
  std::array<Microsoft::WRL::ComPtr<ID3D12CommandList>,4> commands;
  uint32_t mask=0;bool published=false,used=false;
  std::array<Microsoft::WRL::ComPtr<ID3D12Resource>,32> retained;
  std::array<Microsoft::WRL::ComPtr<ID3D12CommandList>,32> retainedCommands;
  unsigned retainedCount=0;
 };
 std::array<Slot,24> slots{};
 struct Watermark {ProducerIdentity id{};bool used=false;};std::array<Watermark,24> retired{};
 std::mutex mutex;OutputLifecycle lifecycle;
 bool WasRetired(const ProducerIdentity& id)const{
  for(const auto& w:retired)if(w.used&&w.id.owner==id.owner&&w.id.device==id.device&&w.id.view==id.view&&
      (id.generation<w.id.generation||(id.generation==w.id.generation&&static_cast<int32_t>(id.frame-w.id.frame)<=0)))return true;
  return false;
 }
 Slot* Find(const ProducerIdentity& id,bool create){
  for(auto& s:slots)if(s.used&&s.frame.identity==id)return &s;
  if(WasRetired(id))return nullptr;
  if(create&&id.owner&&id.generation&&id.device)for(auto& s:slots)if(!s.used){s={};s.used=true;s.frame.identity=id;s.frame.ticket=lifecycle.Request(id.owner,id.generation,id.frame,id.view);return &s;}
  return nullptr;
 }
public:
 bool Begin(const ProducerIdentity& id,ProducerFrame& out){std::lock_guard guard(mutex);auto* s=Find(id,true);if(!s)return false;out={};out.identity=id;out.ticket=s->frame.ticket;lifecycle.Read(out.ticket,out.health);return true;}
 bool Resource(const ProducerIdentity& id,unsigned index,const ProducerResource& value){
  if(index>=4||!value.resource||value.state==UINT32_MAX)return false;
  Microsoft::WRL::ComPtr<ID3D12Device> device;if(FAILED(value.resource->GetDevice(IID_PPV_ARGS(&device))))return false;
  if(reinterpret_cast<uint64_t>(ReShadeDeviceIdentity(device.Get()).Get())!=id.device)return false;
  // The caller normalizes device identity before transporting the contract.
  std::lock_guard guard(mutex);auto* s=Find(id,true);if(!s||s->published)return false;
  if(s->retainedCount==s->retained.size())return false;
  s->retained[s->retainedCount]=value.resource;s->retainedCommands[s->retainedCount++]=value.command;
  s->resources[index]=value.resource;s->commands[index]=value.command;s->frame.resources[index]=value;s->mask|=1u<<index;return true;
 }
 bool Constants(const ProducerIdentity& id,const void* data,uint32_t bytes){
  if(!data||!bytes||bytes>1024)return false;std::lock_guard guard(mutex);auto* s=Find(id,true);if(!s||s->published)return false;
  memcpy(s->frame.constants.data(),data,bytes);s->frame.constantBytes=bytes;return true;
 }
 bool Publish(const ProducerIdentity& id,ProducerFrame& out){
  std::lock_guard guard(mutex);auto* s=Find(id,false);if(!s||s->published||s->mask!=15||!s->frame.constantBytes)return false;
  s->published=true;lifecycle.Observe(s->frame.ticket,OutputStage::ContractComplete);out=s->frame;lifecycle.Read(out.ticket,out.health);
  for(auto& r:out.resources){r.resource->AddRef();if(r.command)r.command->AddRef();}
  return true;
 }
 // Caller must own the frame's GPU retirement before releasing route storage.
 bool Retire(const ProducerIdentity& id){
  std::lock_guard guard(mutex);auto* s=Find(id,false);if(!s)return false;
  // Generation counters belong to outputs, not the process. Retiring a
  // resized desktop output must not invalidate another output/eye/device.
  Watermark* target=nullptr;
  for(auto& w:retired)if(w.used&&w.id.owner==id.owner&&w.id.device==id.device&&w.id.view==id.view){target=&w;break;}
  if(!target)for(auto& w:retired)if(!w.used){target=&w;break;}
  if(!target)return false; // Bounded storage; never evict a live retirement guard.
  if(!target->used||id.generation>target->id.generation||
      (id.generation==target->id.generation&&static_cast<int32_t>(id.frame-target->id.frame)>0)){
      target->id=id;target->used=true;
  }
  *s={};return true;
 }
 bool Observe(uint64_t ticket,OutputStage stage,int64_t result,bool success){return lifecycle.Observe(ticket,stage,result,success);}
 bool Health(uint64_t ticket,OutputTicket& out){return lifecycle.Read(ticket,out);}
 static void Release(ProducerFrame& f){for(auto& r:f.resources){if(r.resource)r.resource->Release();if(r.command)r.command->Release();}f={};}
};
}
