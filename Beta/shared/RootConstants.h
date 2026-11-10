#pragma once
#include <array>
#include <cstdint>
namespace optishade::root_capture {
// D3D12 root signatures have at most 64 DWORDs. Retain only values the game wrote.
struct Constants {
 std::array<uint32_t,64> values{};uint64_t known=0;
 bool Write(uint32_t offset,uint32_t count,const uint32_t* data){
  if(!data||offset>64||count>64-offset)return false;
  for(uint32_t i=0;i<count;++i){values[offset+i]=data[i];known|=uint64_t(1)<<(offset+i);}return true;
 }
 template<class Emit>void Replay(Emit emit)const{
  for(uint32_t i=0;i<64;++i)if(known&(uint64_t(1)<<i))emit(i,values[i]);
 }
};
}
