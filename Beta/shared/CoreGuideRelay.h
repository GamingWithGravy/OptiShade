// OptiShade GPL-3.0-or-later. Sequencing for the existing D3D10->D3D11 relay.
// No resource registry or presentation owner is introduced here.
#pragma once
#include <cstdint>
namespace optishade::guides {
enum class RelayResult:uint32_t {Failed, Warming, Ready};
template<class Operations> RelayResult RunRelayKernels(Operations& operations,bool warm) {
 // A failed game-side transfer must never consume last frame's shared inputs.
 if(!operations.GameInputsComplete())return RelayResult::Failed;
 if(!operations.Prepare()||!operations.Estimate()||!operations.Resolve())return RelayResult::Failed;
 // Copy this frame's prepared image only after the preceding history has been
 // consumed by Estimate. Warm-up may produce zero motion but cannot feed NR.
 if(!operations.AdvanceHistory())return RelayResult::Failed;
 return warm?RelayResult::Ready:RelayResult::Warming;
}
}
