#include "PrivateD3D11NrBridge.h"
#include <iostream>
#include <stdexcept>
#include <type_traits>
#include "../../Beta/reshade/res/shaders/optishade_guides.dxbc.h"
#pragma comment(lib,"d3d11.lib")
#pragma comment(lib,"d3d12.lib")
#pragma comment(lib,"dxgi.lib")
using Microsoft::WRL::ComPtr;
static_assert(!std::is_copy_constructible_v<optishade::d11nr::Bridge>);
static_assert(!std::is_copy_assignable_v<optishade::d11nr::Bridge>);
static_assert(!std::is_move_constructible_v<optishade::d11nr::Bridge>);
static_assert(!std::is_move_assignable_v<optishade::d11nr::Bridge>);
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
int main(){try{
 ComPtr<IDXGIFactory1> factory;CHECK(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
 ComPtr<IDXGIAdapter1> adapter;DXGI_ADAPTER_DESC1 desc{};
 for(UINT i=0;;++i){ComPtr<IDXGIAdapter1> candidate;if(factory->EnumAdapters1(i,&candidate)==DXGI_ERROR_NOT_FOUND)break;candidate->GetDesc1(&desc);if(desc.VendorId==0x10de){adapter=candidate;break;}}
 CHECK(adapter);ComPtr<ID3D11Device> device;ComPtr<ID3D11DeviceContext> context;
 CHECK(SUCCEEDED(D3D11CreateDevice(adapter.Get(),D3D_DRIVER_TYPE_UNKNOWN,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,&context)));
 // The SM5 payload must be accepted by a real D3D11 driver, not just FXC.
 ComPtr<ID3D11ComputeShader> shaders[3];
 const unsigned char* code[]={osguide::shaders::Prepare_dxbc,osguide::shaders::Estimate_dxbc,osguide::shaders::Resolve_dxbc};
 const size_t sizes[]={sizeof(osguide::shaders::Prepare_dxbc),sizeof(osguide::shaders::Estimate_dxbc),sizeof(osguide::shaders::Resolve_dxbc)};
 for(unsigned i=0;i<3;i++)CHECK(SUCCEEDED(device->CreateComputeShader(code[i],sizes[i],nullptr,&shaders[i])));
 for(UINT width:{64u,128u}){
  ComPtr<ID3D11Texture2D> textures[3];ID3D11Texture2D* inputs[3]{};
  for(unsigned i=0;i<3;i++){
   D3D11_TEXTURE2D_DESC d{};d.Width=width;d.Height=64;d.MipLevels=d.ArraySize=d.SampleDesc.Count=1;d.Format=i==0?DXGI_FORMAT_R8G8B8A8_UNORM:i==1?DXGI_FORMAT_R32_FLOAT:DXGI_FORMAT_R16G16_FLOAT;d.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
   CHECK(SUCCEEDED(device->CreateTexture2D(&d,nullptr,&textures[i])));inputs[i]=textures[i].Get();
   ComPtr<ID3D11RenderTargetView> view;CHECK(SUCCEEDED(device->CreateRenderTargetView(inputs[i],nullptr,&view)));float colour[4]={0.25f,0.5f,0.75f,1};context->ClearRenderTargetView(view.Get(),colour);
  }
  optishade::d11nr::Bridge bridge;if(!bridge.Init(device.Get(),inputs))throw std::runtime_error(bridge.Reason());
  CHECK(bridge.Matches(device.Get(),inputs));
  auto evaluate=[](ID3D12CommandQueue* queue,ID3D12Resource* colour,ID3D12Resource*,ID3D12Resource*){
   ComPtr<ID3D12Device> d;CHECK(SUCCEEDED(queue->GetDevice(IID_PPV_ARGS(&d))));
   ComPtr<ID3D12CommandAllocator> a;CHECK(SUCCEEDED(d->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&a))));
   ComPtr<ID3D12GraphicsCommandList> c;CHECK(SUCCEEDED(d->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,a.Get(),nullptr,IID_PPV_ARGS(&c))));
   D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.NumDescriptors=1;hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;ComPtr<ID3D12DescriptorHeap> heap;CHECK(SUCCEEDED(d->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&heap))));
   auto handle=heap->GetCPUDescriptorHandleForHeapStart();d->CreateRenderTargetView(colour,nullptr,handle);float value[4]={1,0,0,1};c->ClearRenderTargetView(handle,value,0,nullptr);CHECK(SUCCEEDED(c->Close()));
   ID3D12CommandList* lists[]{c.Get()};queue->ExecuteCommandLists(1,lists);ComPtr<ID3D12Fence> done;CHECK(SUCCEEDED(d->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&done))));CHECK(SUCCEEDED(queue->Signal(done.Get(),1)));
   HANDLE e=CreateEventW(nullptr,FALSE,FALSE,nullptr);CHECK(e);CHECK(SUCCEEDED(done->SetEventOnCompletion(1,e)));const auto result=WaitForSingleObject(e,5000);CloseHandle(e);CHECK(result==WAIT_OBJECT_0);return true;
  };
  for(unsigned frame=0;frame<8;frame++)if(!bridge.Run(inputs,evaluate))throw std::runtime_error(bridge.Reason());
  D3D11_TEXTURE2D_DESC read{};textures[0]->GetDesc(&read);read.BindFlags=read.MiscFlags=0;read.Usage=D3D11_USAGE_STAGING;read.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
  ComPtr<ID3D11Texture2D> staging;CHECK(SUCCEEDED(device->CreateTexture2D(&read,nullptr,&staging)));context->CopyResource(staging.Get(),textures[0].Get());
  D3D11_MAPPED_SUBRESOURCE mapped{};CHECK(SUCCEEDED(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped)));const auto* pixel=static_cast<unsigned char*>(mapped.pData);bool red=pixel[0]==255&&pixel[1]==0&&pixel[2]==0&&pixel[3]==255;context->Unmap(staging.Get(),0);CHECK(red);CHECK(bridge.ReadyToRetire());
 }
 std::wcout<<L"Physical D3D11/D3D12 same-adapter transport: "<<desc.Description<<L"; 16 colour replacement/readback frames, two extents; three SM5 guide shaders created. No NR model or game validation.\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
