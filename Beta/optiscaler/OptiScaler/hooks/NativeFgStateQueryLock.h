#pragma once

#include "../../../shared/NativeFgStateQuery.h"

namespace optishade::native_mfg {

template<class Call>
sl::Result InvokeProviderCallDirect(Call&& call){
    return call();
}

// Keep the intercepted Streamline call synchronous and on its original caller
// thread. A private mutex cannot order these calls with Streamline's internal
// Present thread, so synchronization must remain with the host integration.
template<class Call>
sl::Result QueryNativeStateOnce(Call call,bool native,const sl::ViewportHandle& view,
                                sl::DLSSGState& caller,const sl::DLSSGOptions* options,
                                StateQueryEvidence& evidence,uint32_t queryVersion=2) {
    return QueryNativeState(call,native,view,caller,options,evidence,queryVersion);
}

}
