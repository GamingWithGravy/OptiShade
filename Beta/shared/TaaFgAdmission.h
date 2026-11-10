#pragma once
#include <cstdint>
#include <sl_dlss_g.h>
namespace optishade::taa {
// The signature is published only after native Streamline SetOptions succeeds.
// Auto/Dynamic can generate frames even when the requested count is zero.
inline bool NativeCompositionAllowed(uint64_t acceptedNativeSignature) {
    const auto mode=static_cast<sl::DLSSGMode>(acceptedNativeSignature >> 32);
    return mode==sl::DLSSGMode::eOn || mode==sl::DLSSGMode::eAuto || mode==sl::DLSSGMode::eDynamic;
}
inline bool NativeContractOwnsFallback(uint64_t acceptedNativeSignature, bool validatedFrameContract) {
    return validatedFrameContract && NativeCompositionAllowed(acceptedNativeSignature);
}
inline bool BlocksLateComposition(bool managedActive, uint64_t acceptedNativeSignature,
                                  bool validatedFrameContract) {
    // Managed FG retains its existing single-owner policy. External native FG
    // takes ownership only for a frame whose matching resources/constants have
    // passed the early contract; a mode request alone must not strand TAA NR.
    return managedActive || NativeContractOwnsFallback(acceptedNativeSignature, validatedFrameContract);
}
}
