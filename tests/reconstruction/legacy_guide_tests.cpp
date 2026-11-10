#include "../../Beta/shared/LegacyNrGuideBridge.h"
#include "../../Beta/shared/CoreGuideRelay.h"
#include "../../Beta/shared/GuideHistory.h"
#include <cassert>
#include <array>
#include <iostream>
#include <vector>
#include <limits>
using namespace optishade::legacy;
int main(){
 SessionIntent intent;
 assert(!intent.Read().requested&&intent.Read().revision==0);
 assert(intent.Set(true,0));assert(intent.Read().requested&&intent.Read().revision==1);
 assert(!intent.Set(false,0));assert(intent.Read().requested);
 assert(intent.Set(false,1));assert(!intent.Read().requested&&intent.Read().revision==2);
 assert(!intent.Set(true,1)); // An old Auto command cannot undo explicit Off.
 GuideFrame f;f.runtime=1;f.commandList=2;f.colorView=3;f.depthView=4;f.motionView=5;
 f.preparedColorView=7;
 f.generation=6;f.width=1920;f.height=1080;f.ready=1;f.provenance=GuideProvenance::CoreEstimated;
 assert(ValidGuides(f,1,2));
 for(unsigned kind=0;kind<11;++kind){auto bad=f;
  if(kind==0)bad.version++;
  if(kind==1)bad.size--;
  if(kind==2)bad.runtime++;
  if(kind==3)bad.commandList++;
  if(kind==4)bad.ready=0;
  if(kind==5)bad.depthView=0;
  if(kind==6)bad.normalizedMotion=0;
  if(kind==7)bad.conventionalDepth=0;
  if(kind==8)bad.width=6000;
  if(kind==9)bad.provenance=GuideProvenance::Unknown;
  if(kind==10)bad.preparedColorView=0;
  assert(!ValidGuides(bad,1,2));
 }
 Snapshot s;std::array<unsigned char,sizeof(Snapshot)+16> bytes;bytes.fill(0xA5);
 assert(!CopySnapshot(s,bytes.data(),sizeof(Snapshot)-1));
 for(auto b:bytes)assert(b==0xA5);
 assert(CopySnapshot(s,bytes.data(),sizeof(Snapshot)));
 for(size_t i=sizeof(Snapshot);i<bytes.size();++i)assert(bytes[i]==0xA5);
 assert(!s.inferenceVerified&&!s.outputVerified); // transport cannot manufacture evidence
 CoreSourceFrame raw;raw.runtime=1;raw.commandList=2;raw.colorView=3;raw.sourceDepthView=4;
 raw.width=1920;raw.height=1080;raw.depthWidth=960;raw.depthHeight=540;raw.sdr=1;
 assert(ValidCoreSource(raw,1,2));
 for(unsigned kind=0;kind<14;++kind){auto bad=raw;
  if(kind==0)bad.version--;
  if(kind==1)bad.size--;
  if(kind==2)bad.runtime++;
  if(kind==3)bad.commandList++;
  if(kind==4)bad.colorView=0;
  if(kind==5)bad.sourceDepthView=0;
  if(kind==6)bad.depthWidth=800;
  if(kind==7)bad.sdr=0;
  if(kind==8)bad.reversed=2;
  if(kind==9)bad.logarithmic=2;
  if(kind==10)bad.multiplier=0;
  if(kind==11)bad.multiplier=std::numeric_limits<float>::quiet_NaN();
  if(kind==12)bad.upsideDown=2;
  if(kind==13)bad.reserved=1;
  assert(!ValidCoreSource(bad,1,2));
 }
 struct Operations {
  unsigned failure=0;std::vector<unsigned> order;
  bool Step(unsigned step){order.push_back(step);return step!=failure;}
  bool GameInputsComplete(){return Step(1);}bool Prepare(){return Step(2);}
  bool Estimate(){return Step(3);}bool Resolve(){return Step(4);}bool AdvanceHistory(){return Step(5);}
 } operations;
 using namespace optishade::guides;
 assert(RunRelayKernels(operations,false)==RelayResult::Warming);
 assert(operations.order==std::vector<unsigned>({1,2,3,4,5}));
 operations.order.clear();assert(RunRelayKernels(operations,true)==RelayResult::Ready);
 assert(operations.order==std::vector<unsigned>({1,2,3,4,5}));
 for(unsigned failure=1;failure<=5;++failure){
  operations.order.clear();operations.failure=failure;
  assert(RunRelayKernels(operations,true)==RelayResult::Failed);
  assert(operations.order.size()==failure); // No stale transfer, later kernel or history advance after a failed stage.
 }
 History history;assert(history.Observe(false,false,1,1,100));
 assert(!history.Observe(false,false,1,1,110));
 assert(history.Observe(true,false,1,1,120));
 assert(history.Observe(true,true,1,1,130));
 assert(history.Observe(true,true,2,1,140));
 assert(history.Observe(true,true,2,2,150)); // New session intent cannot reuse preceding history.
 assert(history.Observe(true,true,2,2,1000));
 std::cout<<"Legacy guide/session ABI v3: initial Off, CAS conflict, borrowed/raw-view context, depth interpretation, bounded snapshot and actual relay sequencing failure/warm-up/history checks passed; no GPU execution.\n";
}
