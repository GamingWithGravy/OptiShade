// Standalone D3D12 shader contract fixture: no simulator, injection, downloads or model.
// Runs the production bytecode on an isolated hardware device or WARP.
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <wrl/client.h>
#include <array>
#include <vector>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <filesystem>
#include <nvsdk_ngx.h>
#include "../shared/TaaWorkingExtent.h"
#include "../optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Common.h"
#include "../optiscaler/OptiScaler/shaders/dlssnr/precompile/DlssNr_Shader.h"
using Microsoft::WRL::ComPtr;
void Check(HRESULT hr) { if(FAILED(hr)){printf("HRESULT %08lX\n",(unsigned long)hr);throw std::runtime_error("D3D12 call failed");} }
void Require(bool b,const char* why) { if(!b) throw std::runtime_error(why); }
struct Surface { ComPtr<ID3D12Resource> resource; D3D12_RESOURCE_STATES state; unsigned w,h; };
class Fixture
{
public:
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> cmd;
    ComPtr<ID3D12Fence> fence;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pipeline;
    ComPtr<ID3D12DescriptorHeap> heap;
    ComPtr<ID3D12Resource> constants;
    UINT stride=0;UINT64 serial=0;HANDLE event=nullptr;
    Fixture(bool warp)
    {
        ComPtr<IDXGIFactory4> factory;Check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
        ComPtr<IDXGIAdapter> adapter;if(warp)Check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)));
        Check(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));
        D3D12_COMMAND_QUEUE_DESC q{};Check(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)));
        Check(device->CreateCommandAllocator(q.Type,IID_PPV_ARGS(&allocator)));
        Check(device->CreateCommandList(0,q.Type,allocator.Get(),nullptr,IID_PPV_ARGS(&cmd)));
        Check(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)));
        event=CreateEventW(nullptr,FALSE,FALSE,nullptr);Require(event,"fence event");
        D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;hd.NumDescriptors=7;hd.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        Check(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&heap)));stride=device->GetDescriptorHandleIncrementSize(hd.Type);
        D3D12_DESCRIPTOR_RANGE ranges[2]{};ranges[0]={D3D12_DESCRIPTOR_RANGE_TYPE_SRV,5,0,0,0};ranges[1]={D3D12_DESCRIPTOR_RANGE_TYPE_UAV,2,0,0,0};
        D3D12_ROOT_PARAMETER params[3]{};params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;
        for(unsigned i=0;i<2;++i){params[i+1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;params[i+1].DescriptorTable={1,&ranges[i]};}
        D3D12_STATIC_SAMPLER_DESC sampler{};sampler.Filter=D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU=sampler.AddressV=sampler.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;sampler.MaxLOD=D3D12_FLOAT32_MAX;sampler.ComparisonFunc=D3D12_COMPARISON_FUNC_ALWAYS;
        D3D12_ROOT_SIGNATURE_DESC rd{};rd.NumParameters=3;rd.pParameters=params;rd.NumStaticSamplers=1;rd.pStaticSamplers=&sampler;
        ComPtr<ID3DBlob> signature,error;Check(D3D12SerializeRootSignature(&rd,D3D_ROOT_SIGNATURE_VERSION_1,&signature,&error));
        Check(device->CreateRootSignature(0,signature->GetBufferPointer(),signature->GetBufferSize(),IID_PPV_ARGS(&root)));
        D3D12_COMPUTE_PIPELINE_STATE_DESC pd{};pd.pRootSignature=root.Get();pd.CS={DlssNr_cso,sizeof(DlssNr_cso)};
        Check(device->CreateComputePipelineState(&pd,IID_PPV_ARGS(&pipeline)));
        constants=Buffer(sizeof(DlssNrConstants),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
    }
    ~Fixture(){if(event)CloseHandle(event);}
    ComPtr<ID3D12Resource> Buffer(UINT64 bytes,D3D12_HEAP_TYPE type,D3D12_RESOURCE_STATES state)
    {
        D3D12_HEAP_PROPERTIES hp{};hp.Type=type;D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;d.Width=bytes;
        d.Height=1;d.DepthOrArraySize=d.MipLevels=1;d.SampleDesc.Count=1;d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        ComPtr<ID3D12Resource> out;Check(device->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_NONE,&d,state,nullptr,IID_PPV_ARGS(&out)));return out;
    }
    Surface Texture(unsigned w,unsigned h,DXGI_FORMAT format=DXGI_FORMAT_R8G8B8A8_UNORM)
    {
        D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=w;d.Height=h;d.DepthOrArraySize=d.MipLevels=1;d.SampleDesc.Count=1;
        d.Format=format;d.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        D3D12_HEAP_PROPERTIES hp{};hp.Type=D3D12_HEAP_TYPE_DEFAULT;Surface out{{},D3D12_RESOURCE_STATE_COMMON,w,h};
        Check(device->CreateCommittedResource(&hp,D3D12_HEAP_FLAG_NONE,&d,out.state,nullptr,IID_PPV_ARGS(&out.resource)));return out;
    }
    void Transition(Surface& s,D3D12_RESOURCE_STATES to)
    {
        if(s.state==to)return;D3D12_RESOURCE_BARRIER b{};b.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        b.Transition={s.resource.Get(),D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,s.state,to};cmd->ResourceBarrier(1,&b);s.state=to;
    }
    void Submit()
    {
        Check(cmd->Close());ID3D12CommandList* lists[]={cmd.Get()};queue->ExecuteCommandLists(1,lists);
        Check(queue->Signal(fence.Get(),++serial));Check(fence->SetEventOnCompletion(serial,event));
        Require(WaitForSingleObject(event,20000)==WAIT_OBJECT_0,"isolated GPU fixture timeout");Check(device->GetDeviceRemovedReason());
        Check(allocator->Reset());Check(cmd->Reset(allocator.Get(),nullptr));
    }
    void Upload(Surface& s,const std::vector<unsigned char>& pixels)
    {
        auto desc=s.resource->GetDesc();D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp{};UINT64 bytes=0;device->GetCopyableFootprints(&desc,0,1,0,&fp,nullptr,nullptr,&bytes);
        auto upload=Buffer(bytes,D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);unsigned char* p=nullptr;Check(upload->Map(0,nullptr,(void**)&p));
        for(unsigned y=0;y<s.h;++y)memcpy(p+y*fp.Footprint.RowPitch,pixels.data()+size_t(y)*s.w*4,size_t(s.w)*4);upload->Unmap(0,nullptr);
        Transition(s,D3D12_RESOURCE_STATE_COPY_DEST);D3D12_TEXTURE_COPY_LOCATION src{},dst{};
        src.pResource=upload.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;src.PlacedFootprint=fp;dst.pResource=s.resource.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        cmd->CopyTextureRegion(&dst,0,0,0,&src,nullptr);Transition(s,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);Submit();
    }
    std::vector<unsigned char> Read(Surface& s)
    {
        auto desc=s.resource->GetDesc();D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp{};UINT64 bytes=0;device->GetCopyableFootprints(&desc,0,1,0,&fp,nullptr,nullptr,&bytes);
        auto readback=Buffer(bytes,D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);Transition(s,D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION src{},dst{};src.pResource=s.resource.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        dst.pResource=readback.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=fp;cmd->CopyTextureRegion(&dst,0,0,0,&src,nullptr);Submit();
        unsigned char* p=nullptr;Check(readback->Map(0,nullptr,(void**)&p));std::vector<unsigned char> pixels(size_t(s.w)*s.h*4);
        for(unsigned y=0;y<s.h;++y)memcpy(pixels.data()+size_t(y)*s.w*4,p+y*fp.Footprint.RowPitch,size_t(s.w)*4);readback->Unmap(0,nullptr);return pixels;
    }
    void Pass(const DlssNrConstants& p,Surface& source,Surface* model,Surface* original,Surface& output)
    {
        Surface* inputs[]={&source,model,original,nullptr,nullptr};auto cpu=heap->GetCPUDescriptorHandleForHeapStart();
        for(auto* input:inputs){D3D12_SHADER_RESOURCE_VIEW_DESC sd{};sd.Format=DXGI_FORMAT_R8G8B8A8_UNORM;sd.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;sd.Texture2D.MipLevels=1;sd.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
            if(input)Transition(*input,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);device->CreateShaderResourceView(input?input->resource.Get():nullptr,&sd,cpu);cpu.ptr+=stride;}
        Transition(output,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        D3D12_UNORDERED_ACCESS_VIEW_DESC ud{};ud.Format=DXGI_FORMAT_R8G8B8A8_UNORM;ud.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE2D;
        device->CreateUnorderedAccessView(output.resource.Get(),nullptr,&ud,cpu);cpu.ptr+=stride;device->CreateUnorderedAccessView(nullptr,nullptr,&ud,cpu);
        void* data=nullptr;Check(constants->Map(0,nullptr,&data));memcpy(data,&p,sizeof(p));constants->Unmap(0,nullptr);
        cmd->SetPipelineState(pipeline.Get());cmd->SetComputeRootSignature(root.Get());ID3D12DescriptorHeap* heaps[]={heap.Get()};cmd->SetDescriptorHeaps(1,heaps);
        cmd->SetComputeRootConstantBufferView(0,constants->GetGPUVirtualAddress());auto gpu=heap->GetGPUDescriptorHandleForHeapStart();cmd->SetComputeRootDescriptorTable(1,gpu);gpu.ptr+=5*stride;cmd->SetComputeRootDescriptorTable(2,gpu);
        cmd->Dispatch((p.Width+7)/8,(p.Height+7)/8,1);Submit();
    }
};

// Optional and explicitly supplied by the caller. Reuses the shipped forwarder
// ABI on private textures; never discovers a game, installs a model or adds an
// application export. Passing no paths runs only the portable shader fixture.
template<class T> T Entry(HMODULE m,const char* name)
{ auto p=GetProcAddress(m,name);Require(p!=nullptr,name);return reinterpret_cast<T>(p); }
void ModelProbe(Fixture& gpu,const wchar_t* corePath,const wchar_t* helperPath,const wchar_t* modelPath,const wchar_t* dataPath)
{
    auto core=LoadLibraryExW(corePath,nullptr,LOAD_WITH_ALTERED_SEARCH_PATH);Require(core,"load supplied NGX core");
    auto helper=LoadLibraryExW(helperPath,nullptr,LOAD_WITH_ALTERED_SEARCH_PATH);Require(helper,"load supplied NR forwarder");
    using Init=NVSDK_NGX_Result(*)(unsigned long long,const wchar_t*,ID3D12Device*,NVSDK_NGX_Version,const NVSDK_NGX_FeatureCommonInfo*);
    auto init=Entry<Init>(core,"NVSDK_NGX_D3D12_Init_Ext");
    auto get=Entry<NVSDK_NGX_Result(*)(NVSDK_NGX_Parameter**)>(core,"NVSDK_NGX_D3D12_GetCapabilityParameters");
    auto destroy=Entry<NVSDK_NGX_Result(*)(NVSDK_NGX_Parameter*)>(core,"NVSDK_NGX_D3D12_DestroyParameters");
    const auto directory=std::filesystem::path(modelPath).parent_path().wstring();const wchar_t* paths[]={directory.c_str()};
    NVSDK_NGX_FeatureCommonInfo info{};info.PathListInfo.Path=paths;info.PathListInfo.Length=1;
    auto result=init(0x24480451,dataPath,gpu.device.Get(),NVSDK_NGX_Version_API,&info);
    printf("NR fixture core init=%08X\n",unsigned(result));Require(result==NVSDK_NGX_Result_Success,"NGX core initialization");
    NVSDK_NGX_Parameter* params=nullptr;Require(get(&params)==NVSDK_NGX_Result_Success && params,"NGX capability parameters");
    auto probe=Entry<void(*)(void*,const char*,float,int)>(helper,"dlssnr_call_probe_float");
    auto setSlot=Entry<void(*)(int)>(helper,"dlssnr_call_set_float_slot");bool found=false;
    for(int slot:{1,2,5,6,7,4,3,0}){probe(params,"DLSSNR.FixtureFloat",0.375f,slot);float v=0;
        if(params->Get("DLSSNR.FixtureFloat",&v)==NVSDK_NGX_Result_Success && v==0.375f){setSlot(slot);found=true;break;}}
    Require(found,"NR float setter round-trip");
    using Create=void*(*)(const wchar_t*,const wchar_t*,ID3D12Device*,ID3D12GraphicsCommandList*,void*,unsigned,unsigned,int,float,int,float,float,float,int,int);
    using Evaluate=int(*)(ID3D12GraphicsCommandList*,void*,void*,ID3D12Resource*,ID3D12Resource*,ID3D12Resource*,ID3D12Resource*,unsigned,unsigned,unsigned,unsigned,unsigned,unsigned,unsigned,unsigned,unsigned,unsigned,int,int,float,int,float,float,float,int,float,float);
    auto create=Entry<Create>(helper,"dlssnr_call_create");auto evaluate=Entry<Evaluate>(helper,"dlssnr_call_evaluate_v2");
    auto release=Entry<void(*)(void*)>(helper,"dlssnr_call_release");auto modelError=Entry<const char*(*)()>(helper,"dlssnr_call_error");
    constexpr unsigned width=3840,height=1080,guideWidth=5120,guideHeight=1440;
    auto color=gpu.Texture(width,height),output=gpu.Texture(width,height),depth=gpu.Texture(guideWidth,guideHeight,DXGI_FORMAT_R32_FLOAT),motion=gpu.Texture(guideWidth,guideHeight,DXGI_FORMAT_R16G16_FLOAT);
    std::vector<unsigned char> colors(size_t(width)*height*4),depths(size_t(guideWidth)*guideHeight*4),vectors(depths.size(),0);
    for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x){const auto i=(size_t(y)*width+x)*4;colors[i]=static_cast<unsigned char>(48+160*x/width);colors[i+1]=static_cast<unsigned char>(48+160*y/height);colors[i+2]=96;colors[i+3]=255;}
    for(unsigned y=0;y<guideHeight;++y)for(unsigned x=0;x<guideWidth;++x){const float v=0.25f+0.5f*float(y)/guideHeight;memcpy(depths.data()+(size_t(y)*guideWidth+x)*4,&v,sizeof(v));}
    gpu.Upload(color,colors);gpu.Upload(depth,depths);gpu.Upload(motion,vectors);
    auto feature=create(modelPath,dataPath,gpu.device.Get(),gpu.cmd.Get(),params,width,height,0,1.f,0,1.f,1.f,1.f,1,1);
    if(!feature){printf("NR create: %s\n",modelError());throw std::runtime_error("NR feature creation");}
    gpu.Submit(); // Creation and evaluation are separated by actual GPU completion.
    for(unsigned frame=0;frame<3;++frame){
        gpu.Transition(output,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        const int evaluated=evaluate(gpu.cmd.Get(),feature,params,color.resource.Get(),depth.resource.Get(),motion.resource.Get(),output.resource.Get(),width,height,guideWidth,guideHeight,guideWidth,guideHeight,0,0,0,0,0,frame==0,1.f,0,1.f,1.f,1.f,1,float(width),float(height));
        printf("NR fixture frame%u evaluate=%08X; %s\n",frame,unsigned(evaluated),modelError());Require(evaluated==1,"NR model evaluate");gpu.Submit();
        const auto pixels=gpu.Read(output);bool nonzero=false;for(size_t i=0;i<pixels.size();i+=4)nonzero|=pixels[i]!=0 || pixels[i+1]!=0 || pixels[i+2]!=0;
        Require(nonzero,"NR returned empty model surface");
    }
    release(feature);Require(destroy(params)==NVSDK_NGX_Result_Success,"destroy capability parameters");
    puts("PASS: actual NR feature create + three evaluations at3840x1080 with native5120x1440 depth/motion regions; GPU completed, nonempty output; synthetic inputs only");
}

int wmain(int argc,wchar_t** argv) try
{
    Fixture gpu(argc>1 && wcscmp(argv[1],L"warp")==0);
    const auto work=optishade::taa::TaaWorkingExtent(5120,1440);
    auto native=gpu.Texture(5120,1440),proxy=gpu.Texture(work.width,work.height),model=gpu.Texture(work.width,work.height),output=gpu.Texture(5120,1440);
    DlssNrConstants p{};p.Width=work.width;p.Height=work.height;p.Mode=DlssNrMode_Downsample;
    std::vector<unsigned char> pixels(size_t(native.w)*native.h*4);
    for(unsigned frame=0;frame<2;++frame)
    {
        for(unsigned y=0;y<native.h;++y)for(unsigned x=0;x<native.w;++x){const auto i=(size_t(y)*native.w+x)*4;
            pixels[i]=static_cast<unsigned char>(16+(x+frame*3)*208/native.w);pixels[i+1]=static_cast<unsigned char>(16+y*208/native.h);
            pixels[i+2]=static_cast<unsigned char>(((x+frame)%7==0 || y%11==0)?205:51);pixels[i+3]=255;}
        gpu.Upload(native,pixels);p.Mode=DlssNrMode_Downsample;p.Width=work.width;p.Height=work.height;gpu.Pass(p,native,nullptr,nullptr,proxy);
        const auto down=gpu.Read(proxy);
        // Independent exact-area CPU reference at edges and throughout the frame.
        for(unsigned y=0;y<work.height;y+=37)for(unsigned x=0;x<work.width;x+=53)for(unsigned channel=0;channel<3;++channel)
        {
            const double x0=double(x)*native.w/work.width,x1=double(x+1)*native.w/work.width,y0=double(y)*native.h/work.height,y1=double(y+1)*native.h/work.height;double expected=0;
            for(unsigned iy=unsigned(y0);iy<unsigned(std::ceil(y1));++iy)for(unsigned ix=unsigned(x0);ix<unsigned(std::ceil(x1));++ix)
                expected+=pixels[(size_t(iy)*native.w+ix)*4+channel]*(std::min(x1,double(ix+1))-std::max(x0,double(ix)))*(std::min(y1,double(iy+1))-std::max(y0,double(iy)));
            expected/=(x1-x0)*(y1-y0);Require(std::abs(double(down[(size_t(y)*work.width+x)*4+channel])-expected)<=1.1,"area-filter coordinate mismatch");
        }
        gpu.Upload(model,down);p.Mode=DlssNrMode_Resolve;p.Width=native.w;p.Height=native.h;p.Passthrough=1;p.ApplyModel=1;p.Transfer=1;
        p.TransferStrength=1;p.ColourStrength=1;p.MaxRatio=4;p.DebugScale=1;p.CompareZoom=1;p.WhitePoint=1;
        gpu.Pass(p,proxy,&model,&native,output);const auto resolved=gpu.Read(output);unsigned maxError=0;
        for(size_t i=0;i<pixels.size();++i)maxError=std::max(maxError,unsigned(std::abs(int(resolved[i])-int(pixels[i]))));
        Require(maxError<=1,"identity model blurred/changed native output");
        p.ApplyModel=0;gpu.Pass(p,proxy,&model,&native,output);Require(gpu.Read(output)==pixels,"Apply model off did not preserve exact native image");
        auto edited=down;for(size_t i=0;i<edited.size();++i)if(i%4!=3)edited[i]=static_cast<unsigned char>(std::min(255,int(edited[i])+8));
        gpu.Upload(model,edited);p.ApplyModel=1;p.DebugView=0;gpu.Pass(p,proxy,&model,&native,output);
        const auto positive=gpu.Read(output);
        for(unsigned y:{1u,720u,1438u})for(unsigned x:{1u,1280u,2560u,3840u,5118u}){
            const size_t i=(size_t(y)*native.w+x)*4;
            Require(positive[i]>pixels[i],"positive model residual missing from native image region");
        }
        p.DebugView=2;gpu.Pass(p,proxy,&model,&native,output);const auto shown=gpu.Read(output);
        for(unsigned y:{0u,1u,359u,720u,1438u,1439u})for(unsigned x:{0u,1u,1279u,2560u,3839u,5118u,5119u})for(unsigned channel=0;channel<3;++channel){
            const double sx=(double(x)+0.5)*work.width/native.w-0.5,sy=(double(y)+0.5)*work.height/native.h-0.5;
            const int ix=int(std::floor(sx)),iy=int(std::floor(sy));const double fx=sx-ix,fy=sy-iy;double expected=0;
            for(int dy=0;dy<2;++dy)for(int dx=0;dx<2;++dx){const unsigned px=unsigned(std::clamp(ix+dx,0,int(work.width)-1)),py=unsigned(std::clamp(iy+dy,0,int(work.height)-1));
                expected+=edited[(size_t(py)*work.width+px)*4+channel]*(dx?fx:1-fx)*(dy?fy:1-fy);}
            Require(std::abs(double(shown[(size_t(y)*native.w+x)*4+channel])-expected)<=1.1,"model-to-native resolve cropped or distorted image coordinates");
        }
        p.DebugView=0;
        printf("PASS frame%u: production shader exact-area footprint; matched-residual identity max byte error=%u; native5120x1440 bypass exact\n",frame,maxError);
        puts("PASS: positive model residual reaches both edges and centre; model-to-native mapping matches independent bilinear reference");
    }
    puts("PASS: isolated full-size shader GPU completion; no model evaluation or simulator compatibility claim");
    if(argc==5)ModelProbe(gpu,argv[1],argv[2],argv[3],argv[4]);
    return 0;
}
catch(const std::exception& e){fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
