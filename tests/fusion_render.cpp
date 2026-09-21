#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <vector>
#include "../shared/EffectsBridge.h"
#include <d3d12sdklayers.h>
#include <cstdio>
#include <stdexcept>
#include <filesystem>
using Microsoft::WRL::ComPtr;
static LONG CALLBACK Crash(EXCEPTION_POINTERS* p){
 if(p->ExceptionRecord->ExceptionCode!=EXCEPTION_STACK_OVERFLOW)return EXCEPTION_CONTINUE_SEARCH;FILE* f=nullptr;fopen_s(&f,"crash.log","w");if(f){fprintf(f,"Exception %08lX at %p\n",p->ExceptionRecord->ExceptionCode,p->ExceptionRecord->ExceptionAddress);void* stack[32];USHORT n=CaptureStackBackTrace(0,32,stack,nullptr);for(USHORT i=0;i<n;i++){HMODULE m=nullptr;wchar_t path[MAX_PATH]{};GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,(LPCWSTR)stack[i],&m);GetModuleFileNameW(m,path,MAX_PATH);fprintf(f,"%ls + %llx\n",path,(unsigned long long)((char*)stack[i]-(char*)m));}fclose(f);}ExitProcess(2);
}
static bool quitting=false;
static void ExceptionProbe(){
    // Deliberately handled first-chance exception: verifies logging without crashing.
    __try{RaiseException(EXCEPTION_ACCESS_VIOLATION,0,0,nullptr);}
    __except(EXCEPTION_EXECUTE_HANDLER){}
}
static LRESULT CALLBACK Proc(HWND h,UINT m,WPARAM w,LPARAM l){if(m==WM_DESTROY){quitting=true;PostQuitMessage(0);return 0;}return DefWindowProcW(h,m,w,l);}
static void Check(HRESULT hr){if(FAILED(hr)){char s[80];sprintf_s(s,"HRESULT %08lX",(unsigned long)hr);throw std::runtime_error(s);}}
static void Barrier(ID3D12GraphicsCommandList* cmd,ID3D12Resource* r,D3D12_RESOURCE_STATES a,D3D12_RESOURCE_STATES b){D3D12_RESOURCE_BARRIER x{};x.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;x.Transition={r,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,a,b};cmd->ResourceBarrier(1,&x);}
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,LPWSTR args,int){
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);wchar_t executable[32768]{};GetModuleFileNameW(nullptr,executable,32768);SetCurrentDirectoryW(std::filesystem::path(executable).parent_path().c_str());ULONG reserve=65536;SetThreadStackGuarantee(&reserve);SetUnhandledExceptionFilter(Crash);AddVectoredExceptionHandler(1,Crash);bool automatic=wcsstr(args,L"--auto")!=nullptr;bool idle=wcsstr(args,L"--idle")!=nullptr;FILE* report=nullptr;fopen_s(&report,"render-test.log","w");
    setvbuf(report,nullptr,_IONBF,0);try {
        ComPtr<ID3D12Debug> debug;bool debugOn=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugOn)debug->EnableDebugLayer();
        HMODULE dll=LoadLibraryW((std::filesystem::path(executable).parent_path()/L"winmm.dll").c_str());if(!dll)throw std::runtime_error("Performance DLL load failed");
        Sleep(2000);
        HMODULE effects=GetModuleHandleW(L"ReShade64.dll");if(!effects)effects=LoadLibraryW(L"ReShade64.dll");
        if(!effects)throw std::runtime_error("Effects DLL load failed");
        auto read=(osfx::Read)GetProcAddress(effects,"OptiShadeEffectsRead");auto send=(osfx::Send)GetProcAddress(effects,"OptiShadeEffectsSend");
        if(!read||!send)throw std::runtime_error("Effects bridge exports missing");
        static osfx::Snapshot snapshot{};        fprintf(report,"Hooks ready; creating host window\n");WNDCLASSW wc{};wc.hInstance=instance;wc.lpszClassName=L"OptiShadeRenderHost";wc.lpfnWndProc=Proc;wc.hCursor=LoadCursor(nullptr,IDC_ARROW);RegisterClassW(&wc);
        HWND window=CreateWindowW(wc.lpszClassName,L"OptiShade | Native D3D12 renderer test",WS_OVERLAPPEDWINDOW,100,100,1100,780,nullptr,nullptr,instance,nullptr);
        if(!automatic)ShowWindow(window,SW_SHOW);
        fprintf(report,"Window created; creating factory\n");ComPtr<IDXGIFactory4> factory;Check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
        fprintf(report,"Factory created; creating device\n");ComPtr<ID3D12Device> device;ComPtr<IDXGIAdapter1> adapter;
        for(UINT i=0;factory->EnumAdapters1(i,&adapter)!=DXGI_ERROR_NOT_FOUND;i++){DXGI_ADAPTER_DESC1 desc{};adapter->GetDesc1(&desc);if(desc.VendorId==0x10de&&SUCCEEDED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))break;adapter.Reset();}
        if(!device)throw std::runtime_error("NVIDIA D3D12 device unavailable");
        fprintf(report,"Device created\n");ComPtr<ID3D12InfoQueue> info;if(debugOn)device.As(&info);
        ComPtr<ID3D12CommandQueue> queue;D3D12_COMMAND_QUEUE_DESC q{};Check(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)));
        DXGI_SWAP_CHAIN_DESC1 desc{};desc.Width=1080;desc.Height=720;desc.BufferCount=3;desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;desc.SampleDesc.Count=1;desc.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;desc.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
        if(wcsstr(args,L"--recreate")){ComPtr<IDXGISwapChain1> bootstrap;Check(factory->CreateSwapChainForHwnd(queue.Get(),window,&desc,nullptr,nullptr,&bootstrap));bootstrap.Reset();fprintf(report,"Bootstrap swapchain released by host; recreating on same HWND\n");}
        ComPtr<IDXGISwapChain1> initial;Check(factory->CreateSwapChainForHwnd(queue.Get(),window,&desc,nullptr,nullptr,&initial));ComPtr<IDXGISwapChain3> swap;Check(initial.As(&swap));initial.Reset();
        ComPtr<ID3D12CommandAllocator> allocator;Check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)));
        ComPtr<ID3D12GraphicsCommandList> cmd;Check(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&cmd)));Check(cmd->Close());
        ComPtr<ID3D12DescriptorHeap> heap;D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;hd.NumDescriptors=1;Check(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&heap)));
        ComPtr<ID3D12Fence> fence;Check(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)));HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr);UINT64 serial=0;
        auto finish=[&](){Check(queue->Signal(fence.Get(),++serial));Check(fence->SetEventOnCompletion(serial,event));if(WaitForSingleObject(event,5000)!=WAIT_OBJECT_0)throw std::runtime_error("Host GPU timeout");};
        auto submit=[&](){Check(cmd->Close());ID3D12CommandList* list[]={cmd.Get()};queue->ExecuteCommandLists(1,list);finish();};
        for(int tick=0;!quitting&&(!automatic||tick<900);tick++){
            read(&snapshot,sizeof(snapshot)); // Request a fresh published snapshot, as the menu does.
            MSG msg;while(PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageW(&msg);}
            if(automatic&&tick==180){bool range=false;for(uint32_t i=0;i<snapshot.uniforms;i++){auto& u=snapshot.uniform[i];if(!strcmp(u.effect,"OptiShade_Test.fx")&&!strcmp(u.name,"Gain"))range=u.hasRange&&u.minimum==0.f&&u.maximum==4.f;}if(!range)throw std::runtime_error("Shader slider range was not published");fprintf(report,"Shader-authored slider limits reach the UI: PASS\n");}
            if(automatic&&(tick==200||tick==320||tick==360)){
                if(!read(&snapshot,sizeof(snapshot)))throw std::runtime_error("Effects runtime not connected");
                osfx::Command c{};c.version=osfx::Version;c.generation=snapshot.generation;
                strcpy_s(c.effect,"OptiShade_Test.fx");strcpy_s(c.name,"Gain");c.kind=osfx::Uniform;c.count=1;c.value[0]=1.5f;
                if(tick==320){c.kind=osfx::Technique;strcpy_s(c.name,"OptiShade_Test");c.enabled=0;}
                if(tick==360){c.kind=osfx::Technique;strcpy_s(c.name,"OptiShade_Test");c.enabled=1;}
                if(!send(&c,sizeof(c)))throw std::runtime_error("Bridge rejected valid change");
            }
            if(automatic&&tick==290){
                if(!snapshot.dirty)throw std::runtime_error("Edited preset was not marked dirty");
                read(&snapshot,sizeof(snapshot));osfx::Command c{};c.version=osfx::Version;c.generation=snapshot.generation;c.kind=osfx::SaveAs;
                auto preset=std::filesystem::absolute(L"OptiShadeData/Presets/Saved test.ini");std::error_code ec;std::filesystem::remove(preset,ec);auto utf8=preset.u8string();strcpy_s(c.path,(const char*)utf8.c_str());if(!send(&c,sizeof(c)))throw std::runtime_error("Save-as rejected");
            }
            if(automatic&&tick==310){read(&snapshot,sizeof(snapshot));if(snapshot.dirty||!snapshot.saveSerial||!snapshot.saveOK)throw std::runtime_error("Save-as did not complete");fprintf(report,"Save-as exported current look and selected new INI: PASS\n");}
            if(automatic&&tick==370){
                read(&snapshot,sizeof(snapshot));osfx::Command c{};c.version=osfx::Version;c.generation=snapshot.generation;c.kind=osfx::SaveAs;strcpy_s(c.path,snapshot.savePath);if(!send(&c,sizeof(c)))throw std::runtime_error("Save collision request rejected before processing");
            }
            if(automatic&&tick==390){read(&snapshot,sizeof(snapshot));if(snapshot.saveSerial!=2||snapshot.saveOK)throw std::runtime_error("Save-as overwrote an existing preset");fprintf(report,"Save-as protects existing preset: PASS\n");}
            if(automatic&&tick==400){
                read(&snapshot,sizeof(snapshot));osfx::Command c{};c.version=osfx::Version;c.generation=snapshot.generation;c.kind=osfx::Preset;strcpy_s(c.path,snapshot.savePath);if(!send(&c,sizeof(c)))throw std::runtime_error("Saved preset reload rejected");
            }
            if(automatic&&tick==430){
                read(&snapshot,sizeof(snapshot));osfx::Command c{};c.version=osfx::Version;c.generation=snapshot.generation;c.kind=osfx::Load;c.enabled=1;strcpy_s(c.effect,"Vibrance.fx");if(!send(&c,sizeof(c)))throw std::runtime_error("Catalogue effect activation rejected");
            }
            if(automatic&&tick==640){bool active=false;for(uint32_t i=0;i<snapshot.techniques;i++)if(!strcmp(snapshot.technique[i].effect,"Vibrance.fx")&&snapshot.technique[i].enabled)active=true;if(!active)throw std::runtime_error("Catalogue FX did not load and enable with the menu closed");fprintf(report,"Catalogue FX loads and enables with menu closed: PASS\n");}
            if(automatic&&tick==660){
                if(!snapshot.dirty)throw std::runtime_error("Effect activation was not marked dirty");
                osfx::Command c{};c.version=osfx::Version;c.generation=snapshot.generation;c.kind=osfx::Discard;if(!send(&c,sizeof(c)))throw std::runtime_error("Discard rejected");
            }
            if(automatic&&tick==760){
                if(snapshot.dirty)throw std::runtime_error("Discard left unsaved changes");bool active=false;for(uint32_t i=0;i<snapshot.techniques;i++)if(!strcmp(snapshot.technique[i].effect,"Vibrance.fx")&&snapshot.technique[i].enabled)active=true;
                if(active)throw std::runtime_error("Discard did not restore saved techniques");fprintf(report,"Discard restores saved look and clears unsaved notice: PASS\n");
            }
            if(automatic&&(tick==16||tick==32)){
                finish();UINT w=tick==16?960:1080,h=tick==16?640:720;
                if(tick==16)Check(swap->ResizeBuffers(3,w,h,DXGI_FORMAT_UNKNOWN,0));else {UINT nodes[]={1,1,1};IUnknown* queues[]={queue.Get(),queue.Get(),queue.Get()};Check(swap->ResizeBuffers1(3,w,h,DXGI_FORMAT_UNKNOWN,0,nodes,queues));}
                fprintf(report,"Resize variant %d succeeded\n",tick==16?0:1);
            }
            ComPtr<ID3D12Resource> target;Check(swap->GetBuffer(swap->GetCurrentBackBufferIndex(),IID_PPV_ARGS(&target)));
            auto rtv=heap->GetCPUDescriptorHandleForHeapStart();device->CreateRenderTargetView(target.Get(),nullptr,rtv);
            Check(allocator->Reset());Check(cmd->Reset(allocator.Get(),nullptr));Barrier(cmd.Get(),target.Get(),D3D12_RESOURCE_STATE_PRESENT,D3D12_RESOURCE_STATE_RENDER_TARGET);
            float colour[]={.2f,.1f,.05f,1};cmd->ClearRenderTargetView(rtv,colour,0,nullptr);Barrier(cmd.Get(),target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_PRESENT);submit();
            if(tick%2){DXGI_PRESENT_PARAMETERS p{};Check(swap->Present1(0,0,&p));}else Check(swap->Present(0,0));finish();
            if(automatic&&(tick==120||tick==280||tick==340||tick==420)){
                auto rd=target->GetDesc();D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT64 size=0;device->GetCopyableFootprints(&rd,0,1,0,&footprint,nullptr,nullptr,&size);
                D3D12_HEAP_PROPERTIES hp{};hp.Type=D3D12_HEAP_TYPE_READBACK;D3D12_RESOURCE_DESC bd{};bd.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;bd.Width=size;bd.Height=1;bd.DepthOrArraySize=1;bd.MipLevels=1;bd.SampleDesc.Count=1;bd.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
                ComPtr<ID3D12Resource> readback;Check(device->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_NONE,&bd,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_PPV_ARGS(&readback)));
                Check(allocator->Reset());Check(cmd->Reset(allocator.Get(),nullptr));Barrier(cmd.Get(),target.Get(),D3D12_RESOURCE_STATE_PRESENT,D3D12_RESOURCE_STATE_COPY_SOURCE);
                D3D12_TEXTURE_COPY_LOCATION dst{};dst.pResource=readback.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;D3D12_TEXTURE_COPY_LOCATION src{};src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
                cmd->CopyTextureRegion(&dst,0,0,0,&src,nullptr);Barrier(cmd.Get(),target.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_PRESENT);submit();
                unsigned char* bytes=nullptr;D3D12_RANGE range{0,(SIZE_T)size};Check(readback->Map(0,&range,(void**)&bytes));auto pixel=bytes+(rd.Height-10)*footprint.Footprint.RowPitch+(rd.Width-10)*4;
                float factor=tick<200?2.f:tick==340?1.f:1.5f;bool valid=abs((int)pixel[0]-51*factor)<=3&&abs((int)pixel[1]-26*factor)<=3&&abs((int)pixel[2]-13*factor)<=3;
                fprintf(report,"GPU readback frame %d: %u %u %u -> %s\n",tick,pixel[0],pixel[1],pixel[2],valid?"PASS":"FAIL");D3D12_RANGE written{0,0};readback->Unmap(0,&written);if(!valid)throw std::runtime_error("Image-effect readback mismatch");
            }
            Sleep(automatic?10:16);
        }
        finish();unsigned errors=0;if(info){for(UINT64 i=0;i<info->GetNumStoredMessages();i++){SIZE_T size=0;info->GetMessage(i,nullptr,&size);std::vector<unsigned char> data(size);auto message=(D3D12_MESSAGE*)data.data();info->GetMessage(i,message,&size);if(message->Severity<=D3D12_MESSAGE_SEVERITY_ERROR){fprintf(report,"D3D12 ERROR: %s\n",message->pDescription);errors++;}}}
        if(automatic&&(!read(&snapshot,sizeof(snapshot))||!snapshot.techniques||snapshot.applied<3||errors))throw std::runtime_error("Bridge/runtime/debug verification failed");
        fprintf(report,"PASS: actual FX compiler, INI preset, uniform and technique changes, four GPU readbacks; applied=%llu, debug errors=%u\n",snapshot.applied,errors);fclose(report);CloseHandle(event);        // The injected DLL remains resident to process termination, just as in the game.
        ExitProcess(0);
    }catch(const std::exception& error){if(report){fprintf(report,"FAIL: %s\n",error.what());fclose(report);}if(!automatic)MessageBoxA(nullptr,error.what(),"OptiShade test",MB_OK);ExitProcess(1);}
}







