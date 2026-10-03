// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include <cstdint>
namespace optishade::nr {
// Accessed under the NR runtime mutex. A retry must not reuse a recent admission
// result from before the pressure stop or before the override was disabled.
struct BudgetCheck {
 uint64_t last=0; bool required=true;
 void invalidate(){required=true;}
 bool due(uint64_t now,bool allocating){
  if(!required&&!allocating&&last&&now-last<1000)return false;
  last=now;required=false;return true;
 }
};
}
