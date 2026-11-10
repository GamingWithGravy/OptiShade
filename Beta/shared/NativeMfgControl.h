#pragma once
#include <algorithm>
#include <cstdint>
#include <mutex>
#include <chrono>
#include <string>

namespace optishade::native_mfg {
enum class GraphicsApi : uint8_t { Unknown, Direct3D11, Direct3D12, Vulkan };
enum class AvailabilityReason : uint8_t {
    Ready,
    TwoXOnly,
    CompatibilityProviderOwns,
    ObservationOnly,
    NoNativeProviderOnDirect3D11,
    NoNativeProviderOnDirect3D12,
    NoNativeProviderOnVulkan,
    GraphicsApiUnknown
};

// Explain why native controls are unavailable without changing capability
// admission. The live provider's multiplier report remains authoritative.
inline AvailabilityReason ClassifyAvailability(bool providerFresh, bool compatibilityProviderOwns,
                                                GraphicsApi api, uint32_t maximum, bool controllable=true) {
    if (compatibilityProviderOwns) return AvailabilityReason::CompatibilityProviderOwns;
    if (providerFresh && !controllable) return AvailabilityReason::ObservationOnly;
    if (providerFresh && maximum == 1) return AvailabilityReason::TwoXOnly;
    if (providerFresh && maximum >= 2 && maximum <= 6) return AvailabilityReason::Ready;
    switch (api) {
    case GraphicsApi::Direct3D11: return AvailabilityReason::NoNativeProviderOnDirect3D11;
    case GraphicsApi::Direct3D12: return AvailabilityReason::NoNativeProviderOnDirect3D12;
    case GraphicsApi::Vulkan: return AvailabilityReason::NoNativeProviderOnVulkan;
    default: return AvailabilityReason::GraphicsApiUnknown;
    }
}

// Streamline currently supports Dynamic MFG on D3D12 only. Keep the provider's
// reported bit separate from the API gate so Auto and the menu share the same
// effective capability and cannot queue a mode the options hook will refuse.
inline bool DynamicSupported(GraphicsApi api, bool known, bool providerSupported) {
    return known && providerSupported && api == GraphicsApi::Direct3D12;
}

// The UI switch is a live-provider control, not an install/configuration flag.
// In particular, desired == -1 means "follow the game"; it must not look ON
// before a current provider has reported that such a request can be applied.
inline bool ToggleEnabled(bool providerAvailable, bool initialized, int desired, uint32_t acceptedGenerated=0, bool dynamic=false) {
    return providerAvailable && initialized && (dynamic || desired > 0 || (desired < 0 && acceptedGenerated > 0));
}

// Native-provider request state. No provider calls or synthetic presentation
// counters belong here. Requests are consumed by the existing game callback.
struct Snapshot {
    uint64_t provider=0, generation=0, revision=0, acceptedRevision=0, sampledAt=0;
    uint32_t view=0, maximum=0, acceptedGenerated=0;
    int withdrawn=-1; // Last override cancelled by a capability change, for truthful UI/diagnostics.
    uint64_t supersededRevision=0; // Last request discarded when its provider/view owner changed.
    int supersededDesired=-1;
    bool supersededPending=false;
    int desired=-1, result=0; // -1 follows game; 0 disables interpolation.
    bool known=false, pending=false, attempted=false;
    // Capability observation is not permission to queue a game-options edit.
    bool controllable=false, dynamicKnown=false, dynamicSupported=false, dynamic=false;
};
class Control {
    mutable std::mutex mutex_;
    Snapshot state_;
public:
    static uint64_t Now(){return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();}
    static bool FreshAt(const Snapshot& s,uint64_t now){return s.known&&s.sampledAt&&now>=s.sampledAt&&now-s.sampledAt<=3000;}
    static bool Fresh(const Snapshot& s){return FreshAt(s,Now());}
    static bool CanConfigure(const Snapshot& s){return Fresh(s)&&s.controllable;}
    static bool CanRequest(const Snapshot& s,int generated,bool dynamic=false){
        return CanConfigure(s)&&generated>=-1&&generated<=int(s.maximum)&&
            (!dynamic||(generated==-1&&s.dynamicKnown&&s.dynamicSupported));
    }
    static bool BoundToCall(const Snapshot& s,uint64_t provider,uint32_t view,uint64_t now){
        return s.controllable&&s.provider==provider&&s.view==view&&s.known&&(FreshAt(s,now)||s.pending);
    }
    Snapshot Read() const {std::lock_guard lock(mutex_);return state_;}
    void Observe(uint64_t provider,uint32_t view,uint32_t maximum,bool controllable=true,
                 bool dynamicKnown=false,bool dynamicSupported=false) {
        std::lock_guard lock(mutex_);
        if(!provider)return;
        if(state_.provider!=provider || state_.view!=view || state_.controllable!=controllable) {
            const auto previous=state_;
            const auto generation=previous.generation+1;
            state_={};state_.generation=generation;
            if(previous.provider){
                state_.supersededRevision=previous.revision;
                state_.supersededDesired=previous.desired;
                state_.supersededPending=previous.pending;
            }
        }
        state_.provider=provider;state_.view=view;state_.known=maximum>=1&&maximum<=6;state_.sampledAt=Now();
        state_.controllable=controllable;state_.dynamicKnown=dynamicKnown;state_.dynamicSupported=dynamicKnown&&dynamicSupported;
        if(!state_.known){
            state_.maximum=0;
            if(state_.desired>=0||state_.dynamic){state_.withdrawn=state_.desired;state_.desired=-1;state_.dynamic=false;++state_.revision;}
            state_.pending=false;return;
        }
        state_.maximum=maximum;
        // Capability loss cancels an unsafe override; it never silently turns
        // a user's requested 4x into a displayed 'accepted 4x' running at 2x.
        if(state_.desired>int(maximum)||(state_.dynamic&&!state_.dynamicSupported)) {
            state_.withdrawn=state_.desired;state_.desired=-1;state_.dynamic=false;++state_.revision;state_.pending=true;
        }
    }
    bool Request(const Snapshot& baseline,int generated,bool dynamic=false) {
        std::lock_guard lock(mutex_);
        if(!CanRequest(state_,generated,dynamic) || baseline.generation!=state_.generation ||
           baseline.revision!=state_.revision)return false;
        state_.withdrawn=-1;state_.desired=generated;state_.dynamic=dynamic;
        state_.pending=true;state_.attempted=false;++state_.revision;return true;
    }
    // Called only for the same native plugin and viewport that supplied caps.
    Snapshot ForCall(uint64_t provider,uint32_t view) const {
        auto value=Read();
        // A request admitted against a fresh range remains bound to that same
        // provider/view until it is accepted or rejected. Do not silently drop
        // it merely because GetState is sampled less often than SetOptions.
        // The provider remains the final authority and can reject a stale range.
        if(!BoundToCall(value,provider,view,Now())){
            value.desired=-1;value.dynamic=false;value.provider=0;
        }
        return value;
    }
    void Complete(const Snapshot& request,uint32_t generated,int result,bool dynamicApplied=false) {
        std::lock_guard lock(mutex_);
        if(!state_.controllable || request.generation!=state_.generation || request.revision!=state_.revision ||
           request.provider!=state_.provider || request.view!=state_.view)return;
        state_.attempted=true;state_.result=result;
        if(result==0){state_.acceptedGenerated=generated;
            if(request.dynamic?dynamicApplied:(request.desired<0||generated==uint32_t(request.desired))){state_.acceptedRevision=request.revision;state_.pending=false;}}
    }
};
// The menu edits an intent locally and submits it only when the shared footer
// Save action is pressed. Provider identity and revision bind that draft to the
// live session it was based on.
struct UiDraft {
    int desired=-1, preferredGenerated=1;
    uint64_t generation=0, revision=0, awaitingRevision=0;
    bool initialized=false, dirty=false, conflict=false, awaiting=false, dynamic=false;
    // An explicit in-game request may be staged before the game exposes its
    // native provider, or while it is not bound to the active output. It is
    // not submitted until Save & Go verifies live control.
    bool pendingProvider=false;
    std::string feedback;

