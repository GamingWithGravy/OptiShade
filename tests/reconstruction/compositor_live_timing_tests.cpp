#include "../../Research/Compositor/live_timing.h"
#include <cassert>
#include <iostream>
using namespace compositor::timing;
int main() {
 const int64_t source=1000000000,begin=source+1000000,interval=16000000;
 for(unsigned count=1;count<=4;++count)for(unsigned i=0;i<count;++i){
  const auto slot=MakeSlot(begin,interval,i,count);
  assert(slot.valid&&slot.due<slot.expires);
  assert(MaySubmit(slot,source,slot.due));
  assert(MaySubmit(slot,source,slot.expires-1));
  assert(!MaySubmit(slot,source,slot.due-1));
  assert(!MaySubmit(slot,source,slot.expires));
 }
 // Regression: a slot was timely BEFORE waiting for the swapchain but expired
 // WHILE waiting. The live path must call this after readiness and again after
 // synthesis, not cache the earlier decision.
 const auto slot=MakeSlot(begin,interval,0,4);
 assert(MaySubmit(slot,source,begin));
 assert(!MaySubmit(slot,source,begin+5000000));
 assert(!MaySubmit(slot,source,source+MaxSourceAgeNs+1));
 assert(!SourceFresh(source,source-1));
 assert(SourceFresh(source,source+MaxSourceAgeNs));
 assert(!SourceFresh(0,source));
 // WGC timestamps identify compositor-render time and may be slightly ahead
 // of the consumer thread's QPC read. Accept a bounded lead, schedule from that
 // timestamp, and never present before the scheduled frame time.
 const int64_t futureSource=source+13000000;
 assert(CaptureTimestampUsable(futureSource,source));
 assert(!CaptureTimestampUsable(source+MaxCaptureTimestampLeadNs+1,source));
 const auto futureSlot=MakeSlot(futureSource,interval,0,4);
 assert(futureSlot.valid&&futureSlot.due==futureSource);
 assert(!MaySubmit(futureSlot,futureSource,futureSource-1));
 assert(MaySubmit(futureSlot,futureSource,futureSource));
 assert(HideExpiredOutput(0,source));
 assert(!HideExpiredOutput(source,source+MaxSourceAgeNs));
 assert(HideExpiredOutput(source,source+MaxSourceAgeNs+1));
 assert(HideExpiredOutput(source,source-1));
 assert(CoherentPair(source-interval,source,begin));
 assert(CoherentPair(source-interval,futureSource,source));
 assert(!CoherentPair(source,source,begin));
 assert(!CoherentPair(source+1,source,begin));
 assert(!CoherentPair(source-MaxSourceAgeNs-1,source,begin));
 assert(!CoherentPair(source-interval,source,source+MaxSourceAgeNs+1));
 assert(!MakeSlot(begin,0,0,2).valid);
 assert(!MakeSlot(begin,interval,2,2).valid);
 assert(!MakeSlot(begin,interval,0,5).valid);
 assert(!MakeSlot(INT64_MAX-1,interval,0,1).valid);
 std::cout<<"Compositor live timing: late-ready, stale/future capture, cut and bounded-slot gates passed; no GPU/scanout test.\n";
}
