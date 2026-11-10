#pragma once
#include <cstdint>
namespace optishade::route {
// Allocation/deallocation stay in the component that defines the concrete type.
// The selected simulator DLL owns the slot; shared engine code only borrows it.
struct BackendRequest {uint32_t size=sizeof(BackendRequest),abi=4,slot=0;void* (*create)()=nullptr;void (*destroy)(void*)=nullptr;bool release=false;};
using BackendCall=bool(*)(const BackendRequest*,uint32_t,void**);
}
