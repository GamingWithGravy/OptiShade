#include "SimulatorRoute.h"
#include "D3D12SubmissionRegistry.h"
#include "NativeFgAssembly.h"
#include "NrGpuLifetime.h"
#include <dxgi1_6.h>
#include <iostream>
#include <stdexcept>
#include <string>
#include <chrono>
#include <thread>
#include <vector>
#pragma comment(lib,"d3d12.lib")
#pragma comment(lib,"dxgi.lib")
using Microsoft::WRL::ComPtr;
using namespace optishade::route;
#define CHECK(x) do { if(!(x)) throw std::runtime_error(#x); } while(0)
static void Drop(SubmissionResult& r) {
 if(r.queue)reinterpret_cast<IUnknown*>(r.queue)->Release();
 if(r.fence)reinterpret_cast<IUnknown*>(r.fence)->Release();r={};
}
static void Complete(SubmissionRegistry& r,ID3D12CommandList* command,uint64_t generation) {
 auto end=std::chrono::steady_clock::now()+std::chrono::seconds(5);
 for(;;){SubmissionResult result{};bool found=r.Query(command,result,generation);
  const bool done=found&&result.completed;Drop(result);if(done)return;
  CHECK(std::chrono::steady_clock::now()<end);std::this_thread::sleep_for(std::chrono::milliseconds(1));}
}
int main(){try {
 {NativeFgAssembly assembly;ProducerFrame frame;
 ProducerIdentity left{1,10,100,50,0},right{2,1,100,50,1};
 CHECK(assembly.Begin(left,frame));CHECK(assembly.Retire(left));
 CHECK(assembly.Begin(right,frame));CHECK(assembly.Retire(right));
 CHECK(!assembly.Begin(left,frame));CHECK(!assembly.Begin(right,frame));
 auto oldLeft=left;oldLeft.generation=9;oldLeft.frame=100;CHECK(!assembly.Begin(oldLeft,frame));
 auto newRight=right;newRight.frame=51;CHECK(assembly.Begin(newRight,frame));CHECK(assembly.Retire(newRight));
 auto otherDevice=left;otherDevice.device=200;otherDevice.generation=1;CHECK(assembly.Begin(otherDevice,frame));
 CHECK(assembly.Retire(otherDevice));
 }

 ComPtr<IDXGIFactory4> factory;CHECK(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
 ComPtr<IDXGIAdapter> warp;CHECK(SUCCEEDED(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp))));
 ComPtr<ID3D12Device> device;CHECK(SUCCEEDED(D3D12CreateDevice(warp.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))));
 ComPtr<ID3D12CommandAllocator> allocator;CHECK(SUCCEEDED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator))));
 ComPtr<ID3D12GraphicsCommandList> command;CHECK(SUCCEEDED(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&command))));
 SubmissionRegistry registry;SubmissionResult result{};CHECK(registry.Recording(command.Get(),result));auto generation=result.generation;Drop(result);
 CHECK(SUCCEEDED(command->Close()));CHECK(registry.Close(command.Get()));CHECK(registry.Pin(command.Get(),generation,true));
 // Real D3D12 software queues: completed queue turnover must not exhaust the
 // bounded timeline table or lose the pinned command generation.
 for(unsigned n=0;n<40;++n){ComPtr<ID3D12CommandQueue> queue;D3D12_COMMAND_QUEUE_DESC desc{};
  CHECK(SUCCEEDED(device->CreateCommandQueue(&desc,IID_PPV_ARGS(&queue))));
  ID3D12CommandList* lists[]={command.Get()};queue->ExecuteCommandLists(1,lists);
  if(!registry.Observe(queue.Get(),command.Get()))throw std::runtime_error("completed queue turnover rejected at queue "+std::to_string(n+1));
  Complete(registry,command.Get(),generation);CHECK(!registry.Retired(command.Get(),generation));
 }
 CHECK(registry.RetirePrivate(command.Get()));CHECK(registry.Retired(command.Get(),generation));CHECK(registry.Pin(command.Get(),generation,false));
 // XP12's Vulkan bridge must retire its private command-list generation before
 // NR shutdown, but only after the bridge fence proves its GPU work complete.
 // Model the production lease against a deliberately gated WARP queue.
 {
  ComPtr<ID3D12CommandAllocator> privateAllocator;CHECK(SUCCEEDED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&privateAllocator))));
  ComPtr<ID3D12GraphicsCommandList> privateCommand;CHECK(SUCCEEDED(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,privateAllocator.Get(),nullptr,IID_PPV_ARGS(&privateCommand))));
  ComPtr<ID3D12CommandQueue> privateQueue;D3D12_COMMAND_QUEUE_DESC privateDesc{};CHECK(SUCCEEDED(device->CreateCommandQueue(&privateDesc,IID_PPV_ARGS(&privateQueue))));
  ComPtr<ID3D12Fence> privateGate;CHECK(SUCCEEDED(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&privateGate))));
  auto& lifetime=optishade::nr_lifetime::Registry();auto& active=optishade::nr_lifetime::Active();CHECK(active.Ready());
  SubmissionResult privateState{};CHECK(lifetime.Recording(privateCommand.Get(),privateState,true));auto privateGeneration=privateState.generation;Drop(privateState);
  auto use=optishade::nr_lifetime::Capture(privateCommand.Get());CHECK(use&&use->Generation()==privateGeneration);CHECK(active.Add(use));use.reset();
  CHECK(SUCCEEDED(privateCommand->Close()));optishade::nr_lifetime::Closed(privateCommand.Get());
  CHECK(SUCCEEDED(privateQueue->Wait(privateGate.Get(),1)));ID3D12CommandList* privateLists[]={privateCommand.Get()};privateQueue->ExecuteCommandLists(1,privateLists);
  optishade::nr_lifetime::Submitted(privateQueue.Get(),privateCommand.Get());
  CHECK(lifetime.RetirePrivate(privateCommand.Get()));CHECK(!active.Ready());
  CHECK(SUCCEEDED(privateGate->Signal(1)));Complete(lifetime,privateCommand.Get(),privateGeneration);CHECK(active.Ready());
 }
 // A game list NR recorded into reports why its lease is pending. Only a
 // submitted, GPU-finished generation that was never Reset is FinishedNotReset;
 // it stays unretired (a replay remains possible) until the game resets it.
 {
  using Wait=optishade::nr_lifetime::Lease::Wait;
  ComPtr<ID3D12CommandAllocator> gameAllocator;CHECK(SUCCEEDED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&gameAllocator))));
  ComPtr<ID3D12GraphicsCommandList> gameCommand;CHECK(SUCCEEDED(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,gameAllocator.Get(),nullptr,IID_PPV_ARGS(&gameCommand))));
  ComPtr<ID3D12CommandQueue> gameQueue;D3D12_COMMAND_QUEUE_DESC gameDesc{};CHECK(SUCCEEDED(device->CreateCommandQueue(&gameDesc,IID_PPV_ARGS(&gameQueue))));
  ComPtr<ID3D12Fence> gameGate;CHECK(SUCCEEDED(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&gameGate))));
  auto& lifetime=optishade::nr_lifetime::Registry();
  SubmissionResult state{};CHECK(lifetime.Recording(gameCommand.Get(),state,true));auto gameGeneration=state.generation;Drop(state);
  auto use=optishade::nr_lifetime::Capture(gameCommand.Get());CHECK(use);
  CHECK(use->State()==Wait::Unsubmitted);
  CHECK(SUCCEEDED(gameCommand->Close()));optishade::nr_lifetime::Closed(gameCommand.Get());CHECK(use->State()==Wait::Unsubmitted);
  CHECK(SUCCEEDED(gameQueue->Wait(gameGate.Get(),1)));ID3D12CommandList* gameLists[]={gameCommand.Get()};gameQueue->ExecuteCommandLists(1,gameLists);
  optishade::nr_lifetime::Submitted(gameQueue.Get(),gameCommand.Get());CHECK(use->State()==Wait::InFlight);
  CHECK(SUCCEEDED(gameGate->Signal(1)));Complete(lifetime,gameCommand.Get(),gameGeneration);
  CHECK(use->State()==Wait::FinishedNotReset);CHECK(!use->Ready());
  CHECK(SUCCEEDED(gameCommand->Reset(gameAllocator.Get(),nullptr)));optishade::nr_lifetime::Reset(gameCommand.Get());
  CHECK(use->State()==Wait::Retired);CHECK(use->Ready());CHECK(SUCCEEDED(gameCommand->Close()));
 }
 // Delayed consumers must not let the production NR use set grow without
 // bound. Hold 256 never-retired generations, then prove admission rejects
 // another generation while preserving every outstanding lease. Re-adding an
 // already-held generation is idempotent and does not consume extra capacity.
 {
  optishade::nr_lifetime::Uses bounded;
  std::vector<optishade::nr_lifetime::Use> delayed;
  delayed.reserve(256);
  for(uint64_t n=1;n<=256;++n){
   auto lease=std::make_shared<optishade::nr_lifetime::Lease>(nullptr,100000+n);
   CHECK(bounded.Add(lease));delayed.push_back(std::move(lease));
  }
  CHECK(bounded.items.size()==256);CHECK(!bounded.Ready());
  CHECK(bounded.Add(delayed.front()));CHECK(bounded.items.size()==256);
  auto overflow=std::make_shared<optishade::nr_lifetime::Lease>(nullptr,100257);
  CHECK(!bounded.Add(overflow));CHECK(bounded.items.size()==256);CHECK(!bounded.Ready());
 }
 // Shutdown diagnostics expose pending binding generations and retained COM
 // references without treating them as safe to release.
 {
  auto& held=optishade::nr_lifetime::HeldObjects();CHECK(held.empty());
  ComPtr<ID3D12Fence> marker;CHECK(SUCCEEDED(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&marker))));
  optishade::nr_lifetime::Held binding;binding.use=std::make_shared<optishade::nr_lifetime::Lease>(nullptr,200001);
  ComPtr<IUnknown> retained=marker;binding.objects.push_back(retained);held.push_back(std::move(binding));
  auto snapshot=optishade::nr_lifetime::SnapshotHeld();
  CHECK(snapshot.groups==1&&snapshot.objects==1&&snapshot.pending==1);
  held.clear();snapshot=optishade::nr_lifetime::SnapshotHeld();
  CHECK(snapshot.groups==0&&snapshot.objects==0&&snapshot.pending==0);
 }
 // Pressure is different from turnover: sixteen genuinely pending queues
 // must remain retained. The seventeenth executed list becomes unresolved.
 SubmissionRegistry pressure;ComPtr<ID3D12Fence> gate;CHECK(SUCCEEDED(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&gate))));
 struct ReleaseGate {ID3D12Fence* fence;~ReleaseGate(){fence->Signal(1);}} release{gate.Get()};
 std::vector<ComPtr<ID3D12CommandQueue>> queues;
 std::vector<ComPtr<ID3D12GraphicsCommandList>> lists;std::vector<uint64_t> generations;
 for(unsigned n=0;n<17;++n){
  ComPtr<ID3D12CommandQueue> q;D3D12_COMMAND_QUEUE_DESC desc{};CHECK(SUCCEEDED(device->CreateCommandQueue(&desc,IID_PPV_ARGS(&q))));
  ComPtr<ID3D12GraphicsCommandList> c;CHECK(SUCCEEDED(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&c))));
  CHECK(pressure.Recording(c.Get(),result));generations.push_back(result.generation);Drop(result);
  CHECK(SUCCEEDED(c->Close()));CHECK(pressure.Close(c.Get()));CHECK(pressure.Pin(c.Get(),generations.back(),true));
  CHECK(SUCCEEDED(q->Wait(gate.Get(),1)));ID3D12CommandList* batch[]={c.Get()};q->ExecuteCommandLists(1,batch);
  CHECK(pressure.Observe(q.Get(),c.Get())==(n<16));CHECK(!pressure.Retired(c.Get(),generations.back()));
  queues.push_back(q);lists.push_back(c);
 }
 CHECK(SUCCEEDED(gate->Signal(1)));
 for(unsigned n=0;n<16;++n){Complete(pressure,lists[n].Get(),generations[n]);CHECK(pressure.RetirePrivate(lists[n].Get()));CHECK(pressure.Retired(lists[n].Get(),generations[n]));CHECK(pressure.Pin(lists[n].Get(),generations[n],false));}
 CHECK(pressure.RetirePrivate(lists.back().Get()));CHECK(!pressure.Retired(lists.back().Get(),generations.back()));
 // Saturation does not permanently block new work after the old queues drain.
 CHECK(SUCCEEDED(command->Reset(allocator.Get(),nullptr)));CHECK(pressure.Recording(command.Get(),result));generation=result.generation;Drop(result);
 CHECK(SUCCEEDED(command->Close()));CHECK(pressure.Close(command.Get()));ID3D12CommandList* batch[]={command.Get()};queues.back()->ExecuteCommandLists(1,batch);
 CHECK(pressure.Observe(queues.back().Get(),command.Get()));Complete(pressure,command.Get(),generation);
 std::cout<<"D3D12 WARP: 40 completed queue turnovers, 17-queue pending pressure, 256-generation NR lease bound, game-list lease wait states, retained-binding shutdown metrics, exact pinned retirement and recovery passed; not simulator output.\n";
 return 0;
 }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
