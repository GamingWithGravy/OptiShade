#include "Xp12CameraRecord.h"
#include <atomic>
#include <iostream>
#include <stdexcept>
#include <thread>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
using namespace optishade::xp12camera;
static Snapshot Make(uint64_t n){Snapshot v{};v.count=n;v.qpc=n*10;v.simFrame=n;for(int i=0;i<16;++i){v.world[i]=double(n);v.projection[i]=double(n)+0.5;}v.width=v.height=int32_t(n);v.viewType=1000;return v;}
int main(){
try{
 static Record record{};
 record.magic=kMagic;record.version=kVersion;record.size=sizeof(Record);record.pid=42;record.processBirth=7;
 CHECK(Valid(record,42,7));
 CHECK(!Valid(record,43,7)&&!Valid(record,42,8));
 record.version=2;CHECK(!Valid(record,42,7));record.version=kVersion;
 Snapshot out{};
 // Nothing published yet: no sample.
 CHECK(!Read(record.samples[WindowPhase],out));
 Publish(record.samples[WindowPhase],Make(5));
 CHECK(Read(record.samples[WindowPhase],out)&&out.count==5&&out.world[15]==5.0&&out.projection[0]==5.5);
 // A write in progress (odd sequence) is never returned.
 record.samples[WindowPhase].sequence.fetch_add(1);
 CHECK(!Read(record.samples[WindowPhase],out));
 record.samples[WindowPhase].sequence.fetch_add(1);
 // Concurrent writer: every sample the reader accepts is internally consistent.
 std::atomic<bool> stop{false};
 std::thread writer([&]{for(uint64_t n=6;!stop;++n)Publish(record.samples[FlightLoop],Make(n));});
 unsigned accepted=0,torn=0;
 for(unsigned i=0;i<200000;++i){
  if(!Read(record.samples[FlightLoop],out))continue;++accepted;
  for(int k=0;k<16;++k)if(out.world[k]!=double(out.count)||out.projection[k]!=double(out.count)+0.5)++torn;
  if(out.qpc!=out.count*10||out.width!=int32_t(out.count))++torn;
 }
 stop=true;writer.join();
 CHECK(torn==0&&accepted>0);
 std::cout<<"XP12 camera record: identity, in-progress and concurrent-read tests passed ("<<accepted<<" consistent reads)\n";
}catch(const std::exception&e){std::cerr<<e.what();return 1;}}
