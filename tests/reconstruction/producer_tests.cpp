#include "ProducerDependencies.h"
#include <iostream>
#include <stdexcept>
using namespace optishade;using namespace optishade::route;
static unsigned checks=0;
#define CHECK(x) do{++checks;if(!(x))throw std::runtime_error(std::string(#x)+" @"+std::to_string(__LINE__));}while(0)
ID3D12Device device,otherDevice;ID3D12CommandQueue consumer{&device},producer{&device};ID3D12CommandList command;ID3D12Fence fence;
int mode=0; // 0 submitted, 1 absent, 2 changed generation, 3 wrong device, 4 pending submission
bool query(const SubmissionRequest* request,uint32_t,SubmissionResult* out,uint32_t){
 if(mode==1)return false;
 if(mode==2||mode==4){if(request->generation)return false;out->generation=mode==2?99:7;out->device=reinterpret_cast<uint64_t>(&device);out->phase=RecordingPhase::Recording;return true;}
 out->device=reinterpret_cast<uint64_t>(mode==3?&otherDevice:&device);out->queue=reinterpret_cast<uint64_t>(&producer);out->fence=reinterpret_cast<uint64_t>(&fence);out->generation=7;out->epoch=12;out->fenceValue=10;out->phase=RecordingPhase::Submitted;return true;
}
readiness::Decision last(){readiness::Snapshot s;CHECK(readiness::State().Read(s));CHECK(s.count>0);return s.recent[(s.sequence-1)%s.recent.size()];}
int main(){try{
 std::vector<ProducerRecording> inputs{{&command,7}};const auto id=reinterpret_cast<uint64_t>(&device);
 CHECK(!OrderProducerRecordings(nullptr,id,inputs,query,true));CHECK(last().outcome==readiness::Outcome::InvalidConsumer);
 CHECK(!OrderProducerRecordings(&consumer,reinterpret_cast<uint64_t>(&otherDevice),inputs,query,true));CHECK(last().outcome==readiness::Outcome::WrongDevice);
 fence.completed=3;CHECK(!OrderProducerRecordings(&consumer,id,inputs,query,true,0));auto failed=last();CHECK(failed.outcome==readiness::Outcome::Deadline);CHECK(failed.dependencies[0].required==10);CHECK(failed.dependencies[0].completedAtCheck==3);CHECK(consumer.waits==0);
 fence.completed=10;CHECK(last().dependencies[0].completedAtCheck==3);CHECK(OrderProducerRecordings(&consumer,id,inputs,query,true));CHECK(last().outcome==readiness::Outcome::Ready);CHECK(consumer.waits==0);
 fence.completed=UINT64_MAX;CHECK(!OrderProducerRecordings(&consumer,id,inputs,query,true));CHECK(last().outcome==readiness::Outcome::DeviceRemoved);
 fence.completed=0;CHECK(OrderProducerRecordings(&producer,id,inputs,query,true));CHECK(last().outcome==readiness::Outcome::SameQueueOrdered);CHECK(last().dependencies[0].completedAtCheck==0);CHECK(producer.waits==0);
 CHECK(OrderProducerRecordings(&consumer,id,inputs,query,false));CHECK(last().outcome==readiness::Outcome::WaitEnqueued);CHECK(consumer.waits==1);CHECK(!last().dependencies[0].completionSampled);
 consumer.waitResult=-1;CHECK(!OrderProducerRecordings(&consumer,id,inputs,query,false));CHECK(last().outcome==readiness::Outcome::WaitFailed);consumer.waitResult=0;
 mode=1;CHECK(!OrderProducerRecordings(&consumer,id,inputs,query,true));CHECK(last().outcome==readiness::Outcome::MissingSubmission);
 mode=2;CHECK(!OrderProducerRecordings(&consumer,id,inputs,query,true,1000));CHECK(last().outcome==readiness::Outcome::ChangedRecording);
 mode=3;CHECK(!OrderProducerRecordings(&consumer,id,inputs,query,true));CHECK(last().outcome==readiness::Outcome::InvalidContract);
 mode=4;CHECK(!OrderProducerRecordings(&consumer,id,inputs,query,true,9000));CHECK(last().budgetUs==8000);CHECK(last().outcome==readiness::Outcome::MissingSubmission);
 std::array<ProducerRecording,4> tags{{{&command,7},{&command,7},{&command,8},{nullptr,0}}};auto selected=ActiveProducerRecordings(tags);CHECK(selected.size()==2);CHECK(selected[0].second==7&&selected[1].second==8);
 std::cout<<checks<<" producer assertions passed (CPU doubles; not GPU validation)\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
