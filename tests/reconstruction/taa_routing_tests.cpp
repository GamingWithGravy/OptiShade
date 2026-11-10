#include "TaaRoutePolicy.h"
#include "TaaFgAdmission.h"
#include "NativeFgTagReplacement.h"
#include <stdexcept>
#include <iostream>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
int main(){
 {int contract[]={2,53,0,1};auto tags=optishade::taa::ReplacementInputTags(contract);CHECK(tags.size()==3 && tags[0]==2 && tags[1]==0 && tags[2]==1);}
try{
 const auto nativeOn=(uint64_t(sl::DLSSGMode::eOn)<<32)|1u;
 const auto nativeAuto=(uint64_t(sl::DLSSGMode::eAuto)<<32);
 const auto nativeOff=uint64_t(sl::DLSSGMode::eOff)<<32;
 CHECK(optishade::taa::NativeCompositionAllowed(nativeOn));
 CHECK(optishade::taa::NativeCompositionAllowed(nativeAuto));
 CHECK(!optishade::taa::NativeCompositionAllowed(nativeOff));
 CHECK(!optishade::taa::BlocksLateComposition(false,nativeOn,false));
 CHECK(optishade::taa::BlocksLateComposition(false,nativeOn,true));
 CHECK(!optishade::taa::BlocksLateComposition(false,nativeOff,true));
 CHECK(optishade::taa::BlocksLateComposition(true,nativeOff,false));
 optishade::taa::NativeInputs inputs;
 CHECK(!inputs.recent(1,1920,1080,100));
 inputs.observe(1,1920,1080,100);
 CHECK(inputs.recent(1,1920,1080,100));
 CHECK(!inputs.recent(2,1920,1080,101));
 CHECK(!inputs.recent(1,2560,1440,101));
 CHECK(!inputs.recent(1,1920,1080,99));
 CHECK(inputs.recent(1,1920,1080,2099));
 CHECK(!inputs.recent(1,1920,1080,2100));
 inputs.observe(1,1920,1080,2200);
 CHECK(inputs.recent(1,1920,1080,2201));
 inputs.observe(0,1920,1080,2300);inputs.observe(1,0,1080,2300);
 CHECK(!inputs.recent(0,1920,1080,2301)&&!inputs.recent(1,0,1080,2301));
 for(unsigned i=2;i<=10;++i)inputs.observe(i,1920,1080,2300+i);
 CHECK(inputs.recent(10,1920,1080,2310));CHECK(!inputs.recent(1,1920,1080,2310));
 std::cout<<"Native/TAA routing: device, extent, freshness, renewal and bounded evidence tests passed\n";
}catch(const std::exception&e){std::cerr<<e.what();return 1;}}
