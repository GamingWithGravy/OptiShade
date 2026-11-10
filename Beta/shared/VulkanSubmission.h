#pragma once
#include <cstdint>
#include <array>
#include <mutex>
namespace optishade::vknr {
// Only explicitly armed bridge recordings are tracked. Successful real queue
// submission is required after flush; a recycled native address is not proof.
class SubmissionJournal {
 struct Entry {uint64_t command=0,queue=0,epoch=0;bool submitted=false;};
 std::array<Entry,16> entries{};uint64_t serial=0;std::mutex mutex;
public:
 uint64_t Arm(uint64_t queue,uint64_t command){std::lock_guard lock(mutex);auto epoch=++serial;entries[epoch%entries.size()]={command,queue,epoch,false};return epoch;}
 void Observe(uint64_t queue,uint64_t command,bool success){std::lock_guard lock(mutex);for(auto& e:entries)if(e.command==command&&e.queue==queue)e.submitted=success;}
 bool Consume(uint64_t epoch){std::lock_guard lock(mutex);auto& e=entries[epoch%entries.size()];bool ok=e.epoch==epoch&&e.submitted;e={};return ok;}
};
inline SubmissionJournal& Submissions(){static SubmissionJournal value;return value;}
// The callback owns resetting its immediate runtime. No pre-flush command
// pointer escapes this boundary into the following recording.
inline bool FlushSubmitted(const osvtaa::Frame& f,uint64_t command){auto epoch=Submissions().Arm(f.queue,command);f.flush(f.commandContext);return Submissions().Consume(epoch);}
}
