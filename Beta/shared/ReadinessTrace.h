// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <sstream>
#include <string>

namespace optishade::readiness {
// CPU monotonic microseconds. These values are not GPU timestamps or latency.
inline uint64_t NowUs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
enum class Outcome : uint32_t {
    InvalidConsumer, WrongDevice, MissingSubmission, ChangedRecording, InvalidContract,
    DeviceRemoved, Deadline, Ready, SameQueueOrdered, WaitEnqueued, WaitFailed
};
inline const char* Name(Outcome value) {
    switch (value) {
    case Outcome::InvalidConsumer: return "invalid consumer";
    case Outcome::WrongDevice: return "device identity mismatch";
    case Outcome::MissingSubmission: return "submission observation unavailable";
    case Outcome::ChangedRecording: return "recording generation unavailable or changed";
    case Outcome::InvalidContract: return "invalid submitted resource contract";
    case Outcome::DeviceRemoved: return "fence reports device removal";
    case Outcome::Deadline: return "producer deadline missed";
    case Outcome::Ready: return "cross-queue producers completed at check";
    case Outcome::SameQueueOrdered: return "same-queue submission ordered (not completion)";
    case Outcome::WaitEnqueued: return "queue waits enqueued (not completion)";
    case Outcome::WaitFailed: return "queue wait enqueue failed";
    }
    return "unknown";
}
inline bool Failed(Outcome value) {
    return value != Outcome::Ready && value != Outcome::SameQueueOrdered && value != Outcome::WaitEnqueued;
}
struct Dependency {
    uint64_t command=0, recording=0, submissionEpoch=0, queue=0, fence=0;
    uint64_t required=0, completedAtCheck=0, checkedAtUs=0;
    uint32_t phase=0;
    bool completionSampled=false, crossQueue=false;
};
struct Decision {
    uint64_t sequence=0, startedAtUs=0, decidedAtUs=0, device=0, consumerQueue=0;
    uint32_t budgetUs=0, dependencyCount=0, captured=0;
    bool completionOnly=false;
    Outcome outcome=Outcome::InvalidConsumer;
    std::array<Dependency,8> dependencies{};
};
struct Snapshot {
    uint64_t sequence=0, overwritten=0, contentionDrops=0;
    uint32_t count=0;
    bool hasFirstFailure=false;
    Decision firstFailure{};
    std::array<Decision,32> recent{};
};
class Journal {
    std::mutex mutex_;
    Snapshot data_{};
    std::atomic<uint64_t> drops_{0};
public:
    // Bounded, value-only publication. No resource retention, allocation, I/O,
    // worker creation, or blocking on another thread in a rendering callback.
    bool Record(Decision value) {
        std::unique_lock<std::mutex> lock(mutex_,std::try_to_lock);
        if (!lock.owns_lock()) { ++drops_; return false; }
        value.sequence=++data_.sequence;
        data_.recent[(value.sequence-1)%data_.recent.size()]=value;
        if (data_.count<data_.recent.size()) ++data_.count; else ++data_.overwritten;
        if (!data_.hasFirstFailure && Failed(value.outcome)) {
            data_.hasFirstFailure=true; data_.firstFailure=value;
        }
        return true;
    }
    bool Read(Snapshot& out) {
        std::unique_lock<std::mutex> lock(mutex_,std::try_to_lock);
        if (!lock.owns_lock()) return false;
        out=data_; out.contentionDrops=drops_.load(std::memory_order_relaxed); return true;
    }
};
inline Journal& State() { static Journal value; return value; }
class Capture {
    Journal& journal_;
public:
    Decision value{};
    explicit Capture(Journal& journal=State()):journal_(journal) { value.startedAtUs=NowUs(); }
    bool Finish(Outcome result,bool success) {
        value.decidedAtUs=NowUs(); value.outcome=result; journal_.Record(value); return success;
    }
    Dependency* Add(uint64_t command,uint64_t generation) {
        ++value.dependencyCount;
        if (value.captured==value.dependencies.size()) return nullptr;
        auto& entry=value.dependencies[value.captured++]; entry.command=command; entry.recording=generation; return &entry;
    }
};
// Called only by the existing diagnostic worker or an explicit Copy report
// action. Snapshot numbers are immutable: never re-query a fence while exporting.
inline std::string Format(const Decision& value) {
    std::ostringstream out;
    out << "seq=" << value.sequence << " outcome=\"" << Name(value.outcome) << "\""
        << " device=" << value.device << " consumerQueue=" << value.consumerQueue
        << " startedUs=" << value.startedAtUs << " decidedUs=" << value.decidedAtUs
        << " budgetUs=" << value.budgetUs << " completionOnly=" << value.completionOnly
        << " dependencies=" << value.dependencyCount << " captured=" << value.captured;
    for (uint32_t i=0;i<value.captured;++i) {
        const auto& d=value.dependencies[i];
        out << "\n  cmd=" << d.command << " recording=" << d.recording << " epoch=" << d.submissionEpoch
            << " queue=" << d.queue << " phase=" << d.phase << " fence=" << d.fence
            << " required=" << d.required << " sampled=" << d.completionSampled
            << " completedAtCheck=" << d.completedAtCheck << " checkedUs=" << d.checkedAtUs
            << " crossQueue=" << d.crossQueue;
    }
    return out.str();
}
inline std::string Report(const Snapshot& snapshot) {
    std::ostringstream out;
    out << "OptiShade readiness decisions v1\nCPU monotonic microseconds; not GPU latency.\n"
        << "sequence=" << snapshot.sequence << " overwritten=" << snapshot.overwritten
        << " contentionDrops=" << snapshot.contentionDrops << '\n';
    if (snapshot.hasFirstFailure) out << "First failure (this process):\n" << Format(snapshot.firstFailure) << '\n';
    const uint64_t first=snapshot.sequence-snapshot.count;
    for (uint32_t i=0;i<snapshot.count;++i) out << Format(snapshot.recent[(first+i)%snapshot.recent.size()]) << '\n';
    return out.str();
}
}
