// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include "MfgControl.h"
#include "BackgroundStatus.h"
namespace optishade::mfg {
// UI intent only. None of these methods changes a provider or configuration.
struct Draft {
    Settings value{},baseline{},submittedBase{},undoBefore{},undoApplied{};
    bool hasUndo=false;
    template<class Visit> static void Fields(Visit visit){
        visit(&Settings::followGame);visit(&Settings::dynamic);visit(&Settings::overrideOff);
        visit(&Settings::multiplier);visit(&Settings::targetFps);visit(&Settings::preset);
        visit(&Settings::vsyncMode);visit(&Settings::reflexLimit);
    }
    bool CanUndo(const Snapshot& state)const{
        if(!hasUndo||awaiting||conflict||!state.verified||identity!=state.identity)return false;
        bool safe=true;
        Fields([&](auto member){if(undoBefore.*member!=undoApplied.*member &&
            (state.settings.*member!=undoApplied.*member||value.*member!=undoApplied.*member))safe=false;});
        return safe;
    }
    bool StageUndo(const Snapshot& state){
        if(!CanUndo(state))return false;
        Fields([&](auto member){if(undoBefore.*member!=undoApplied.*member)value.*member=undoBefore.*member;});
        dirty=!SameRequest(value,state.settings);review=dirty;return dirty;
    }
    bool initialized=false,dirty=false,review=false,conflict=false;
    uint64_t awaiting=0;
    std::string identity,feedback;
    void Observe(const Snapshot& state) {
        if(!state.verified)return; // A temporary disconnect must not erase edits.
        if(!initialized){value=baseline=state.settings;identity=state.identity;initialized=true;return;}
        if(identity!=state.identity){conflict=true;review=false;return;}
        if(!dirty&&!awaiting)value=baseline=state.settings;
        else if(!awaiting&&!SameRequest(baseline,state.settings)){conflict=true;review=false;}
        if(!awaiting)dirty=!SameRequest(value,state.settings);
    }
    void Discard(const Snapshot& state){if(awaiting)return;value=baseline=state.settings;identity=state.identity;initialized=true;dirty=review=conflict=false;feedback.clear();}
    void Submitted(uint64_t id){submittedBase=baseline;awaiting=id;review=false;feedback="Save queued; current output is unchanged until the backend applies it.";}
    void Complete(uint64_t id,SaveProgress result,const std::string& text,const Snapshot& state){
        if(!awaiting||id!=awaiting||result==SaveProgress::None)return;
        awaiting=0;feedback=text;
        // A failed save keeps the draft. A successful file save is not GPU evidence.
        dirty=result!=SaveProgress::Saved||!SameRequest(value,state.settings);
        if(result==SaveProgress::Saved){
            if(SameRequest(value,state.settings)){undoBefore=submittedBase;undoApplied=state.settings;hasUndo=!SameRequest(undoBefore,undoApplied);}
            else hasUndo=false;
            baseline=state.settings;
        }
    }
};
inline bool CurrentAcknowledgement(const Snapshot& state){return HasCurrentAcknowledgement(state);}
inline bool RecentTiming(const Snapshot& state){const auto& s=state.status;return state.live&&s.fpsAgeMs<=2000&&s.actualFramesPresented>1&&s.realFpsMilli>0&&s.outputFpsMilli>0;}
}
