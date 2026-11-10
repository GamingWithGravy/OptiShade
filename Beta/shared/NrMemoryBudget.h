// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include <cstdint>
namespace optishade::nr {
// Accessed under the NR runtime mutex. A retry must not reuse a recent admission
// result from before the pressure stop or before the override was disabled.
struct AllocationPlan {
 uint64_t adapter=0, tuningGeneration=0;
 uint32_t width=0,height=0,workWidth=0,workHeight=0,format=0,precision=0,passes=0;
 bool beforeUpscale=false,rayReconstruction=false,proxy=false,estimatedTaa=false;
 bool same(const AllocationPlan& b)const{
  return adapter==b.adapter&&tuningGeneration==b.tuningGeneration&&width==b.width&&height==b.height&&
   workWidth==b.workWidth&&workHeight==b.workHeight&&format==b.format&&precision==b.precision&&passes==b.passes&&
   beforeUpscale==b.beforeUpscale&&rayReconstruction==b.rayReconstruction&&proxy==b.proxy&&estimatedTaa==b.estimatedTaa;
 }
};
// Recovery is sampled, not a per-frame allocation retry. Three seconds of
// headroom above the normal 64 MiB running reserve prevents budget oscillation.
struct BudgetRecovery {
 uint64_t last=0,healthySince=0; bool sampled=false,healthy=false;
 void reset(){last=healthySince=0;sampled=healthy=false;}
 bool due(uint64_t now){
  if(sampled&&now>=last&&now-last<1000)return false;
  last=now;sampled=true;return true;
 }
 bool observe(uint64_t now,bool valid,uint64_t budget,uint64_t usage){
  constexpr uint64_t headroom=128ull*1024*1024;
  if(!valid||!budget||usage>=budget||budget-usage<headroom){healthy=false;return false;}
  if(!healthy||now<healthySince){healthy=true;healthySince=now;return false;}
  return now-healthySince>=3000;
 }
};
struct BudgetCheck {
 uint64_t last=0; bool required=true,hasPlan=false; AllocationPlan lastPlan{};
 void invalidate(){required=true;hasPlan=false;}
 bool due(uint64_t now,const AllocationPlan& plan,bool allocationNeeded){
  const bool changed=allocationNeeded&&(!hasPlan||!lastPlan.same(plan));
  if(!required&&!changed&&last&&now>=last&&now-last<1000)return false;
  last=now;required=false;lastPlan=plan;hasPlan=true;return true;
 }
};
}
