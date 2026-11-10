#include "DlssNr_Capture.h"
#include <iostream>
#include <stdexcept>
#include <fstream>
#include <thread>
#include <atomic>
static unsigned checks=0;
#define CHECK(x) do{++checks;if(!(x))throw std::runtime_error(std::string(#x)+" @"+std::to_string(__LINE__));}while(0)

struct Scene {
 ID3D12Device device;ID3D12GraphicsCommandList command;
 ID3D12Resource* before;ID3D12Resource* after;
 Scene(){D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=d.Height=64;d.DepthOrArraySize=d.MipLevels=d.SampleDesc.Count=1;d.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
  before=new ID3D12Resource(d);after=new ID3D12Resource(d);next(1);}
 ~Scene(){before->Release();after->Release();}
 void next(uint64_t generation){command.use=std::make_shared<CaptureLease>();command.use->generation=generation;}
 void record(capture::FrameCapture& batch,capture::Identity id={11,12,0,13,14}){
  batch.record(&command,&device,before,D3D12_RESOURCE_STATE_RENDER_TARGET,after,D3D12_RESOURCE_STATE_RENDER_TARGET,id);
 }
};

int main(){try{
 const auto directory=std::filesystem::current_path()/"capture-test-output";
 {Scene s;capture::FrameCapture batch;batch.request(1);const auto budgetBefore=capture::ProcessReadbackBudget().used();s.record(batch);
  CHECK(capture::ProcessReadbackBudget().used()>budgetBefore);
  const auto maps=captureMaps,released=captureReleases,allocations=captureAllocations;
  CHECK(s.command.copies==2&&batch.progress()==1&&s.before->refs==2&&s.after->refs==2);
  for(unsigned cpuFrame=0;cpuFrame<100;++cpuFrame){CHECK(!batch.readyToWrite());CHECK(batch.write(directory).empty());}
  CHECK(captureMaps==maps&&!batch.release()&&captureReleases==released);
  CHECK(capture::ProcessReadbackBudget().used()>budgetBefore); // Retain reservation while a GPU consumer can replay this recording.
  batch.request(8);s.record(batch);CHECK(s.command.copies==2&&captureAllocations==allocations);
  s.command.use->completed=true; // First fence completes, but game list can replay.
  CHECK(!batch.readyToWrite()&&!batch.release()&&captureMaps==maps);
  s.command.use->retired=true;CHECK(batch.readyToWrite());
  CHECK(!batch.write(directory).empty()&&captureMaps==maps+3&&!batch.isActive());
  CHECK(capture::ProcessReadbackBudget().used()==budgetBefore);
  CHECK(s.before->refs==1&&s.after->refs==1);
  CHECK(std::filesystem::file_size(directory/"before_00.raw")==16384);
  std::ifstream manifest(directory/"manifest.txt");std::string text((std::istreambuf_iterator<char>(manifest)),{});
  CHECK(text.find("owner 11 generation 12 view 0 frameToken 13 ticket 14 recording 1")!=std::string::npos);
 }
 {Scene s;capture::FrameCapture batch;batch.request(2);s.record(batch);auto old=s.command.use;
  s.next(2);s.record(batch,{11,12,0,14,15});s.command.use->retired=s.command.use->completed=true;
  auto maps=captureMaps;CHECK(!batch.readyToWrite()&&batch.write(directory).empty()&&captureMaps==maps);
  old->completed=true;CHECK(!batch.readyToWrite()); // Other queue/retirement still unresolved.
  old->retired=true;CHECK(batch.readyToWrite());CHECK(!batch.write(directory).empty());
 }
 {Scene s;capture::FrameCapture batch;batch.request(1);s.record(batch);auto maps=captureMaps;
  s.command.use->retired=true; // Never submitted / reset recording: discard, never Map.
  CHECK(!batch.readyToWrite());CHECK(batch.write(directory).empty()&&captureMaps==maps);
  CHECK(batch.isActive()&&batch.progress()==0&&s.before->refs==1);
  CHECK(batch.release());
 }
 {Scene s;capture::FrameCapture batch;batch.request(2);s.record(batch);auto maps=captureMaps,copies=s.command.copies;
  s.before->desc.Width=128;s.record(batch);CHECK(s.command.copies==copies);
  CHECK(batch.write(directory).empty()&&!batch.release()&&captureMaps==maps);
  s.command.use->retired=s.command.use->completed=true;
  CHECK(batch.write(directory).empty()&&batch.isActive()&&batch.progress()==0&&captureMaps==maps);
  CHECK(batch.release());
 }
 {Scene s;capture::FrameCapture batch;batch.request(2);s.record(batch);auto maps=captureMaps;
  s.record(batch,{11,13,0,14,15});CHECK(s.command.copies==2); // Same-sized recreated output.
  s.command.use->retired=s.command.use->completed=true;
  CHECK(batch.write(directory).empty()&&captureMaps==maps&&batch.progress()==0);CHECK(batch.release());
 }
 {Scene s;capture::FrameCapture batch;batch.request(1);s.record(batch);auto maps=captureMaps,released=captureReleases;
  // Failed Signal / device removal remains unknown, regardless of CPU progress.
  for(unsigned i=0;i<32;++i){CHECK(!batch.release()&&batch.write(directory).empty());}
  CHECK(captureMaps==maps&&captureReleases==released);
  s.command.use->retired=true; // Fixture teardown injects cancellation only now.
  CHECK(batch.write(directory).empty()&&captureMaps==maps);CHECK(batch.release());
 }
 {Scene a,b;capture::FrameCapture one,two;one.request(1);two.request(1);a.record(one);b.record(two,{21,22,1,23,24});
  a.command.use->retired=a.command.use->completed=true;
  CHECK(one.readyToWrite()&&!two.readyToWrite());CHECK(!one.write(directory).empty());
  CHECK(!two.release());b.command.use->retired=true;CHECK(two.write(directory).empty());CHECK(two.release());
 }
 {Scene s;capture::FrameCapture batch;batch.request(100);
  for(unsigned i=0;i<12;++i){s.next(i+1);s.command.use->retired=s.command.use->completed=true;s.record(batch,{11,12,0,i+1,i+1});}
  CHECK(batch.progress()==8&&s.command.copies==16&&batch.readyToWrite());CHECK(!batch.write(directory).empty());
 }
 {Scene s;capture::FrameCapture batch;batch.request(2);s.device.failAllocationAfter=1;auto maps=captureMaps,released=captureReleases;
  s.record(batch);CHECK(s.command.copies==0);CHECK(batch.write(directory).empty()&&!batch.isActive());
  CHECK(captureMaps==maps&&captureReleases==released+1); // Partial allocation freed, never submitted.
 }
 {Scene s;capture::FrameCapture batch;batch.request(capture::kMaxFrames);auto allocations=captureAllocations,copies=s.command.copies;
  captureFootprintOverride=capture::kMaxReadbackBytes/(capture::kMaxFrames*2)+1;
  s.record(batch);captureFootprintOverride=0;
  CHECK(s.command.copies==copies&&captureAllocations==allocations);
  CHECK(batch.write(directory).empty()&&!batch.isActive()); // Reject over-budget 8-frame readback before allocation.
 }
 {Scene s;capture::FrameCapture batch;batch.request(1);auto allocations=captureAllocations,copies=s.command.copies;
  captureFootprintOverride=UINT64_MAX-1;
  s.record(batch);captureFootprintOverride=0;
  CHECK(s.command.copies==copies&&captureAllocations==allocations);
  CHECK(batch.write(directory).empty()&&!batch.isActive()); // Invalid/overflow-sized device footprint fails closed.
 }
 {auto& budget=capture::ProcessReadbackBudget();const auto before=budget.used();
  CHECK(before==0&&budget.tryReserve(capture::kMaxProcessReadbackBytes-1));
  Scene s;capture::FrameCapture batch;batch.request(1);auto allocations=captureAllocations,copies=s.command.copies;
  s.record(batch);
  CHECK(s.command.copies==copies&&captureAllocations==allocations); // A second output cannot exceed the process-wide cap.
  CHECK(budget.used()==capture::kMaxProcessReadbackBytes-1);
  CHECK(batch.write(directory).empty()&&!batch.isActive()&&budget.used()==capture::kMaxProcessReadbackBytes-1);
  budget.release(capture::kMaxProcessReadbackBytes-1);CHECK(budget.used()==0);
 }
 {capture::ReadbackBudget budget(100);std::atomic<unsigned> accepted{0};std::vector<std::thread> workers;
  for(unsigned i=0;i<32;++i)workers.emplace_back([&]{if(budget.tryReserve(10))accepted.fetch_add(1,std::memory_order_relaxed);});
  for(auto& worker:workers)worker.join();
  CHECK(accepted.load()==10&&budget.used()==100); // Concurrent output requests cannot oversubscribe the shared limit.
  budget.release(100);CHECK(budget.used()==0);
 }
 {Scene s;capture::FrameCapture batch;batch.request(1);s.record(batch);s.command.use->retired=s.command.use->completed=true;
  captureMapFails=true;CHECK(batch.write(directory).empty());captureMapFails=false;
  CHECK(!batch.isActive()&&!std::filesystem::exists(directory/"manifest.txt"));
 }
 std::filesystem::remove_all(directory);
 std::cout<<checks<<" production FrameCapture ownership/Map/release/per-batch and process-wide 512-MiB budget checks passed with injected resources and exact lease states; no GPU execution tested\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
