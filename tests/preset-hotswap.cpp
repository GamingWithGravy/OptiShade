#include "../shared/PresetHotSwapPolicy.h"
#include <cassert>
#include <iostream>
int main(){
 using namespace optishade::hotswap;
 PressGate g;
 assert(!g.update(false,true,true)); // release inherited from another context
 assert(!g.update(true,false,true));
 assert(g.update(false,true,true));
 assert(!g.update(false,true,true)); // repeated release cannot toggle twice
 g.update(true,false,true);g.update(false,false,false);
 assert(!g.update(false,true,true)); // focus loss cancels armed input
 g.update(true,false,false);assert(!g.update(false,true,true)); // key capture
 assert(!may_switch(true,true,false));assert(!may_switch(true,false,true));
 assert(!may_switch(false,false,false));assert(may_switch(true,false,false));
 std::cout<<"PASS: release gating, focus/capture suppression, loading and unsaved-edit protection\n";
}
