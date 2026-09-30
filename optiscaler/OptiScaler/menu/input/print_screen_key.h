#pragma once
#include <cstdint>

namespace OptiInput {
// Windows may deliver Print Screen as a key-up without a key-down. Remember
// actual down evidence across frames and correlate raw/WM releases by their
// message times; no input source owns the key for the whole focus session.
struct PrintScreenKey {
    bool DownObserved=false, InternalReleased=false, HaveWindowRelease=false;
    uint32_t InternalReleaseTime=0, WindowReleaseTime=0, DownTime=0;
    bool ObserveDown(uint32_t time){
        // A duplicate raw/queued down delivered after its WM release is old.
        if(HaveWindowRelease&&static_cast<int32_t>(time-WindowReleaseTime)<=0)return false;
        if(InternalReleased&&static_cast<int32_t>(time-InternalReleaseTime)<=0)return false;
        DownObserved=true;InternalReleased=false;DownTime=time;return true;
    }
    bool OlderThanDown(uint32_t time) const {return DownObserved&&static_cast<int32_t>(time-DownTime)<0;}
    void ObserveInternalRelease(uint32_t time){
        if(DownObserved&&!InternalReleased){InternalReleased=true;InternalReleaseTime=time;}
    }
    bool MissingWindowDown(uint32_t time){
        if(HaveWindowRelease&&static_cast<int32_t>(time-WindowReleaseTime)<=0)return false;
        HaveWindowRelease=true;WindowReleaseTime=time;
        // A raw/poll release can precede the equivalent queued WM up.
        // A later distinct WM-only press must not inherit that old down edge.
        const bool represented=DownObserved&&(!InternalReleased||static_cast<int32_t>(time-InternalReleaseTime)<=0);
        DownObserved=false;InternalReleased=false;
        return !represented;
    }
};
}
