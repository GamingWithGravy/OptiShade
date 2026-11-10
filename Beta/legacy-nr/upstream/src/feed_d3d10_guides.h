// OptiShade GPL-3.0-or-later. Original core guide kernels on the feed's existing
// D3D11 relay. No second device, guide producer, transport or presenter.
#pragma once
#include <d3dcompiler.h>
#include <mutex>
#include <vector>
#include "feed_d3d10.h"
#include "../../../shared/CoreGuideRelay.h"
#include "../../../shared/GuideHistory.h"
#include "../../../shared/LegacyNrGuideBridge.h"
#include "../../../shared/GuideDepthTransfer.h"
#include "../../../reshade/res/shaders/optishade_guides.dxbc.h"

struct FeedD3D10CoreGuides {
    FeedD3D10Bridge source_depth{};
    ID3D10RenderTargetView* depth_target=nullptr;
    ID3D10VertexShader* copy_vs=nullptr;
    ID3D10PixelShader* copy_ps=nullptr;
    ID3D10Buffer* copy_constants=nullptr;
    ID3D10RasterizerState* copy_rasterizer=nullptr;
    ID3D11Texture2D* texture[5]{}; // previous, current, coarse, conventional depth, backward UV motion
    ID3D11ShaderResourceView* srv[5]{};
    ID3D11UnorderedAccessView* uav[5]{};
    ID3D11ComputeShader* shader[3]{};
    ID3D11Buffer* constants=nullptr;
    // References are retained if either API cannot establish retirement. That
    // one bounded allocation is quarantined; no replacement is allocated.
    ID3D10Device1* game_hold=nullptr;
    ID3D11Device* relay_hold=nullptr;
    uint32_t width=0,height=0,depth_width=0,depth_height=0;
    uint64_t generation=0;
    bool allocated=false,used=false,warm=false,ready=false,quarantined=false,upside_down=false;
    optishade::guides::History history;
    optishade::format_view::Interpretation interpretation{};
    bool interpretation_seen=false;
};

template<class T> static void FeedD3D10CoreDrop(T*& value) {
    if(value){value->Release();value=nullptr;}
}
static bool FeedD3D10ReleaseCore(FeedD3D10* relay,FeedD3D10CoreGuides* core) {
    if(core->quarantined)return false;
    core->ready=false;
    if(core->used&&(!FeedD3D10SyncGame(relay)||!FeedD3D10SyncRelay(relay))){
        core->warm=false;core->quarantined=true;
        FeedD3D10Fail(relay,"core guide retirement (restart required)",DXGI_ERROR_DEVICE_HUNG);
        return false;
    }
    for(auto& value:core->shader)FeedD3D10CoreDrop(value);
    for(auto& value:core->srv)FeedD3D10CoreDrop(value);
    for(auto& value:core->uav)FeedD3D10CoreDrop(value);
    for(auto& value:core->texture)FeedD3D10CoreDrop(value);
    FeedD3D10CoreDrop(core->constants);
    FeedD3D10CoreDrop(core->copy_constants);
    FeedD3D10CoreDrop(core->copy_rasterizer);
    FeedD3D10CoreDrop(core->copy_vs);FeedD3D10CoreDrop(core->copy_ps);
    FeedD3D10CoreDrop(core->depth_target);FeedD3D10ReleaseBridge(&core->source_depth);
    FeedD3D10CoreDrop(core->game_hold);FeedD3D10CoreDrop(core->relay_hold);
    const auto generation=core->generation;*core={};core->generation=generation;
    return true;
}

