#include "VulkanBridgeRetry.h"
#include <cassert>
#include <iostream>
using namespace optishade::vknr;
int main(){
 BridgeAttemptKey a{1,2,3,4,5,1920,1080};BridgeRetry gate;
 assert(gate.Begin(a,0));assert(!gate.Begin(a,1));assert(!gate.Begin(a,999));assert(gate.Begin(a,1000));
 for(unsigned i=0;i<7;++i){BridgeRetry g;assert(g.Begin(a,100));auto b=a;
  switch(i){case 0:b.device++;break;case 1:b.queue++;break;case 2:b.owner++;break;case 3:b.generation++;break;case 4:b.runtime++;break;case 5:b.width++;break;case 6:b.height++;break;}
  assert(g.Begin(b,101));assert(!g.Begin(b,102));
 }
 assert(gate.Begin(a,900));gate.Reset();assert(gate.Begin(a,901));
 std::cout<<"PASS: retry deadline, all owner/extent changes, clock rollback and explicit reset\n";
}
