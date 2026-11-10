// Foveated NR shader on WARP: the real dlssnr.hlsl bytecode.
//  1. Foveate off is bit-identical to the pre-foveation shader (data/dlssnr_pre_foveate.cso)
//     for the downsample and resolve passes, so non-VR players see no change.
//  2. Foveated downsample reads only the window.
//  3. Foveated resolve keeps the frame untouched outside the window and fades the edit in.
#include "DlssNr_Common.h"
#include "precompile/DlssNr_Shader.h"
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>
#pragma comment(lib,"d3d12.lib")
#pragma comment(lib,"dxgi.lib")
using Microsoft::WRL::ComPtr;
#define CHECK(x) do { if(!(x)) throw std::runtime_error(std::string("line ")+std::to_string(__LINE__)+": "+#x); } while(0)

struct Gpu {
 ComPtr<ID3D12Device> device;ComPtr<ID3D12CommandQueue> queue;ComPtr<ID3D12CommandAllocator> allocator;
 ComPtr<ID3D12GraphicsCommandList> list;ComPtr<ID3D12Fence> fence;uint64_t value=0;ComPtr<ID3D12RootSignature> root;
 ComPtr<ID3D12DescriptorHeap> heap;UINT inc=0;
 Gpu(){
  ComPtr<IDXGIFactory4> factory;CHECK(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
  ComPtr<IDXGIAdapter> warp;CHECK(SUCCEEDED(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp))));
  CHECK(SUCCEEDED(D3D12CreateDevice(warp.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))));
  D3D12_COMMAND_QUEUE_DESC q{};CHECK(SUCCEEDED(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue))));
  CHECK(SUCCEEDED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator))));
  CHECK(SUCCEEDED(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&list))));
  CHECK(SUCCEEDED(list->Close()));
  CHECK(SUCCEEDED(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence))));
  // b0 root CBV, t0-t4 and u0-u1 tables, s0 linear clamp: the registers dlssnr.hlsl declares.
  D3D12_DESCRIPTOR_RANGE srv{D3D12_DESCRIPTOR_RANGE_TYPE_SRV,5,0,0,0},uav{D3D12_DESCRIPTOR_RANGE_TYPE_UAV,2,0,0,0};
  D3D12_ROOT_PARAMETER params[3]{};
  params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;params[0].Descriptor={0,0};
  params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;params[1].DescriptorTable={1,&srv};
  params[2].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;params[2].DescriptorTable={1,&uav};
  D3D12_STATIC_SAMPLER_DESC sampler{};sampler.Filter=D3D12_FILTER_MIN_MAG_MIP_LINEAR;
  sampler.AddressU=sampler.AddressV=sampler.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;sampler.MaxLOD=D3D12_FLOAT32_MAX;
  D3D12_ROOT_SIGNATURE_DESC desc{3,params,1,&sampler,D3D12_ROOT_SIGNATURE_FLAG_NONE};
  ComPtr<ID3DBlob> blob,error;CHECK(SUCCEEDED(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error)));
  CHECK(SUCCEEDED(device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root))));
  D3D12_DESCRIPTOR_HEAP_DESC h{D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,7,D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,0};
  CHECK(SUCCEEDED(device->CreateDescriptorHeap(&h,IID_PPV_ARGS(&heap))));
  inc=device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
 }
 ComPtr<ID3D12PipelineState> Pipeline(const void* code,size_t size){
  D3D12_COMPUTE_PIPELINE_STATE_DESC d{};d.pRootSignature=root.Get();d.CS={code,size};
  ComPtr<ID3D12PipelineState> pso;CHECK(SUCCEEDED(device->CreateComputePipelineState(&d,IID_PPV_ARGS(&pso))));return pso;
 }
 ComPtr<ID3D12Resource> Buffer(D3D12_HEAP_TYPE type,UINT64 bytes){
  D3D12_HEAP_PROPERTIES heapProps{type};D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;d.Width=bytes;d.Height=1;
  d.DepthOrArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
  ComPtr<ID3D12Resource> r;CHECK(SUCCEEDED(device->CreateCommittedResource(&heapProps,D3D12_HEAP_FLAG_NONE,&d,
   type==D3D12_HEAP_TYPE_READBACK?D3D12_RESOURCE_STATE_COPY_DEST:D3D12_RESOURCE_STATE_GENERIC_READ,nullptr,IID_PPV_ARGS(&r))));return r;
 }
 // RGBA32F texture filled from data (w*h*4 floats).
 ComPtr<ID3D12Resource> Texture(UINT w,UINT h,const std::vector<float>& data){
  D3D12_HEAP_PROPERTIES def{D3D12_HEAP_TYPE_DEFAULT};D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;
  d.Width=w;d.Height=h;d.DepthOrArraySize=1;d.MipLevels=1;d.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;d.SampleDesc.Count=1;
  d.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
  ComPtr<ID3D12Resource> t;CHECK(SUCCEEDED(device->CreateCommittedResource(&def,D3D12_HEAP_FLAG_NONE,&d,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_PPV_ARGS(&t))));
  D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp{};UINT64 total=0;device->GetCopyableFootprints(&d,0,1,0,&fp,nullptr,nullptr,&total);
  auto upload=Buffer(D3D12_HEAP_TYPE_UPLOAD,total);unsigned char* p=nullptr;CHECK(SUCCEEDED(upload->Map(0,nullptr,(void**)&p)));
  for(UINT y=0;y<h;++y)std::memcpy(p+fp.Offset+y*fp.Footprint.RowPitch,data.data()+size_t(y)*w*4,w*16);upload->Unmap(0,nullptr);
  Begin();D3D12_TEXTURE_COPY_LOCATION dst{t.Get(),D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,{}},src{upload.Get(),D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,{}};
  dst.SubresourceIndex=0;src.PlacedFootprint=fp;list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
  Transition(t.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);End();return t;
 }
 void Begin(){CHECK(SUCCEEDED(allocator->Reset()));CHECK(SUCCEEDED(list->Reset(allocator.Get(),nullptr)));}
 void End(){CHECK(SUCCEEDED(list->Close()));ID3D12CommandList* l[]={list.Get()};queue->ExecuteCommandLists(1,l);
  CHECK(SUCCEEDED(queue->Signal(fence.Get(),++value)));HANDLE e=CreateEventW(nullptr,FALSE,FALSE,nullptr);
  CHECK(SUCCEEDED(fence->SetEventOnCompletion(value,e)));WaitForSingleObject(e,INFINITE);CloseHandle(e);}
 void Transition(ID3D12Resource* r,D3D12_RESOURCE_STATES a,D3D12_RESOURCE_STATES b){
  D3D12_RESOURCE_BARRIER barrier{};barrier.Transition={r,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,a,b};list->ResourceBarrier(1,&barrier);}
 // Runs one pass and returns the target's texels.
 std::vector<float> Run(ID3D12PipelineState* pso,const DlssNrConstants& c,ID3D12Resource* const srvs[5],UINT outW,UINT outH){
  auto cb=Buffer(D3D12_HEAP_TYPE_UPLOAD,256);void* p=nullptr;CHECK(SUCCEEDED(cb->Map(0,nullptr,&p)));std::memcpy(p,&c,sizeof c);cb->Unmap(0,nullptr);
  std::vector<float> zero(size_t(outW)*outH*4,0.0f);auto target=Texture(outW,outH,zero),keep=Texture(outW,outH,zero);
  auto cpu=heap->GetCPUDescriptorHandleForHeapStart();
  for(int i=0;i<5;++i){D3D12_SHADER_RESOURCE_VIEW_DESC v{};v.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;v.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;
   v.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;v.Texture2D.MipLevels=1;
   device->CreateShaderResourceView(srvs[i],&v,{cpu.ptr+SIZE_T(i)*inc});}
  ID3D12Resource* uavs[2]={target.Get(),keep.Get()};
  for(int i=0;i<2;++i){D3D12_UNORDERED_ACCESS_VIEW_DESC v{};v.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;v.ViewDimension=D3D12_UAV_DIMENSION_TEXTURE2D;
   device->CreateUnorderedAccessView(uavs[i],nullptr,&v,{cpu.ptr+SIZE_T(5+i)*inc});}
  Begin();Transition(target.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
  Transition(keep.Get(),D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
  ID3D12DescriptorHeap* heaps[]={heap.Get()};list->SetDescriptorHeaps(1,heaps);list->SetComputeRootSignature(root.Get());list->SetPipelineState(pso);
  list->SetComputeRootConstantBufferView(0,cb->GetGPUVirtualAddress());
  auto gpu=heap->GetGPUDescriptorHandleForHeapStart();list->SetComputeRootDescriptorTable(1,gpu);list->SetComputeRootDescriptorTable(2,{gpu.ptr+5ull*inc});
  list->Dispatch((outW+7)/8,(outH+7)/8,1);
  Transition(target.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
  D3D12_RESOURCE_DESC d=target->GetDesc();D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp{};UINT64 total=0;device->GetCopyableFootprints(&d,0,1,0,&fp,nullptr,nullptr,&total);
  auto readback=Buffer(D3D12_HEAP_TYPE_READBACK,total);
  D3D12_TEXTURE_COPY_LOCATION dst{readback.Get(),D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,{}},src{target.Get(),D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,{}};
  dst.PlacedFootprint=fp;src.SubresourceIndex=0;list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);End();
  std::vector<float> out(size_t(outW)*outH*4);unsigned char* r=nullptr;CHECK(SUCCEEDED(readback->Map(0,nullptr,(void**)&r)));
  for(UINT y=0;y<outH;++y)std::memcpy(out.data()+size_t(y)*outW*4,r+fp.Offset+y*fp.Footprint.RowPitch,outW*16);readback->Unmap(0,nullptr);
  return out;
 }
};

static std::vector<float> Noise(UINT w,UINT h,unsigned seed,float lo,float hi){
 std::mt19937 rng(seed);std::uniform_real_distribution<float> d(lo,hi);std::vector<float> v(size_t(w)*h*4);
 for(size_t i=0;i<v.size();++i)v[i]=(i%4==3)?1.0f:d(rng);return v;
}
static bool Same(const std::vector<float>& a,const std::vector<float>& b){return a.size()==b.size()&&std::memcmp(a.data(),b.data(),a.size()*4)==0;}

int main(int argc,char** argv){try{
 // The pre-foveation shader lives beside this source; a path argument overrides it.
 const std::filesystem::path data=argc>1?std::filesystem::path(argv[1]):std::filesystem::path(__FILE__).parent_path()/"data";
 std::ifstream oldFile(data/"dlssnr_pre_foveate.cso",std::ios::binary);CHECK(oldFile.good());
 std::vector<char> oldCode((std::istreambuf_iterator<char>(oldFile)),std::istreambuf_iterator<char>());
 Gpu gpu;auto oldPso=gpu.Pipeline(oldCode.data(),oldCode.size()),newPso=gpu.Pipeline(DlssNr_cso,sizeof DlssNr_cso);
 const UINT W=64,H=48,w=32,h=24;
 auto original=gpu.Texture(W,H,Noise(W,H,1,0.0f,2.0f)),proxyFull=gpu.Texture(W,H,Noise(W,H,2,0.0f,1.0f));
 auto proxySmall=gpu.Texture(w,h,Noise(w,h,3,0.05f,0.95f)),modelSmall=gpu.Texture(w,h,Noise(w,h,4,0.05f,0.95f));
 auto dummy=gpu.Texture(4,4,Noise(4,4,5,0.0f,1.0f));

 // 1a. Downsample, foveate off: identical to the pre-foveation shader.
 DlssNrConstants down{};down.Mode=DlssNrMode_Downsample;down.Width=w;down.Height=h;
 ID3D12Resource* downSrv[5]={proxyFull.Get(),dummy.Get(),dummy.Get(),dummy.Get(),dummy.Get()};
 {auto a=gpu.Run(oldPso.Get(),down,downSrv,w,h),b=gpu.Run(newPso.Get(),down,downSrv,w,h);
  double sum=0;for(float v:a)sum+=v;std::cerr<<"downsample output sum "<<sum<<"\n";
  CHECK(sum>1.0);  // the pass really ran and wrote the target
  CHECK(Same(a,b));}

 // 1b. Resolve, foveate off, classic and matched residual, SDR passthrough and linear: identical.
 ID3D12Resource* resolveSrv[5]={proxySmall.Get(),modelSmall.Get(),original.Get(),dummy.Get(),dummy.Get()};
 for(uint32_t transfer=0;transfer<2;++transfer)for(uint32_t pass=0;pass<2;++pass){
  DlssNrConstants r{};r.Mode=DlssNrMode_Resolve;r.Width=W;r.Height=H;r.WhitePoint=1.5f;r.TransferStrength=1.0f;r.ColourStrength=1.0f;
  r.MaxRatio=4.0f;r.Passthrough=pass;r.Transfer=transfer;r.ApplyModel=1;r.DebugScale=1.0f;r.CompareZoom=1.0f;
  r.SkinDetail=r.SkinColour=r.EnvironmentDetail=r.EnvironmentColour=1.0f;
  auto a=gpu.Run(oldPso.Get(),r,resolveSrv,W,H),b=gpu.Run(newPso.Get(),r,resolveSrv,W,H);
  double sum=0;for(float v:a)sum+=v;CHECK(sum>1.0);  // the resolve really wrote the frame
  CHECK(Same(a,b));
 }

 // 2. Foveated downsample at 1:1 reads exactly the window [16,48)x[12,36) of the 64x48 proxy.
 {std::vector<float> src=Noise(W,H,6,0.0f,1.0f);auto t=gpu.Texture(W,H,src);
  DlssNrConstants d{};d.Mode=DlssNrMode_Downsample;d.Width=w;d.Height=h;d.Foveate=1;d.FovMinX=0.25f;d.FovMaxX=0.75f;d.FovMinY=0.25f;d.FovMaxY=0.75f;
  ID3D12Resource* s[5]={t.Get(),dummy.Get(),dummy.Get(),dummy.Get(),dummy.Get()};auto out=gpu.Run(newPso.Get(),d,s,w,h);
  for(UINT y=0;y<h;++y)for(UINT x=0;x<w;++x)for(int c=0;c<4;++c){
   const float a=out[(size_t(y)*w+x)*4+c],b=src[(size_t(y+12)*W+x+16)*4+c];
   if(std::fabs(a-b)>=1e-6f){for(UINT yy=0;yy<H;++yy)for(UINT xx=0;xx<W;++xx)if(std::fabs(src[(size_t(yy)*W+xx)*4+c]-a)<1e-7f)std::cerr<<"  value found at source "<<xx<<","<<yy<<"\n";std::cerr<<"mismatch at "<<x<<","<<y<<" c"<<c<<" got "<<a<<" want "<<b<<"\n";}
   CHECK(std::fabs(a-b)<1e-6f);}
 }

 // 3. Foveated resolve: outside the window the frame is untouched; the edit is full in the middle
 //    and fades towards the edge.
 {std::vector<float> orig=Noise(W,H,7,0.2f,0.8f);auto o=gpu.Texture(W,H,orig);
  std::vector<float> proxy(size_t(w)*h*4,0.5f),model(size_t(w)*h*4,0.9f);for(size_t i=3;i<proxy.size();i+=4)proxy[i]=model[i]=1.0f;
  auto p=gpu.Texture(w,h,proxy),m=gpu.Texture(w,h,model);
  DlssNrConstants r{};r.Mode=DlssNrMode_Resolve;r.Width=W;r.Height=H;r.WhitePoint=1.0f;r.TransferStrength=1.0f;r.ColourStrength=1.0f;r.MaxRatio=4.0f;
  r.Passthrough=1;r.Transfer=0;r.ApplyModel=1;r.DebugScale=1.0f;r.CompareZoom=1.0f;r.SkinDetail=r.SkinColour=r.EnvironmentDetail=r.EnvironmentColour=1.0f;
  ID3D12Resource* s[5]={p.Get(),m.Get(),o.Get(),dummy.Get(),dummy.Get()};
  auto whole=gpu.Run(newPso.Get(),r,s,W,H);
  r.Foveate=1;r.FovMinX=0.25f;r.FovMaxX=0.75f;r.FovMinY=0.25f;r.FovMaxY=0.75f;r.FovFeather=0.5f;
  auto fov=gpu.Run(newPso.Get(),r,s,W,H);
  const auto at=[&](const std::vector<float>& v,UINT x,UINT y){return v[(size_t(y)*W+x)*4];};
  for(UINT y=0;y<H;++y)for(UINT x=0;x<W;++x){
   const bool inside=x>=16&&x<48&&y>=12&&y<36;
   if(!inside)for(int c=0;c<3;++c)CHECK(fov[(size_t(y)*W+x)*4+c]==orig[(size_t(y)*W+x)*4+c]);
  }
  // Centre pixel: the edit lands in full, as it does without foveation (uniform proxy/model).
  CHECK(std::fabs(at(fov,32,24)-at(whole,32,24))<1e-5f);
  CHECK(std::fabs(at(fov,32,24)-orig[(size_t(24)*W+32)*4])>1e-3f);
  // Just inside the window edge the frame moves less than at the centre.
  const float edge=std::fabs(at(fov,16,24)-orig[(size_t(24)*W+16)*4]),full=std::fabs(at(whole,16,24)-orig[(size_t(24)*W+16)*4]);
  CHECK(edge<full*0.25f);
 }
 std::cout<<"nr foveated shader GPU tests passed (old/new identical with foveation off; window downsample; window resolve)\n";return 0;
}catch(const std::exception& e){std::cerr<<"FAILED: "<<e.what()<<"\n";return 1;}}
