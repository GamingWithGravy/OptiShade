#include "ExternalFgStatus.h"
#include <stdexcept>
#include <iostream>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
int main(){
try{
 using optishade::external_fg_status::IsGenerating;
 using Json=nlohmann::json;
 const uint32_t pid=16840;const uint64_t birth=134377866723633589ull,now=1793313585ull;
 // Shape of RTX40MFG-Universal.status.json while 2x is generating.
 const Json live={{"version",1801},{"pid",pid},{"processBirth",birth},{"heartbeat",now},{"route","external"},
                  {"gameFrameGenerationOn",true},{"appliedMultiplier",2},{"actualFramesPresented",2}};
 uint32_t multiplier=0;
 CHECK(IsGenerating(live,pid,birth,now,&multiplier)&&multiplier==2);
 CHECK(IsGenerating(live,pid,birth,now+5));
 // Stale heartbeat, another process or a restarted one never counts.
 CHECK(!IsGenerating(live,pid,birth,now+6));
 CHECK(!IsGenerating(live,pid+1,birth,now));
 CHECK(!IsGenerating(live,pid,birth+1,now));
 CHECK(!IsGenerating(live,pid,birth,now-2));
 // Game FG off, a 1x request or a present carrying one frame is not generating.
 auto off=live;off["gameFrameGenerationOn"]=false;CHECK(!IsGenerating(off,pid,birth,now));
 auto single=live;single["appliedMultiplier"]=1;CHECK(!IsGenerating(single,pid,birth,now));
 auto paused=live;paused["actualFramesPresented"]=1;CHECK(!IsGenerating(paused,pid,birth,now));
 // Missing or malformed fields and non-objects fail closed.
 auto missing=live;missing.erase("heartbeat");CHECK(!IsGenerating(missing,pid,birth,now));
 auto text=live;text["pid"]="16840";CHECK(!IsGenerating(text,pid,birth,now));
 CHECK(!IsGenerating(Json::parse("[1,2]"),pid,birth,now));
 CHECK(!IsGenerating(Json::parse("not json",nullptr,false),pid,birth,now));
 // A paused generation (one frame per present, FG still on at 2x+) is Paused;
 // the hold keeps the generating answer through it for kPauseHoldMs only.
 using optishade::external_fg_status::Classify;using optishade::external_fg_status::Generation;
 using optishade::external_fg_status::PauseHold;using optishade::external_fg_status::kPauseHoldMs;
 CHECK(Classify(paused,pid,birth,now)==Generation::Paused);
 CHECK(Classify(live,pid,birth,now)==Generation::Generating);
 CHECK(Classify(off,pid,birth,now)==Generation::None&&Classify(single,pid,birth,now)==Generation::None);
 CHECK(Classify(paused,pid,birth,now+6)==Generation::None&&Classify(paused,pid+1,birth,now)==Generation::None);
 {PauseHold h;uint32_t m=9;
  CHECK(!h.Update(Generation::Paused,3,1000,m)&&m==0);          // never generated: not held
  CHECK(h.Update(Generation::Generating,3,2000,m)&&m==3);
  CHECK(h.Update(Generation::Paused,3,2900,m)&&m==3&&h.holding); // dynamic mode's one-second gap
  CHECK(h.Update(Generation::Generating,3,3800,m)&&!h.holding);
  CHECK(h.Update(Generation::Paused,3,3800+kPauseHoldMs,m)&&h.holding);
  CHECK(!h.Update(Generation::Paused,3,3801+kPauseHoldMs,m)&&m==0&&!h.holding); // a long dropout falls back
  CHECK(!h.Update(Generation::Paused,3,3802+kPauseHoldMs,m));      // and stays off until it generates again
  CHECK(h.Update(Generation::Generating,2,20000,m)&&m==2);
  CHECK(!h.Update(Generation::None,2,20100,m)&&m==0);           // FG off or a stale status: immediately
  CHECK(!h.Update(Generation::Paused,2,20200,m));}
 std::cout<<"External FG status: identity, freshness, generation, pause hold and malformed-input tests passed\n";
}catch(const std::exception&e){std::cerr<<e.what();return 1;}}
