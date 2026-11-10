#pragma once
// Portable injection seams for the real FrameCapture class. These are resource
// and lease doubles, not a D3D12 implementation or a substitute for WARP tests.
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <vector>
#include <algorithm>
using SIZE_T=std::size_t;
using HRESULT=int;
#define SUCCEEDED(x) ((x)>=0)
#define FAILED(x) ((x)<0)
#define IID_PPV_ARGS(x) x
enum DXGI_FORMAT { DXGI_FORMAT_UNKNOWN,DXGI_FORMAT_R16G16B16A16_TYPELESS,DXGI_FORMAT_R16G16B16A16_FLOAT,
 DXGI_FORMAT_R32G32B32A32_TYPELESS,DXGI_FORMAT_R32G32B32A32_FLOAT,DXGI_FORMAT_R10G10B10A2_TYPELESS,
 DXGI_FORMAT_R10G10B10A2_UNORM,DXGI_FORMAT_R8G8B8A8_TYPELESS,DXGI_FORMAT_R8G8B8A8_UNORM,
 DXGI_FORMAT_B8G8R8A8_TYPELESS,DXGI_FORMAT_B8G8R8A8_UNORM };
enum {D3D12_RESOURCE_DIMENSION_BUFFER=1,D3D12_RESOURCE_DIMENSION_TEXTURE2D=2,
 D3D12_HEAP_TYPE_READBACK=3,D3D12_HEAP_FLAG_NONE=0,D3D12_TEXTURE_LAYOUT_ROW_MAJOR=1,
 D3D12_RESOURCE_BARRIER_TYPE_TRANSITION=0,D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES=-1,
 D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT=1,D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX=2};
using D3D12_RESOURCE_STATES=int;
constexpr D3D12_RESOURCE_STATES D3D12_RESOURCE_STATE_COPY_DEST=1,D3D12_RESOURCE_STATE_COPY_SOURCE=2,D3D12_RESOURCE_STATE_RENDER_TARGET=3;
struct D3D12_RESOURCE_DESC {int Dimension=0;uint64_t Width=0;unsigned Height=0,DepthOrArraySize=0,MipLevels=0;
 DXGI_FORMAT Format=DXGI_FORMAT_UNKNOWN;struct {unsigned Count=0,Quality=0;} SampleDesc;int Layout=0;};
struct D3D12_SUBRESOURCE_FOOTPRINT {DXGI_FORMAT Format=DXGI_FORMAT_UNKNOWN;unsigned Width=0,Height=0,Depth=0,RowPitch=0;};
struct D3D12_PLACED_SUBRESOURCE_FOOTPRINT {uint64_t Offset=0;D3D12_SUBRESOURCE_FOOTPRINT Footprint;};
struct D3D12_RANGE {SIZE_T Begin,End;};
struct D3D12_HEAP_PROPERTIES {int Type=0;};
inline unsigned captureMaps=0,captureAllocations=0,captureReleases=0;
inline bool captureMapFails=false;
inline uint64_t captureFootprintOverride=0;
struct ID3D12Resource {
 D3D12_RESOURCE_DESC desc;unsigned refs=1;std::vector<unsigned char> data;
 explicit ID3D12Resource(D3D12_RESOURCE_DESC d):desc(d),data(d.Dimension==D3D12_RESOURCE_DIMENSION_BUFFER?d.Width:d.Width*d.Height*4,128){++captureAllocations;}
 D3D12_RESOURCE_DESC GetDesc()const{return desc;}
 void AddRef(){++refs;}
 void Release(){++captureReleases;if(!--refs)delete this;}
 HRESULT Map(unsigned,const D3D12_RANGE*,void** mapped){++captureMaps;if(captureMapFails)return -1;*mapped=data.data();return 0;}
 void Unmap(unsigned,const D3D12_RANGE*){}
};
struct D3D12_RESOURCE_BARRIER {int Type=0;struct {ID3D12Resource* pResource=nullptr;unsigned Subresource=0;D3D12_RESOURCE_STATES StateBefore=0,StateAfter=0;} Transition;};
struct D3D12_TEXTURE_COPY_LOCATION {ID3D12Resource* pResource=nullptr;int Type=0;D3D12_PLACED_SUBRESOURCE_FOOTPRINT PlacedFootprint;unsigned SubresourceIndex=0;};
struct CaptureLease {bool retired=false,completed=false;uint64_t generation=0;
 bool Ready()const{return retired;}bool Completed()const{return retired&&completed;}uint64_t Generation()const{return generation;}};
struct ID3D12GraphicsCommandList {
 std::shared_ptr<CaptureLease> use;unsigned copies=0;
 void ResourceBarrier(unsigned,const D3D12_RESOURCE_BARRIER*){}
 void CopyTextureRegion(const D3D12_TEXTURE_COPY_LOCATION* dst,unsigned,unsigned,unsigned,const D3D12_TEXTURE_COPY_LOCATION* src,void*){
  ++copies;std::fill(dst->pResource->data.begin(),dst->pResource->data.end(),src->pResource->data[0]);
 }
};
struct ID3D12Device {
 int failAllocationAfter=-1;
 void GetCopyableFootprints(const D3D12_RESOURCE_DESC* d,unsigned,unsigned,uint64_t,D3D12_PLACED_SUBRESOURCE_FOOTPRINT* footprint,void*,void*,unsigned long long* bytes){
  footprint->Footprint={d->Format,unsigned(d->Width),d->Height,1,unsigned((d->Width*4+255)&~255ull)};*bytes=captureFootprintOverride?captureFootprintOverride:uint64_t(footprint->Footprint.RowPitch)*d->Height;
 }
 HRESULT CreateCommittedResource(const D3D12_HEAP_PROPERTIES*,int,const D3D12_RESOURCE_DESC* d,D3D12_RESOURCE_STATES,void*,ID3D12Resource** result){
  if(failAllocationAfter==0)return -1;if(failAllocationAfter>0)--failAllocationAfter;*result=new ID3D12Resource(*d);return 0;
 }
};
namespace optishade::nr_lifetime {
using Use=std::shared_ptr<CaptureLease>;
inline Use Capture(ID3D12GraphicsCommandList* cmd){return cmd->use;}
struct Uses {bool accepts=true;bool Add(const Use&){return accepts;}};
inline Uses& Active(){static Uses uses;return uses;}
}
#if !defined(_WIN32)
inline std::FILE* _wfopen(const wchar_t* path,const wchar_t* mode){
 auto p=std::filesystem::path(path).string();auto m=std::filesystem::path(mode).string();return std::fopen(p.c_str(),m.c_str());
}
#endif
