#pragma once
#include <cstdint>
namespace optishade::vknr {
struct BridgeAttemptKey {
 uint64_t device=0,queue=0,owner=0,generation=0,runtime=0;
 uint32_t width=0,height=0;
 bool operator==(const BridgeAttemptKey&)const=default;
};
// Retry transient allocation/import failures without recreating devices every
// rendered frame. A new owner/extent gets an immediate attempt; no CPU sleep.
struct BridgeRetry {
 BridgeAttemptKey key{};uint64_t last=0;bool attempted=false;
 bool Begin(const BridgeAttemptKey& current,uint64_t now){
  if(attempted&&key==current&&now>=last&&now-last<1000)return false;
  key=current;last=now;attempted=true;return true;
 }
 void Reset(){attempted=false;last=0;key={};}
};
}
