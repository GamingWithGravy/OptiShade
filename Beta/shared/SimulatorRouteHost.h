#pragma once
#include "SimulatorRoute.h"
#include "NativeFgAssembly.h"
#include "RouteOwnedBackend.h"
#include "OutputDomain.h"
#include <Windows.h>
#include <mutex>
#include <filesystem>
namespace optishade::route {
inline OutputKey CurrentOutputKey();
struct Adapter {HMODULE module=nullptr;Descriptor descriptor{};Validate validate=nullptr;FrameEvent event=nullptr;VulkanCall vulkan=nullptr;PresentationCall presentation=nullptr;SubmissionCall submission=nullptr;ConstantCall constants=nullptr;AssemblyCall assembly=nullptr;BackendCall backend=nullptr;};
inline Simulator CurrentSimulator(){static const auto id=[] {wchar_t exe[32768]{};if(!GetModuleFileNameW(nullptr,exe,32768))return Simulator::Unknown;return Identify(std::filesystem::path(exe).filename().wstring());}();return id;}
inline const Adapter& Current(){
 static const Adapter selected=[] {
  Adapter a;const auto id=CurrentSimulator();const wchar_t* name=nullptr;
  switch(id){case Simulator::Msfs2024:name=L"OptiShadeMSFS2024.dll";break;case Simulator::Msfs2020:name=L"OptiShadeMSFS2020.dll";break;case Simulator::XPlane12:name=L"OptiShadeXPlane12.dll";break;default:name=L"OptiShadeGeneric.dll";break;}
  // Xbox/MS Store's running EXE may resolve into WindowsApps. Route assets
  // belong beside the loaded game-local Fusion Engine component, not that EXE.
  HMODULE self=nullptr;
  if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,reinterpret_cast<LPCWSTR>(&Current),&self))return a;
  wchar_t component[32768]{};if(!GetModuleFileNameW(self,component,32768))return a;
  auto path=std::filesystem::path(component).parent_path()/L"OptiShadeData"/L"Engine"/L"Routes"/name;
  // Only the selected game-local route is loaded; no PATH/current-dir search.
  auto m=LoadLibraryExW(path.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32);
  if(!m)return a;
  auto q=reinterpret_cast<Query>(GetProcAddress(m,"OptiShadeRouteQuery"));
  auto v=reinterpret_cast<Validate>(GetProcAddress(m,"OptiShadeRouteValidate"));
  auto e=reinterpret_cast<FrameEvent>(GetProcAddress(m,"OptiShadeRouteFrameEvent"));
  auto vk=reinterpret_cast<VulkanCall>(GetProcAddress(m,"OptiShadeRouteVulkan"));
  auto present=reinterpret_cast<PresentationCall>(GetProcAddress(m,"OptiShadeRoutePresentation"));
  auto submit=reinterpret_cast<SubmissionCall>(GetProcAddress(m,"OptiShadeRouteSubmission"));
  auto constants=reinterpret_cast<ConstantCall>(GetProcAddress(m,"OptiShadeRouteConstants"));
  auto assembly=reinterpret_cast<AssemblyCall>(GetProcAddress(m,"OptiShadeRouteNativeFrame"));
  auto backend=reinterpret_cast<BackendCall>(GetProcAddress(m,"OptiShadeRouteBackend"));
  Descriptor d;
  if(!q||!v||!e||!present||!submit||!constants||!assembly||!backend||!q(&d,sizeof(d))||d.size!=sizeof(d)||d.abi!=Abi||d.simulator!=id||(id==Simulator::XPlane12&&!vk)){FreeLibrary(m);return a;}
  a.module=m;a.descriptor=d;a.validate=v;a.event=e;a.vulkan=vk;a.presentation=present;a.submission=submit;a.constants=constants;a.assembly=assembly;a.backend=backend;return a;
 }();return selected;
}
inline bool ExternalFgObserver(){return Current().module&&Current().descriptor.externalFgObserver!=0;}
class LegacyWindow {
public:
 void Begin(uint32_t frame,uint32_t){Call(Event::Token,frame,0);}
 bool Constants(uint32_t frame,uint32_t view,uint32_t){return Call(Event::Constants,frame,view);}
 bool Frame(uint32_t view,uint32_t,uint32_t& frame)const{return Call(Event::Frame,0,view,&frame);}
 void Present(){Call(Event::Present,0,0);}
 void Reset(){Call(Event::Reset,0,0);}
 bool Ambiguous()const{return Call(Event::Ambiguous,0,0);}
private:
 static bool Call(Event e,uint32_t f,uint32_t v,uint32_t* out=nullptr){const auto& a=Current();const auto key=CurrentOutputKey();FrameEventRequest r;r.event=e;r.frame=f;r.view=v;r.owner=key.owner;r.device=key.device;return a.event&&a.event(&r,sizeof(r),out);}
};
}

