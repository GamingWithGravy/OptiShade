#include "../../Beta/optiscaler/OptiScaler/dlssnr/DlssNr_Capture.h"
#include <dxgi1_6.h>
#include <iostream>
#include <stdexcept>
#include <fstream>
#pragma comment(lib,"d3d12.lib")
#pragma comment(lib,"dxgi.lib")
using Microsoft::WRL::ComPtr;
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)

static void Wait(ID3D12Device* device,ID3D12CommandQueue* queue) {
    ComPtr<ID3D12Fence> fence;CHECK(SUCCEEDED(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence))));
    CHECK(SUCCEEDED(queue->Signal(fence.Get(),1)));
    HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr);CHECK(event);
    const auto hr=fence->SetEventOnCompletion(1,event);
    const auto waited=SUCCEEDED(hr)?WaitForSingleObject(event,5000):WAIT_FAILED;CloseHandle(event);
    CHECK(waited==WAIT_OBJECT_0&&fence->GetCompletedValue()!=UINT64_MAX&&fence->GetCompletedValue()>=1);
}

int main(){try{
    ComPtr<IDXGIFactory4> factory;CHECK(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
    ComPtr<IDXGIAdapter> warp;CHECK(SUCCEEDED(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp))));
    ComPtr<ID3D12Device> device;CHECK(SUCCEEDED(D3D12CreateDevice(warp.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))));
    ComPtr<ID3D12CommandQueue> first,second;D3D12_COMMAND_QUEUE_DESC queueDesc{};
    CHECK(SUCCEEDED(device->CreateCommandQueue(&queueDesc,IID_PPV_ARGS(&first))));
    CHECK(SUCCEEDED(device->CreateCommandQueue(&queueDesc,IID_PPV_ARGS(&second))));
    ComPtr<ID3D12CommandAllocator> allocator;ComPtr<ID3D12GraphicsCommandList> commands;
    CHECK(SUCCEEDED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator))));
    CHECK(SUCCEEDED(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&commands))));
    ComPtr<ID3D12Resource> before,after;D3D12_RESOURCE_DESC desc{};
    desc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;desc.Width=desc.Height=64;
    desc.DepthOrArraySize=desc.MipLevels=desc.SampleDesc.Count=1;
    desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_DEFAULT;
    CHECK(SUCCEEDED(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_RENDER_TARGET,nullptr,IID_PPV_ARGS(&before))));
    CHECK(SUCCEEDED(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_RENDER_TARGET,nullptr,IID_PPV_ARGS(&after))));
    D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;hd.NumDescriptors=2;
    ComPtr<ID3D12DescriptorHeap> views;CHECK(SUCCEEDED(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&views))));
    auto beforeView=views->GetCPUDescriptorHandleForHeapStart(),afterView=beforeView;
    afterView.ptr+=device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    device->CreateRenderTargetView(before.Get(),nullptr,beforeView);device->CreateRenderTargetView(after.Get(),nullptr,afterView);
    const float a[]={0.25f,0.5f,0.75f,1},b[]={0.75f,0.5f,0.25f,1};
    commands->ClearRenderTargetView(beforeView,a,0,nullptr);commands->ClearRenderTargetView(afterView,b,0,nullptr);
    capture::FrameCapture batch;batch.request(1);
    batch.record(commands.Get(),device.Get(),before.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,
                 after.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,{11,12,0,13,14});
    CHECK(batch.progress()==1&&!batch.readyToWrite());
    CHECK(SUCCEEDED(commands->Close()));optishade::nr_lifetime::Closed(commands.Get());
    ID3D12CommandList* lists[]={commands.Get()};first->ExecuteCommandLists(1,lists);
    optishade::nr_lifetime::Submitted(first.Get(),commands.Get());Wait(device.Get(),first.Get());
    CHECK(!batch.readyToWrite()&&!batch.release()); // Completed, but still replayable.
    ComPtr<ID3D12Fence> gate;CHECK(SUCCEEDED(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&gate))));
    struct GateRelease {ID3D12Fence* fence;~GateRelease(){fence->Signal(1);}} release{gate.Get()};
    CHECK(SUCCEEDED(second->Wait(gate.Get(),1)));second->ExecuteCommandLists(1,lists);
    optishade::nr_lifetime::Submitted(second.Get(),commands.Get());
    optishade::nr_lifetime::RetirePrivate(commands.Get());
    const auto directory=std::filesystem::temp_directory_path()/std::filesystem::path(L"OptiShadeCaptureTest-"+std::to_wstring(GetCurrentProcessId()));
    std::filesystem::remove_all(directory);
    for(unsigned cpuFrame=0;cpuFrame<16;++cpuFrame)
        CHECK(!batch.readyToWrite()&&!batch.release()&&batch.write(directory).empty());
    CHECK(!std::filesystem::exists(directory)); // Pending second queue cannot be replaced by frame age.
    CHECK(SUCCEEDED(gate->Signal(1)));Wait(device.Get(),second.Get());
    CHECK(batch.readyToWrite());CHECK(batch.write(directory)==directory.string());
    CHECK(std::filesystem::file_size(directory/"before_00.raw")==64*64*4);
    std::ifstream beforeRaw(directory/"before_00.raw",std::ios::binary),afterRaw(directory/"after_00.raw",std::ios::binary);
    unsigned char pixelBefore[4]{},pixelAfter[4]{};
    beforeRaw.read(reinterpret_cast<char*>(pixelBefore),4);afterRaw.read(reinterpret_cast<char*>(pixelAfter),4);
    CHECK(pixelBefore[0]>=63&&pixelBefore[0]<=64&&pixelBefore[2]>=191&&pixelBefore[3]==255);
    CHECK(pixelAfter[0]>=191&&pixelAfter[2]>=63&&pixelAfter[2]<=64&&pixelAfter[3]==255);
    beforeRaw.close();afterRaw.close();
    CHECK(!batch.isActive());

    // A new recording using the same COM object, then a real successful Reset
    // before submission, must discard its uninitialized readback without a file.
    CHECK(SUCCEEDED(allocator->Reset()));CHECK(SUCCEEDED(commands->Reset(allocator.Get(),nullptr)));
    optishade::nr_lifetime::Reset(commands.Get());
    batch.request(1);batch.record(commands.Get(),device.Get(),before.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,
                                  after.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,{11,13,0,15,16});
    CHECK(SUCCEEDED(commands->Close()));optishade::nr_lifetime::Closed(commands.Get());
    CHECK(SUCCEEDED(commands->Reset(allocator.Get(),nullptr)));optishade::nr_lifetime::Reset(commands.Get());
    CHECK(!batch.readyToWrite());CHECK(batch.write(directory/"abandoned").empty());
    CHECK(batch.isActive()&&batch.progress()==0&&!std::filesystem::exists(directory/"abandoned"));
    CHECK(batch.release());CHECK(SUCCEEDED(commands->Close()));
    optishade::nr_lifetime::RetirePrivate(commands.Get());optishade::nr_lifetime::Active().Collect();
    std::filesystem::remove_all(directory);
    std::cout<<"D3D12 WARP capture: completed/replayable vs second-queue-pending retirement, exact readback pixels and abandoned-recording discard passed; no NR model or game output tested\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
