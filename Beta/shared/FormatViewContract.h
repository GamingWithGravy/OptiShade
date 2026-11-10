// OptiShade GPL-3.0-or-later. Scalar input interpretation used by existing
// frame owners. This file owns no resource, device, history, queue or presenter.
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include "GuideExtent.h"

namespace optishade::format_view {
struct Extent { uint32_t width=0,height=0; };
struct Rect { uint32_t x=0,y=0,width=0,height=0; };
struct SurfaceView {
    Extent extent{}; // allocation at mip zero; rect is in the selected mip
    Rect rect{};
    uint32_t layers=0,layer=0,samples=0,mipLevels=0,mip=0;
    uint32_t selectedLayers=0,selectedMips=0;
};
struct ViewIdentity {
    uint64_t owner=0,generation=0;
    uint32_t index=0,count=0;
    bool projection=false,known=false;
};
enum class ColorEncoding:uint32_t { Unknown,Srgb,Linear,Pq,Hlg };
enum class ColorRange:uint32_t { Unknown,Sdr,ScRgb,HDR10 };
enum class ColorStorage:uint32_t { Unknown,Rgba8,Bgra8,Rgb10A2,Rgba16Float,Rgba32Float,R11G11B10Float };
struct ColorMeaning {
    ColorEncoding encoding=ColorEncoding::Unknown;
    ColorRange range=ColorRange::Unknown;
    // Zero is unknown. This is never inferred from the channel bit count.
    float referenceWhiteNits=0;
};
enum class DepthEncoding:uint32_t { Unknown,DeviceZ,LinearViewZ };
struct DepthMeaning {
    DepthEncoding encoding=DepthEncoding::Unknown;
    bool reversed=false,logarithmic=false,upsideDown=false;
    float multiplier=1;
    // Positive view-space distances, required only for LinearViewZ. DeviceZ
    // does not become linear depth just because it is stored in R32_FLOAT.
    float nearZ=0,farZ=0;
};
enum class MotionUnits:uint32_t { Unknown,BackwardUv,BackwardPixels,ForwardUv,ForwardPixels };
struct MotionMeaning {
    MotionUnits units=MotionUnits::Unknown;
    Extent reference{};
    bool upsideDown=false;
};

inline bool Same(Extent a,Extent b) { return a.width==b.width&&a.height==b.height; }
inline bool Same(Rect a,Rect b) { return a.x==b.x&&a.y==b.y&&a.width==b.width&&a.height==b.height; }
inline bool Same(const SurfaceView& a,const SurfaceView& b) {
    return Same(a.extent,b.extent)&&Same(a.rect,b.rect)&&a.layers==b.layers&&a.layer==b.layer&&
        a.samples==b.samples&&a.mipLevels==b.mipLevels&&a.mip==b.mip&&
        a.selectedLayers==b.selectedLayers&&a.selectedMips==b.selectedMips;
}
inline bool Same(const ViewIdentity& a,const ViewIdentity& b) {
    return a.owner==b.owner&&a.generation==b.generation&&a.index==b.index&&a.count==b.count&&
        a.projection==b.projection&&a.known==b.known;
}
inline bool Same(const ColorMeaning& a,const ColorMeaning& b) {
    return a.encoding==b.encoding&&a.range==b.range&&a.referenceWhiteNits==b.referenceWhiteNits;
}
inline bool Same(const DepthMeaning& a,const DepthMeaning& b) {
    return a.encoding==b.encoding&&a.reversed==b.reversed&&a.logarithmic==b.logarithmic&&
        a.upsideDown==b.upsideDown&&a.multiplier==b.multiplier&&a.nearZ==b.nearZ&&a.farZ==b.farZ;
}
inline Extent MipExtent(const SurfaceView& s) {
    if(!s.extent.width||!s.extent.height||s.mip>=s.mipLevels||s.mip>=32)return {};
    return {std::max(1u,s.extent.width>>s.mip),std::max(1u,s.extent.height>>s.mip)};
}
inline bool ValidRect(Rect r,Extent e) {
    return e.width&&e.height&&r.width&&r.height&&r.x<e.width&&r.y<e.height&&
        r.width<=e.width-r.x&&r.height<=e.height-r.y;
}
// UINT32_MAX is the documented API "all remaining" view count. Normalize it
// against the actual allocation before comparing or submitting the view.
inline uint32_t SelectedCount(uint32_t total,uint32_t first,uint32_t selected) {
    if(first>=total||!selected)return 0;
    if(selected==UINT32_MAX)return total-first;
    return selected<=total-first?selected:0;
}
inline bool ValidateSurface(const SurfaceView& s) {
    const auto extent=MipExtent(s);
    return s.extent.width<=16384&&s.extent.height<=16384&&s.layers&&s.samples&&
        s.mipLevels<=15&&SelectedCount(s.layers,s.layer,s.selectedLayers)&&
        SelectedCount(s.mipLevels,s.mip,s.selectedMips)&&ValidRect(s.rect,extent);
}
inline bool ValidateView(const ViewIdentity& v) {
    return v.known&&v.count>=1&&v.count<=16&&v.index<v.count&&
        (v.projection||(v.count==1&&v.index==0));
}
inline bool SameBoundView(const ViewIdentity& a,const ViewIdentity& b) {
    return ValidateView(a)&&ValidateView(b)&&a.owner&&a.generation&&Same(a,b);
}
inline bool FullSingleSurface(const SurfaceView& s) {
    return ValidateSurface(s)&&s.layers==1&&s.layer==0&&s.samples==1&&s.mipLevels==1&&s.mip==0&&
        SelectedCount(s.layers,s.layer,s.selectedLayers)==1&&
        SelectedCount(s.mipLevels,s.mip,s.selectedMips)==1&&
        Same(s.rect,Rect{0,0,s.extent.width,s.extent.height});
}
inline bool SubresourceIndex(const SurfaceView& s,uint32_t& index) {
    if(!ValidateSurface(s)||SelectedCount(s.layers,s.layer,s.selectedLayers)!=1||
        SelectedCount(s.mipLevels,s.mip,s.selectedMips)!=1)return false;
    const uint64_t value=uint64_t(s.layer)*s.mipLevels+s.mip;
    if(value>UINT32_MAX)return false;
    index=static_cast<uint32_t>(value);return true;
}
inline bool ValidateDepth(const DepthMeaning& d) {
    if(!std::isfinite(d.multiplier)||d.multiplier<=0)return false;
    if(d.encoding==DepthEncoding::DeviceZ)return d.nearZ==0&&d.farZ==0;
    return d.encoding==DepthEncoding::LinearViewZ&&!d.logarithmic&&!d.reversed&&
        std::isfinite(d.nearZ)&&d.nearZ>0&&!std::isnan(d.farZ)&&d.farZ>d.nearZ;
}

enum class Reason:uint32_t {
    Ready,InvalidSurface,UnknownView,NeedsViewExtraction,NeedsSampleResolve,
    NeedsMipSelection,ExtentOutsideCurrentRoute,DepthExtentMismatch,
    NeedsColorConversion,UnknownDepth,NeedsLinearDepthConversion
};
inline const char* Explain(Reason reason) {
    switch(reason){
    case Reason::Ready:return "Current SDR guide format/view contract accepted";
    case Reason::InvalidSurface:return "Invalid selected texture view, rectangle or subresource";
    case Reason::UnknownView:return "A matching eye/view identity is required";
    case Reason::NeedsViewExtraction:return "Array or subrect input requires qualified view extraction";
    case Reason::NeedsSampleResolve:return "Multisample input requires a qualified colour/depth/motion resolve";
    case Reason::NeedsMipSelection:return "Selected mip input requires qualified staging";
    case Reason::ExtentOutsideCurrentRoute:return "Output exceeds the current 64–5120 by 64–2160 guide envelope";
    case Reason::DepthExtentMismatch:return "Depth scale/aspect does not match output (supported scale is 0.25x–4x)";
    case Reason::NeedsColorConversion:return "Colour transfer/storage requires a qualified conversion before SDR guides";
    case Reason::UnknownDepth:return "Depth encoding or projection is missing or invalid";
    case Reason::NeedsLinearDepthConversion:return "Linear view depth requires qualified conversion to conventional device depth";
    }
    return "Unknown input conversion requirement";
}
// This is the existing core-guide envelope, not a universal capability claim.
// Wider input can be described and tested without deleting its admission guard.
inline Reason CoreGuideReason(const SurfaceView& color,const SurfaceView& depth,
    ColorStorage storage,const ColorMeaning& meaning,const DepthMeaning& depthMeaning,
    const ViewIdentity& view,bool allowUnspecifiedSdr) {
    if(!ValidateSurface(color)||!ValidateSurface(depth))return Reason::InvalidSurface;
    if(!ValidateView(view))return Reason::UnknownView;
    if(color.samples!=1||depth.samples!=1)return Reason::NeedsSampleResolve;
    if(color.mipLevels!=1||depth.mipLevels!=1||color.mip||depth.mip)return Reason::NeedsMipSelection;
    if(!FullSingleSurface(color)||!FullSingleSurface(depth))return Reason::NeedsViewExtraction;
    if(color.extent.width<64||color.extent.height<64||color.extent.width>5120||color.extent.height>2160)
        return Reason::ExtentOutsideCurrentRoute;
    if(!guides::CompatibleDepthExtent(color.extent.width,color.extent.height,depth.extent.width,depth.extent.height))
        return Reason::DepthExtentMismatch;
    const bool unspecified=meaning.encoding==ColorEncoding::Unknown&&meaning.range==ColorRange::Unknown;
    const bool sdr=meaning.encoding==ColorEncoding::Srgb&&meaning.range==ColorRange::Sdr;
    if((storage!=ColorStorage::Rgba8&&storage!=ColorStorage::Bgra8)||
       !std::isfinite(meaning.referenceWhiteNits)||meaning.referenceWhiteNits<0||
       (!sdr&&!(allowUnspecifiedSdr&&unspecified)))return Reason::NeedsColorConversion;
    if(!ValidateDepth(depthMeaning))return Reason::UnknownDepth;
    if(depthMeaning.encoding!=DepthEncoding::DeviceZ)return Reason::NeedsLinearDepthConversion;
    return Reason::Ready;
}

// Pure reference for the actual nearest-depth transfer kernel. Mapping uses
// pixel centres and integer arithmetic, so half/quarter scale and odd extents
// select the same texel; no interpolation invents depth across a silhouette.
inline bool SourcePixel(Rect source,Extent destination,uint32_t x,uint32_t y,
    bool upsideDown,uint32_t& sourceX,uint32_t& sourceY) {
    if(!source.width||!source.height||!destination.width||!destination.height||
       destination.width>16384||destination.height>16384||source.width>16384||source.height>16384||
       x>=destination.width||y>=destination.height||source.x>16384-source.width||
       source.y>16384-source.height)return false;
    const uint64_t sx=((uint64_t(x)*2+1)*source.width)/(uint64_t(destination.width)*2);
    const uint64_t sy=((uint64_t(y)*2+1)*source.height)/(uint64_t(destination.height)*2);
    sourceX=source.x+static_cast<uint32_t>(std::min(sx,uint64_t(source.width-1)));
    const auto row=static_cast<uint32_t>(std::min(sy,uint64_t(source.height-1)));
    sourceY=source.y+(upsideDown?source.height-1-row:row);return true;
}
// Device-depth reference preserves the original multiplier/log/reverse order.
// LinearViewZ requires a real projection; no near/far guess is permitted.
inline bool ConventionalDepth(float sample,const DepthMeaning& meaning,float& result) {
    if(!ValidateDepth(meaning)||!std::isfinite(sample))return false;
    double value=double(sample)*meaning.multiplier;
    if(meaning.encoding==DepthEncoding::LinearViewZ){
        if(value<=0)return false;
        if(std::isinf(meaning.farZ))value=1-double(meaning.nearZ)/value;
        else value=double(meaning.farZ)/(meaning.farZ-meaning.nearZ)*
            (1-double(meaning.nearZ)/value);
    }else{
        if(meaning.logarithmic)value=std::expm1(value*std::log(1.01))/0.01;
        if(meaning.reversed)value=1-value;
    }
    if(!std::isfinite(value))return false;
    result=static_cast<float>(std::max(0.0,std::min(1.0,value)));return true;
}
inline bool BackwardUv(float x,float y,const MotionMeaning& meaning,float& outX,float& outY) {
    if(!std::isfinite(x)||!std::isfinite(y)||!meaning.reference.width||!meaning.reference.height)return false;
    if(meaning.units==MotionUnits::BackwardPixels){x/=meaning.reference.width;y/=meaning.reference.height;}
    else if(meaning.units!=MotionUnits::BackwardUv)return false;
    // A forward field cannot be inverted by simply changing its sign: the
    // displacement belongs to a different pixel. Such a route stays blocked.
    outX=x;outY=meaning.upsideDown?-y:y;return true;
}
// A history key contains interpretation, not rotating resource handles or
// per-frame counters. It lives inside the existing guide owner.
struct Interpretation {
    SurfaceView color{},depth{};
    ViewIdentity view{};
    ColorMeaning colorMeaning{};
    DepthMeaning depthMeaning{};
    uint32_t colorResourceFormat=0,colorViewFormat=0,depthResourceFormat=0,depthViewFormat=0;
};
inline bool Same(const Interpretation& a,const Interpretation& b) {
    return Same(a.color,b.color)&&Same(a.depth,b.depth)&&Same(a.view,b.view)&&
        Same(a.colorMeaning,b.colorMeaning)&&Same(a.depthMeaning,b.depthMeaning)&&
        a.colorResourceFormat==b.colorResourceFormat&&a.colorViewFormat==b.colorViewFormat&&
        a.depthResourceFormat==b.depthResourceFormat&&a.depthViewFormat==b.depthViewFormat;
}
}
