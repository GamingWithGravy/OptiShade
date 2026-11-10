#pragma once
#include <cstdint>
#include <cmath>
#include <initializer_list>
namespace optishade::vr {
struct Slice {uint32_t width=0,height=0,layers=0,layer=0,left=0,top=0,right=0,bottom=0;};
inline bool Range(float minimum,float maximum,float nearZ,float farZ){
 return minimum==0.f&&maximum==1.f&&!std::isnan(nearZ)&&!std::isnan(farZ)&&nearZ>0&&farZ>0&&nearZ!=farZ;
}
inline const char* Pair(const Slice& color,const Slice& depth){
 for(const auto* s:{&color,&depth})if(!s->layers||s->layer>=s->layers||s->right<=s->left||s->bottom<=s->top||s->right>s->width||s->bottom>s->height)return "Invalid projection eye rectangle or array layer";
 if(depth.left||depth.top||depth.right!=depth.width||depth.bottom!=depth.height)return "Depth must cover a complete D3D12 eye slice";
 if(color.right-color.left!=depth.width||color.bottom-color.top!=depth.height)return "Projection colour and depth eye extents differ";
 if(depth.width<64||depth.height<64||depth.width>5120||depth.height>2160)return "Projection eye exceeds the current SDR NR working envelope";
 return nullptr;
}
}
