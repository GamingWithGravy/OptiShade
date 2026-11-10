#pragma once

#include <cstdint>
#include <mutex>

namespace optishade::native_mfg {

struct CapabilitySnapshot {
    uint32_t maximum = 1;
    uint32_t viewport = 0;
    bool dynamicKnown = false;
    bool dynamicSupported = false;
    bool known = false;
};

// Capabilities are observed only when the game calls GetState. The managed
// output reads this cache later; it never makes its own thread-affine query.
class CapabilityCache {
    mutable std::mutex mutex_;
    CapabilitySnapshot state_;

public:
    CapabilitySnapshot Read() const {
        std::lock_guard lock(mutex_);
        return state_;
    }

    bool Observe(uint32_t maximum, uint32_t viewport, bool dynamicKnown, bool dynamicSupported) {
        std::lock_guard lock(mutex_);
        if (maximum < 1 || maximum > 6) {
            state_ = {};
            return false;
        }
        state_ = {maximum, viewport, dynamicKnown, dynamicKnown && dynamicSupported, true};
        return true;
    }

    void Reset() {
        std::lock_guard lock(mutex_);
        state_ = {};
    }
};

}