// Only state touched by the depth transfer is captured. Every Get reference is
// released after restoring it, including predication and stream-output targets.
struct FeedD3D10DepthState {
    ID3D10Device1* device;
    ID3D10VertexShader* vs=nullptr;ID3D10GeometryShader* gs=nullptr;ID3D10PixelShader* ps=nullptr;
    ID3D10InputLayout* layout=nullptr;D3D10_PRIMITIVE_TOPOLOGY topology{};
    ID3D10ShaderResourceView* source=nullptr;ID3D10Buffer* constants=nullptr;
    ID3D10RenderTargetView* targets[D3D10_SIMULTANEOUS_RENDER_TARGET_COUNT]{};
    ID3D10DepthStencilView* depth=nullptr;ID3D10BlendState* blend=nullptr;
    FLOAT factor[4]{};UINT mask=0;ID3D10DepthStencilState* depth_state=nullptr;UINT stencil=0;
    ID3D10RasterizerState* rasterizer=nullptr;
    UINT viewport_count=D3D10_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE;
    D3D10_VIEWPORT viewports[D3D10_VIEWPORT_AND_SCISSORRECT_OBJECT_COUNT_PER_PIPELINE]{};
    ID3D10Buffer* stream[D3D10_SO_BUFFER_SLOT_COUNT]{};UINT offsets[D3D10_SO_BUFFER_SLOT_COUNT]{};
    ID3D10Predicate* predicate=nullptr;BOOL predication=FALSE;
    explicit FeedD3D10DepthState(ID3D10Device1* value):device(value){
        device->VSGetShader(&vs);device->GSGetShader(&gs);device->PSGetShader(&ps);
        device->IAGetInputLayout(&layout);device->IAGetPrimitiveTopology(&topology);
        device->PSGetShaderResources(0,1,&source);device->PSGetConstantBuffers(0,1,&constants);
        device->OMGetRenderTargets(D3D10_SIMULTANEOUS_RENDER_TARGET_COUNT,targets,&depth);
        device->OMGetBlendState(&blend,factor,&mask);device->OMGetDepthStencilState(&depth_state,&stencil);
        device->RSGetState(&rasterizer);device->RSGetViewports(&viewport_count,viewports);
        device->SOGetTargets(D3D10_SO_BUFFER_SLOT_COUNT,stream,offsets);device->GetPredication(&predicate,&predication);
    }
    ~FeedD3D10DepthState(){
        ID3D10ShaderResourceView* none=nullptr;device->PSSetShaderResources(0,1,&none);
        device->OMSetRenderTargets(D3D10_SIMULTANEOUS_RENDER_TARGET_COUNT,targets,depth);
        device->OMSetBlendState(blend,factor,mask);device->OMSetDepthStencilState(depth_state,stencil);
        device->RSSetState(rasterizer);device->RSSetViewports(viewport_count,viewports);
        device->VSSetShader(vs);device->GSSetShader(gs);device->PSSetShader(ps);
        device->IASetInputLayout(layout);device->IASetPrimitiveTopology(topology);
        device->PSSetShaderResources(0,1,&source);device->PSSetConstantBuffers(0,1,&constants);
        device->SOSetTargets(D3D10_SO_BUFFER_SLOT_COUNT,stream,offsets);device->SetPredication(predicate,predication);
        FeedD3D10CoreDrop(vs);FeedD3D10CoreDrop(gs);FeedD3D10CoreDrop(ps);FeedD3D10CoreDrop(layout);
        FeedD3D10CoreDrop(source);FeedD3D10CoreDrop(constants);FeedD3D10CoreDrop(depth);FeedD3D10CoreDrop(blend);
        FeedD3D10CoreDrop(depth_state);FeedD3D10CoreDrop(rasterizer);FeedD3D10CoreDrop(predicate);
        for(auto& value:targets)FeedD3D10CoreDrop(value);
        for(auto& value:stream)FeedD3D10CoreDrop(value);
    }
    FeedD3D10DepthState(const FeedD3D10DepthState&)=delete;
    FeedD3D10DepthState& operator=(const FeedD3D10DepthState&)=delete;
};

