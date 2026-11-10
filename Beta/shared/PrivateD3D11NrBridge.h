#pragma once
#include <d3d11_4.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <array>
#include "D3D12FrameContext.h"
namespace optishade::d11nr {
// One synchronous transaction, on the rendering adapter. Shared textures only
// transport copies; NR works on private D3D12 resources with explicit states.
// A failed completion quarantines the whole transaction; never reuse its memory.
class Bridge {
 template<class T> using Ptr=Microsoft::WRL::ComPtr<T>;
 struct Image {Ptr<ID3D11Texture2D> eleven;Ptr<ID3D12Resource> shared,work;D3D11_TEXTURE2D_DESC desc{};};
 Ptr<ID3D11Device5> d11;Ptr<ID3D11DeviceContext4> context;
 Ptr<ID3D12Device> d12;Ptr<ID3D12CommandQueue> queue;
 Ptr<ID3D11Fence> f11;Ptr<ID3D12Fence> fence;
 Ptr<ID3D12CommandAllocator> allocator;Ptr<ID3D12GraphicsCommandList> commands;
 std::array<Image,3> images;
 uint64_t value=0;bool inFlight=false,poisoned=false;
 const char* reason="D3D11 bridge not initialized";
 bool Fail(const char* text){reason=text;return false;}
 bool GpuFailure(const char* text){poisoned=true;return Fail(text);}
 bool Wait(){
  if(!inFlight)return true;
  if(!fence||fence->GetCompletedValue()==UINT64_MAX)return GpuFailure("D3D11 NR device lost");
  if(fence->GetCompletedValue()>=value){inFlight=false;return true;}
  HANDLE e=CreateEventW(nullptr,FALSE,FALSE,nullptr);if(!e)return GpuFailure("D3D11 NR completion event failed");
  const auto hr=fence->SetEventOnCompletion(value,e);
  const auto waited=SUCCEEDED(hr)?WaitForSingleObject(e,5000):WAIT_FAILED;CloseHandle(e);
  if(waited!=WAIT_OBJECT_0||fence->GetCompletedValue()==UINT64_MAX||fence->GetCompletedValue()<value)return GpuFailure("D3D11 NR completion unknown; restart required");
  inFlight=false;return true;
 }
 static void Barrier(ID3D12GraphicsCommandList* cmd,ID3D12Resource* resource,D3D12_RESOURCE_STATES before,D3D12_RESOURCE_STATES after){
  D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;b.Transition={resource,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,before,after};cmd->ResourceBarrier(1,&b);
 }
 bool Record(){return SUCCEEDED(allocator->Reset())&&SUCCEEDED(commands->Reset(allocator.Get(),nullptr));}
 bool Execute(){
  if(FAILED(commands->Close()))return GpuFailure("D3D11 NR bridge command close failed");
  ID3D12CommandList* lists[]{commands.Get()};inFlight=true;queue->ExecuteCommandLists(1,lists);
  if(FAILED(queue->Signal(fence.Get(),++value)))return GpuFailure("D3D11 NR bridge signal failed");
  return Wait();
 }
 bool MakeImage(Image& image,const D3D11_TEXTURE2D_DESC& source){
  image.desc=source;auto shared=source;shared.Usage=D3D11_USAGE_DEFAULT;shared.BindFlags=D3D11_BIND_SHADER_RESOURCE|D3D11_BIND_RENDER_TARGET;
  shared.CPUAccessFlags=0;shared.MiscFlags=D3D11_RESOURCE_MISC_SHARED_NTHANDLE|D3D11_RESOURCE_MISC_SHARED;
  if(FAILED(d11->CreateTexture2D(&shared,nullptr,&image.eleven)))return Fail("D3D11 format cannot be shared with D3D12");
  Ptr<IDXGIResource1> resource;if(FAILED(image.eleven.As(&resource)))return false;
  HANDLE h=nullptr;if(FAILED(resource->CreateSharedHandle(nullptr,DXGI_SHARED_RESOURCE_READ|DXGI_SHARED_RESOURCE_WRITE,nullptr,&h)))return false;
  const auto hr=d12->OpenSharedHandle(h,IID_PPV_ARGS(&image.shared));CloseHandle(h);if(FAILED(hr))return Fail("D3D12 could not open the D3D11 image");
  auto desc=image.shared->GetDesc();desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET|D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
  D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_DEFAULT;
  return SUCCEEDED(d12->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_COMMON,nullptr,IID_PPV_ARGS(&image.work)));
 }
public:
 Bridge()=default;
 Bridge(const Bridge&)=delete;
 Bridge& operator=(const Bridge&)=delete;
 Bridge(Bridge&&)=delete;
 Bridge& operator=(Bridge&&)=delete;
 const char* Reason()const{return reason;}
 bool Poisoned()const{return poisoned;}
 bool ReadyToRetire()const{return !poisoned&&(!inFlight||(fence&&fence->GetCompletedValue()!=UINT64_MAX&&fence->GetCompletedValue()>=value));}
 ID3D12CommandQueue* Queue()const{return queue.Get();}
 ID3D12Device* Device()const{return d12.Get();}
 bool Matches(ID3D11Device* device,ID3D11Texture2D* const* inputs)const{
  if(ReShadeObjectIdentity(device)!=ReShadeObjectIdentity(d11.Get()))return false;
  for(unsigned i=0;i<3;i++){if(!inputs[i])return false;Ptr<ID3D11Device> owner;inputs[i]->GetDevice(&owner);if(ReShadeObjectIdentity(owner.Get())!=ReShadeObjectIdentity(device))return false;D3D11_TEXTURE2D_DESC desc{};inputs[i]->GetDesc(&desc);const auto& old=images[i].desc;
   if(desc.Width!=old.Width||desc.Height!=old.Height||desc.Format!=old.Format||desc.ArraySize!=old.ArraySize||desc.MipLevels!=old.MipLevels||desc.SampleDesc.Count!=old.SampleDesc.Count)return false;}
  return true;
 }
 bool Init(ID3D11Device* device,ID3D11Texture2D* const* inputs,ID3D12Device* reuse=nullptr,ID3D12CommandQueue* reuseQueue=nullptr){
  if(!device||FAILED(device->QueryInterface(IID_PPV_ARGS(&d11))))return Fail("D3D11.4 shared-fence support is required");
  Ptr<ID3D11DeviceContext> immediate;device->GetImmediateContext(&immediate);
  if(!immediate||FAILED(immediate.As(&context)))return Fail("D3D11.4 immediate context is unavailable");
  Ptr<IDXGIDevice> dxgi;Ptr<IDXGIAdapter> adapter;DXGI_ADAPTER_DESC adapterDesc{};
  if(FAILED(device->QueryInterface(IID_PPV_ARGS(&dxgi)))||FAILED(dxgi->GetAdapter(&adapter))||FAILED(adapter->GetDesc(&adapterDesc)))return Fail("Rendering adapter could not be identified");
  if(adapterDesc.VendorId!=0x10de)return Fail("No qualified NR inference backend for this rendering adapter");
  d12=reuse;queue=reuseQueue;
  if(!d12&&FAILED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_12_0,IID_PPV_ARGS(&d12))))return Fail("Matching D3D12 inference device unavailable");
  const auto luid=d12->GetAdapterLuid();if(luid.HighPart!=adapterDesc.AdapterLuid.HighPart||luid.LowPart!=adapterDesc.AdapterLuid.LowPart)return Fail("NR adapter identity mismatch");
  D3D12_COMMAND_QUEUE_DESC q{};
  if((!queue&&FAILED(d12->CreateCommandQueue(&q,IID_PPV_ARGS(&queue))))||FAILED(d12->CreateFence(0,D3D12_FENCE_FLAG_SHARED,IID_PPV_ARGS(&fence))))return false;
  HANDLE h=nullptr;if(FAILED(d12->CreateSharedHandle(fence.Get(),nullptr,GENERIC_ALL,nullptr,&h)))return false;
  const auto hr=d11->OpenSharedFence(h,IID_PPV_ARGS(&f11));CloseHandle(h);if(FAILED(hr))return Fail("D3D11 cannot open the shared completion fence");
  if(FAILED(d12->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)))||FAILED(d12->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&commands)))||FAILED(commands->Close()))return false;
  for(unsigned i=0;i<3;i++){
   D3D11_TEXTURE2D_DESC desc{};inputs[i]->GetDesc(&desc);Ptr<ID3D11Device> owner;inputs[i]->GetDevice(&owner);
   if(ReShadeObjectIdentity(owner.Get())!=ReShadeObjectIdentity(device)||desc.SampleDesc.Count!=1||desc.ArraySize!=1||desc.MipLevels!=1)return Fail("D3D11 guides must be single-surface, single-sample resources on the rendering device");
   if(i&&(desc.Width!=images[0].desc.Width||desc.Height!=images[0].desc.Height))return Fail("D3D11 guide extents do not match colour");
   if((i==0&&desc.Format!=DXGI_FORMAT_R8G8B8A8_UNORM&&desc.Format!=DXGI_FORMAT_B8G8R8A8_UNORM)||(i==1&&desc.Format!=DXGI_FORMAT_R32_FLOAT)||(i==2&&desc.Format!=DXGI_FORMAT_R16G16_FLOAT))return Fail("D3D11 NR requires SDR colour, R32 depth and RG16 motion");
   if(!MakeImage(images[i],desc))return false;
  }
  reason="D3D11 bridge initialized; no inference observed";return true;
 }
 template<class Evaluate> bool Run(ID3D11Texture2D* const* inputs,Evaluate evaluate){
  if(poisoned||!Matches(d11.Get(),inputs)||!Wait())return false;
  for(unsigned i=0;i<3;i++)context->CopyResource(images[i].eleven.Get(),inputs[i]);
  inFlight=true;if(FAILED(context->Signal(f11.Get(),++value)))return GpuFailure("D3D11 producer signal failed");context->Flush();
  if(FAILED(queue->Wait(fence.Get(),value))||!Wait()||!Record())return GpuFailure("D3D11 producer completion failed");
  const auto read=D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
  for(unsigned i=0;i<3;i++){
   Barrier(commands.Get(),images[i].work.Get(),D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_COPY_DEST);
   commands->CopyResource(images[i].work.Get(),images[i].shared.Get());
   Barrier(commands.Get(),images[i].work.Get(),D3D12_RESOURCE_STATE_COPY_DEST,i?read:D3D12_RESOURCE_STATE_RENDER_TARGET);
  }
  if(!Execute())return false;
  // The callback must return only after its own queue completion. Failure may
  // leave work pending: quarantine instead of copying a stale/in-flight picture.
  if(!evaluate(queue.Get(),images[0].work.Get(),images[1].work.Get(),images[2].work.Get()))return GpuFailure("D3D11 neural transaction did not complete");
  if(!Record())return GpuFailure("D3D11 return command reset failed");
  Barrier(commands.Get(),images[0].work.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
  Barrier(commands.Get(),images[0].shared.Get(),D3D12_RESOURCE_STATE_COMMON,D3D12_RESOURCE_STATE_COPY_DEST);
  commands->CopyResource(images[0].shared.Get(),images[0].work.Get());
  Barrier(commands.Get(),images[0].shared.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_COMMON);
  for(unsigned i=0;i<3;i++)Barrier(commands.Get(),images[i].work.Get(),i?read:D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_COMMON);
  if(!Execute())return false;
  context->CopyResource(inputs[0],images[0].eleven.Get());
  inFlight=true;if(FAILED(context->Signal(f11.Get(),++value)))return GpuFailure("D3D11 return signal failed");context->Flush();
  if(!Wait())return false;reason="D3D11 transport completed; inference status is reported separately";return true;
 }
};
}
