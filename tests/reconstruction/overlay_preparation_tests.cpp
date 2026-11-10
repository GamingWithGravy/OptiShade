#include "OverlayPreparation.h"
#include <cassert>
#include <stdexcept>
struct Mutex {
    bool held=false;
    void lock(){ assert(!held); held=true; }
    bool try_lock(){ if(held)return false; held=true;return true; }
    void unlock(){assert(held);held=false;}
};
int main(){
    int drawCalls=0;
    assert(!optishade::overlay::DrawIfPrepared(true,false,[&]() noexcept {++drawCalls;return true;}));
    assert(drawCalls==0);
    assert(optishade::overlay::DrawIfPrepared(true,true,[&]() noexcept {++drawCalls;return true;}));
    assert(drawCalls==1);
    assert(optishade::overlay::DrawIfPrepared(false,false,[&]() noexcept {++drawCalls;return true;}));
    assert(drawCalls==2);
    Mutex present,graphics;
    for(bool secondary:{false,true}){
        present.lock();if(secondary)graphics.lock();
        bool prepared=false;
        const bool callbackSucceeded=optishade::overlay::PrepareOutsideQueueLocks(present,secondary?&graphics:nullptr,[&]() noexcept -> bool {
            // Model a font upload re-entering the same layer during preparation.
            present.lock();if(secondary)graphics.lock();
            prepared=true;
            if(secondary)graphics.unlock();present.unlock();
            return true;
        });
        assert(callbackSucceeded&&prepared&&present.held&&(!secondary||graphics.held));
        const bool declined=optishade::overlay::PrepareOutsideQueueLocks(
            present,secondary?&graphics:nullptr,[]() noexcept -> bool{return false;});
        assert(!declined&&present.held&&(!secondary||graphics.held));
        const bool threwCallbackSucceeded=optishade::overlay::PrepareOutsideQueueLocks(
            present,secondary?&graphics:nullptr,[]{throw std::runtime_error("upload");});
        assert(!threwCallbackSucceeded);
        assert(present.held&&(!secondary||graphics.held));
        if(secondary)graphics.unlock();present.unlock();
    }
}