namespace optishade::route {
// Vulkan ownership is authoritative inside the XP12 adapter. The common
// interception layer transports API events; it cannot select an MSFS owner.
class VulkanRegistry {
 vkowner::Registry fallback;
 bool Run(VulkanRequest r,VulkanResult& result){const auto& a=Current();const bool ok=a.vulkan&&a.vulkan(&r,sizeof(r),&result,sizeof(result));owner=result.owner;return ok;}
 bool XPlane()const{return CurrentSimulator()==Simulator::XPlane12;}
public:
 vkowner::Registry::Chain owner{};
 void surface(uint64_t a,uint64_t b,uint64_t c){if(!XPlane()){fallback.surface(a,b,c);owner=fallback.owner;return;}VulkanRequest r;r.event=VulkanEvent::Surface;r.a=a;r.b=b;r.c=c;VulkanResult out;Run(r,out);}
 bool swapchain(uint64_t a,uint64_t b,uint64_t c,bool eligible,bool alive){if(!XPlane()){bool ok=fallback.swapchain(a,b,c,eligible,alive);owner=fallback.owner;return ok;}VulkanRequest r;r.event=VulkanEvent::Swapchain;r.a=a;r.b=b;r.c=c;r.eligible=eligible;r.alive=alive;VulkanResult out;return Run(r,out);}
 void queue(uint64_t a,uint64_t b,uint32_t family,bool graphics){if(!XPlane()){fallback.queue(a,b,family,graphics);owner=fallback.owner;return;}VulkanRequest r;r.event=VulkanEvent::Queue;r.a=a;r.b=b;r.family=family;r.graphics=graphics;VulkanResult out;Run(r,out);}
 vkowner::Registry::Surface lookup(uint64_t a){if(!XPlane())return fallback.lookup(a);VulkanRequest r;r.event=VulkanEvent::Lookup;r.a=a;VulkanResult out;Run(r,out);return out.surface;}
 vkowner::Registry::Queue findQueue(uint64_t a){if(!XPlane())return fallback.findQueue(a);VulkanRequest r;r.event=VulkanEvent::FindQueue;r.a=a;VulkanResult out;Run(r,out);return out.queue;}
 uint64_t swapchainGeneration(uint64_t device,uint64_t swapchain){if(!XPlane())return vkowner::FindSwapchainGeneration(device,swapchain,fallback.chains);VulkanRequest r;r.event=VulkanEvent::FindSwapchainGeneration;r.a=device;r.b=swapchain;VulkanResult out;return Run(r,out)?out.generation:0;}
 bool present(uint64_t a,uint32_t count,const uint64_t* chains,const uint32_t* images,uint32_t imageCount){if(!XPlane())return fallback.present(a,count,chains,images,imageCount);VulkanRequest r;r.event=VulkanEvent::Present;r.a=a;r.count=count;r.chains=chains;r.images=images;r.imageCount=imageCount;VulkanResult out;return Run(r,out);}
 void eraseChain(uint64_t a){Erase(VulkanEvent::EraseChain,a);}
 void eraseSurface(uint64_t a){Erase(VulkanEvent::EraseSurface,a);}
 void eraseDevice(uint64_t a){Erase(VulkanEvent::EraseDevice,a);}
 void eraseInstance(uint64_t a){Erase(VulkanEvent::EraseInstance,a);}
 void Erase(VulkanEvent event,uint64_t a){if(!XPlane()){switch(event){case VulkanEvent::EraseChain:fallback.eraseChain(a);break;case VulkanEvent::EraseSurface:fallback.eraseSurface(a);break;case VulkanEvent::EraseDevice:fallback.eraseDevice(a);break;case VulkanEvent::EraseInstance:fallback.eraseInstance(a);break;default:break;}owner=fallback.owner;return;}VulkanRequest r;r.event=event;r.a=a;VulkanResult out;Run(r,out);}
};
}

#include "PresentationOwner.h"
namespace optishade::route {
class PresentationOwner {
 optishade::PresentationOwner generic;
 bool Managed()const {auto id=CurrentSimulator();return id==Simulator::Msfs2024||id==Simulator::Msfs2020||id==Simulator::Unknown;}
 PresentationResult Call(PresentationEvent event,HWND window,const void* chain,bool claim=false){PresentationRequest r;r.event=event;r.window=reinterpret_cast<uint64_t>(window);r.swapchain=reinterpret_cast<uint64_t>(chain);r.claim=claim;PresentationResult out;const auto& a=Current();if(a.presentation)a.presentation(&r,sizeof(r),&out,sizeof(out));return out;}
public:
 bool Accept(HWND window,bool claim=false,const void* chain=nullptr){return Managed()?Call(PresentationEvent::Accept,window,chain,claim).accepted!=0:generic.Accept(window,claim,chain);}
 uint64_t Generation(HWND window,const void* chain){return Managed()?Call(PresentationEvent::Generation,window,chain).generation:generic.Generation(window,chain);}
 uint64_t Advance(const void* chain){return Managed()?Call(PresentationEvent::Advance,nullptr,chain).generation:generic.Advance(chain);}
 void Retire(HWND window,const void* chain){if(Managed())Call(PresentationEvent::Retire,window,chain);else generic.Retire(window,chain);}
};
}

