#pragma once
#include <cstdint>
#include <limits>
namespace optishade::taa {
// Completion of this private submit is necessary, not sufficient: the caller
// must also retire recording leases and every held/retired resource reference.
inline bool PrivateSubmitRetired(bool poisoned,bool borrowed,bool hasFence,uint64_t completed,uint64_t required) {
    if(poisoned||borrowed)return false;
    if(!hasFence)return required==0;
    return completed!=std::numeric_limits<uint64_t>::max()&&completed>=required;
}
}
