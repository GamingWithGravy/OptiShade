#pragma once
#include <array>
#include <cstddef>
#include <cstdint>

namespace OptiShadeLog {
// Fixed enum slots keep alternating reasons independent without an unbounded map
// of resource addresses. Caller supplies a monotonic clock and synchronization.
template <size_t Count> class ReasonLimits {
    struct Entry { bool seen = false; uint64_t last = 0; uint64_t count = 0; };
    std::array<Entry, Count> entries_ {};
public:
    bool record(size_t reason, uint64_t now, uint64_t interval = 60000) {
        if (reason >= Count) return false;
        auto& e = entries_[reason];
        if (e.count != UINT64_MAX) ++e.count;
        if (!e.seen || now - e.last >= interval) { e.seen = true; e.last = now; return true; }
        return false;
    }
    uint64_t count(size_t reason) const { return reason < Count ? entries_[reason].count : 0; }
};
}
