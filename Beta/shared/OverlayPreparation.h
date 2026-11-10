#pragma once
#include <mutex>
#include <type_traits>
#include <utility>

namespace optishade::overlay {
template<class Draw>
bool DrawIfPrepared(bool preparationRequired, bool preparationSucceeded, Draw&& draw) noexcept {
    if(preparationRequired && !preparationSucceeded) return false;
    return std::forward<Draw>(draw)();
}

// The caller already owns these queue locks. UI preparation can upload fonts
// through the Vulkan layer and must be able to acquire the same locks there.
// Reacquire before returning to the downstream overlay submit/present section.
template<class Mutex, class Prepare>
bool PrepareOutsideQueueLocks(Mutex& present, Mutex* graphics, Prepare&& prepare) {
    std::unique_lock<Mutex> presentLock(present, std::adopt_lock);
    std::unique_lock<Mutex> graphicsLock;
    if(graphics && graphics != &present)
        graphicsLock = std::unique_lock<Mutex>(*graphics, std::adopt_lock);
    const bool secondary = graphicsLock.owns_lock();
    if(secondary) graphicsLock.unlock();
    presentLock.unlock();
    auto reacquire = [&] {
        if(secondary) std::lock(presentLock, graphicsLock);
        else presentLock.lock();
        presentLock.release();
        if(secondary) graphicsLock.release();
    };
    bool prepared=false;
    if constexpr(std::is_nothrow_invocable_r_v<bool,Prepare>)
        prepared=std::forward<Prepare>(prepare)();
    else {
        try { std::forward<Prepare>(prepare)(); prepared=true; }
        catch(...) { reacquire(); return false; }
    }
    reacquire();
    return prepared;
}
}
