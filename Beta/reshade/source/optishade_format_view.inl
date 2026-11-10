// OptiShade GPL-3.0-or-later. Adapt actual ReShade allocation and view
// descriptors to the shared scalar contract; never infer an eye from a layer.
#pragma once
// The including runtime/addon supplies its own matching ReShade API headers.
#include "../../shared/FormatViewContract.h"
namespace osformat {
namespace fv=optishade::format_view;
using namespace reshade;
inline fv::ColorStorage Storage(api::format format) {
    switch(api::format_to_default_typed(format,0)){
    case api::format::r8g8b8a8_unorm:return fv::ColorStorage::Rgba8;
    case api::format::b8g8r8a8_unorm:return fv::ColorStorage::Bgra8;
    case api::format::r10g10b10a2_unorm:return fv::ColorStorage::Rgb10A2;
    case api::format::r16g16b16a16_float:return fv::ColorStorage::Rgba16Float;
    case api::format::r32g32b32a32_float:return fv::ColorStorage::Rgba32Float;
    case api::format::r11g11b10_float:return fv::ColorStorage::R11G11B10Float;
    default:return fv::ColorStorage::Unknown;
    }
}
inline fv::ColorMeaning Meaning(api::color_space space) {
    switch(space){
    case api::color_space::srgb_nonlinear:return {fv::ColorEncoding::Srgb,fv::ColorRange::Sdr,0};
    // Declared scRGB uses linear BT.709 primaries and 80 nits at RGB=1.
    // https://learn.microsoft.com/windows/win32/direct3darticles/high-dynamic-range
    case api::color_space::extended_srgb_linear:return {fv::ColorEncoding::Linear,fv::ColorRange::ScRgb,80};
    case api::color_space::hdr10_st2084:return {fv::ColorEncoding::Pq,fv::ColorRange::HDR10,0};
    case api::color_space::hdr10_hlg:return {fv::ColorEncoding::Hlg,fv::ColorRange::Unknown,0};
    default:return {};
    }
}
inline fv::SurfaceView Surface(const api::resource_desc& desc,const api::resource_view_desc& view) {
    if(desc.type!=api::resource_type::texture_2d||view.type!=api::resource_view_type::texture_2d)return {};
    fv::SurfaceView result;
    result.extent={desc.texture.width,desc.texture.height};
    result.layers=desc.texture.depth_or_layers;result.layer=view.texture.first_layer;
    result.samples=desc.texture.samples;result.mipLevels=desc.texture.levels;result.mip=view.texture.first_level;
    result.selectedLayers=fv::SelectedCount(result.layers,result.layer,view.texture.layers);
    result.selectedMips=fv::SelectedCount(result.mipLevels,result.mip,view.texture.levels);
    const auto extent=fv::MipExtent(result);result.rect={0,0,extent.width,extent.height};
    return result;
}
inline bool ReadableDepth(api::format format) {
    switch(format){
    case api::format::r16_unorm:case api::format::r16_float:case api::format::r32_float:
    case api::format::r24_unorm_x8_uint:case api::format::r32_float_x8_uint:
    // OpenGL depth textures retain the depth-stencil format in the view
    // descriptor; the sampler still reads their depth aspect.
    case api::format::d16_unorm:case api::format::d24_unorm_x8_uint:
    case api::format::d24_unorm_s8_uint:case api::format::d32_float:case api::format::d32_float_s8_uint:return true;
    default:return false;
    }
}
struct Inspection {
    fv::Interpretation interpretation{};
    fv::ColorStorage colorStorage=fv::ColorStorage::Unknown;
    fv::Reason reason=fv::Reason::InvalidSurface;
};
inline Inspection Inspect(const api::resource_desc& color,const api::resource_view_desc& colorView,
    const api::resource_desc& depth,const api::resource_view_desc& depthView,api::color_space space,
    const fv::DepthMeaning& depthMeaning,const fv::ViewIdentity& view) {
    Inspection result;auto& f=result.interpretation;
    if(color.type!=api::resource_type::texture_2d||depth.type!=api::resource_type::texture_2d||
       colorView.type!=api::resource_view_type::texture_2d||depthView.type!=api::resource_view_type::texture_2d)
        return result;
    f.color=Surface(color,colorView);f.depth=Surface(depth,depthView);f.view=view;
    f.colorMeaning=Meaning(space);f.depthMeaning=depthMeaning;
    f.colorResourceFormat=static_cast<uint32_t>(color.texture.format);
    f.colorViewFormat=static_cast<uint32_t>(colorView.format);
    f.depthResourceFormat=static_cast<uint32_t>(depth.texture.format);
    f.depthViewFormat=static_cast<uint32_t>(depthView.format);
    if(!fv::ValidateSurface(f.color)||!fv::ValidateSurface(f.depth))return result;
    result.colorStorage=Storage(colorView.format);
    // The copy to the producer's UNORM snapshot preserves encoded components.
    // An sRGB view is metadata, not permission to decode/re-encode the copy.
    if(result.colorStorage!=Storage(color.texture.format)||
       api::format_to_typeless(color.texture.format)!=api::format_to_typeless(colorView.format)){
        result.reason=fv::Reason::NeedsColorConversion;return result;
    }
    if(!ReadableDepth(depthView.format)||
       api::format_to_typeless(depth.texture.format)!=api::format_to_typeless(depthView.format)){
        result.reason=fv::Reason::UnknownDepth;return result;
    }
    result.reason=fv::CoreGuideReason(f.color,f.depth,result.colorStorage,f.colorMeaning,
        f.depthMeaning,f.view,space==api::color_space::unknown);
    return result;
}
}
