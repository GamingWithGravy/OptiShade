#define NOMINMAX
#include "../shared/D3D12FrameContext.h"
#include "../shared/D3D12Capabilities.h"
#include "../shared/D3D12QueueWait.h"
#include "../shared/RenderingCapability.h"
#include "../shared/BackendSelection.h"
#include "../shared/D3D11Adapter.h"
#include <array>
#include <dxgi1_4.h>
#include <cassert>
#include <cstdio>
using Microsoft::WRL::ComPtr;
static void Check(HRESULT hr) { if(FAILED(hr)){printf("HRESULT %08lX\n",(unsigned long)hr);abort();} }
static ComPtr<ID3D12Resource> Buffer(ID3D12Device* device) {
    D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC desc{};desc.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;desc.Width=256;
    desc.Height=1;desc.DepthOrArraySize=1;desc.MipLevels=1;desc.SampleDesc.Count=1;desc.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ComPtr<ID3D12Resource> resource;
    Check(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_COMMON,nullptr,IID_PPV_ARGS(&resource)));
    return resource;
}
int main() {
    using namespace optishade;
    // A second rendering adapter must not inherit the preferred adapter's DLSS evidence.
    struct Adapter { LUID luid; Evidence dlss; };
    const std::array<Adapter,2> adapters {{{{11,0},Evidence::Yes},{{22,0},Evidence::No}}};
    assert(FindRenderingAdapter(adapters,LUID{22,0})->dlss==Evidence::No);
    assert(FindRenderingAdapter(adapters,LUID{11,0})->dlss==Evidence::Yes);
    assert(!FindRenderingAdapter(adapters,LUID{33,0}));
    assert(!FindRenderingAdapter(adapters,LUID{11,1}));
    assert(SelectAutomaticUpscaler(Evidence::Yes,Evidence::Yes,Evidence::No)==AutomaticUpscaler::Dlss);
    assert(SelectAutomaticUpscaler(Evidence::No,Evidence::Yes,Evidence::No)==AutomaticUpscaler::XeSS);
    assert(SelectAutomaticUpscaler(Evidence::Unknown,Evidence::Yes,Evidence::Unknown)==AutomaticUpscaler::XeSS);
    assert(SelectAutomaticUpscaler(Evidence::Yes,Evidence::No,Evidence::No)==AutomaticUpscaler::XeSS);
    assert(SelectAutomaticUpscaler(Evidence::No,Evidence::No,Evidence::Yes)==AutomaticUpscaler::FidelityFX);
    assert(!NvidiaUpscalerUnavailableReason(Evidence::Yes,true));
    assert(NvidiaUpscalerUnavailableReason(Evidence::Unknown,true));
    assert(NvidiaUpscalerUnavailableReason(Evidence::No,true));
    assert(NvidiaUpscalerUnavailableReason(Evidence::Yes,false));
    puts("PASS: adapter-specific automatic decisions; unknown/runtime-missing evidence cannot assert DLSS availability");
    BackendEvidence evidence;
    assert(ResolveBackendStage(evidence)==BackendStage::WaitingForInput);
    evidence.installed=Evidence::Yes;assert(ResolveBackendStage(evidence)!=BackendStage::Active);
    evidence.gameInput=Evidence::Yes;assert(ResolveBackendStage(evidence)==BackendStage::Detected);
    evidence.loaded=Evidence::Yes;assert(ResolveBackendStage(evidence)==BackendStage::Loaded);
    evidence.initialized=Evidence::Yes;assert(ResolveBackendStage(evidence)==BackendStage::Initialized);
    evidence.active=Evidence::Yes;assert(ResolveBackendStage(evidence)==BackendStage::Active);
    evidence.failed=true;assert(ResolveBackendStage(evidence)==BackendStage::Failed);
    evidence.failed=false;evidence.hardware=Evidence::No;assert(ResolveBackendStage(evidence)==BackendStage::Unsupported);
    evidence.hardware=Evidence::Unknown;evidence.loaded=Evidence::No;assert(ResolveBackendStage(evidence)==BackendStage::Unavailable);
    puts("PASS: evidence-based stage decisions (installation alone is not activation)");
    D3D12Capabilities caps;
    assert(NvidiaNeuralPreflight(caps));
    caps.health=S_OK;caps.identified=true;caps.vendor=0x1002;
    assert(NvidiaNeuralPreflight(caps));
    caps.vendor=0x8086;assert(NvidiaNeuralPreflight(caps));
    caps.vendor=0x10de;assert(!NvidiaNeuralPreflight(caps));
    caps.software=true;assert(NvidiaNeuralPreflight(caps));
    caps.software=false;caps.health=DXGI_ERROR_DEVICE_REMOVED;assert(NvidiaNeuralPreflight(caps));
    assert(NvidiaNeuralPreflight(QueryD3D12Capabilities(nullptr)));
    puts("PASS: neural preflight rejects AMD/Intel/software/removed/unknown devices without inventing runtime support");
    ComPtr<ID3D12Device> device;Check(D3D12CreateDevice(nullptr,D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));
    D3D12_COMMAND_QUEUE_DESC q{};q.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;
    ComPtr<ID3D12CommandQueue> queue;Check(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)));
    assert(WaitForQueueIdle(nullptr)==E_POINTER);
    Check(WaitForQueueIdle(queue.Get()));Check(WaitForQueueIdle(queue.Get()));
    ComPtr<ID3D12Fence> gate;Check(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&gate)));
    Check(queue->Wait(gate.Get(),1));
    const HRESULT timed=WaitForQueueIdle(queue.Get(),10);
    Check(gate->Signal(1));Check(WaitForQueueIdle(queue.Get()));
    assert(timed==DXGI_ERROR_WAS_STILL_DRAWING);
    puts("PASS: first/repeated queue waits, bounded timeout and recovery");
    ComPtr<ID3D12CommandAllocator> allocator;Check(device->CreateCommandAllocator(q.Type,IID_PPV_ARGS(&allocator)));
    ComPtr<ID3D12GraphicsCommandList> commands;Check(device->CreateCommandList(0,q.Type,allocator.Get(),nullptr,IID_PPV_ARGS(&commands)));
    auto resource=Buffer(device.Get());
    D3D12FrameContext frame{commands.Get(),resource.Get(),resource.Get(),resource.Get(),resource.Get(),nullptr,queue.Get()};
    assert(!frame.ValidateDeviceIdentity());frame.colour=nullptr;assert(frame.ValidateDeviceIdentity());frame.colour=resource.Get();
    ComPtr<IDXGIFactory4> factory;Check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
    ComPtr<IDXGIAdapter> warp;Check(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp)));
    ComPtr<ID3D12Device> other;Check(D3D12CreateDevice(warp.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&other)));
    assert(device.Get()!=other.Get());
    assert(!frame.ValidateDeviceIdentity(device.Get()));
    assert(frame.ValidateDeviceIdentity(other.Get()));
    const auto measured=QueryD3D12Capabilities(device.Get());
    assert(measured.identified && SUCCEEDED(measured.health));
    assert(measured.adapter.HighPart==device->GetAdapterLuid().HighPart && measured.adapter.LowPart==device->GetAdapterLuid().LowPart);
    assert(QueryD3D12Capabilities(other.Get()).software);
    printf("PASS: actual hardware and WARP capability queries; backend/device mismatch rejected (vendor %04X, native16 %s, waves %s)\n", measured.vendor, EvidenceLabel(measured.native16), EvidenceLabel(measured.waves));
    auto foreign=Buffer(other.Get());frame.depth=foreign.Get();assert(frame.ValidateDeviceIdentity());frame.depth=resource.Get();
    frame.exposure=foreign.Get();assert(frame.ValidateDeviceIdentity());frame.exposure=nullptr;
    ComPtr<ID3D12CommandQueue> otherQueue;Check(other->CreateCommandQueue(&q,IID_PPV_ARGS(&otherQueue)));
    frame.queue=otherQueue.Get();assert(frame.ValidateDeviceIdentity());frame.queue=queue.Get();assert(!frame.ValidateDeviceIdentity());
    Check(commands->Close());
    assert(!D3D11AdapterLuid(nullptr));
    for (auto driver : {D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP}) {
        ComPtr<ID3D11Device> dx11;
        Check(D3D11CreateDevice(nullptr,driver,nullptr,0,nullptr,0,D3D11_SDK_VERSION,&dx11,nullptr,nullptr));
        const auto actual=D3D11AdapterLuid(dx11.Get());assert(actual);
        ComPtr<IDXGIDevice> dxgi;Check(dx11.As(&dxgi));ComPtr<IDXGIAdapter> adapter;Check(dxgi->GetAdapter(&adapter));
        DXGI_ADAPTER_DESC desc{};Check(adapter->GetDesc(&desc));
        assert(actual->HighPart==desc.AdapterLuid.HighPart && actual->LowPart==desc.AdapterLuid.LowPart);
        const std::array<Adapter,2> reversed{{{{actual->LowPart+1,actual->HighPart},Evidence::Yes},{*actual,Evidence::No}}};
        assert(FindRenderingAdapter(reversed,*actual)->dlss==Evidence::No);
    }
    puts("PASS: DX11 hardware/WARP adapter identity, null evidence and non-primary inventory mapping");
    puts("PASS: valid/missing inputs; foreign resource, exposure and queue rejected; valid inputs recover");
}
