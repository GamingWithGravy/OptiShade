#pragma once
#include <cstdint>

namespace optishade::nr_session {
enum class Code { Accepted,Conflict,Busy };
struct State {bool requested=false;uint64_t revision=0,explicitOffRevision=0;};
struct Result {Code code=Code::Busy;uint64_t revision=0;};

// Reuses the renderer's existing state owner. No waiting request queue, provider
// calls, tuning edits, persisted enabling or memory override belongs here.
template<class Events,class Read,class Set>
Result TrySet(Events& events,bool requested,uint64_t expectedRevision,Read read,Set set) {
    Result result;
    events.TryWithState([&]{
        const auto current=read();result.revision=current.revision;
        if(current.revision!=expectedRevision){result.code=Code::Conflict;return;}
        set(requested);
        result={Code::Accepted,read().revision};
    });
    return result;
}
}
