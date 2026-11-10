#include "OverlaySubmissionLock.h"
#include <cassert>
#include <thread>
#include <future>
int main(){
 std::recursive_mutex owner;
 // A concurrent recreation owns the mutex: callback must return without
 // touching resources or waiting (the caller may own the effects queue).
 owner.lock();
 auto skipped=std::async(std::launch::async,[&]{bool entered=false;
   bool ok=optishade::overlay::TrySubmitWithOwner(owner,[&]{entered=true;return false;});
   return ok&&!entered;});
 assert(skipped.wait_for(std::chrono::seconds(2))==std::future_status::ready);
 assert(skipped.get());owner.unlock();
 bool entered=false;
 assert(!optishade::overlay::TrySubmitWithOwner(owner,[&]{
   entered=true;
   auto competing=std::async(std::launch::async,[&]{if(owner.try_lock()){owner.unlock();return true;}return false;});
   assert(!competing.get());return false;
 }));
 assert(entered);
 assert(owner.try_lock());owner.unlock();
 // Same-thread fallback can recurse into the existing owner lock.
 owner.lock();assert(optishade::overlay::TrySubmitWithOwner(owner,[]{return true;}));owner.unlock();
}
