#include "../shared/SimulatorRoute.h"
#include <mutex>
#include <map>
#include <tuple>
namespace {std::mutex lock;std::map<std::pair<uint64_t,uint64_t>,Window> windows;}
extern "C" __declspec(dllexport) bool OptiShadeRouteQuery(optishade::route::Descriptor* out,uint32_t bytes){
 if(!out||bytes!=sizeof(*out))return false;*out=descriptor;return true;
}
extern "C" __declspec(dllexport) bool OptiShadeRouteValidate(const optishade::route::FrameContext* f,uint32_t bytes){
 using namespace optishade::route;
 return f&&bytes==sizeof(*f)&&f->size==sizeof(*f)&&f->abi==Abi&&f->simulator==descriptor.simulator&&f->api==descriptor.api&&
 f->device&&f->queue&&f->colour&&f->depth&&f->motion&&f->presentationOwner&&f->presentationGeneration&&f->width>=64&&f->height>=64&&RouteFrameAllowed(f);
}
extern "C" __declspec(dllexport) bool OptiShadeRouteFrameEvent(const FrameEventRequest* r,uint32_t bytes,uint32_t* out){
 using namespace optishade::route;std::lock_guard guard(lock);
 if(!r||bytes!=sizeof(*r)||r->size!=sizeof(*r)||r->abi!=Abi||descriptor.api!=Api::Dx12)return false;
 const auto key=std::make_pair(r->device,r->owner);
 if(r->event==Event::Reset){windows.erase(key);return true;}
 auto it=windows.find(key);if(it==windows.end()){if(windows.size()>=32)return false;it=windows.try_emplace(key).first;}
 auto& window=it->second;
 switch(r->event){case Event::Token:window.Begin(r->frame);return true;
 case Event::Constants:return window.Constants(r->frame,r->view);case Event::Present:window.Present();return true;
 case Event::Frame:return out&&window.Frame(r->view,*out);case Event::Ambiguous:return window.Ambiguous();default:return false;}
}

// The selected simulator DLL owns its presentation lifetime. Loading the XP12
// route never creates a DXGI owner; its Vulkan registry remains authoritative.
#include "../shared/PresentationOwner.h"
#include "../shared/D3D12SubmissionRegistry.h"
namespace { SubmissionRegistry submissions{descriptor.externalFgObserver!=0}; }
extern "C" __declspec(dllexport) bool OptiShadeRoutePresentation(const PresentationRequest* r,uint32_t bytes,PresentationResult* out,uint32_t outBytes){
 if(!r||!out||bytes!=sizeof(*r)||outBytes!=sizeof(*out)||r->size!=sizeof(*r)||r->abi!=Abi||descriptor.api!=Api::Dx12)return false;
 static optishade::PresentationOwner owner;
 *out={};auto hwnd=reinterpret_cast<HWND>(r->window);auto chain=reinterpret_cast<const void*>(r->swapchain);
 switch(r->event){
 case PresentationEvent::Accept:out->accepted=owner.Accept(hwnd,r->claim!=0,chain);out->generation=owner.Generation(hwnd,chain);break;
 case PresentationEvent::Generation:out->generation=owner.Generation(hwnd,chain);out->accepted=out->generation!=0;break;
 case PresentationEvent::Advance:out->generation=owner.Advance(chain);out->accepted=out->generation!=0;/* Recording leases are device/command owned, not invalidated by another output resize. */break;
 case PresentationEvent::Retire:if(owner.Generation(hwnd,chain)){owner.Retire(hwnd,chain);}out->accepted=1;break;
 default:return false;
 }return true;
}

#include "../shared/D3D12SubmissionRegistry.h"
extern "C" __declspec(dllexport) bool OptiShadeRouteSubmission(const SubmissionRequest* r,uint32_t bytes,SubmissionResult* out,uint32_t outBytes){
 if(!r||!out||bytes!=sizeof(*r)||outBytes!=sizeof(*out)||r->size!=sizeof(*r)||r->abi!=Abi||descriptor.api!=Api::Dx12)return false;
 *out={};
 if(r->event==SubmissionEvent::Clear){submissions.Clear();return true;}
 if(r->event==SubmissionEvent::Observe)return submissions.Observe(reinterpret_cast<ID3D12CommandQueue*>(r->queue),reinterpret_cast<ID3D12CommandList*>(r->command));
 if(r->event==SubmissionEvent::Query)return submissions.Query(reinterpret_cast<ID3D12CommandList*>(r->command),*out,r->generation);
 if(r->event==SubmissionEvent::Recording||r->event==SubmissionEvent::Reset)return submissions.Recording(reinterpret_cast<ID3D12CommandList*>(r->command),*out,r->event==SubmissionEvent::Reset);
 if(r->event==SubmissionEvent::Close)return submissions.Close(reinterpret_cast<ID3D12CommandList*>(r->command));
 if(r->event==SubmissionEvent::Pin||r->event==SubmissionEvent::Unpin)return submissions.Pin(reinterpret_cast<ID3D12CommandList*>(r->command),r->generation,r->event==SubmissionEvent::Pin);
 return false;
}

