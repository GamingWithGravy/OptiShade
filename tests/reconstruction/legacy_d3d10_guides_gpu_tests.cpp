// Windows-only execution of the actual D3D10 depth-transfer/original-DXBC relay.
// Default is WARP software rendering; --hardware explicitly selects a real GPU.
// Neither mode starts NR, a game, a capture session or a presentation loop.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d10_1.h>
#include <d3d11.h>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include "../../Beta/legacy-nr/upstream/src/feed_d3d10_guides.h"
#pragma comment(lib,"d3d10_1.lib")
#pragma comment(lib,"d3d11.lib")
#pragma comment(lib,"dxgi.lib")

static void Check(bool value,const char* why){if(!value)throw std::runtime_error(why);}
static void Hr(HRESULT hr,const char* why){if(FAILED(hr))throw std::runtime_error(std::string(why)+" HRESULT="+std::to_string(static_cast<unsigned>(hr)));}
static float Half(uint16_t bits){
 const int sign=(bits&0x8000)?-1:1;const unsigned exponent=(bits>>10)&31,mantissa=bits&1023;
 if(exponent==0)return sign*std::ldexp(static_cast<float>(mantissa),-24);
 if(exponent==31)return mantissa?NAN:sign*INFINITY;
 return sign*std::ldexp(1.0f+static_cast<float>(mantissa)/1024.0f,static_cast<int>(exponent)-15);
}
static std::vector<float> Read(ID3D11Device* device,ID3D11DeviceContext* context,ID3D11Texture2D* texture,bool motion){
 D3D11_TEXTURE2D_DESC desc{};texture->GetDesc(&desc);desc.Usage=D3D11_USAGE_STAGING;
 desc.BindFlags=desc.MiscFlags=0;desc.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
 ID3D11Texture2D* staging=nullptr;Hr(device->CreateTexture2D(&desc,nullptr,&staging),"Create staging");
 context->CopyResource(staging,texture);D3D11_MAPPED_SUBRESOURCE mapped{};
 const HRESULT hr=context->Map(staging,0,D3D11_MAP_READ,0,&mapped);
 if(FAILED(hr)){staging->Release();Hr(hr,"Map staging");}
 std::vector<float> values(size_t(desc.Width)*desc.Height*(motion?2:1));
 for(unsigned y=0;y<desc.Height;++y){
  const auto* row=static_cast<const unsigned char*>(mapped.pData)+size_t(y)*mapped.RowPitch;
  if(motion){const auto* source=reinterpret_cast<const uint16_t*>(row);
   for(unsigned x=0;x<desc.Width*2;++x)values[(size_t(y)*desc.Width*2)+x]=Half(source[x]);}
  else std::memcpy(values.data()+size_t(y)*desc.Width,row,size_t(desc.Width)*sizeof(float));
 }
 context->Unmap(staging,0);staging->Release();return values;
}

