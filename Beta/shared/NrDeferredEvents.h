#pragma once
#include <deque>
#include <mutex>
#include <utility>

namespace optishade::nr {
// Driver callbacks can run while DXGI owns an internal lock. Never wait for the
// NR state lock from those callbacks: the render thread may be inside DXGI.
// The inbox lock protects only moving events, never handlers or COM operations.
template<class Event> class DeferredEvents {
    std::recursive_mutex state;
    std::mutex inboxMutex;
    std::deque<Event> inbox;
    void (*consume)(const Event&);
    bool draining = false; // protected by state, including recursive entry
    void Drain() {
        if (draining) return;
        draining = true;
        struct Reset { bool& flag; ~Reset(){ flag=false; } } reset{draining};
        // Consume the finite snapshot visible at entry. A driver/simulation
        // thread can keep posting while handlers run; chasing those arrivals
        // until the inbox is empty can monopolise a presentation callback.
        // Later arrivals remain FIFO in the inbox for the next guard/Post.
        std::deque<Event> batch;
        { std::lock_guard<std::mutex> lock(inboxMutex); batch.swap(inbox); }
        for (const auto& event : batch) consume(event);
    }
public:
    explicit DeferredEvents(void (*handler)(const Event&)) : consume(handler) {}
    class Guard {
        DeferredEvents& owner;
        std::unique_lock<std::recursive_mutex> lock;
    public:
        explicit Guard(DeferredEvents& value) : owner(value), lock(value.state) { owner.Drain(); }
        ~Guard() { owner.Drain(); }
        Guard(const Guard&) = delete;
        Guard& operator=(const Guard&) = delete;
    };
    Guard Lock() { return Guard(*this); }
    // Control requests may fail busy instead of waiting behind the render
    // thread. Successful callers share the existing owner and its finite event
    // drain; this does not create another GPU or command-list lifetime owner.
    template<class Function> bool TryWithState(Function&& function) {
        std::unique_lock<std::recursive_mutex> lock(state,std::try_to_lock);
        if(!lock.owns_lock())return false;
        Drain();
        std::forward<Function>(function)();
        Drain();
        return true;
    }
    void Post(Event event) {
        { std::lock_guard<std::mutex> lock(inboxMutex); inbox.push_back(std::move(event)); }
        // Drop the inbox lock BEFORE touching state. No notification is discarded.
        std::unique_lock<std::recursive_mutex> lock(state, std::try_to_lock);
        if (lock.owns_lock()) Drain();
    }
};
}
