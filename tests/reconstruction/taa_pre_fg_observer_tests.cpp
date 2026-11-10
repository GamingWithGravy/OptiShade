#include "TaaPreFgObserver.h"
#include "TaaFgAdmission.h"
#include <stdexcept>
#include <iostream>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
int main(){
try{
 using namespace optishade::taa;
 CHECK(MsfsExecutable(L"FlightSimulator2024.exe")&&MsfsExecutable(L"flightsimulator.exe"));
 CHECK(!MsfsExecutable(L"FlightSimulator2024.exe.bak")&&!MsfsExecutable(L"X-Plane.exe"));
 // Beta builds keep their observer whatever the setting.
 CHECK(PreFgObserver(true,false,false,false,false));
 // Final builds: setting on, MSFS, DLSS-G options native, route-authorised observer.
 CHECK(PreFgObserver(false,true,true,true,true));
 CHECK(!PreFgObserver(false,false,true,true,true));
 CHECK(!PreFgObserver(false,true,false,true,true));
 CHECK(!PreFgObserver(false,true,true,false,true));
 CHECK(!PreFgObserver(false,true,true,true,false));
 // The status signature is accepted by the same admission as a SetOptions one.
 CHECK(StatusSignature(true,3)==((uint64_t(sl::DLSSGMode::eOn)<<32)|2));
 CHECK(NativeCompositionAllowed(StatusSignature(true,2)));
 CHECK(!NativeCompositionAllowed(StatusSignature(false,3)));
 CHECK(!NativeCompositionAllowed(StatusSignature(true,1)));
 CHECK(!NativeCompositionAllowed(StatusSignature(true,0)));
 std::cout<<"TAA pre-FG observer: hook policy and status signature tests passed\n";
}catch(const std::exception&e){std::cerr<<e.what();return 1;}}