struct FeedD3D10DepthPrograms {
    std::mutex mutex;std::vector<unsigned char> vertex,pixel;
};
static FeedD3D10DepthPrograms feed_d3d10_depth_programs;
struct FeedD3D10CompilerModule {
    HMODULE value=nullptr;
    explicit FeedD3D10CompilerModule(HMODULE module):value(module){}
    ~FeedD3D10CompilerModule(){if(value)FreeLibrary(value);}
    FeedD3D10CompilerModule(const FeedD3D10CompilerModule&)=delete;
    FeedD3D10CompilerModule& operator=(const FeedD3D10CompilerModule&)=delete;
};
struct FeedD3D10CompilerBlob {
    ID3DBlob* value=nullptr;
    FeedD3D10CompilerBlob()=default;
    ~FeedD3D10CompilerBlob(){FeedD3D10CoreDrop(value);}
    ID3DBlob** put(){FeedD3D10CoreDrop(value);return &value;}
    FeedD3D10CompilerBlob(const FeedD3D10CompilerBlob&)=delete;
    FeedD3D10CompilerBlob& operator=(const FeedD3D10CompilerBlob&)=delete;
};
static HRESULT FeedD3D10PrepareDepthPrograms(){
    auto& programs=feed_d3d10_depth_programs;std::lock_guard lock(programs.mutex);
    if(!programs.vertex.empty()&&!programs.pixel.empty())return S_OK;
    const auto& copy=optishade::guides::depth_transfer::Hlsl;
    // ID3DBlob's vtable is implemented by d3dcompiler_47.dll. Keep that
    // module loaded until every returned blob has been read and released.
    FeedD3D10CompilerModule compiler{LoadLibraryExW(L"d3dcompiler_47.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32)};
    if(!compiler.value)return HRESULT_FROM_WIN32(GetLastError());
    auto compile=reinterpret_cast<pD3DCompile>(GetProcAddress(compiler.value,"D3DCompile"));
    if(!compile)return HRESULT_FROM_WIN32(ERROR_PROC_NOT_FOUND);
    FeedD3D10CompilerBlob vs,ps,error;
    HRESULT hr=compile(copy,sizeof(copy)-1,"OptiShade depth transfer",nullptr,nullptr,"CopyVS","vs_4_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,vs.put(),error.put());
    error.put();
    if(SUCCEEDED(hr))hr=compile(copy,sizeof(copy)-1,"OptiShade depth transfer",nullptr,nullptr,"CopyPS","ps_4_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,ps.put(),error.put());
    error.put();
    if(SUCCEEDED(hr)){
        if(!vs.value||!ps.value)return E_UNEXPECTED;
        const auto* v=static_cast<const unsigned char*>(vs.value->GetBufferPointer());
        const auto* p=static_cast<const unsigned char*>(ps.value->GetBufferPointer());
        const size_t vs_size=vs.value->GetBufferSize(),ps_size=ps.value->GetBufferSize();
        if(!v||!p||!vs_size||!ps_size)return E_UNEXPECTED;
        programs.vertex.assign(v,v+vs_size);programs.pixel.assign(p,p+ps_size);
    }
    return hr;
}

static bool FeedD3D10CreateCore(FeedD3D10* relay,FeedD3D10CoreGuides* core,
                               const optishade::legacy::CoreSourceFrame& frame){
    if(core->quarantined||!relay->ok)return false;
    core->game_hold=relay->game;core->game_hold->AddRef();
    core->relay_hold=relay->relay;core->relay_hold->AddRef();
    const auto fail=[&](const char* where,HRESULT hr){FeedD3D10Fail(relay,where,hr);FeedD3D10ReleaseCore(relay,core);return false;};
    if(!FeedD3D10MakeBridge(relay,&core->source_depth,frame.depthWidth,frame.depthHeight,DXGI_FORMAT_R32_FLOAT,true))
        return fail("core scene-depth bridge",relay->hr);
    HRESULT hr=relay->game->CreateRenderTargetView(core->source_depth.tex10,nullptr,&core->depth_target);
    if(FAILED(hr))return fail("core scene-depth target",hr);
    // The existing host worker compiles these CPU bytecodes before publishing
    // JOB_CONNECT/JOB_BUILD. A render callback never loads a compiler or waits
    // for its mutex; an unavailable preparation remains a failed build.
    {
        auto& programs=feed_d3d10_depth_programs;
        std::unique_lock lock(programs.mutex,std::try_to_lock);
        if(!lock.owns_lock()||programs.vertex.empty()||programs.pixel.empty())return fail("core depth-transfer preparation",E_PENDING);
        hr=relay->game->CreateVertexShader(programs.vertex.data(),programs.vertex.size(),&core->copy_vs);
        if(SUCCEEDED(hr))hr=relay->game->CreatePixelShader(programs.pixel.data(),programs.pixel.size(),&core->copy_ps);
    }
    if(FAILED(hr))return fail("core depth-transfer shaders",hr);
    D3D10_BUFFER_DESC cbd{};cbd.ByteWidth=sizeof(optishade::guides::depth_transfer::Constants);cbd.BindFlags=D3D10_BIND_CONSTANT_BUFFER;cbd.Usage=D3D10_USAGE_DEFAULT;
    hr=relay->game->CreateBuffer(&cbd,nullptr,&core->copy_constants);
    if(FAILED(hr))return fail("core depth-transfer constants",hr);
    D3D10_RASTERIZER_DESC raster{};raster.FillMode=D3D10_FILL_SOLID;raster.CullMode=D3D10_CULL_NONE;raster.DepthClipEnable=TRUE;
    hr=relay->game->CreateRasterizerState(&raster,&core->copy_rasterizer);
    if(FAILED(hr))return fail("core depth-transfer rasterizer",hr);
    for(unsigned i=0;i<5;++i){
        D3D11_TEXTURE2D_DESC desc{};desc.Width=i<3?(frame.width+3)/4:frame.width;
        desc.Height=i<3?(frame.height+3)/4:frame.height;desc.MipLevels=desc.ArraySize=desc.SampleDesc.Count=1;
        desc.Format=i<2?DXGI_FORMAT_R16G16B16A16_FLOAT:i==3?DXGI_FORMAT_R32_FLOAT:DXGI_FORMAT_R16G16_FLOAT;
        desc.Usage=D3D11_USAGE_DEFAULT;desc.BindFlags=D3D11_BIND_SHADER_RESOURCE|(i?D3D11_BIND_UNORDERED_ACCESS:0);
        hr=relay->relay->CreateTexture2D(&desc,nullptr,&core->texture[i]);
        if(SUCCEEDED(hr))hr=relay->relay->CreateShaderResourceView(core->texture[i],nullptr,&core->srv[i]);
        if(SUCCEEDED(hr)&&i)hr=relay->relay->CreateUnorderedAccessView(core->texture[i],nullptr,&core->uav[i]);
        if(FAILED(hr))return fail("original core guide textures/views",hr);
    }
    const unsigned char* bytes[]={osguide::shaders::Prepare_dxbc,osguide::shaders::Estimate_dxbc,osguide::shaders::Resolve_dxbc};
    const size_t sizes[]={sizeof(osguide::shaders::Prepare_dxbc),sizeof(osguide::shaders::Estimate_dxbc),sizeof(osguide::shaders::Resolve_dxbc)};
    for(unsigned i=0;i<3;++i){hr=relay->relay->CreateComputeShader(bytes[i],sizes[i],nullptr,&core->shader[i]);
        if(FAILED(hr))return fail("original core guide compute shader",hr);}
    D3D11_BUFFER_DESC cb{};cb.ByteWidth=32;cb.BindFlags=D3D11_BIND_CONSTANT_BUFFER;cb.Usage=D3D11_USAGE_DEFAULT;
    hr=relay->relay->CreateBuffer(&cb,nullptr,&core->constants);
    if(FAILED(hr))return fail("original core guide constants",hr);
    core->width=frame.width;core->height=frame.height;core->depth_width=frame.depthWidth;core->depth_height=frame.depthHeight;
    core->allocated=true;++core->generation;return true;
}

static optishade::guides::RelayResult FeedD3D10RunCore(FeedD3D10* relay,FeedD3D10CoreGuides* core,
    FeedD3D10Bridge* color,ID3D10Resource* game_color,ID3D10ShaderResourceView* scene_depth,
    const optishade::legacy::CoreSourceFrame& frame,uint64_t request_revision,
    const optishade::format_view::Interpretation& interpretation){
    using optishade::guides::RelayResult;core->ready=false;
    if(core->quarantined||!color||!color->tex10||!color->srv11||!game_color||!scene_depth)return RelayResult::Failed;
    using namespace optishade::format_view;
    const DepthMeaning expected{DepthEncoding::DeviceZ,frame.reversed!=0,frame.logarithmic!=0,frame.upsideDown!=0,frame.multiplier};
    if(!optishade::legacy::ValidCoreSource(frame,frame.runtime,frame.commandList)||
       interpretation.view.owner!=frame.runtime||!interpretation.view.generation||
       interpretation.view.projection||interpretation.view.index||interpretation.view.count!=1||
       !Same(interpretation.depthMeaning,expected)||
       !Same(interpretation.color.extent,Extent{frame.width,frame.height})||
       !Same(interpretation.depth.extent,Extent{frame.depthWidth,frame.depthHeight})||
       CoreGuideReason(interpretation.color,interpretation.depth,
        color->fmt==DXGI_FORMAT_R8G8B8A8_UNORM?ColorStorage::Rgba8:
        color->fmt==DXGI_FORMAT_B8G8R8A8_UNORM?ColorStorage::Bgra8:ColorStorage::Unknown,
        interpretation.colorMeaning,interpretation.depthMeaning,interpretation.view,true)!=Reason::Ready)return RelayResult::Failed;
    optishade::guides::depth_transfer::Constants transfer;
    if(!optishade::guides::depth_transfer::Prepare(interpretation.depth,
        {frame.depthWidth,frame.depthHeight},interpretation.depthMeaning,transfer))return RelayResult::Failed;
    if(core->allocated&&(core->width!=frame.width||core->height!=frame.height||
       core->depth_width!=frame.depthWidth||core->depth_height!=frame.depthHeight))
        if(!FeedD3D10ReleaseCore(relay,core))return RelayResult::Failed;
    if(!core->allocated&&!FeedD3D10CreateCore(relay,core,frame))return RelayResult::Failed;
    // Previous warm-up can return without a host round trip. Its relay reads
    // still have to retire before the game overwrites either shared input.
    if(core->used&&!FeedD3D10SyncRelay(relay)){
        core->quarantined=true;FeedD3D10Fail(relay,"core previous-input retirement",DXGI_ERROR_DEVICE_HUNG);return RelayResult::Failed;
    }
    if(!core->interpretation_seen||!Same(core->interpretation,interpretation)){
        core->interpretation=interpretation;core->interpretation_seen=true;core->warm=false;++core->generation;
    }
    if(core->history.Observe(frame.reversed!=0,frame.logarithmic!=0,frame.multiplier,request_revision,GetTickCount64())||
       core->upside_down!=(frame.upsideDown!=0)){core->warm=false;++core->generation;}
    core->upside_down=frame.upsideDown!=0;
    FeedD3D10Deposit(relay,color,game_color);
    {
        FeedD3D10DepthState restore(relay->game);
        relay->game->UpdateSubresource(core->copy_constants,0,nullptr,&transfer,0,0);
        relay->game->SetPredication(nullptr,FALSE);relay->game->SOSetTargets(0,nullptr,nullptr);
        relay->game->IASetInputLayout(nullptr);relay->game->IASetPrimitiveTopology(D3D10_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        relay->game->VSSetShader(core->copy_vs);relay->game->GSSetShader(nullptr);relay->game->PSSetShader(core->copy_ps);
        relay->game->OMSetRenderTargets(1,&core->depth_target,nullptr);
        const FLOAT blend[]={1,1,1,1};relay->game->OMSetBlendState(nullptr,blend,UINT_MAX);relay->game->OMSetDepthStencilState(nullptr,0);
        relay->game->RSSetState(core->copy_rasterizer);
        D3D10_VIEWPORT viewport{0,0,frame.depthWidth,frame.depthHeight,0.0f,1.0f};relay->game->RSSetViewports(1,&viewport);
        relay->game->PSSetShaderResources(0,1,&scene_depth);relay->game->PSSetConstantBuffers(0,1,&core->copy_constants);
        relay->game->Draw(3,0);
    }
    core->used=true;
    struct Constants {uint32_t width,height,warm,reversed,logarithmic;float multiplier;uint32_t depthWidth,depthHeight;};
    static_assert(sizeof(Constants)==32);
    const Constants constants{frame.width,frame.height,core->warm?1u:0u,frame.reversed,frame.logarithmic,
                              frame.multiplier,frame.depthWidth,frame.depthHeight};
    relay->relay_ctx->UpdateSubresource(core->constants,0,nullptr,&constants,0,0);
    struct Operations {
        FeedD3D10* relay;FeedD3D10CoreGuides* core;FeedD3D10Bridge* color;
        bool GameInputsComplete(){return FeedD3D10SyncGame(relay);}
        bool Dispatch(unsigned pass){
            auto* ctx=relay->relay_ctx;
            ID3D11ShaderResourceView* srvs[5]{};ID3D11UnorderedAccessView* uavs[4]{};
            if(pass==0){srvs[0]=color->srv11;uavs[0]=core->uav[1];}
            if(pass==1){srvs[2]=core->srv[0];srvs[3]=core->srv[1];uavs[1]=core->uav[2];}
            if(pass==2){srvs[1]=core->source_depth.srv11;srvs[4]=core->srv[2];uavs[2]=core->uav[3];uavs[3]=core->uav[4];}
            ctx->CSSetConstantBuffers(0,1,&core->constants);ctx->CSSetShaderResources(0,5,srvs);
            ctx->CSSetUnorderedAccessViews(0,4,uavs,nullptr);ctx->CSSetShader(core->shader[pass],nullptr,0);
            ctx->Dispatch(pass==2?(core->width+7)/8:((core->width+3)/4+7)/8,
                          pass==2?(core->height+7)/8:((core->height+3)/4+7)/8,1);
            ID3D11ShaderResourceView* no_srv[5]{};ID3D11UnorderedAccessView* no_uav[4]{};
            ctx->CSSetUnorderedAccessViews(0,4,no_uav,nullptr);ctx->CSSetShaderResources(0,5,no_srv);
            return SUCCEEDED(relay->relay->GetDeviceRemovedReason());
        }
        bool Prepare(){return Dispatch(0);}bool Estimate(){return Dispatch(1);}bool Resolve(){return Dispatch(2);}
        bool AdvanceHistory(){relay->relay_ctx->CopyResource(core->texture[0],core->texture[1]);
            return SUCCEEDED(relay->relay->GetDeviceRemovedReason());}
    } operations{relay,core,color};
    const auto result=optishade::guides::RunRelayKernels(operations,core->warm);
    if(result==RelayResult::Failed){core->warm=false;return result;}
    core->warm=true;core->ready=result==RelayResult::Ready;
    return result;
}
