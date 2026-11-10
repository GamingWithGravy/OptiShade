// OptiShade GPL-3.0-or-later. Borrowed views stay owned by the existing core
// guide/runtime and are consumed synchronously on its render thread.
#pragma once
#include <atomic>
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cmath>
#include "GuideExtent.h"
namespace optishade::legacy {
inline constexpr uint32_t GuideVersion=3;
enum class GuideProvenance:uint32_t {Unknown=0,CoreEstimated=1};
struct GuideFrame {
 uint32_t size=sizeof(GuideFrame),version=GuideVersion;
 uint64_t runtime=0,commandList=0,colorView=0,depthView=0,motionView=0;
 // The same producer's pre-effect, orientation-normalized colour snapshot.
 uint64_t preparedColorView=0;
 uint64_t generation=0;
 uint32_t width=0,height=0,ready=0;
 GuideProvenance provenance=GuideProvenance::Unknown;
 // Core vectors are backward UV displacement; depth is already conventional.
 uint32_t normalizedMotion=1,conventionalDepth=1;
};
inline bool ValidGuides(const GuideFrame& f,uint64_t runtime,uint64_t commandList) {
 return f.size==sizeof(GuideFrame)&&f.version==GuideVersion&&f.runtime==runtime&&runtime&&
  f.commandList==commandList&&commandList&&f.colorView&&f.preparedColorView&&f.depthView&&f.motionView&&f.generation&&
  f.width>=64&&f.height>=64&&f.width<=5120&&f.height<=2160&&f.ready==1&&
  f.provenance==GuideProvenance::CoreEstimated&&f.normalizedMotion==1&&f.conventionalDepth==1;
}
// D3D10 has no compute stage. The same original guide kernels execute on the
// feed's existing, same-adapter D3D11 relay. This is a raw input contract, never
// a claim that depth/motion guides or neural output have already been produced.
struct CoreSourceFrame {
 uint32_t size=sizeof(CoreSourceFrame),version=GuideVersion;
 uint64_t runtime=0,commandList=0,colorView=0,sourceDepthView=0;
 uint32_t width=0,height=0,depthWidth=0,depthHeight=0;
 uint32_t reversed=0,logarithmic=0,upsideDown=0,sdr=0;
 float multiplier=1;
 uint32_t reserved=0;
};
inline bool ValidCoreSource(const CoreSourceFrame& f,uint64_t runtime,uint64_t commandList) {
 return f.size==sizeof(CoreSourceFrame)&&f.version==GuideVersion&&f.runtime==runtime&&runtime&&
  f.commandList==commandList&&commandList&&f.colorView&&f.sourceDepthView&&f.sdr==1&&
  f.width>=64&&f.height>=64&&f.width<=5120&&f.height<=2160&&
  guides::CompatibleDepthExtent(f.width,f.height,f.depthWidth,f.depthHeight)&&
  f.reversed<=1&&f.logarithmic<=1&&f.upsideDown<=1&&f.reserved==0&&
  std::isfinite(f.multiplier)&&f.multiplier>0;
}
struct IntentSnapshot {uint64_t revision=0;bool requested=false;};
class SessionIntent {
 // Fresh process always starts Off. This is never deserialized from a preset.
 std::atomic<uint64_t> state_{0};
public:
 IntentSnapshot Read()const {const auto value=state_.load();return {value>>1,(value&1)!=0};}
 bool Set(bool requested,uint64_t expectedRevision) {
  auto previous=state_.load();
  if((previous>>1)!=expectedRevision||expectedRevision>=UINT64_MAX/2)return false;
  return state_.compare_exchange_strong(previous,((expectedRevision+1)<<1)|(requested?1ull:0ull));
 }
};
struct Snapshot {
 uint32_t size=sizeof(Snapshot),version=GuideVersion;
 uint64_t requestRevision=0;
 uint32_t requested=0,feedActive=0,guidesReady=0,inferenceVerified=0,outputVerified=0;
 uint32_t api=0,vendorId=0,deviceId=0;
 uint64_t adapterLuid=0,deviceGeneration=0,guideGeneration=0,transportedFrames=0;
 uint64_t window=0,sampleTick=0;
 uint64_t deviceIdentity=0,outputIdentity=0,outputGeneration=0;
 uint64_t acceptedRevision=0;
 uint32_t failed=0,reserved=0;
};
inline bool CopySnapshot(const Snapshot& source,void* destination,uint32_t bytes) {
 if(!destination||bytes<sizeof(Snapshot))return false;
 std::memcpy(destination,&source,sizeof(Snapshot));return true;
}
using GuideAbi=uint32_t(*)();
using NeedsGuides=bool(*)(void* runtime);
using SubmitGuides=bool(*)(const GuideFrame*);
using SubmitCoreSource=bool(*)(const CoreSourceFrame*);
using SetSessionIntent=bool(*)(uint32_t requested,uint64_t expectedRevision);
using ReadSnapshot=bool(*)(void* destination,uint32_t bytes);
}
