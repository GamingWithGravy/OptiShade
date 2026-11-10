#pragma once
// NGX frame generation uses DLSSG.* resources, not the generic SR Color/Output
// slots. A game may reuse a parameter table whose generic pointers are stale.
// Hide only these unrelated slots during FG so SR-only observers cannot treat
// a successful FG evaluate as a fresh SR output. Never dereference saved values.
namespace optishade {
template<class Params> class ScopedFgSrInputs {
 Params* params_; struct Slot { const char* name; ID3D12Resource* resource=nullptr; void* pointer=nullptr; int kind=0; };
 Slot slots_[2]{{"Color"},{"Output"}};
public:
 ScopedFgSrInputs(Params* p,bool fg):params_(fg?p:nullptr){
  if(!params_)return;
  for(auto& s:slots_){if(params_->Get(s.name,&s.resource)==1)s.kind=1;
   else if(params_->Get(s.name,&s.pointer)==1)s.kind=2;
   params_->Set(s.name,static_cast<ID3D12Resource*>(nullptr));}
 }
 ~ScopedFgSrInputs(){if(params_)for(auto& s:slots_){if(s.kind==2)params_->Set(s.name,s.pointer);else params_->Set(s.name,s.resource);}}
 ScopedFgSrInputs(const ScopedFgSrInputs&)=delete;ScopedFgSrInputs& operator=(const ScopedFgSrInputs&)=delete;
};
inline unsigned NrPassesForRoute(unsigned configured,bool proxy,bool nativeFg){(void)nativeFg;return proxy?1u:configured;}
}