int main(int argc,char** argv){
 const bool hardware=argc==2&&std::strcmp(argv[1],"--hardware")==0;
 if(argc>1&&!hardware){std::cerr<<"usage: legacy_d3d10_guides_gpu_tests [--hardware]\n";return 1;}
 try{
  ID3D10Device1* game=nullptr;
  Hr(D3D10CreateDevice1(nullptr,hardware?D3D10_DRIVER_TYPE_HARDWARE:D3D10_DRIVER_TYPE_WARP,nullptr,0,
       D3D10_FEATURE_LEVEL_10_1,D3D10_1_SDK_VERSION,&game),"Create D3D10.1 device");
  FeedD3D10 relay{};
  Check(FeedD3D10Open(&relay,game),relay.where?relay.where:"Open same-adapter D3D11 relay");
  Hr(FeedD3D10PrepareDepthPrograms(),"Compile CPU transfer bytecode before rendering");
  constexpr unsigned width=128,height=128,dw=64,dh=64;
  std::vector<uint32_t> color(width*height),depth(dw*dh);
  const auto luma=[](unsigned x,unsigned y){return ((x*73+y*151+x*y*29)%191)+32;};
  const auto fill=[&](bool shifted){for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x){
   const unsigned bx=x/4,v=luma(shifted?(bx?bx-1:0):bx,y/4);
   color[y*width+x]=0xFF000000u|(v<<16)|(v<<8)|v;
  }};fill(false);
  for(unsigned y=0;y<dh;++y)for(unsigned x=0;x<dw;++x)
   depth[y*dw+x]=static_cast<uint32_t>((double(x+3*y)/(dw+3*dh))*16777215.0);
  D3D10_TEXTURE2D_DESC cd{};cd.Width=width;cd.Height=height;cd.MipLevels=cd.ArraySize=cd.SampleDesc.Count=1;
  cd.Format=DXGI_FORMAT_R8G8B8A8_UNORM;cd.Usage=D3D10_USAGE_DEFAULT;cd.BindFlags=D3D10_BIND_RENDER_TARGET|D3D10_BIND_SHADER_RESOURCE;
  D3D10_SUBRESOURCE_DATA data{color.data(),width*4,0};ID3D10Texture2D* color_texture=nullptr;
  Hr(game->CreateTexture2D(&cd,&data,&color_texture),"Create colour");
  D3D10_TEXTURE2D_DESC dd=cd;dd.Width=dw;dd.Height=dh;dd.Format=DXGI_FORMAT_R24G8_TYPELESS;
  dd.BindFlags=D3D10_BIND_DEPTH_STENCIL|D3D10_BIND_SHADER_RESOURCE;
  data={depth.data(),dw*4,0};ID3D10Texture2D* depth_texture=nullptr;
  Hr(game->CreateTexture2D(&dd,&data,&depth_texture),"Create real D24 scene depth");
  D3D10_SHADER_RESOURCE_VIEW_DESC sv{};sv.Format=DXGI_FORMAT_R24_UNORM_X8_TYPELESS;
  sv.ViewDimension=D3D10_SRV_DIMENSION_TEXTURE2D;sv.Texture2D.MipLevels=1;
  ID3D10ShaderResourceView* source_depth=nullptr;Hr(game->CreateShaderResourceView(depth_texture,&sv,&source_depth),"Create scene depth SRV");
  D3D10_DEPTH_STENCIL_VIEW_DESC dv{};dv.Format=DXGI_FORMAT_D24_UNORM_S8_UINT;dv.ViewDimension=D3D10_DSV_DIMENSION_TEXTURE2D;
  ID3D10DepthStencilView* dsv=nullptr;Hr(game->CreateDepthStencilView(depth_texture,&dv,&dsv),"Create scene DSV");
  game->OMSetRenderTargets(0,nullptr,dsv);
  game->IASetPrimitiveTopology(D3D10_PRIMITIVE_TOPOLOGY_LINELIST);
  D3D10_VIEWPORT viewport{7,9,55,41,0.2f,0.8f};game->RSSetViewports(1,&viewport);
  D3D10_RASTERIZER_DESC rd{};rd.FillMode=D3D10_FILL_SOLID;rd.CullMode=D3D10_CULL_FRONT;
  rd.ScissorEnable=TRUE;rd.DepthClipEnable=TRUE;ID3D10RasterizerState* raster=nullptr;
  Hr(game->CreateRasterizerState(&rd,&raster),"Create game rasterizer");game->RSSetState(raster);
  const D3D10_RECT scissor{0,0,1,1};game->RSSetScissorRects(1,&scissor);
  FeedD3D10Bridge bridge{};Check(FeedD3D10MakeBridge(&relay,&bridge,width,height,cd.Format,false),"Create shared colour bridge");
  FeedD3D10CoreGuides core;
  optishade::legacy::CoreSourceFrame frame;frame.runtime=1;frame.commandList=2;frame.colorView=3;frame.sourceDepthView=4;
  frame.width=width;frame.height=height;frame.depthWidth=dw;frame.depthHeight=dh;frame.sdr=1;frame.reversed=1;
  Check(optishade::legacy::ValidCoreSource(frame,1,2),"Fixture raw-input contract");
  optishade::format_view::Interpretation interpretation;
  interpretation.color={{width,height},{0,0,width,height},1,0,1,1,0,1,1};
  interpretation.depth={{dw,dh},{0,0,dw,dh},1,0,1,1,0,1,1};
  interpretation.view={frame.runtime,1,0,1,false,true};
  interpretation.colorMeaning={optishade::format_view::ColorEncoding::Srgb,optishade::format_view::ColorRange::Sdr,0};
  interpretation.colorResourceFormat=interpretation.colorViewFormat=cd.Format;
  interpretation.depthResourceFormat=dd.Format;interpretation.depthViewFormat=sv.Format;
  const auto run=[&]{
   interpretation.depthMeaning={optishade::format_view::DepthEncoding::DeviceZ,frame.reversed!=0,frame.logarithmic!=0,frame.upsideDown!=0,frame.multiplier};
   return FeedD3D10RunCore(&relay,&core,&bridge,color_texture,source_depth,frame,1,interpretation);
  };
  Check(run()==optishade::guides::RelayResult::Warming,"First frame must not submit NR with invented temporal data");
  auto motion=Read(relay.relay,relay.relay_ctx,core.texture[4],true);
  for(float value:motion)Check(value==0,"Warm-up motion was not zero");
  fill(true);game->UpdateSubresource(color_texture,0,nullptr,color.data(),width*4,0);
  Check(run()==optishade::guides::RelayResult::Ready,"Second frame should have original-kernel guides");
  motion=Read(relay.relay,relay.relay_ctx,core.texture[4],true);
  for(unsigned y=12;y<height-12;++y)for(unsigned x=16;x<width-12;++x){
   const size_t i=(size_t(y)*width+x)*2;
   Check(std::abs(motion[i]+4.0f/width)<1e-4f&&std::abs(motion[i+1])<1e-4f,"Backward UV translation differs from original kernel");
  }
  for(unsigned flip=0;flip<2;++flip)for(unsigned logarithmic=0;logarithmic<2;++logarithmic){
   frame.upsideDown=flip;frame.logarithmic=logarithmic;
   const auto result=run();Check(result!=optishade::guides::RelayResult::Failed,"Depth semantics execution failed");
   const auto values=Read(relay.relay,relay.relay_ctx,core.texture[3],false);
   for(unsigned y=0;y<height;++y)for(unsigned x=0;x<width;++x){
    const unsigned sx=((2*x+1)*dw)/(2*width),mapped=((2*y+1)*dh)/(2*height),sy=flip?dh-1-mapped:mapped;
    double d=double(depth[sy*dw+sx]&0xFFFFFFu)/16777215.0;
    if(logarithmic)d=(std::exp(d*std::log(1.01))-1)/0.01;
    Check(std::abs(values[y*width+x]-(1-d))<2e-5,"D24/scaled/reversed/log/vertical depth mismatch");
   }
  }
  // The transfer had to override scissor/cull/topology and detach a bound DSV.
  // Verify real API state afterwards, not merely matching Set/Get source text.
  D3D10_PRIMITIVE_TOPOLOGY topology{};game->IAGetPrimitiveTopology(&topology);
  Check(topology==D3D10_PRIMITIVE_TOPOLOGY_LINELIST,"Game topology changed");
  UINT count=1;D3D10_VIEWPORT actual{};game->RSGetViewports(&count,&actual);
  Check(count==1&&std::memcmp(&actual,&viewport,sizeof(viewport))==0,"Game viewport changed");
  ID3D10RasterizerState* actual_raster=nullptr;game->RSGetState(&actual_raster);
  Check(actual_raster==raster,"Game rasterizer changed");FeedD3D10CoreDrop(actual_raster);
  ID3D10DepthStencilView* actual_depth=nullptr;game->OMGetRenderTargets(0,nullptr,&actual_depth);
  Check(actual_depth==dsv,"Game depth binding changed");FeedD3D10CoreDrop(actual_depth);
  Check(FeedD3D10ReleaseCore(&relay,&core),"Actual two-API retirement failed");
  FeedD3D10ReleaseBridge(&bridge);game->ClearState();game->Flush();
  FeedD3D10CoreDrop(raster);FeedD3D10CoreDrop(dsv);FeedD3D10CoreDrop(source_depth);
  FeedD3D10CoreDrop(depth_texture);FeedD3D10CoreDrop(color_texture);FeedD3D10Close(&relay);game->Release();
  std::cout<<"PASS actual D3D10/D3D11 "<<(hardware?"hardware":"WARP software")
           <<" relay: original DXBC warm-up/motion, real D24/scaled/reversed/log/vertical depth, state restoration and retirement; no NR/game/presentation qualification.\n";
  return 0;
 }catch(const std::exception& error){std::cerr<<"FAIL D3D10 relay gate: "<<error.what()<<'\n';return 1;}
}