#include "../shared/FrameConstants.h"
#include <array>
#include <cstring>
namespace { struct ConstantPayload {uint32_t bytes=0;std::array<unsigned char,1024> data{};};std::map<std::tuple<uint64_t,uint64_t,uint32_t>,FrameConstantWindow<ConstantPayload>> constantOutputs;std::mutex constantsMutex; }
extern "C" __declspec(dllexport) bool OptiShadeRouteConstants(const ConstantRequest* r,uint32_t bytes,void* out,uint32_t outBytes){
 if(!r||bytes!=sizeof(*r)||r->size!=sizeof(*r)||r->abi!=Abi||(descriptor.simulator!=Simulator::Msfs2024&&descriptor.simulator!=Simulator::Unknown))return false;
 std::lock_guard guard(constantsMutex);
 const auto key=std::make_tuple(r->device,r->owner,r->view);
 if(r->event==ConstantEvent::Reset){for(auto it=constantOutputs.begin();it!=constantOutputs.end();){if(std::get<0>(it->first)==r->device&&std::get<1>(it->first)==r->owner)it=constantOutputs.erase(it);else ++it;}return true;}
 auto it=constantOutputs.find(key);if(it==constantOutputs.end()){if(constantOutputs.size()>=128)return false;it=constantOutputs.try_emplace(key).first;}
 auto& frameConstants=it->second;
 switch(r->event){
 case ConstantEvent::Reset:frameConstants.Reset();return true;
 case ConstantEvent::Consume:if(!frameConstants.Matches(r->frame,r->view))return false;frameConstants.Consume(r->view,r->frame);return true;
 case ConstantEvent::Store:{if(!r->payload||!r->payloadBytes||r->payloadBytes>1024)return false;ConstantPayload value;value.bytes=r->payloadBytes;memcpy(value.data.data(),r->payload,r->payloadBytes);return frameConstants.AcceptedConstants(r->frame,r->view,&value);}
 case ConstantEvent::Read:{ConstantPayload value;if(!out||!frameConstants.Constants(r->frame,r->view,value)||value.bytes!=outBytes)return false;memcpy(out,value.data.data(),value.bytes);return true;}
 default:return false;
 }
}

#include "../shared/NativeFgAssembly.h"
namespace { NativeFgAssembly nativeFrames; }
extern "C" __declspec(dllexport) bool OptiShadeRouteNativeFrame(const AssemblyRequest* r,uint32_t bytes,ProducerFrame* out,uint32_t outBytes){
 // AssemblyRequest carries its own ABI (NativeFgAssembly.h), not the route ABI.
 // Checking it against the route ABI (5) refused every request (abi 4), so no
 // TAA pre-FG frame was ever assembled: with the game's FG on, TAA NR stayed
 // paused and worked only while unfocusing paused FG (OSD-HP3C/3RRK/HAV3).
 if(!r||bytes!=sizeof(*r)||r->size!=sizeof(*r)||r->abi!=AssemblyRequest{}.abi||(descriptor.simulator!=Simulator::Msfs2024&&descriptor.simulator!=Simulator::Unknown))return false;
 switch(r->event){
 case AssemblyEvent::Begin:return out&&outBytes==sizeof(*out)&&nativeFrames.Begin(r->identity,*out);
 case AssemblyEvent::Resource:return nativeFrames.Resource(r->identity,r->index,r->resource);
 case AssemblyEvent::Constants:return nativeFrames.Constants(r->identity,r->constants,r->constantBytes);
 case AssemblyEvent::Publish:return out&&outBytes==sizeof(*out)&&nativeFrames.Publish(r->identity,*out);
 case AssemblyEvent::Retire:return nativeFrames.Retire(r->identity);
 case AssemblyEvent::Observe:return nativeFrames.Observe(r->ticket,r->stage,r->result,r->success);
 case AssemblyEvent::Health:return out&&outBytes==sizeof(*out)&&nativeFrames.Health(r->ticket,out->health);
 default:return false;
 }
}

#include "../shared/RouteOwnedBackend.h"
namespace {struct BackendSlot {void* value=nullptr;void(*destroy)(void*)=nullptr;};std::array<BackendSlot,32> backendSlots{};std::recursive_mutex backendMutex;}
extern "C" __declspec(dllexport) bool OptiShadeRouteBackend(const BackendRequest* r,uint32_t bytes,void** out){
 if(!r||!out||bytes!=sizeof(*r)||r->size!=sizeof(*r)||r->abi!=Abi||r->slot>=backendSlots.size())return false;
 std::lock_guard guard(backendMutex);auto& slot=backendSlots[r->slot];
 if(r->release){auto previous=slot;slot={};*out=nullptr;if(previous.value&&previous.destroy)previous.destroy(previous.value);return true;}
 if(!slot.value){if(!r->create||!r->destroy)return false;slot.value=r->create();slot.destroy=r->destroy;}
 *out=slot.value;return *out!=nullptr;
}
