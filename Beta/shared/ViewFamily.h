#pragma once
#include <array>
#include <cstdint>
namespace optishade::views {
struct View {uint64_t image=0;uint32_t width=0,height=0,layers=0,layer=0,left=0,top=0,right=0,bottom=0;};
struct Rect {uint32_t left=0,top=0,right=0,bottom=0;};
struct Layout {std::array<Rect,16> packed{};uint32_t count=0,width=0,height=0;bool direct=false;};
inline bool Build(const View* views,uint32_t count,Layout& out){
 out={};if(!views||!count||count>out.packed.size())return false;
 bool direct=true;uint32_t x=0,h=0;
 for(uint32_t i=0;i<count;++i){const auto& v=views[i];
  if(!v.image||!v.width||!v.height||v.layer>=v.layers||v.left>=v.right||v.top>=v.bottom||v.right>v.width||v.bottom>v.height)return false;
  const auto width=v.right-v.left,height=v.bottom-v.top;
  if(width>16384-x||height>16384)return false;
  for(uint32_t j=0;j<i;++j){const auto& b=views[j];if(v.image==b.image&&v.layer==b.layer&&v.left<b.right&&b.left<v.right&&v.top<b.bottom&&b.top<v.bottom)return false;}
  out.packed[i]={x,0,x+width,height};
  direct &= v.image==views[0].image && v.layer==0 && v.layers==1 && v.left==x && v.top==0 && height==v.height;
  x+=width;if(height>h)h=height;
 }
 out.count=count;out.width=x;out.height=h;out.direct=direct&&views[0].width==x;return true;
}
}
