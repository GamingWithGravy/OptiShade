#pragma once
#include <cstdint>
namespace optishade::fxready {
enum class Result { Waiting, Active, Cancelled, RuntimeLost, TimedOut };
struct Request {uint64_t started=0,generation=0;};
inline bool alive(uint64_t now,uint64_t heartbeat){return heartbeat && now>=heartbeat && now-heartbeat<=10000;}
inline Result poll(Request request,uint64_t now,uint64_t generation,bool connected,bool loading,bool active) {
    if(request.generation!=generation)return Result::Cancelled;
    if(!connected)return Result::RuntimeLost;
    if(!loading && active)return Result::Active;
    if(now>=request.started && now-request.started>=120000)return Result::TimedOut;
    return Result::Waiting;
}
}
