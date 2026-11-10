#pragma once
#include <optional>
namespace optishade::taa {
// Only the exact reserved, unconsumed frame may retry at the provider boundary.
// No reassignment across frame/view/device/owner generations; no duplicate work.
template<class Identity> inline bool AllowNativeFgPreparation(const std::optional<Identity>& pending,
 const Identity& current, bool providerBoundary, unsigned attempts, bool sealed, bool submitted, bool retired, bool failed){
 if(sealed||submitted||retired||failed||attempts>=2)return false;
 if(!pending)return attempts==0;
 return *pending==current && providerBoundary && attempts==1;
}
}

namespace optishade::taa {
// One frame has at most 8 ms of readiness polling at the provider boundary. Once this owner is known
// to pass through the provider-input Present, reserve that allowance for the
// later boundary rather than spending it before final game work is submitted.
class NativeFgReadinessBudget {
 unsigned allocated_=0;
public:
 unsigned Take(bool providerObserved, bool providerBoundary) noexcept {
  if (providerObserved && !providerBoundary) return 0;
  const unsigned limit=providerBoundary?8000u:2000u;
  const unsigned available=limit>allocated_?limit-allocated_:0;
  allocated_+=available;return available;
 }
};
}
