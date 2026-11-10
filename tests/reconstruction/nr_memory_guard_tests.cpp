#include "NrMemoryGuard.h"
#include <stdexcept>
#include <iostream>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
int main(){
try{
 namespace guard=optishade::nr::memory_guard;
 constexpr uint64_t mib=guard::kMiB;
 // RTX 4060 tester, 1080p model, two passes: 765 MiB to start from nothing.
 const auto start=guard::ModelReserve(1920,1080,2);
 CHECK(start/mib==765);
 CHECK(guard::ModelReserve(1920,1080,0)==guard::ModelReserve(1920,1080,1));
 // A rebuild of the same size needs nothing new; a larger one only the growth.
 CHECK(guard::RequiredFree(start,start)==0);
 CHECK(guard::RequiredFree(guard::ModelReserve(2560,1440,2),start)==guard::ModelReserve(2560,1440,2)-start);
 CHECK(guard::RequiredFree(start,guard::ModelReserve(2560,1440,2))==0);
 // Admission: 6565 MiB budget, 6069 MiB used is 496 MiB free.
 CHECK(!guard::Admits(6565*mib,6069*mib,start));
 CHECK(guard::Admits(6565*mib,6069*mib,0));
 CHECK(guard::Admits(0,9000*mib,start));
 CHECK(!guard::Admits(6000*mib,7000*mib,mib));
 // Recovery waits for the refused requirement, not a token headroom.
 guard::Recovery r;
 r.Refused(start);
 CHECK(r.Required()==start&&r.WaitMs()==3000);
 uint64_t t=1000;
 CHECK(r.Due(t));CHECK(!r.Observe(t,true,6565*mib,6069*mib)); // 496 MiB free: not enough
 t+=1000;CHECK(r.Due(t));CHECK(!r.Observe(t,true,6565*mib,5600*mib)); // 965 MiB free: healthy from now
 CHECK(!r.Due(t+500));
 t+=1000;CHECK(r.Due(t));CHECK(!r.Observe(t,true,6565*mib,5600*mib));
 t+=2000;CHECK(r.Due(t));CHECK(r.Observe(t,true,6565*mib,5600*mib)); // 3 s of headroom
 // A dip restarts the wait.
 r.Refused(start);t+=1000;CHECK(r.Due(t));CHECK(!r.Observe(t,true,6565*mib,5600*mib));
 t+=2000;CHECK(r.Due(t));CHECK(!r.Observe(t,true,6565*mib,6400*mib));
 t+=1000;CHECK(r.Due(t));CHECK(!r.Observe(t,true,6565*mib,5600*mib));
 t+=2000;CHECK(r.Due(t));CHECK(!r.Observe(t,true,6565*mib,5600*mib));
 // Each refusal waits longer: 3 s, 10 s, then 30 s.
 CHECK(r.WaitMs()==10000);
 r.Refused(start);CHECK(r.WaitMs()==30000);
 r.Refused(start);CHECK(r.WaitMs()==30000);
 r.Admitted();r.Refused(start);CHECK(r.WaitMs()==3000);
 // A manual restart forgets the history; invalid readings never count.
 r.Manual();CHECK(r.Required()==guard::kMinimumHeadroom);
 t+=5000;CHECK(r.Due(t));CHECK(!r.Observe(t,false,6565*mib,0));
 std::cout<<"NR memory guard: reserve, rebuild credit, admission and retry back-off tests passed\n";
}catch(const std::exception&e){std::cerr<<e.what();return 1;}}
