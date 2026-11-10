#pragma once

#include <cstddef>
#include <vector>

namespace optishade::vkoverlay {

enum class FenceState { Signaled, NotReady, Error };
enum class FenceDecision { Proceed, Defer, ReplaceResources, DisableOverlay };
inline constexpr std::size_t MaxRetiredFrameResources = 4;

// A successful overlay-present/reacquisition pair permits replacement of the
// busy frame resources. It never makes resetting or recording into resources
// with an unsignaled fence safe. Retired resources stay alive until their fence
// signals, with a strict per-image bound to avoid unbounded retention.
constexpr FenceDecision DecideAcquiredImageFence(FenceState state,
                                                  bool previouslyPresented,
                                                  std::size_t retiredResources) noexcept {
    if (state == FenceState::Signaled)
        return FenceDecision::Proceed;
    if (state == FenceState::NotReady) {
        if (previouslyPresented && retiredResources < MaxRetiredFrameResources)
            return FenceDecision::ReplaceResources;
        return FenceDecision::Defer;
    }
    return FenceDecision::DisableOverlay;
}

// Retired payloads stay owned until the same submission fence proves GPU
// completion. Fence errors are deliberately retained for teardown handling.
template <typename Resources, typename FenceStatus, typename Destroy>
std::size_t ReapCompletedResources(std::vector<Resources>& resources,
                                   FenceStatus&& fenceStatus,
                                   Destroy&& destroy) {
    std::size_t reaped = 0;
    for (auto it = resources.begin(); it != resources.end();) {
        if (fenceStatus(*it) == FenceState::Signaled) {
            destroy(*it);
            it = resources.erase(it);
            ++reaped;
        } else {
            ++it;
        }
    }
    return reaped;
}

}
