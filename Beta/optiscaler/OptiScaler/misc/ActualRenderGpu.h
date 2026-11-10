// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include "IdentifyGpu.h"
#include "../../../shared/RuntimeRenderContext.h"
#include "../../../shared/D3D12FrameContext.h"
#include <d3d11.h>
#include <algorithm>
#include <array>
#include <optional>

namespace optishade::actual_gpu {
inline runtime_render::Device Metadata(IUnknown* object,const GpuInformation& gpu){
    const auto identity=ReShadeObjectIdentity(object);
    return {reinterpret_cast<uint64_t>(identity.Get()),
        (uint64_t(uint32_t(gpu.luid.HighPart))<<32)|gpu.luid.LowPart,
        static_cast<uint32_t>(gpu.vendorId),gpu.deviceId,
        static_cast<uint32_t>(gpu.nvidiaArchInfo.architecture_id),gpu.softwareAdapter,gpu.name};
}
// Buffer identities are published by the existing primary Present owner. They
// are refreshed only for a new swapchain/generation, without retaining objects
// or creating another lifetime registry.
inline std::array<uint64_t,16> OutputBuffers(IDXGISwapChain* swap,uint64_t generation){
    std::array<uint64_t,16> result{};
    if(!swap||!generation)return result;
    const auto identity=reinterpret_cast<uint64_t>(ReShadeObjectIdentity(swap).Get());
    const auto current=runtime_render::State().Read();
    if(current.output==identity&&current.context.outputGeneration==generation&&
       std::any_of(current.backBuffers.begin(),current.backBuffers.end(),[](uint64_t value){return value!=0;}))return current.backBuffers;
    DXGI_SWAP_CHAIN_DESC description{};
    if(FAILED(swap->GetDesc(&description))||!description.BufferCount||description.BufferCount>result.size())return result;
    for(unsigned i=0;i<description.BufferCount;++i){
        Microsoft::WRL::ComPtr<ID3D12Resource> dx12;
        if(SUCCEEDED(swap->GetBuffer(i,IID_PPV_ARGS(&dx12))))result[i]=reinterpret_cast<uint64_t>(ReShadeObjectIdentity(dx12.Get()).Get());
        else {
            Microsoft::WRL::ComPtr<ID3D11Texture2D> dx11;
            if(SUCCEEDED(swap->GetBuffer(i,IID_PPV_ARGS(&dx11))))result[i]=reinterpret_cast<uint64_t>(ReShadeObjectIdentity(dx11.Get()).Get());
        }
    }
    return result;
}
inline void NrOutput(IUnknown* color,uint64_t ticket,uint64_t revision,bool compositionReachedOutput,bool failed=false){
    if(!color)return;
    runtime_render::State().NrOutput(reinterpret_cast<uint64_t>(ReShadeObjectIdentity(color).Get()),
        ticket,revision,compositionReachedOutput,GetTickCount64(),failed);
}
inline std::optional<GpuInformation> Current(bool requireStreamline=false){
    const auto live=runtime_render::State().Read();
    if(!live.Fresh(GetTickCount64())||!live.device.Known())return std::nullopt;
    if(requireStreamline&&!live.streamlineMatches)return std::nullopt;
    LUID luid{uint32_t(live.device.luid),LONG(live.device.luid>>32)};
    auto gpu=IdentifyGpu::getGpuByLuid(luid);
    if(!IsEqualLUID(gpu.luid,luid)||gpu.softwareAdapter)return std::nullopt;
    return gpu;
}
}
