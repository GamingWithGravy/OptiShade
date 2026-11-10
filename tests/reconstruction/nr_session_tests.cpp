#include "NrDeferredEvents.h"
#include "NrSessionControl.h"
#include <atomic>
#include <condition_variable>
#include <iostream>
#include <mutex>
#include <thread>

static unsigned checks=0;
#define CHECK(x) do { ++checks; if(!(x)){std::cerr<<#x<<" @"<<__LINE__<<'\n';return 1;} } while(false)
static unsigned drained=0;
static void Consume(const unsigned& value){drained+=value;}
int main(){
 using namespace optishade::nr_session;
 optishade::nr::DeferredEvents<unsigned> events(Consume);
 State current;unsigned sets=0;bool persisted=false,memoryOverride=false;
 auto read=[&]{return current;};
 auto set=[&](bool value){++sets;current.requested=value;++current.revision;if(!value)current.explicitOffRevision=current.revision;};
 CHECK(!current.requested&&current.revision==0);
 auto result=TrySet(events,true,0,read,set);
 CHECK(result.code==Code::Accepted&&result.revision==1&&sets==1&&current.requested);
 CHECK(!persisted&&!memoryOverride);
 result=TrySet(events,false,0,read,set);
 CHECK(result.code==Code::Conflict&&result.revision==1&&sets==1&&current.requested);
 result=TrySet(events,true,1,read,set);
 CHECK(result.code==Code::Accepted&&result.revision==2&&sets==2&&current.explicitOffRevision==0);
 // An explicit Off changes the existing owner revision; a stale Auto On
 // cannot undo it. Suspension alone never edits this requested bit.
 result=TrySet(events,false,2,read,set);
 CHECK(result.code==Code::Accepted&&result.revision==3&&!current.requested&&current.explicitOffRevision==3);
 result=TrySet(events,true,2,read,set);
 CHECK(result.code==Code::Conflict&&sets==3&&!current.requested);
 result=TrySet(events,false,3,read,set);
 CHECK(result.code==Code::Accepted&&result.revision==4&&current.explicitOffRevision==4&&!current.requested);
 std::mutex waitMutex;std::condition_variable wake;bool held=false,release=false;
 std::thread owner([&]{auto guard=events.Lock();std::unique_lock lock(waitMutex);held=true;wake.notify_one();wake.wait(lock,[&]{return release;});});
 {std::unique_lock lock(waitMutex);wake.wait(lock,[&]{return held;});}
 result=TrySet(events,true,4,read,set);
 CHECK(result.code==Code::Busy&&sets==4&&!current.requested);
 events.Post(4);CHECK(drained==0);
 {std::lock_guard lock(waitMutex);release=true;}wake.notify_one();owner.join();
 CHECK(drained==4);
 result=TrySet(events,true,4,read,set);
 CHECK(result.code==Code::Accepted&&result.revision==5&&sets==5&&current.requested);
 CHECK(events.TryWithState([&]{auto recursive=events.Lock();events.Post(2);}));
 CHECK(drained==6&&!persisted&&!memoryOverride);
 std::cout<<checks<<" NR session control checks passed\n";
}
