#include <Windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <iostream>
#include <stdexcept>
#include "PresentationOwner.h"
#pragma comment(lib,"user32.lib")
#pragma comment(lib,"d3d12.lib")
#pragma comment(lib,"dxgi.lib")
using Microsoft::WRL::ComPtr;
#define CHECK(x) do {if(!(x))throw std::runtime_error(#x);}while(0)
int main(){
 HWND parent=CreateWindowExW(0,L"STATIC",L"Application",WS_OVERLAPPEDWINDOW,0,0,640,480,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
 HWND child=CreateWindowExW(0,L"STATIC",L"Render child",WS_CHILD,0,0,640,480,parent,nullptr,GetModuleHandleW(nullptr),nullptr);
 HWND owned=CreateWindowExW(0,L"STATIC",L"Owned render",WS_POPUP,0,0,640,480,parent,nullptr,GetModuleHandleW(nullptr),nullptr);
 HWND tool=CreateWindowExW(WS_EX_TOOLWINDOW,L"STATIC",L"Tool",WS_POPUP,0,0,640,480,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
 int result=0;
 try{
  CHECK(parent&&child&&owned&&tool);
  ComPtr<IDXGIFactory4> factory;CHECK(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
  ComPtr<IDXGIAdapter> warp;CHECK(SUCCEEDED(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp))));
  ComPtr<ID3D12Device> device;CHECK(SUCCEEDED(D3D12CreateDevice(warp.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))));
  ComPtr<ID3D12CommandQueue> queue;D3D12_COMMAND_QUEUE_DESC q{};CHECK(SUCCEEDED(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue))));
  optishade::PresentationOwner registry;
  for(HWND window:{child,owned}){
   CHECK(!registry.Accept(window,true)); // A window hint alone is insufficient.
   DXGI_SWAP_CHAIN_DESC1 desc{};desc.Width=640;desc.Height=480;desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
   desc.SampleDesc.Count=1;desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;desc.BufferCount=2;desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
   ComPtr<IDXGISwapChain1> chain;CHECK(SUCCEEDED(factory->CreateSwapChainForHwnd(queue.Get(),window,&desc,nullptr,nullptr,&chain)));
   HWND actual=nullptr;CHECK(SUCCEEDED(chain->GetHwnd(&actual))&&actual==window);
   ComPtr<IUnknown> identity;CHECK(SUCCEEDED(chain.As(&identity)));
   std::cout<<"Real D3D12 WARP swapchain created for "<<(window==child?"child":"owned")<<" HWND.\n";
   CHECK(registry.Accept(window,true,identity.Get()));
   auto generation=registry.Generation(window,identity.Get());CHECK(generation!=0);
   CHECK(registry.Accept(window,false));
   int other;CHECK(!registry.Accept(window,true,&other));
   CHECK(registry.Advance(identity.Get())>generation);
   registry.Retire(window,identity.Get());CHECK(!registry.Generation(window,identity.Get()));
  }
  int identity;CHECK(!registry.Accept(tool,true,&identity));CHECK(!registry.Accept(GetDesktopWindow(),true,&identity));
  CHECK(registry.Accept(parent,true,&identity));registry.Retire(parent,&identity);
  std::cout<<"Child/owned output admission, no-identity rejection, conflict, retirement, tool/foreign rejection passed; not game output.\n";
 }catch(const std::exception& e){std::cerr<<e.what()<<'\n';result=1;}
 DestroyWindow(child);DestroyWindow(owned);DestroyWindow(tool);DestroyWindow(parent);return result;
}