namespace optishade::route {
inline bool Submission(SubmissionRequest r,SubmissionResult& out){const auto& a=Current();return a.submission&&a.submission(&r,sizeof(r),&out,sizeof(out));}
}

namespace optishade::route {
template<class T> class ConstantWindow {
 bool Call(ConstantEvent event,uint32_t frame,uint32_t view,const T* in=nullptr,T* out=nullptr){
  static_assert(sizeof(T)<=1024);ConstantRequest r;r.event=event;r.frame=frame;r.view=view;r.payload=in;r.payloadBytes=in?sizeof(T):0;const auto key=CurrentOutputKey();r.owner=key.owner;r.device=key.device;
  const auto& a=Current();return a.constants&&a.constants(&r,sizeof(r),out,out?sizeof(T):0);
 }
public:
 bool AcceptedConstants(uint32_t frame,uint32_t view,const T* value){return Call(ConstantEvent::Store,frame,view,value);}
 bool Constants(uint32_t frame,uint32_t view,T& out){return Call(ConstantEvent::Read,frame,view,nullptr,&out);}
 void Consume(uint32_t view,uint32_t frame){Call(ConstantEvent::Consume,frame,view);}
 void Reset(){Call(ConstantEvent::Reset,0,0);}
};
}

namespace optishade::route { inline bool NativeFrame(const AssemblyRequest& r,ProducerFrame* out=nullptr){const auto& a=Current();return a.assembly&&a.assembly(&r,sizeof(r),out,out?sizeof(*out):0);} }

namespace optishade::route {
template<class T,unsigned Slot> T* Backend(uint32_t requestAbi=BackendRequest{}.abi){
 const auto& a=Current();if(!a.backend)return nullptr;
 BackendRequest r;r.abi=requestAbi;r.slot=Slot;r.create=[]()->void*{return new T{};};r.destroy=[](void* p){delete static_cast<T*>(p);};void* out=nullptr;
 return a.backend(&r,sizeof(r),&out)?static_cast<T*>(out):nullptr;
}
template<unsigned Slot> bool ReleaseBackend(){const auto& a=Current();if(!a.backend)return false;BackendRequest r;r.slot=Slot;r.release=true;void* out=nullptr;return a.backend(&r,sizeof(r),&out);}
}

namespace optishade::route {
template<class T,unsigned Slot> T& Owned(){
 if(auto* state=Backend<T,Slot>())return *state;
 // Unsupported executables retain the generic engine path. Managed routes
 // reject work at their API boundary when their adapter could not be loaded.
 static T generic{};return generic;
}
}

#include "OutputDomain.h"
namespace optishade::route {
inline OutputDirectory& Outputs(){return Owned<OutputDirectory,25>();}
inline thread_local unsigned outputScopeIndex=OutputDirectory::Capacity;
inline unsigned OutputIndex(){return outputScopeIndex<OutputDirectory::Capacity?outputScopeIndex:Outputs().selected.load();}
inline OutputKey CurrentOutputKey(){return Outputs().Key(OutputIndex());}
class OutputScope {
    unsigned previous=outputScopeIndex;
    bool valid=false;
public:
    explicit OutputScope(OutputKey key){const auto index=Outputs().FindOrAdd(key);valid=index<OutputDirectory::Capacity;if(valid){outputScopeIndex=index;Outputs().selected=index;}}
    explicit OutputScope(unsigned index){valid=index<OutputDirectory::Capacity;if(valid)outputScopeIndex=index;}
    ~OutputScope(){outputScopeIndex=previous;}
    explicit operator bool()const{return valid;}
    OutputScope(const OutputScope&)=delete;
};
template<class T,unsigned Slot> T& OutputOwned(){return Owned<OutputStorage<T>,Slot>().Get(OutputIndex());}
template<class T,unsigned Slot> void ReleaseOutputOwned(unsigned index){Owned<OutputStorage<T>,Slot>().Release(index);}
template<class F> void ForEachOutput(F&& fn){
    OutputScope generic(0u);fn();
    const auto entries=Outputs().Snapshot();
    for(unsigned i=1;i<OutputDirectory::Capacity;++i)if(entries[i].used){OutputScope scope(i);fn();}
}
}
