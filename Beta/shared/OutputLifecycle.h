#pragma once
#include <array>
#include <cstdint>
#include <mutex>
namespace optishade::route {
enum class OutputStage:uint32_t {Requested,ContractComplete,NrRecorded,Submitted,GpuCompleted,FgAccepted,Generated,Presented,PresentSubmitted,Count};
struct OutputTicket {uint64_t ticket=0,owner=0,generation=0;uint32_t frame=0,view=0,observed=0,failed=0;std::array<int64_t,static_cast<unsigned>(OutputStage::Count)> result{};};
class OutputLifecycle {
 std::array<OutputTicket,128> tickets{};std::mutex mutex;uint64_t sequence=0;
public:
 uint64_t Request(uint64_t owner,uint64_t generation,uint32_t frame,uint32_t view){
  if(!owner||!generation)return 0;std::lock_guard guard(mutex);
  for(auto& t:tickets)if(t.ticket&&t.owner==owner&&t.generation==generation&&t.frame==frame&&t.view==view)return t.ticket;
  auto id=++sequence;auto& t=tickets[id%tickets.size()];t={};t.ticket=id;t.owner=owner;t.generation=generation;t.frame=frame;t.view=view;t.observed=1;return id;
 }
 bool Observe(uint64_t id,OutputStage stage,int64_t result=0,bool success=true){
  if(!id||stage>=OutputStage::Count)return false;std::lock_guard guard(mutex);auto& t=tickets[id%tickets.size()];if(t.ticket!=id)return false;
  const auto bit=1u<<static_cast<unsigned>(stage);t.observed|=bit;t.result[static_cast<unsigned>(stage)]=result;if(!success)t.failed|=bit;return true;
 }
 bool Read(uint64_t id,OutputTicket& out){std::lock_guard guard(mutex);auto& t=tickets[id%tickets.size()];if(!id||t.ticket!=id)return false;out=t;return true;}
 // Stages are independent observations. GPU completion deliberately does not
 // imply FG acceptance, generated frames, a Present call or visible scanout.
};
}
