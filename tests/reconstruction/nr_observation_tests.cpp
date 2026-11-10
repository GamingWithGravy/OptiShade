#include "NrObservation.h"
#include <iostream>
#include <stdexcept>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
int main(){try{
 using namespace optishade::nr_observation;
 CHECK(std::string(Provenance(Route::EstimatedTAA).motion)=="ImageEstimated");
 CHECK(std::string(Provenance(Route::PreFgTAA).motion)=="InterceptedTemporalIntegration");
 CHECK(std::string(Provenance(Route::Unknown).depth)=="Unavailable");
 Tracker tracker;tracker.Request(true,true,1);
 CHECK(!tracker.Read(100).recent); // User intent alone proves nothing.
 Owner owner{1,2,3,4,0,1920,1080,Route::EstimatedTAA};
 auto ticket=tracker.Begin(owner,10,100);CHECK(ticket);
 tracker.Evaluated(ticket,true);CHECK(!tracker.Read(101).recent);
 tracker.Submitted(ticket,2,101,true);CHECK(!tracker.Read(102).recent);
 tracker.Completed(ticket,2,1000,2.5);auto result=tracker.Read(103);
 CHECK(result.recent&&result.composed&&result.completedFrame==10&&result.request==result.effective);
 CHECK(!tracker.Read(1600).recent); // Stale success cannot certify current output.
 tracker.Request(true,true,2);CHECK(!tracker.Read(104).recent);
 tracker.Completed(ticket,2,1000,2.5);CHECK(!tracker.Read(104).recent); // Old revision cannot revive success.
 auto next=tracker.Begin(owner,11,110);tracker.Evaluated(next,false);tracker.Completed(next,2,0,std::nullopt);
 CHECK(tracker.Read(111).recent&&!tracker.Read(111).composed); // Execution is separate from composition.
 tracker.Request(false,true,2);CHECK(!tracker.Read(112).recent);
 std::cout<<"NR provenance and intent/evaluation/submission/completion/composition/freshness/revision separation passed (CPU observations, no model execution)\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
