#pragma once
#include <sl_dlss_g.h>
#include "NativeFgCapabilityCache.h"

namespace optishade::native_mfg {
struct StateQueryEvidence {
    uint32_t maximum=0;
    uint32_t callerVersion=0;
    uint32_t providerFramesPresented=0;
    bool stateKnown=false;
    bool dynamicKnown=false;
    bool dynamicSupported=false;
    bool promoted=false;
    sl::Result capabilityResult=sl::Result::eErrorFeatureMissing;
};

inline bool KnownState(const sl::DLSSGState& state) {
    return state.structType==sl::DLSSGState::s_structType &&
           state.structVersion>=1 && state.structVersion<=4;
}

// Copy fields, never the base header or the allocation's tail padding. The
// destination is the game's version-sized allocation, not a current SDK object.
inline void CopyStateOutputs(const sl::DLSSGState& source,sl::DLSSGState& destination) {
    destination.estimatedVRAMUsageInBytes=source.estimatedVRAMUsageInBytes;
    destination.status=source.status;
    destination.minWidthOrHeight=source.minWidthOrHeight;
    destination.numFramesActuallyPresented=source.numFramesActuallyPresented;
    if(destination.structVersion>=2){
        destination.numFramesToGenerateMax=source.numFramesToGenerateMax;
        destination.bReserved4=source.bReserved4;
        destination.bIsVsyncSupportAvailable=source.bIsVsyncSupportAvailable;
    }
    if(destination.structVersion>=3){
        destination.inputsProcessingCompletionFence=source.inputsProcessingCompletionFence;
        destination.lastPresentInputsProcessingCompletionFenceValue=source.lastPresentInputsProcessingCompletionFenceValue;
    }
    if(destination.structVersion>=4)destination.bIsDynamicMFGSupported=source.bIsDynamicMFGSupported;
}

inline void ReadStateEvidence(const sl::DLSSGState& state,StateQueryEvidence& evidence) {
    if(!KnownState(state))return;
    evidence.stateKnown=true;
    evidence.providerFramesPresented=state.numFramesActuallyPresented;
    if(state.structVersion>=2)evidence.maximum=state.numFramesToGenerateMax;
    if(state.structVersion>=4){
        evidence.dynamicKnown=true;
        evidence.dynamicSupported=state.bIsDynamicMFGSupported==sl::eTrue;
    }
}

// An off-Present-thread query must not enter Streamline. If the provider has
// already reported capabilities for this viewport, answer only the game's
// capability fields from that snapshot. Never replay frame counters or the
// Present-thread completion fence from an earlier query.
inline bool PopulateCachedCapabilityState(sl::DLSSGState& caller,
                                          const CapabilitySnapshot& snapshot,
                                          uint32_t viewport) {
    if(!KnownState(caller)||caller.structVersion<2||!snapshot.known||
       snapshot.viewport!=viewport||snapshot.maximum<1||snapshot.maximum>6)
        return false;
    caller.estimatedVRAMUsageInBytes=0;
    caller.status=sl::DLSSGStatus::eOk;
    caller.minWidthOrHeight=0;
    caller.numFramesActuallyPresented=0;
    caller.numFramesToGenerateMax=snapshot.maximum;
    caller.bReserved4=sl::eFalse;
    caller.bIsVsyncSupportAvailable=sl::eFalse;
    if(caller.structVersion>=3){
        caller.inputsProcessingCompletionFence=nullptr;
        caller.lastPresentInputsProcessingCompletionFenceValue=0;
    }
    if(caller.structVersion>=4)
        caller.bIsDynamicMFGSupported=snapshot.dynamicKnown&&snapshot.dynamicSupported?sl::eTrue:sl::eFalse;
    return true;
}

// Managed input emulation does not resolve, initialize or query a provider.
// Unknown layouts are refused instead of guessing their allocation size.
inline sl::Result DummyState(sl::DLSSGState& caller) {
    if(!KnownState(caller))return sl::Result::eErrorInvalidParameter;
    sl::DLSSGState output{};
    output.numFramesActuallyPresented=1;
    output.numFramesToGenerateMax=1;
    output.bIsVsyncSupportAvailable=sl::eTrue;
    output.estimatedVRAMUsageInBytes=uint64_t(300)*1024*1024;
    CopyStateOutputs(output,caller);
    return sl::Result::eOk;
}

inline bool ExposeProviderMfgMaximum(sl::DLSSGState& caller,uint32_t maximum) {
    if(!KnownState(caller)||caller.structVersion<2)return false;
    // The game's own multiplier menu reads this provider capability. Never
    // clamp it to a synthetic single-frame value; that makes the native list
    // render empty even when the provider reports working MFG choices.
    caller.numFramesToGenerateMax=maximum;
    return true;
}

// Preserve the caller's exact allocation and ABI, and invoke the provider once.
// GetState consumes provider state, so an ABI retry can consume counters twice
// and can change ordering with Present. Capability evidence is limited to fields
// present in the caller's original version; never promote the structure to probe.
template<class Call>
sl::Result QueryNativeState(Call call,bool native,const sl::ViewportHandle& view,
                           sl::DLSSGState& caller,const sl::DLSSGOptions* options,
                           StateQueryEvidence& evidence,uint32_t queryVersion=2) {
    (void)native;
    (void)queryVersion;
    evidence={};evidence.callerVersion=static_cast<uint32_t>(caller.structVersion);
    const auto type=caller.structType;const auto version=caller.structVersion;auto* next=caller.next;
    const bool known=KnownState(caller);
    sl::DLSSGState original{};
    if(known){
        original.structType=type;original.structVersion=version;original.next=next;
        CopyStateOutputs(caller,original);
    }
    const auto result=call(view,caller,options);
    caller.structType=type;caller.structVersion=version;caller.next=next;
    // Restore only fields guaranteed to fit the caller's known version. Unknown
    // layouts remain pass-through; reading or copying a current SDK-sized object
    // from them could overrun the caller's allocation.
    if(result!=sl::Result::eOk&&known)CopyStateOutputs(original,caller);
    evidence.capabilityResult=result;
    if(result==sl::Result::eOk)ReadStateEvidence(caller,evidence);
    return result;
}
}
