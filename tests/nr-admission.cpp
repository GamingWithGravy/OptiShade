#define NOMINMAX
#include "../optiscaler/OptiScaler/shaders/dlssnr/DlssNr_ActiveColor.h"
#include "../shared/D3D12FrameContext.h"
#include <dxgi1_4.h>
#include <cassert>
#include <cstdio>
#include <cstring>
using Microsoft::WRL::ComPtr;
static D3D12_RESOURCE_DESC Texture(unsigned w,unsigned h,DXGI_FORMAT format=DXGI_FORMAT_R8G8B8A8_UNORM)
{
    D3D12_RESOURCE_DESC d{};d.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;d.Width=w;d.Height=h;
    d.DepthOrArraySize=1;d.MipLevels=1;d.SampleDesc.Count=1;d.Format=format;return d;
}
static bool LegacyExtent(const D3D12_RESOURCE_DESC& a,unsigned w,unsigned h,unsigned x,unsigned y)
{
    if(a.Dimension!=D3D12_RESOURCE_DIMENSION_TEXTURE2D||a.SampleDesc.Count!=1||a.DepthOrArraySize!=1||
       !a.Width||a.Width>D3D12_REQ_TEXTURE2D_U_OR_V_DIMENSION||!a.Height||a.Height>D3D12_REQ_TEXTURE2D_U_OR_V_DIMENSION||x||y)return false;
    if(!w&&!h)return true;
    return w&&h&&w<=a.Width&&h<=a.Height;
}
int main()
{
    using namespace optishade::nr_admission;
    for(unsigned allocation:{0u,1280u,1344u,1920u,16384u,16385u})
    for(unsigned active:{0u,1280u,1920u,20000u})
    for(unsigned samples:{0u,1u,2u})
    for(unsigned arrays:{1u,2u})
    for(unsigned origin:{0u,1u}){
        auto d=Texture(allocation,1080);d.SampleDesc.Count=samples;d.DepthOrArraySize=(UINT16)arrays;
        assert(DlssNr::PreSrColorExtent(d,active,active?720:0,origin,0).has_value()==LegacyExtent(d,active,active?720:0,origin,0));
    }
    const auto padded=DlssNr::PreSrColorExtent(Texture(1344,768),1280,720);
    assert(padded&&padded->width==1280&&padded->height==720);
    assert(DlssNr::PreSrColorExtent(Texture(1920,1080),1920,1080)); // 1:1/DLAA dimensions alone are valid.
    assert(std::strstr(DlssNr::PreSrColorExtentReason(Texture(1920,1080),1280,0),"one active"));
    assert(std::strstr(DlssNr::PreSrColorExtentReason(Texture(1280,720),1920,1080),"exceeds"));
    auto eye=Texture(2548,2744);eye.DepthOrArraySize=2;
    assert(std::strstr(DlssNr::PreSrColorExtentReason(eye,1698,1829),"array/eye"));
    const unsigned matrix[][2]={{1920,1080},{2560,1440},{3440,1440},{3840,2160},{5120,1440},{1278,718},{2560,1600},{3838,2158}};
    for(const auto& size:matrix){
        auto c=Texture(size[0],size[1]),d=Texture(size[0],size[1],DXGI_FORMAT_R32_FLOAT),m=Texture(size[0],size[1],DXGI_FORMAT_R16G16_FLOAT);
        const char* reason=TaaReason(c,d,m);
        assert(!reason);
        d.Width-=1;assert(std::strstr(TaaReason(c,d,m),"match full output"));
    }
    auto c=Texture(1920,1080),d=Texture(1920,1080,DXGI_FORMAT_R32_FLOAT),m=Texture(1920,1080,DXGI_FORMAT_R16G16_FLOAT);
    c.MipLevels=2;assert(std::strstr(TaaReason(c,d,m),"one mip"));c.MipLevels=1;
    c.Format=DXGI_FORMAT_R16G16B16A16_FLOAT;assert(std::strstr(TaaReason(c,d,m),"SDR"));c.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
    m.SampleDesc.Count=2;assert(std::strstr(TaaReason(c,d,m),"multisampled"));m.SampleDesc.Count=1;
    m.DepthOrArraySize=2;assert(std::strstr(TaaReason(c,d,m),"array/eye"));
    Reasons alternating;uint64_t suppressed=0;unsigned logged=0;
    for(uint64_t now=0;now<30000;++now)logged+=alternating.Permit(now%2+1,42,7,now,suppressed)?1:0;
    assert(logged==2);assert(alternating.Permit(1,42,7,30000,suppressed));assert(suppressed==14999);
    Reasons overflow;logged=0;
    for(uint64_t i=1;i<=100000;++i)logged+=overflow.Permit(i,i,i,10,suppressed)?1:0;
    assert(logged==65); // 64 identities + one overflow, not one message per new resource/view.
    assert(overflow.Permit(100001,100001,100001,30010,suppressed));assert(suppressed==99935);
    puts("PASS: admission predicate equivalence, padded/1:1 extents, exact rejections, TAA output matrix, alternating/overflow log bounds");

    ComPtr<ID3D12Device> device;
    assert(SUCCEEDED(D3D12CreateDevice(nullptr,D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))));
    ComPtr<IUnknown> canonical;assert(SUCCEEDED(device.As(&canonical)));
    assert(optishade::ReShadeDeviceIdentity(device.Get())==canonical);
    ComPtr<ID3D12Device1> otherInterface;assert(SUCCEEDED(device.As(&otherInterface)));
    ComPtr<ID3D12Device> roundTrip;assert(SUCCEEDED(otherInterface.As(&roundTrip)));
    assert(optishade::ReShadeDeviceIdentity(roundTrip.Get())==canonical);
    ComPtr<IDXGIFactory4> factory;assert(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))));
    ComPtr<IDXGIAdapter> warp;assert(SUCCEEDED(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp))));
    ComPtr<ID3D12Device> foreign;assert(SUCCEEDED(D3D12CreateDevice(warp.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&foreign))));
    assert(optishade::ReShadeDeviceIdentity(foreign.Get())!=canonical);
    assert(!optishade::ReShadeDeviceIdentity(nullptr));
    puts("PASS: actual hardware canonical QI identity round-trip and foreign WARP logical-device rejection; no model evaluation performed");
}
