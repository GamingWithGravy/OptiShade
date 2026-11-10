#include "SimulatorRoute.h"
#include "NativeFgAssembly.h"
#include <Windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cassert>
#include <iostream>
#pragma comment(lib,"d3d12.lib")
#pragma comment(lib,"dxgi.lib")
#pragma comment(lib,"user32.lib")
using namespace optishade::route;
using Microsoft::WRL::ComPtr;
extern "C" bool OptiShadeRouteQuery(Descriptor*,uint32_t);
extern "C" bool OptiShadeRouteConstants(const ConstantRequest*,uint32_t,void*,uint32_t);
extern "C" bool OptiShadeRoutePresentation(const PresentationRequest*,uint32_t,PresentationResult*,uint32_t);
extern "C" bool OptiShadeRouteSubmission(const SubmissionRequest*,uint32_t,SubmissionResult*,uint32_t);
extern "C" bool OptiShadeRouteFrameEvent(const FrameEventRequest*,uint32_t,uint32_t*);
int main(){
 Descriptor d;assert(OptiShadeRouteQuery(&d,sizeof(d))&&d.simulator==Simulator::Unknown&&d.api==Api::Dx12&&!d.externalFgObserver);
 assert(Identify(L"UnlistedEngine-Win64-Shipping.exe")==Simulator::Unknown);
 ConstantRequest c;c.device=11;c.owner=12;c.frame=30;c.view=0;c.event=ConstantEvent::Store;
 uint32_t value=42,read=0;c.payload=&value;c.payloadBytes=sizeof(value);
 assert(OptiShadeRouteConstants(&c,sizeof(c),nullptr,0));
 c.event=ConstantEvent::Read;assert(OptiShadeRouteConstants(&c,sizeof(c),&read,sizeof(read))&&read==value);
 c.owner=13;assert(!OptiShadeRouteConstants(&c,sizeof(c),&read,sizeof(read)));
 c.owner=12;c.frame=29;assert(!OptiShadeRouteConstants(&c,sizeof(c),&read,sizeof(read)));
 FrameEventRequest f;f.owner=12;f.device=11;f.frame=30;f.event=Event::Constants;
 assert(OptiShadeRouteFrameEvent(&f,sizeof(f),nullptr));f.event=Event::Frame;
 assert(OptiShadeRouteFrameEvent(&f,sizeof(f),&read)&&read==30);
 f.view=1;assert(!OptiShadeRouteFrameEvent(&f,sizeof(f),&read));
 ComPtr<IDXGIFactory4> factory;assert(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
 ComPtr<IDXGIAdapter> warp;assert(SUCCEEDED(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp))));
 ComPtr<ID3D12Device> device;assert(SUCCEEDED(D3D12CreateDevice(warp.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))));
 ComPtr<ID3D12CommandAllocator> allocator;assert(SUCCEEDED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator))));
 ComPtr<ID3D12GraphicsCommandList> list;assert(SUCCEEDED(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&list))));
 SubmissionRequest s;s.command=reinterpret_cast<uint64_t>(list.Get());s.event=SubmissionEvent::Recording;SubmissionResult out;
 assert(OptiShadeRouteSubmission(&s,sizeof(s),&out,sizeof(out))&&out.generation&&!out.completed);
 const auto generation=out.generation;assert(SUCCEEDED(list->Close()));s.event=SubmissionEvent::Close;
 assert(OptiShadeRouteSubmission(&s,sizeof(s),&out,sizeof(out)));
 s.event=SubmissionEvent::Query;s.generation=generation;
 assert(!OptiShadeRouteSubmission(&s,sizeof(s),&out,sizeof(out)));
 s.generation=0;
 assert(OptiShadeRouteSubmission(&s,sizeof(s),&out,sizeof(out))&&!out.completed&&out.phase==RecordingPhase::Closed);
 // A closed, never-submitted command remains unretired; queue idle cannot prove it safe.
 assert(!out.queue&&!out.fence);
 std::cout<<"Generic adapter: unlisted identity, isolated accepted constants/tokens, real WARP recording admission passed. No NR inference or game output claimed.\n";
}
