// OptiShade GPL-3.0-or-later. The existing D3D10 relay's depth-copy prepass.
// Source is compiled by its existing worker; no second producer or lifetime.
#pragma once
#include "FormatViewContract.h"
namespace optishade::guides::depth_transfer {
struct Constants {
    uint32_t width=0,height=0,sourceX=0,sourceY=0;
    uint32_t sourceWidth=0,sourceHeight=0,flip=0,conversion=0;
    float nearZ=0,farZ=0,multiplier=1;
    uint32_t reserved=0;
};
static_assert(sizeof(Constants)==48,"Depth transfer shader constant ABI");
// Raw DeviceZ is copied exactly; the original Resolve kernel still owns its
// scale/log/reversal transform. LinearViewZ preparation is reference-tested
// here, but the production CoreGuideReason guard still refuses that route.
inline bool Prepare(const format_view::SurfaceView& source,format_view::Extent output,
    const format_view::DepthMeaning& meaning,Constants& constants) {
    if(!format_view::ValidateSurface(source)||source.samples!=1||source.layers!=1||source.layer!=0||
       format_view::SelectedCount(source.layers,source.layer,source.selectedLayers)!=1||
       format_view::SelectedCount(source.mipLevels,source.mip,source.selectedMips)!=1||
       !output.width||!output.height||output.width>16384||output.height>16384||
       !format_view::ValidateDepth(meaning))return false;
    Constants result{output.width,output.height,source.rect.x,source.rect.y,
        source.rect.width,source.rect.height,meaning.upsideDown?1u:0u,0,0,0,meaning.multiplier,0};
    if(meaning.encoding==format_view::DepthEncoding::LinearViewZ){
        result.conversion=std::isinf(meaning.farZ)?2u:1u;
        result.nearZ=meaning.nearZ;result.farZ=result.conversion==1?meaning.farZ:0;
    }
    constants=result;return true;
}
inline constexpr char Hlsl[]=R"OSDEPTH(
cbuffer Extent:register(b0) {
 uint width,height,sourceX,sourceY;
 uint sourceWidth,sourceHeight,flip,conversion;
 float nearZ,farZ,multiplier;uint reserved;
};
Texture2D<float> scene:register(t0);
float4 CopyVS(uint id:SV_VertexID):SV_Position{return float4(id==2?3:-1,id==1?3:-1,0,1);}
float CopyPS(float4 position:SV_Position):SV_Target {
 uint2 p=min(uint2(position.xy),uint2(width-1,height-1));
 uint2 samplePixel=min(((p*2u+1u)*uint2(sourceWidth,sourceHeight))/(uint2(width,height)*2u),uint2(sourceWidth-1,sourceHeight-1));
 if(flip)samplePixel.y=sourceHeight-1-samplePixel.y;
 samplePixel+=uint2(sourceX,sourceY);
 float d=scene.Load(int3(samplePixel,0));
 if(conversion) {
  d*=multiplier;
  if(!isfinite(d)||d<=0)return asfloat(0x7fc00000u);
  d=conversion==2?1-nearZ/d:(farZ/(farZ-nearZ))*(1-nearZ/d);
  return saturate(d);
 }
 return d;
}
)OSDEPTH";
}
