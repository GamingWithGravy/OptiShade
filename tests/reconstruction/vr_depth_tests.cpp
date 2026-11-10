#include <Windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <iostream>
#include <stdexcept>
#include <cmath>
#include "VrProjection.h"
using Microsoft::WRL::ComPtr;
static void hr(HRESULT h){if(FAILED(h))throw std::runtime_error("D3D12 operation failed");}
static void check(bool v){if(!v)throw std::runtime_error("VR depth assertion failed");}
int main(){try{
 using namespace optishade::vr;Slice c{128,64,2,1,64,0,128,64},d{64,64,2,1,0,0,64,64};check(!Pair(c,d));auto bad=d;bad.layer=2;check(Pair(c,bad));bad=d;bad.left=1;check(Pair(c,bad));bad=d;bad.width=65;check(Pair(c,bad));check(Range(0,1,.1f,1000));check(Range(0,1,1000,.1f));check(!Range(0,1,0,1));check(!Range(0,1,NAN,1));check(!Range(.2f,1,.1f,1000));
 ComPtr<IDXGIFactory4> factory;hr(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));ComPtr<IDXGIAdapter> adapter;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));ComPtr<ID3D12Device> device;hr(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));
 D3D12_COMMAND_QUEUE_DESC qd{};ComPtr<ID3D12CommandQueue> queue;hr(device->CreateCommandQueue(&qd,IID_PPV_ARGS(&queue)));
 for(auto format:{DXGI_FORMAT_D32_FLOAT,DXGI_FORMAT_D16_UNORM,DXGI_FORMAT_D24_UNORM_S8_UINT}){
  D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_DEFAULT;D3D12_RESOURCE_DESC desc{};desc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;desc.Width=desc.Height=64;desc.DepthOrArraySize=2;desc.MipLevels=1;desc.Format=format;desc.SampleDesc.Count=1;desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
  ComPtr<ID3D12Resource> source;hr(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_DEPTH_WRITE,nullptr,IID_PPV_ARGS(&source)));
  D3D12_DESCRIPTOR_HEAP_DESC dh{};dh.Type=D3D12_DESCRIPTOR_HEAP_TYPE_DSV;dh.NumDescriptors=2;ComPtr<ID3D12DescriptorHeap> descriptors;hr(device->CreateDescriptorHeap(&dh,IID_PPV_ARGS(&descriptors)));
  auto handle=descriptors->GetCPUDescriptorHandleForHeapStart();auto stride=device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_DSV);
  D3D12_DEPTH_STENCIL_VIEW_DESC vd{};vd.Format=format;vd.ViewDimension=D3D12_DSV_DIMENSION_TEXTURE2DARRAY;vd.Texture2DArray.ArraySize=1;
  for(unsigned eye=0;eye<2;++eye){vd.Texture2DArray.FirstArraySlice=eye;D3D12_CPU_DESCRIPTOR_HANDLE target{handle.ptr+eye*stride};device->CreateDepthStencilView(source.Get(),&vd,target);}
  desc.DepthOrArraySize=1;desc.Flags=D3D12_RESOURCE_FLAG_NONE;desc.Format=format==DXGI_FORMAT_D32_FLOAT?DXGI_FORMAT_R32_TYPELESS:format==DXGI_FORMAT_D16_UNORM?DXGI_FORMAT_R16_TYPELESS:DXGI_FORMAT_R24G8_TYPELESS;
  ComPtr<ID3D12Resource> dest[2],readback[2];D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT64 bytes=0;device->GetCopyableFootprints(&desc,0,1,0,&footprint,nullptr,nullptr,&bytes);
  for(unsigned eye=0;eye<2;++eye){hr(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_PPV_ARGS(&dest[eye])));D3D12_RESOURCE_DESC buffer{};buffer.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;buffer.Width=bytes;buffer.Height=1;buffer.DepthOrArraySize=buffer.MipLevels=1;buffer.SampleDesc.Count=1;buffer.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;auto readHeap=heap;readHeap.Type=D3D12_HEAP_TYPE_READBACK;hr(device->CreateCommittedResource(&readHeap,D3D12_HEAP_FLAG_NONE,&buffer,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_PPV_ARGS(&readback[eye])));}
  ComPtr<ID3D12CommandAllocator> allocator;hr(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)));ComPtr<ID3D12GraphicsCommandList> cmd;hr(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&cmd)));
  for(unsigned eye=0;eye<2;++eye){D3D12_CPU_DESCRIPTOR_HANDLE target{handle.ptr+eye*stride};cmd->ClearDepthStencilView(target,D3D12_CLEAR_FLAG_DEPTH,eye?.75f:.25f,0,0,nullptr);}
  auto barrier=[&](ID3D12Resource* r,D3D12_RESOURCE_STATES from,D3D12_RESOURCE_STATES to){D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;b.Transition={r,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,from,to};cmd->ResourceBarrier(1,&b);};
  barrier(source.Get(),D3D12_RESOURCE_STATE_DEPTH_WRITE,D3D12_RESOURCE_STATE_COPY_SOURCE);
  for(unsigned eye=0;eye<2;++eye){D3D12_TEXTURE_COPY_LOCATION src{},dst{};src.pResource=source.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;src.SubresourceIndex=eye;dst.pResource=dest[eye].Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;cmd->CopyTextureRegion(&dst,0,0,0,&src,nullptr);barrier(dest[eye].Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_COPY_SOURCE);src=dst;dst.pResource=readback[eye].Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;cmd->CopyTextureRegion(&dst,0,0,0,&src,nullptr);}
  barrier(source.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_DEPTH_WRITE);hr(cmd->Close());ID3D12CommandList* lists[]={cmd.Get()};queue->ExecuteCommandLists(1,lists);ComPtr<ID3D12Fence> fence;hr(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)));HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr);hr(queue->Signal(fence.Get(),1));hr(fence->SetEventOnCompletion(1,event));check(WaitForSingleObject(event,5000)==WAIT_OBJECT_0);CloseHandle(event);
  for(unsigned eye=0;eye<2;++eye){void* p=nullptr;hr(readback[eye]->Map(0,nullptr,&p));float value=format==DXGI_FORMAT_D32_FLOAT?*static_cast<float*>(p):format==DXGI_FORMAT_D16_UNORM?*static_cast<uint16_t*>(p)/65535.f:(*static_cast<uint32_t*>(p)&0xffffff)/16777215.f;check(std::abs(value-(eye?.75f:.25f))<.0001f);readback[eye]->Unmap(0,nullptr);}
 }
 std::cout<<"OpenXR projection contract and D3D12 WARP D16/D24/D32 array-eye extraction passed; no headset/model-output claim.\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
#pragma comment(lib,"d3d12.lib")
#pragma comment(lib,"dxgi.lib")
