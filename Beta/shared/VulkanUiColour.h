#pragma once
#include <cmath>
#include <cstdint>
namespace optishade::ui {
// ImGui packs display-space RGB. Vulkan sRGB attachments encode shader RGB,
// unlike the UNORM target used by the desktop renderer. Decode the upload
// copy only; do not mutate the saved palette, original draw data or alpha.
inline uint32_t LinearVertexColour(uint32_t colour,unsigned r,unsigned g,unsigned b) {
 static const auto table=[](){struct Values {uint8_t bytes[256];} v{};
  for(int i=0;i<256;++i){const float x=i/255.f;const float y=x<=.04045f?x/12.92f:std::pow((x+.055f)/1.055f,2.4f);v.bytes[i]=static_cast<uint8_t>(std::lround(y*255.f));}return v;}();
 const uint32_t mask=(255u<<r)|(255u<<g)|(255u<<b);
 return (colour&~mask)|(uint32_t(table.bytes[(colour>>r)&255])<<r)|(uint32_t(table.bytes[(colour>>g)&255])<<g)|(uint32_t(table.bytes[(colour>>b)&255])<<b);
}
}
