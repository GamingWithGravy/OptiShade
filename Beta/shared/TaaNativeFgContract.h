#pragma once
#include <d3d12.h>
#include <dxgi1_4.h>
#include <sl.h>
#include <cmath>
#include "FrameConstants.h"
#include "NrAdmission.h"
#include "D3D12FrameContext.h"

namespace optishade::taa {
inline uintptr_t SwapchainIdentity(IDXGISwapChain* swap) {
    if(!swap)return 0;
    Microsoft::WRL::ComPtr<IUnknown> identity;
    if(SUCCEEDED(swap->QueryInterface(IID_PPV_ARGS(&identity)))&&identity)
        return reinterpret_cast<uintptr_t>(identity.Get());
    return reinterpret_cast<uintptr_t>(swap);
}
inline bool IsCurrentNativeFgOutput(IDXGISwapChain* swap,ID3D12Resource* color) {
    if(!swap||!color)return false;
    Microsoft::WRL::ComPtr<IDXGISwapChain3> current;
    Microsoft::WRL::ComPtr<ID3D12Resource> buffer;
    Microsoft::WRL::ComPtr<IUnknown> a,b;
    if(FAILED(swap->QueryInterface(IID_PPV_ARGS(&current)))||
       FAILED(current->GetBuffer(current->GetCurrentBackBufferIndex(),IID_PPV_ARGS(&buffer)))||
       FAILED(color->QueryInterface(IID_PPV_ARGS(&a)))||FAILED(buffer.As(&b)))return false;
    return a==b;
}
// Validates one immutable contract assembled from same-token split tags.
// Recording and lifetime ownership are supplied by the route assembly.
struct NativeFgInputs {
    ID3D12Resource *color=nullptr, *output=nullptr, *depth=nullptr, *motion=nullptr;
    D3D12_RESOURCE_STATES colorState{}, outputState{}, depthState{}, motionState{};
    bool pairedOutput=false;
};
inline const char* NativeFgContract(ID3D12GraphicsCommandList* cmd,
    const sl::ResourceTag* tags, uint32_t count, const sl::Constants& constants,
    NativeFgInputs& output) {
    output={};
    if (!cmd || cmd->GetType()!=D3D12_COMMAND_LIST_TYPE_DIRECT || !tags || count>64)
        return "native FG requires a direct command list and a bounded complete tag batch";
    const sl::ResourceTag *color=nullptr,*backbuffer=nullptr,*depth=nullptr,*motion=nullptr;
    for (uint32_t i=0;i<count;++i) {
        const auto& tag=tags[i];
        const sl::ResourceTag** slot=nullptr;
        if(tag.type==sl::kBufferTypeHUDLessColor)slot=&color;
        else if(tag.type==sl::kBufferTypeBackbuffer)slot=&backbuffer;
        else if(tag.type==sl::kBufferTypeDepth)slot=&depth;
        else if(tag.type==sl::kBufferTypeMotionVectors)slot=&motion;
        if(!slot)continue;
        if(*slot)return "native FG batch contains duplicate input tags";
        if(!tag.resource || !tag.resource->native || tag.resource->type!=sl::ResourceType::eTex2d)
            return "native FG resource is unavailable";
        // A synthetic legacy Backbuffer tag may deliberately have no arrival
        // state: the paired route never touches that surface until Present,
        // where DXGI defines its state. Every surface touched at this seam must
        // still carry an explicit state.
        if(tag.resource->state==UINT32_MAX && tag.type!=sl::kBufferTypeBackbuffer)
            return "native FG resource arrival state is unavailable";
        if(tag.next || tag.resource->next)return "native FG resource extensions require an explicit contract";
        *slot=&tag;
    }
    if(!color||!backbuffer||!depth||!motion)return "native FG needs colour, real output, depth and motion in one frame-bound batch";
    const bool paired=color->resource->native!=backbuffer->resource->native;
    if(!paired && color->resource->state!=backbuffer->resource->state)
        return "native FG shared colour has contradictory arrival states";
    if(color->lifecycle!=sl::eValidUntilPresent || backbuffer->lifecycle!=sl::eValidUntilPresent)
        return "native FG shared colour must remain valid until present";
    if(constants.depthInverted==sl::eInvalid || constants.reset==sl::eInvalid ||
       constants.cameraMotionIncluded!=sl::eTrue || constants.motionVectors3D!=sl::eFalse ||
       constants.motionVectorsJittered!=sl::eFalse)
        return "native FG guide encoding is incomplete or unsupported";
    if(!std::isfinite(constants.mvecScale.x)||!std::isfinite(constants.mvecScale.y)||
       !constants.mvecScale.x || !constants.mvecScale.y)
        return "native FG motion scale is invalid";
    NativeFgInputs selected;
    selected.color=static_cast<ID3D12Resource*>(color->resource->native);
    selected.output=static_cast<ID3D12Resource*>(backbuffer->resource->native);
    selected.depth=static_cast<ID3D12Resource*>(depth->resource->native);
    selected.motion=static_cast<ID3D12Resource*>(motion->resource->native);
    selected.pairedOutput=paired;
    if(selected.color==selected.depth || selected.color==selected.motion || selected.depth==selected.motion ||
       selected.output==selected.depth || selected.output==selected.motion)
        return "native FG guide resources alias colour/output or each other";
    const auto c=selected.color->GetDesc(),o=selected.output->GetDesc(),d=selected.depth->GetDesc(),m=selected.motion->GetDesc();
    if(const auto* reason=nr_admission::NativeFgBaseMipReason(c,d,m))return reason;
    if(c.Width>3840||c.Height>2160)return "native FG early route exceeds the native neural-model envelope";
    if(o.Width!=c.Width || o.Height!=c.Height)
        return "native FG HUD-less colour and real output dimensions differ";
    if(paired && o.Format!=c.Format)
        return "native FG HUD-less colour and real output formats differ";
    // The first paired carrier is deliberately narrow. The captured diagnostics
    // are RGBA8 SDR; HDR10/scRGB need their own transfer-function proof before
    // we allow the residual to cross the FG/output seam.
    if(paired && c.Format!=DXGI_FORMAT_R8G8B8A8_UNORM)
        return "paired native FG transfer currently requires SDR RGBA8";
    for(const auto* tag:{color,backbuffer,depth,motion}) {
        const auto& e=tag->extent;
        if(e.top||e.left||((e.width||e.height)&&(e.width!=c.Width||e.height!=c.Height)))
            return "native FG subrect does not cover the full shared output";
        if(tag!=backbuffer &&
           (static_cast<ID3D12Resource*>(tag->resource->native)->GetDesc().Flags&D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE))
            return "native FG input denies shader access";
    }
    if(const auto* reason=D3D12FrameContext{cmd,selected.color,selected.depth,selected.motion,selected.output}.ValidateDeviceIdentity(nullptr,true))return reason;
    selected.colorState=static_cast<D3D12_RESOURCE_STATES>(color->resource->state);
    selected.outputState=backbuffer->resource->state==UINT32_MAX ? D3D12_RESOURCE_STATE_PRESENT :
        static_cast<D3D12_RESOURCE_STATES>(backbuffer->resource->state);
    selected.depthState=static_cast<D3D12_RESOURCE_STATES>(depth->resource->state);
    selected.motionState=static_cast<D3D12_RESOURCE_STATES>(motion->resource->state);
    output=selected;
    return nullptr;
}
// Legacy resource tags are valid in a Present interval, not on a simulation
// token's thread. Accept one unambiguous constants frame/viewport per interval.
// Never retain tag pointers or infer a frame from a timeout/thread match alone.
class LegacyFgFrameWindow {
    bool ready=false,ambiguous=false,haveToken=false;
    uint32_t frame=0,view=0,token=0;
public:
    void Begin(uint32_t value,uint32_t) {
        if(haveToken && static_cast<int32_t>(value-token)<0)return;
        if(!haveToken || value!=token) {
            ambiguous=false;
            // Constants can arrive before token observation, but only an exact
            // accepted frame match can be retained across this boundary.
            if(!ready || frame!=value)ready=false;
            token=value;haveToken=true;
        }
    }
    bool Constants(uint32_t value,uint32_t viewport,uint32_t) {
        if(haveToken && value!=token)return false;
        if(ambiguous)return false;
        if(ready&&(value!=frame||viewport!=view)){ambiguous=true;ready=false;return false;}
        frame=value;view=viewport;ready=true;return true;
    }
    bool Frame(uint32_t viewport,uint32_t,uint32_t& value)const {
        if(!haveToken||!ready||ambiguous||viewport!=view||frame!=token)return false;
        value=frame;return true;
    }
    // Present is a consumer event; the next producer token/constants may
    // already have arrived. It cannot retire that newer producer contract.
    void Present(){}
    void Reset(){ready=ambiguous=haveToken=false;frame=view=token=0;}
    bool Ambiguous()const{return ambiguous;}
};
// A legacy API may omit Backbuffer. Materialise only the current DXGI buffer
// as metadata for validation. A separate HUD-less colour remains untouched here;
// the real output is not accessed until Present, where its state is defined.
inline const char* CompleteLegacySharedOutput(IDXGISwapChain* swap,const sl::ResourceTag* tags,
    uint32_t count,sl::ResourceTag* completed,uint32_t& completedCount,
    sl::Resource& syntheticOutput) {
    completedCount=0;
    if(!swap||!tags||!completed||count>63)return "legacy FG tag batch is unavailable or too large";
    const sl::ResourceTag* colour=nullptr;bool haveOutput=false;
    for(uint32_t i=0;i<count;++i){completed[i]=tags[i];
        if(tags[i].type==sl::kBufferTypeHUDLessColor){if(colour)return "legacy FG has duplicate colour tags";colour=&tags[i];}
        haveOutput|=tags[i].type==sl::kBufferTypeBackbuffer;
    }
    if(!colour||!colour->resource||!colour->resource->native||colour->resource->type!=sl::ResourceType::eTex2d)
        return "legacy FG has no usable colour resource";
    if(!haveOutput) {
        Microsoft::WRL::ComPtr<IDXGISwapChain3> current;
        Microsoft::WRL::ComPtr<ID3D12Resource> buffer;
        if(FAILED(swap->QueryInterface(IID_PPV_ARGS(&current)))||
           FAILED(current->GetBuffer(current->GetCurrentBackBufferIndex(),IID_PPV_ARGS(&buffer)))||!buffer)
            return "legacy FG real output is unavailable";
        syntheticOutput.type=sl::ResourceType::eTex2d;
        syntheticOutput.native=buffer.Get();
        syntheticOutput.memory=nullptr;
        syntheticOutput.view=nullptr;
        syntheticOutput.state=UINT32_MAX;
        syntheticOutput.next=nullptr;
        completed[count]=sl::ResourceTag(&syntheticOutput,sl::kBufferTypeBackbuffer,sl::eValidUntilPresent);
        completed[count].extent=colour->extent;
        ++count;
    }
    completedCount=count;return nullptr;
}
// No duplicate dispatch, no stale constants, and no viewport takeover by a pop-out.
using NativeFgFrameGate=optishade::route::FrameConstantWindow<sl::Constants>;
}


