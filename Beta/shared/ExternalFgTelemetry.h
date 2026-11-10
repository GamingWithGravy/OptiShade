#pragma once

#include <cstdint>
#include <mutex>

namespace optishade::external_fg_telemetry {

// Diagnostic counters only. These record options accepted by the resolved
// provider and its own GetState presentation count; they never drive controls.
struct Snapshot {
    uint32_t lastAcceptedMode = 0;
    uint32_t lastAcceptedAdditionalFrames = 0;
    uint32_t maxAcceptedAdditionalFrames = 0;
    uint32_t maxFramesSinceStateQuery = 0;
    uint32_t stateQueryCount = 0;
    uint32_t presentCallCount = 0;
    uint32_t lastStateThreadId = 0;
    uint32_t lastPresentThreadId = 0;
    uintptr_t lastPresentSwapchainId = 0;
    uint32_t presentCallCountAtLastState = 0;
    uint64_t lastStateIntervalMs = 0;
    uint64_t lastStateAgeSincePresentMs = 0;
    bool hasStateInterval = false;
    bool hasPresentSample = false;
    bool lastStateThreadMatchesPresent = false;
};

class Recorder {
    mutable std::mutex mutex_;
    Snapshot state_;
    uint64_t lastStateTick_ = 0;
    uint64_t lastPresentTick_ = 0;
    uint64_t lastBlockedStatePersistTick_ = 0;
    uint32_t lastBlockedStateReason_ = 0;
    bool hasBlockedStatePersist_ = false;

public:
    Snapshot RecordAcceptedOptions(uint32_t mode, uint32_t additionalFrames) {
        std::lock_guard lock(mutex_);
        state_.lastAcceptedMode = mode;
        state_.lastAcceptedAdditionalFrames = additionalFrames;
        // Streamline's eOff value is zero. Preserve the highest accepted active
        // request across later off calls so a session summary retains test runs.
        if (mode != 0)
            state_.maxAcceptedAdditionalFrames =
                state_.maxAcceptedAdditionalFrames > additionalFrames
                    ? state_.maxAcceptedAdditionalFrames
                    : additionalFrames;
        return state_;
    }

    Snapshot RecordStateSample(uint32_t framesSinceQuery) {
        std::lock_guard lock(mutex_);
        if (state_.maxFramesSinceStateQuery < framesSinceQuery)
            state_.maxFramesSinceStateQuery = framesSinceQuery;
        return state_;
    }

    // These are diagnostic-only observations. The captured thread IDs and
    // cadence never alter provider calls, options, or synchronization.
    Snapshot RecordStateCall(uint32_t threadId, uint64_t tickMs) {
        std::lock_guard lock(mutex_);
        if (state_.stateQueryCount != UINT32_MAX)
            ++state_.stateQueryCount;
        if (lastStateTick_ && tickMs >= lastStateTick_) {
            state_.lastStateIntervalMs = tickMs - lastStateTick_;
            state_.hasStateInterval = true;
        }
        lastStateTick_ = tickMs;
        state_.lastStateThreadId = threadId;
        state_.presentCallCountAtLastState = state_.presentCallCount;
        state_.hasPresentSample = lastPresentTick_ && tickMs >= lastPresentTick_;
        if (state_.hasPresentSample) {
            state_.lastStateAgeSincePresentMs = tickMs - lastPresentTick_;
            state_.lastStateThreadMatchesPresent = threadId == state_.lastPresentThreadId;
        } else {
            state_.lastStateAgeSincePresentMs = 0;
            state_.lastStateThreadMatchesPresent = false;
        }
        return state_;
    }

    Snapshot RecordPresentCall(uint32_t threadId, uint64_t tickMs, uintptr_t swapchainId = 0) {
        std::lock_guard lock(mutex_);
        if (state_.presentCallCount != UINT32_MAX)
            ++state_.presentCallCount;
        state_.lastPresentThreadId = threadId;
        state_.lastPresentSwapchainId = swapchainId;
        lastPresentTick_ = tickMs;
        return state_;
    }

    // A refused GetState can be polled every frame. Keep the crash evidence
    // durable without rebuilding the session snapshot on every refused call.
    bool ShouldPersistBlockedState(uint64_t tickMs, uint32_t reason) {
        std::lock_guard lock(mutex_);
        if (hasBlockedStatePersist_ && reason == lastBlockedStateReason_ &&
            tickMs >= lastBlockedStatePersistTick_ &&
            tickMs - lastBlockedStatePersistTick_ < 1000)
            return false;
        hasBlockedStatePersist_ = true;
        lastBlockedStatePersistTick_ = tickMs;
        lastBlockedStateReason_ = reason;
        return true;
    }

    Snapshot Read() const {
        std::lock_guard lock(mutex_);
        return state_;
    }
};

inline Recorder& Session() {
    static Recorder recorder;
    return recorder;
}

} // namespace optishade::external_fg_telemetry
