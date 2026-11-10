// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

namespace optishade {
enum class SaveProgress { None, Saved, Failed };
// A single worker owns slow read/write callbacks. Peek never calls the provider,
// waits for file access, or creates a worker. Start is an explicit startup action.
template<class State, class Request> class BackgroundStatus {
public:
    struct Envelope {
        State state{};
        uint64_t sampledAtMs=0, completedRequest=0;
        SaveProgress save=SaveProgress::None;
        std::string saveMessage, readError;
    };
    using Read=std::function<State()>;
    using Write=std::function<bool(const Request&,std::string&)>;
    using Pointer=std::shared_ptr<const Envelope>;
    static uint64_t NowMs() {
        return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
    }
private:
    Read read_;
    Write write_;
    std::chrono::milliseconds interval_;
    Pointer published_=std::make_shared<const Envelope>();
    std::mutex commands_;
    std::condition_variable wake_;
    std::optional<Request> pending_;
    uint64_t serial_=0, pendingId_=0;
    bool busy_=false, stopping_=false;
    std::atomic<bool> started_{false};
    std::thread thread_;
    void Run() {
        Envelope next;
        for (;;) {
            std::optional<Request> request;uint64_t id=0;
            {
                std::lock_guard<std::mutex> lock(commands_);
                if(stopping_)return;
                if(pending_){request=std::move(pending_);pending_.reset();id=pendingId_;}
            }
            if(request) {
                next.completedRequest=id;
                try {
                    next.saveMessage.clear();
                    const bool saved=write_(*request,next.saveMessage);
                    next.save=saved?SaveProgress::Saved:SaveProgress::Failed;
                    if(next.saveMessage.empty())next.saveMessage=saved?
                        "Settings saved; waiting for runtime acknowledgement.":"Settings were not saved.";
                } catch(...) {next.save=SaveProgress::Failed;next.saveMessage="Settings could not be saved safely.";}
            }
            try {
                // Build the new state before publishing. A failed read must NOT
                // renew the timestamp of an older successful observation.
                State observed=read_();
                next.state=std::move(observed);next.sampledAtMs=NowMs();next.readError.clear();
            } catch(...) {next.readError="Status read failed; earlier observations are not current.";}
            std::atomic_store_explicit(&published_,Pointer(std::make_shared<Envelope>(next)),std::memory_order_release);
            {
                std::unique_lock<std::mutex> lock(commands_);
                if(request)busy_=false;
                wake_.wait_for(lock,interval_,[this]{return stopping_||pending_.has_value();});
                if(stopping_)return;
            }
        }
    }
public:
    BackgroundStatus(Read read,Write write,std::chrono::milliseconds interval=std::chrono::milliseconds(300)):
        read_(std::move(read)),write_(std::move(write)),interval_(interval) {}
    BackgroundStatus(const BackgroundStatus&)=delete;
    BackgroundStatus& operator=(const BackgroundStatus&)=delete;
    ~BackgroundStatus(){Stop();}
    void Start() {
        if(started_.exchange(true,std::memory_order_acq_rel))return;
        try {thread_=std::thread([this]{Run();});}
        catch(...) {started_.store(false,std::memory_order_release);throw;}
    }
    bool Started()const{return started_.load(std::memory_order_acquire);}
    Pointer Peek()const{return std::atomic_load_explicit(&published_,std::memory_order_acquire);}
    uint64_t Queue(Request request) {
        if(!Started())return 0;
        std::unique_lock<std::mutex> lock(commands_,std::try_to_lock);
        if(!lock.owns_lock()||stopping_||busy_)return 0;
        busy_=true;pendingId_=++serial_;pending_=std::move(request);wake_.notify_one();return pendingId_;
    }
    // Explicit owner shutdown only. Production uses a process-lifetime owner,
    // so a file worker is never joined from DllMain / DLL_PROCESS_DETACH.
    void Stop() {
        {std::lock_guard<std::mutex> lock(commands_);stopping_=true;}
        wake_.notify_one();if(thread_.joinable())thread_.join();
    }
};
}
