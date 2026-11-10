#include <cstddef>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#if defined(__GNUC__) && !defined(__clang__)
// The unchanged ReShade SDK uses MSVC's type/member-name spelling. Scope its
// GCC diagnostic exception to that vendor header, not the tested production code.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wchanges-meaning"
#pragma GCC diagnostic ignored "-Wignored-qualifiers"
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"
#endif
#include "../../Beta/reshade/include/reshade_api_resource.hpp"
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic pop
#endif
#include "../../Beta/reshade/source/optishade_format_view.inl"
#include "../../Beta/shared/GuideDepthTransfer.h"

namespace fv=optishade::format_view;
namespace api=reshade::api;
static unsigned checks=0;
static void Check(bool value,const char* why) { ++checks;if(!value)throw std::runtime_error(why); }
static fv::SurfaceView Surface(unsigned w,unsigned h) {return {{w,h},{0,0,w,h},1,0,1,1,0,1,1};}
int main() {
 try {
  auto color=Surface(1920,1080),depth=Surface(960,540);
  fv::ColorMeaning sdr{fv::ColorEncoding::Srgb,fv::ColorRange::Sdr,0};
  fv::DepthMeaning device{fv::DepthEncoding::DeviceZ,false,false,false,1};
  fv::ViewIdentity view{4,5,0,1,false,true};
  const auto reason=[&](const auto& c,const auto& d) {
   return fv::CoreGuideReason(c,d,fv::ColorStorage::Rgba8,sdr,device,view,false);
  };
  Check(reason(color,depth)==fv::Reason::Ready,"existing single-surface SDR route");
  auto changed=depth;changed.samples=4;
  Check(reason(color,changed)==fv::Reason::NeedsSampleResolve,"MSAA must remain gated");
  changed=depth;changed.layers=2;
  Check(reason(color,changed)==fv::Reason::NeedsViewExtraction,"array must remain gated");
  changed=depth;changed.mipLevels=2;
  Check(reason(color,changed)==fv::Reason::NeedsMipSelection,"mips must remain gated");
  changed=depth;changed.rect.x=1;--changed.rect.width;
  Check(reason(color,changed)==fv::Reason::NeedsViewExtraction,"subrect needs actual extraction");
  changed=depth;changed.rect.x=UINT32_MAX;
  Check(reason(color,changed)==fv::Reason::InvalidSurface,"overflow rectangle rejected");
  changed=Surface(900,540);
  Check(reason(color,changed)==fv::Reason::DepthExtentMismatch,"independent axes cannot stretch depth");
  Check(reason(Surface(6000,1080),depth)==fv::Reason::ExtentOutsideCurrentRoute,"wide output retains qualification gate");
  Check(fv::CoreGuideReason(color,depth,fv::ColorStorage::Rgba16Float,sdr,device,view,false)==fv::Reason::NeedsColorConversion,
   "float storage does not authorize HDR conversion");
  Check(fv::CoreGuideReason(color,depth,fv::ColorStorage::Rgba8,{},device,view,false)==fv::Reason::NeedsColorConversion,
   "unknown colour transfer not silently called SDR");
  Check(fv::CoreGuideReason(color,depth,fv::ColorStorage::Rgba8,{},device,view,true)==fv::Reason::Ready,
   "only existing unknown-SDR policy is retained explicitly");
  auto unknown=view;unknown.known=false;
  Check(!fv::ValidateView(unknown)&&!fv::SameBoundView(view,unknown),"missing eye metadata remains unknown");
  Check(fv::SameBoundView(view,view),"exact current view identity");
  for(unsigned i=0;i<5;++i) {auto v=view;
   if(i==0)++v.owner;
   if(i==1)++v.generation;
   if(i==2)++v.index;
   if(i==3)++v.count;
   if(i==4)v.projection=true;
   Check(!fv::SameBoundView(view,v),"cross-owner/generation/eye/projection cannot share a binding");
  }
  auto eye=view;eye.index=1;eye.count=2;eye.projection=true;
  Check(fv::ValidateView(eye),"known existing per-eye projection identity");
  Check(fv::CoreGuideReason(color,depth,fv::ColorStorage::Rgba8,sdr,device,eye,false)==fv::Reason::Ready,
   "the existing extracted single-eye route is preserved");
  auto slice=Surface(1024,512);slice.layers=3;slice.layer=1;slice.mipLevels=5;slice.mip=2;slice.rect={0,0,256,128};
  uint32_t subresource=99;
  Check(fv::SubresourceIndex(slice,subresource)&&subresource==7,"layer and mip bind to actual subresource");
  slice.selectedLayers=UINT32_MAX;
  Check(!fv::SubresourceIndex(slice,subresource),"all remaining array layers are not one eye");
  Check(fv::SelectedCount(1,0,UINT32_MAX)==1,"API all remaining count normalized");
  Check(fv::SelectedCount(2,1,UINT32_MAX)==1,"API selected last layer normalized");
  Check(fv::SelectedCount(2,1,2)==0&&fv::SelectedCount(0,0,UINT32_MAX)==0,"invalid view count rejected");
  uint32_t sx=0,sy=0;
  for(unsigned y=0;y<17;++y)for(unsigned x=0;x<31;++x)for(bool flip:{false,true}) {
   Check(fv::SourcePixel({7,5,13,9},{31,17},x,y,flip,sx,sy),"odd subrect reference maps");
   const auto ex=7+static_cast<unsigned>(std::floor((x+0.5)*13/31));
   const auto row=static_cast<unsigned>(std::floor((y+0.5)*9/17));
   Check(sx==ex&&sy==5+(flip?8-row:row),"nearest-depth centre sample/vertical convention");
  }
  sx=33;sy=44;
  Check(!fv::SourcePixel({0,0,UINT32_MAX,9},{31,17},0,0,false,sx,sy)&&sx==33&&sy==44,"oversized sample arithmetic rejected without output");
  Check(!fv::SourcePixel({0,0,13,9},{UINT32_MAX,UINT32_MAX},UINT32_MAX-1,UINT32_MAX-1,false,sx,sy)&&sx==33&&sy==44,
   "extreme positive destination cannot overflow the reference arithmetic");
  Check(!fv::SourcePixel({UINT32_MAX,UINT32_MAX,13,9},{31,17},0,0,false,sx,sy)&&sx==33&&sy==44,
   "source offset overflow cannot escape the allocation");
  Check(!fv::SourcePixel({0,0,13,9},{31,17},31,0,false,sx,sy),"destination bounds checked");
  float z=99;
  Check(fv::ConventionalDepth(0.25f,device,z)&&z==0.25f,"device depth is preserved, not linearized");
  auto reverse=device;reverse.reversed=true;reverse.multiplier=2;
  Check(fv::ConventionalDepth(0.25f,reverse,z)&&z==0.5f,"original scale then reverse order");
  reverse.logarithmic=true;
  Check(fv::ConventionalDepth(0.25f,reverse,z)&&std::abs(z-float(1-std::expm1(0.5*std::log(1.01))/0.01))<1e-6,
   "original scale/log/reverse transform preserved");
  fv::DepthMeaning linear{fv::DepthEncoding::LinearViewZ,false,false,false,1,0.1f,1000};
  Check(fv::CoreGuideReason(color,depth,fv::ColorStorage::Rgba8,sdr,linear,view,false)==fv::Reason::NeedsLinearDepthConversion,
   "linear-depth conversion reference is not route qualification");
  Check(fv::ConventionalDepth(0.1f,linear,z)&&std::abs(z)<1e-6,"linear near plane maps to conventional zero");
  Check(fv::ConventionalDepth(1000,linear,z)&&std::abs(z-1)<1e-6,"linear far plane maps to conventional one");
  Check(fv::ConventionalDepth(1,linear,z)&&std::abs(z-0.900090f)<1e-6,"positive view distance uses declared projection");
  linear.farZ=std::numeric_limits<float>::infinity();
  Check(fv::ConventionalDepth(1,linear,z)&&std::abs(z-0.9f)<1e-6,"infinite far projection");
  Check(!fv::ConventionalDepth(0,linear,z),"zero view distance is invalid, not manufactured depth");
  linear.nearZ=0;Check(!fv::ValidateDepth(linear),"missing projection cannot be guessed");
  Check(!fv::ConventionalDepth(NAN,device,z),"nonfinite depth input rejected");
  float mx=0,my=0;
  Check(fv::BackwardUv(-4,2,{fv::MotionUnits::BackwardPixels,{1920,1080},false},mx,my)&&
      std::abs(mx+4.0f/1920)<1e-8&&std::abs(my-2.0f/1080)<1e-8,"pixel motion uses original reference extent");
  Check(fv::BackwardUv(0.2f,-0.1f,{fv::MotionUnits::BackwardUv,{1920,1080},true},mx,my)&&mx==0.2f&&my==0.1f,
      "declared orientation changes vertical displacement once");
  Check(!fv::BackwardUv(1,2,{fv::MotionUnits::ForwardPixels,{1920,1080},false},mx,my),"forward motion cannot be inverted by negation");
  Check(!fv::BackwardUv(1,2,{fv::MotionUnits::BackwardPixels,{},false},mx,my),"unknown motion reference remains unavailable");
  api::resource_desc c(1920,1080,1,1,api::format::r8g8b8a8_typeless,1,api::memory_heap::default_,api::resource_usage::render_target);
  api::resource_desc d(960,540,1,1,api::format::r24_g8_typeless,1,api::memory_heap::default_,api::resource_usage::shader_resource);
  api::resource_view_desc cv(api::format::r8g8b8a8_unorm_srgb),dv(api::format::r24_unorm_x8_uint);
  const auto inspect=[&]{return osformat::Inspect(c,cv,d,dv,api::color_space::srgb_nonlinear,device,view);};
  const auto before=inspect();Check(before.reason==fv::Reason::Ready,"actual resource/view adapter accepts same typed family");
  Check(before.interpretation.colorViewFormat==uint32_t(api::format::r8g8b8a8_unorm_srgb)&&
      before.interpretation.colorMeaning.encoding==fv::ColorEncoding::Srgb,"encoded-view interpretation retained explicitly");
  cv.format=api::format::b8g8r8a8_unorm;Check(inspect().reason==fv::Reason::NeedsColorConversion,"channel-order alias cannot use a raw copy");
  cv.format=api::format::r8g8b8a8_uint;Check(inspect().reason==fv::Reason::NeedsColorConversion,"integer view does not sample UNORM colour");
  cv.format=api::format::r8g8b8a8_unorm;dv.format=api::format::x24_unorm_g8_uint;
  Check(inspect().reason==fv::Reason::UnknownDepth,"stencil view is not scene depth");
  dv.format=api::format::r24_unorm_x8_uint;dv.texture.levels=UINT32_MAX;
  Check(inspect().reason==fv::Reason::Ready,"real API default remaining mip count supported");
  dv.texture.first_level=1;Check(inspect().reason==fv::Reason::InvalidSurface,"invalid actual selected mip rejected");
  dv.texture.first_level=0;
  const auto hdr=osformat::Inspect(c,cv,d,dv,api::color_space::hdr10_st2084,device,view);
  Check(hdr.reason==fv::Reason::NeedsColorConversion&&hdr.interpretation.colorMeaning.encoding==fv::ColorEncoding::Pq,
   "declared PQ is visible but retains conversion guard");
  Check(osformat::Meaning(api::color_space::extended_srgb_linear).referenceWhiteNits==80,"declared scRGB reference is explicit");
  Check(osformat::Meaning(api::color_space::unknown).encoding==fv::ColorEncoding::Unknown,"unknown API colour remains unknown");
  const auto buffer=api::resource_desc(4096,api::memory_heap::default_,api::resource_usage::shader_resource);
  Check(osformat::Inspect(buffer,cv,d,dv,api::color_space::srgb_nonlinear,device,view).reason==fv::Reason::InvalidSurface,
   "buffer descriptor rejected before reading the inactive texture union");
  auto interpretation=before.interpretation;
  Check(fv::Same(interpretation,interpretation),"stable interpretation does not reset history");
  auto next=interpretation;next.depth.extent={480,270};next.depth.rect={0,0,480,270};
  Check(!fv::Same(interpretation,next),"depth scale transition invalidates history");
  next=interpretation;next.colorViewFormat=uint32_t(api::format::r8g8b8a8_unorm);
  Check(!fv::Same(interpretation,next),"selected colour interpretation invalidates history");
  next=interpretation;next.view.generation++;
  Check(!fv::Same(interpretation,next),"actual eye generation invalidates history");
  optishade::guides::depth_transfer::Constants constants{};
  Check(optishade::guides::depth_transfer::Prepare(depth,{960,540},device,constants)&&constants.conversion==0,
   "production depth copy leaves original guide conversion owner intact");
  linear={fv::DepthEncoding::LinearViewZ,false,false,false,1,0.1f,1000};
  Check(optishade::guides::depth_transfer::Prepare(depth,{1920,1080},linear,constants)&&constants.conversion==1,
   "finite linear-depth preparation builds exact kernel constants only");
  linear.farZ=INFINITY;
  Check(optishade::guides::depth_transfer::Prepare(depth,{1920,1080},linear,constants)&&constants.conversion==2&&constants.farZ==0,
   "infinite-far preparation avoids infinity shader arithmetic");
  depth.samples=4;
  Check(!optishade::guides::depth_transfer::Prepare(depth,{1920,1080},device,constants),"no naive MSAA depth average");
  depth.samples=1;depth.layers=2;depth.layer=1;
  Check(!optishade::guides::depth_transfer::Prepare(depth,{1920,1080},device,constants),"array layer requires actual 2D extraction before Texture2D copy shader");
  std::cout<<"PASS: "<<checks<<" format/view, actual ReShade descriptor admission, depth/motion reference and history interpretation checks. HDR/MSAA/wider/XR qualification is not implied.\n";
  return 0;
 }catch(const std::exception& e){std::cerr<<"FAIL: "<<e.what()<<"\n";return 1;}
}
