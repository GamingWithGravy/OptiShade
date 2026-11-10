#pragma once
#include <mutex>
namespace optishade::overlay {
template<class Queue,class Prepare,class Draw> class Callbacks {
 std::mutex mutex;
 Queue queue{};
public:
 struct Snapshot {Prepare prepare{};Draw draw{};};
private:
 Snapshot callbacks;
public:
 void Set(Queue q,Prepare p,Draw d){std::lock_guard lock(mutex);queue=q;callbacks={p,d};}
 void Clear(){std::lock_guard lock(mutex);queue={};callbacks={};}
 Snapshot For(Queue q){std::lock_guard lock(mutex);return q==queue?callbacks:Snapshot{};}
};
}