    void Observe(const Snapshot& state,bool bindingReady=true) {
        if(!Control::Fresh(state))return;
        if(!initialized){
            if(!pendingProvider){Discard(state);return;}
            // A provider can be visible before the renderer has bound it to
            // the selected primary output. Keep the first-run intent queued
            // until the runtime proves this exact provider/view is current.
            if(!bindingReady)return;
            if(desired>int(state.maximum)){
                pendingProvider=false;initialized=true;generation=state.generation;revision=state.revision;
                conflict=true;dirty=false;feedback="The game provider appeared, but its reported MFG range does not include the staged multiplier. Discard the draft and choose a supported multiplier.";
                return;
            }
            initialized=true;generation=state.generation;revision=state.revision;pendingProvider=false;
            feedback="Live provider detected. Review the staged MFG request, then use Save & Go to ask the game to apply it.";
            return;
        }
        // A clean, idle menu follows live provider refreshes. Never rebase an
        // edited draft, an outstanding acknowledgement, or a retained conflict.
        if(!dirty&&!awaiting&&!conflict&&(generation!=state.generation||revision!=state.revision)){
            Discard(state);return;
        }
        if(generation!=state.generation){
            // The old provider can no longer acknowledge this request. End its
            // wait so the user can discard/rebase against the new owner.
            awaiting=false;
            conflict=true;
            feedback=state.supersededPending
                ? "The active provider changed. The pending request was superseded; discard this draft to load the new provider."
                : "The active provider changed. Discard this draft to load the new provider.";
            return;
        }
        if(awaiting){
            if(state.revision!=awaitingRevision){conflict=true;awaiting=false;feedback="The provider range changed while the request was being applied.";return;}
            if(state.attempted&&(!state.pending||state.result!=0)){
                awaiting=false;desired=state.desired;dynamic=state.dynamic;revision=state.revision;dirty=false;
                feedback=state.result==0?"Settings accepted by the live provider.":"The live provider rejected this request. Choose an available multiplier and save again.";
            }
            return;
        }
        if(state.revision!=revision){conflict=true;feedback="The live provider state changed. Discard this draft to load current settings.";return;}
        if(!dirty){desired=state.desired;dynamic=state.dynamic;if(desired>0)preferredGenerated=desired;}
    }
    bool Stage(const Snapshot& state,int requested,bool requestDynamic=false) {
        Observe(state);
        if(!Control::CanRequest(state,requested,requestDynamic)||!initialized||conflict||awaiting||state.generation!=generation||state.revision!=revision)return false;
        desired=requested;dynamic=requestDynamic;if(requested>0)preferredGenerated=requested;
        // The first explicit Follow game action also relinquishes any saved
        // legacy startup override, even though no session request existed yet.
        dirty=!state.revision||desired!=state.desired||dynamic!=state.dynamic||(state.attempted&&state.result!=0);feedback.clear();return true;
    }
    bool StagePending(const Snapshot& state,int requested) {
        // Do not call Observe here: the menu may have a fresh capability
        // sample whose provider is not yet bound to the game's primary output.
        // Observe(state) with its default binding would incorrectly mark that
        // session ready and discard the first request. Staging is local only;
        // Submit still requires fresh, writable, output-bound provider state.
        (void)state;
        if(initialized||conflict||awaiting||requested<0||requested>5)return false;
        desired=requested;dynamic=false;dirty=true;pendingProvider=true;
        feedback="MFG request staged. Waiting for the running game to bind a writable frame-generation provider to its active output; nothing is sent until then.";
        return true;
    }
    bool Submit(Control& control,const Snapshot& state) {
        Observe(state);
        if(!dirty||conflict||awaiting||!Control::CanRequest(state,desired,dynamic)||state.generation!=generation||state.revision!=revision||!control.Request(state,desired,dynamic)){
            feedback="Save unavailable: the live provider changed or is no longer ready. Your draft is retained.";return false;
        }
        const auto submitted=control.Read();awaitingRevision=submitted.revision;revision=submitted.revision;awaiting=true;dirty=false;
        feedback="Saved. Waiting for the game to submit its next Frame Generation options so the live provider can apply the change.";return true;
    }
    void Discard(const Snapshot& state) {
        if(awaiting)return;
        desired=state.desired;dynamic=state.dynamic;generation=state.generation;revision=state.revision;initialized=Control::Fresh(state);dirty=false;conflict=false;awaiting=false;pendingProvider=false;feedback.clear();
        if(desired>0)preferredGenerated=desired;
    }
};
inline Control& Session(){static Control control;return control;}
}
