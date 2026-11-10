#pragma once

namespace optishade::native_mfg_ui {
// Preserve the last accepted ON state while provider telemetry is stale. The
// UI separately disables edits until a fresh capability sample arrives.
inline bool ToggleEnabled(bool providerAvailable, bool initialized, int desired,
                          unsigned int acceptedGenerated=0, bool dynamic=false,
                          bool pendingProvider=false) {
    if(!initialized)return pendingProvider?desired>0:(providerAvailable&&acceptedGenerated>0);
    return dynamic || desired>0 || (desired<0 && acceptedGenerated>0);
}
// A first 2x request is only local intent until the native provider is bound
// to the game's active output. Let testers stage that intent even when an
// alternate or compatibility route currently owns frame generation; the
// Save & Go admission check remains responsible for preventing a live request
// from reaching the wrong provider or output.
inline bool CanStageInitialRequest(bool providerAvailable,bool initialized,
                                   bool conflict,bool awaiting) {
    return !providerAvailable&&!initialized&&!conflict&&!awaiting;
}
// A stale provider must not receive requests, but the user can stage OFF for
// the same previously active session. The ordinary fresh-control save gate
// submits it only if that provider/output returns with the same generation.
template<class Draft,class Snapshot>
inline bool StageOffWhileWaiting(Draft& draft,const Snapshot& state) {
    if(!draft.initialized||draft.conflict||draft.awaiting||!state.provider||!state.known||
       state.generation!=draft.generation||state.revision!=draft.revision||
       !(draft.dynamic||draft.desired>0||state.acceptedGenerated>0))return false;
    draft.desired=0;draft.dynamic=false;draft.dirty=true;
    draft.feedback="OFF staged. Save when fresh provider control returns.";
    return true;
}
}
