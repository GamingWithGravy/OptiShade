#pragma once
#include <d3d12.h>
#include <array>
#include <cstdint>
#include <string_view>
#include "TaaWorkingExtent.h"

namespace optishade::nr_admission
{
inline uint64_t ReasonKey(std::string_view text)
{
    uint64_t value = 14695981039346656037ull;
    for (unsigned char c : text) { value ^= c; value *= 1099511628211ull; }
    return value ? value : 1;
}

// Fixed slots; alternating reasons cannot defeat suppression. Excess identities
// share one overflow bucket instead of evicting a live reason every frame.
class Reasons
{
    struct Slot { uint64_t key=0, context=0, generation=0, last=0, suppressed=0; };
    std::array<Slot,64> slots {};
    Slot overflow {};
public:
    bool Permit(uint64_t key,uint64_t context,uint64_t generation,uint64_t now,uint64_t& suppressed)
    {
        Slot* selected=nullptr;
        for(auto& slot:slots) if(slot.key==key&&slot.context==context&&slot.generation==generation){selected=&slot;break;}
        if(!selected) for(auto& slot:slots) if(!slot.key){slot={key,context,generation,now,0};suppressed=0;return true;}
        if(!selected) selected=&overflow;
        if(!selected->key){*selected={key,context,generation,now,0};suppressed=0;return true;}
        if(now-selected->last<30000){++selected->suppressed;return false;}
        suppressed=selected->suppressed;selected->suppressed=0;selected->last=now;return true;
    }
};

inline const char* Texture2DReason(const D3D12_RESOURCE_DESC& r)
{
    if(r.Dimension!=D3D12_RESOURCE_DIMENSION_TEXTURE2D)return "resource is not a 2D texture";
    if(r.SampleDesc.Count!=1)return "multisampled texture is unsupported";
    if(r.DepthOrArraySize!=1)return "array/eye texture is unsupported by this single-surface route";
    if(!r.Width||!r.Height)return "texture allocation has zero extent";
    if(r.Width>D3D12_REQ_TEXTURE2D_U_OR_V_DIMENSION||r.Height>D3D12_REQ_TEXTURE2D_U_OR_V_DIMENSION)
        return "texture allocation exceeds D3D12 2D bounds";
    return nullptr;
}
inline const char* TaaReason(const D3D12_RESOURCE_DESC& c,const D3D12_RESOURCE_DESC& d,const D3D12_RESOURCE_DESC& m)
{
    for(const auto* r:{&c,&d,&m}){
        if(const auto* reason=Texture2DReason(*r))return reason;
        if(r->MipLevels!=1)return "TAA requires one mip per input";
    }
    if(d.Width!=c.Width||m.Width!=c.Width||d.Height!=c.Height||m.Height!=c.Height)
        return "TAA depth/motion guides must match full output extent";
    if(!optishade::taa::TaaWorkingExtent(c.Width,c.Height).valid())
        return "TAA size exceeds the bounded 5120x2160 desktop envelope";
    if(c.Format!=DXGI_FORMAT_R8G8B8A8_UNORM&&c.Format!=DXGI_FORMAT_B8G8R8A8_UNORM)
        return "TAA requires SDR RGBA8/BGRA8 UNORM colour";
    if(d.Format!=DXGI_FORMAT_R32_FLOAT)return "TAA depth guide must be R32_FLOAT";
    if(m.Format!=DXGI_FORMAT_R16G16_FLOAT)return "TAA motion guide must be R16G16_FLOAT";
    return nullptr;
}
}
