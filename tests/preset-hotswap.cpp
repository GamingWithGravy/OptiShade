#include "../shared/PresetHotSwapPolicy.h"
#include "../shared/PresetPathIdentity.h"
#include <fstream>
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
 auto base=std::filesystem::temp_directory_path()/L"OptiShade-hotswap-identity-test";
 std::filesystem::create_directories(base);
 auto main=base/L"Main.ini", alternate=base/L"Alternate.ini", alias=base/L"Alias.ini";
 std::ofstream(main)<<"Techniques=\n";std::ofstream(alternate)<<"Techniques=\n";
 std::error_code ec;std::filesystem::remove(alias,ec);
 std::filesystem::create_hard_link(alternate,alias);
 assert(same_preset(alias,alternate,base));
 assert(same_preset(L"./Alternate.ini",alternate,base));
 assert(!same_preset(main,alternate,base));
 auto current=main;
 for(int i=0;i<10;++i){current=next_preset(current,main,alternate,base);assert(current==(i%2==0?alternate:main));}
 assert(next_preset(alias,main,alternate,base)==main);
 assert(next_preset(L"./Alternate.ini",main,alternate,base)==main);
 std::filesystem::remove(alias);std::filesystem::remove(main);std::filesystem::remove(alternate);std::filesystem::remove(base);
 std::cout<<"PASS: ten alternating swaps and relative/aliased preset identity\n";
 std::cout<<"PASS: release gating, focus/capture suppression, loading and unsaved-edit protection\n";
}
