#pragma once
#include <cstdint>
namespace optishade {
// One shared overlay renderer: changing HWND must not bypass allocation backoff.
class OverlayRetry {
    uint64_t failedAt = 0;
    bool pending = false;
public:
    bool Ready(uint64_t now) const { return !pending || now - failedAt >= 2000; }
    void Failed(uint64_t now) { failedAt = now; pending = true; }
    void Succeeded() { pending = false; }
};
}
