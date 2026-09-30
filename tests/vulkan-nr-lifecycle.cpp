#include "../shared/VulkanNrLifecycle.h"
#include <cassert>
#include <iostream>
#include <limits>
int main(){
 using namespace optishade::vknr;
 Lifecycle primary,secondary;
 HistoryIdentity identity{{0,0,10,11,12,13},1,1,1920,1080};
 assert(primary.observe(identity));assert(!primary.observe(identity));
 secondary.observe(identity);secondary.result(true);
 for(unsigned i=0;i<100;++i)primary.result(false);
 assert(primary.calls==100&&primary.completed==0); // No arbitrary warm-up failure latch.
 primary.result(true);assert(primary.completed==1&&secondary.completed==1);
 primary.missing();assert(primary.observe(identity));assert(!primary.observe(identity));
 ++identity.guides[2];assert(primary.observe(identity)); // Same-size guide replacement.
 ++identity.effects;assert(primary.observe(identity)); // Effect reload/preset generation, handles reused.
 ++identity.surface;assert(primary.observe(identity)); // Same-size swapchain recreation.
 identity.width=2560;identity.height=1440;assert(primary.observe(identity));
 assert(secondary.identity.width==1920&&secondary.generation==1); // Independent history state.
 unsigned reports=0;
 for(uint64_t now=1;now<=100000;++now){reports+=primary.report(Reason::MissingGuides,now);reports+=primary.report(Reason::InvalidGuides,now);}
 assert(reports==40);assert(primary.reasons[unsigned(Reason::MissingGuides)].total==100000); // Alternation cannot defeat bounded logging.
 for(unsigned passes:{1u,2u,3u,1u}){
  GuideOptions options{1.f,passes,true};auto extent=working_extent(3840,2160,options);assert(extent.supported&&extent.width==3840&&extent.height==2160);
  options.applyModel=false;assert(working_extent(3840,2160,options).supported&&!options.applyModel);
 }
 for(float scale:{.25f,.5f,1.f}){auto e=working_extent(3840,2160,{scale,2,true});assert(e.supported&&e.width==uint32_t(3840*scale)&&e.height==uint32_t(2160*scale));}
 auto doubled=working_extent(1920,1080,{2.f,3,true});assert(doubled.supported&&doubled.width==3840&&doubled.height==2160);
 assert(!working_extent(3840,2160,{2.f,1,true}).supported);
 assert(!working_extent(5120,1440,{.5f,1,true}).supported); // Native restriction remains explicit.
 assert(!working_extent(1920,1080,{1.f,4,true}).supported);
 assert(!working_extent(1920,1080,{std::numeric_limits<float>::quiet_NaN(),1,true}).supported);
 assert(!working_extent(1920,1080,{std::numeric_limits<float>::infinity(),1,true}).supported);
 assert(!working_extent(0,1080,{1.f,1,true}).supported);
 std::cout<<"PASS: independent generations, same-size guide/surface/reload recovery, indefinite warm-up, bounded interleaved reasons\nPASS: requested 1/2/3/1 passes, Apply Model flag and supported/bounded working extents (GPU evaluation pending)\n";
}
