#pragma once

#include <Windows.h>
#include <sl_dlss_g.h>
#include <atomic>

namespace optishade::native_mfg {

struct GuardedStateCall {
    sl::Result result = sl::Result::eErrorExceptionHandler;
    DWORD exceptionCode = 0;
    uintptr_t exceptionAddress = 0;
    ULONG_PTR accessOperation = ULONG_PTR(-1);
    uintptr_t faultAddress = 0;
    bool suppressedAfterFault = false;
};

#if defined(_MSC_VER)
inline int CaptureProviderException(EXCEPTION_POINTERS* pointers,GuardedStateCall* outcome) noexcept {
    if(!pointers||!pointers->ExceptionRecord||!outcome||
       pointers->ExceptionRecord->ExceptionCode!=EXCEPTION_ACCESS_VIOLATION)
        return EXCEPTION_CONTINUE_SEARCH;
    const auto* record=pointers->ExceptionRecord;
    outcome->exceptionCode=record->ExceptionCode;
    outcome->exceptionAddress=reinterpret_cast<uintptr_t>(record->ExceptionAddress);
    if(record->NumberParameters>=2){
        outcome->accessOperation=record->ExceptionInformation[0];
        outcome->faultAddress=static_cast<uintptr_t>(record->ExceptionInformation[1]);
    }
    return EXCEPTION_EXECUTE_HANDLER;
}
#endif

// SetOptions is also a third-party callback. A malformed or unsupported
// activation request must not let an access violation in that provider crash
// the host game. The caller shares the same fault latch with GetState so no
// further DLSS-G callbacks are made after a provider fault.
inline GuardedStateCall InvokeSetOptionsGuarded(decltype(&slDLSSGSetOptions) function,
                                                 const sl::ViewportHandle& viewport,
                                                 const sl::DLSSGOptions& options,
                                                 std::atomic<bool>* faultLatch=nullptr) noexcept {
    GuardedStateCall outcome{};
    if(faultLatch&&faultLatch->load(std::memory_order_acquire)){
        outcome.suppressedAfterFault=true;
        return outcome;
    }
    if(!function){outcome.result=sl::Result::eErrorFeatureMissing;return outcome;}
#if defined(_MSC_VER)
    __try {
        outcome.result=function(viewport,options);
    } __except (CaptureProviderException(GetExceptionInformation(),&outcome)) {
        outcome.result=sl::Result::eErrorExceptionHandler;
    }
#else
    try { outcome.result=function(viewport,options); }
    catch (...) { outcome.exceptionCode=1;outcome.result=sl::Result::eErrorExceptionHandler; }
#endif
    if(faultLatch&&outcome.exceptionCode)faultLatch->store(true,std::memory_order_release);
    return outcome;
}

// Streamline's GetState is a third-party callback and is documented as not
// thread safe. Contain an access violation from that callback at the boundary
// so one provider fault does not terminate the game process. The caller must
// latch the fault and stop querying this provider for the rest of the process.
inline GuardedStateCall InvokeGetStateGuarded(decltype(&slDLSSGGetState) function,
                                               const sl::ViewportHandle& viewport,
                                               sl::DLSSGState& state,
                                               const sl::DLSSGOptions* options,
                                               std::atomic<bool>* faultLatch=nullptr) noexcept {
    GuardedStateCall outcome{};
    if(faultLatch&&faultLatch->load(std::memory_order_acquire)){
        outcome.suppressedAfterFault=true;
        return outcome;
    }
    if (!function) {
        outcome.result = sl::Result::eErrorFeatureMissing;
        return outcome;
    }
#if defined(_MSC_VER)
    __try {
        outcome.result = function(viewport, state, options);
    } __except (CaptureProviderException(GetExceptionInformation(),&outcome)) {
        outcome.result = sl::Result::eErrorExceptionHandler;
    }
#else
    try {
        outcome.result = function(viewport, state, options);
    } catch (...) {
        outcome.exceptionCode = 1;
        outcome.result = sl::Result::eErrorExceptionHandler;
    }
#endif
    if(faultLatch&&outcome.exceptionCode)faultLatch->store(true,std::memory_order_release);
    return outcome;
}

}
