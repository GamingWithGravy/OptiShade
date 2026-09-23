#pragma once
#include <Windows.h>
#include <mutex>
namespace optishade {
// Identity is borrowed only while the swapchain exists; its owner must call Retire.
class PresentationOwner {
    std::mutex mutex;
    HWND window = nullptr;
    const void* swapchain = nullptr;
public:
    bool Accept(HWND candidate, bool claim = false, const void* identity = nullptr) {
        if (!candidate) return true; // Preserve existing windowless/VR routing.
        std::lock_guard<std::mutex> lock(mutex);
        if (window && !IsWindow(window)) { window = nullptr; swapchain = nullptr; }
        // Instrument/tool windows must not win ownership simply by presenting first.
        // Apply this while unclaimed (including non-claiming resize/status calls),
        // leaving an established owner's behaviour stable until explicit retirement.
        if (!window) {
            if (!IsWindow(candidate)) return false;
            if (GetWindowLongPtrW(candidate, GWL_STYLE) & WS_CHILD) return false;
            if (GetWindowLongPtrW(candidate, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) return false;
            if (GetWindow(candidate, GW_OWNER)) return false;
        }
        if (!window && claim) {
            window = candidate;
            swapchain = identity;
        }
        if (window && window != candidate) return false;
        if (swapchain && identity && swapchain != identity) return false;
        if (window && claim && !swapchain) swapchain = identity;
        return true;
    }
    void Retire(HWND candidate, const void* identity) {
        std::lock_guard<std::mutex> lock(mutex);
        if (window == candidate && swapchain == identity) { window = nullptr; swapchain = nullptr; }
    }
};
}
