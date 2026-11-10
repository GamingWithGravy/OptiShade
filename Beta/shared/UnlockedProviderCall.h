#pragma once
#include <utility>
namespace optishade {
// A provider may synchronously join callbacks which inspect our owner on a
// different thread. Restore the lock before inspecting mutable owner state.
template<class Lock, class Call> auto InvokeWithoutOwnerLock(Lock& lock, Call&& call) {
 struct Restore { Lock& lock; ~Restore(){lock.lock();} } restore{lock};
 lock.unlock();
 return std::forward<Call>(call)();
}
}
