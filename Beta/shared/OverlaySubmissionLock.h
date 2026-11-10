#pragma once
#include <mutex>
#include <utility>
namespace optishade::overlay {
// Called under an effects queue lock. Never wait for an owner that may be
// waiting for that queue during swapchain recreation. A skipped overlay leaves
// the original present waits untouched; the next frame may retry.
template<class Mutex, class Submit>
bool TrySubmitWithOwner(Mutex& mutex, Submit&& submit) {
    std::unique_lock<Mutex> lock(mutex, std::try_to_lock);
    if(!lock.owns_lock()) return true;
    return std::forward<Submit>(submit)();
}
}
