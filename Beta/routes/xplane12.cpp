#include "../shared/SimulatorRoute.h"
using namespace optishade::route;
class Window {
 bool ready=false,ambiguous=false;uint32_t frame=0,view=0;
public:
 void Begin(uint32_t){} // MSFS2020 retains its previously shipped contract.
 bool Constants(uint32_t value,uint32_t viewport){if(ambiguous)return false;if(ready&&(value!=frame||viewport!=view)){ambiguous=true;ready=false;return false;}frame=value;view=viewport;ready=true;return true;}
 bool Frame(uint32_t viewport,uint32_t& value)const{if(!ready||ambiguous||viewport!=view)return false;value=frame;return true;}
 void Present(){ready=ambiguous=false;}
 void Reset(){Present();frame=view=0;}
 bool Ambiguous()const{return ambiguous;}
};
static const Descriptor descriptor{sizeof(Descriptor),Abi,Simulator::XPlane12,Api::Vulkan,0};
static bool RouteFrameAllowed(const FrameContext*);
#include "adapter_exports.inl"

namespace {optishade::vkowner::Registry owners;std::mutex ownerLock;}
extern "C" __declspec(dllexport) bool OptiShadeRouteVulkan(const VulkanRequest* r,uint32_t bytes,VulkanResult* out,uint32_t outBytes){
 if(!r||!out||bytes!=sizeof(*r)||outBytes!=sizeof(*out)||r->size!=sizeof(*r)||r->abi!=Abi)return false;
 std::lock_guard guard(ownerLock);*out={};bool ok=true;
 switch(r->event){
 case VulkanEvent::Surface:owners.surface(r->a,r->b,r->c);break;
 case VulkanEvent::Swapchain:ok=owners.swapchain(r->a,r->b,r->c,r->eligible,r->alive);break;
 case VulkanEvent::Queue:owners.queue(r->a,r->b,r->family,r->graphics);break;
 case VulkanEvent::Present:ok=owners.present(r->a,r->count,r->chains,r->images,r->imageCount);break;
 case VulkanEvent::Lookup:out->surface=owners.lookup(r->a);break;
 case VulkanEvent::FindQueue:out->queue=owners.findQueue(r->a);break;
 case VulkanEvent::FindSwapchainGeneration:out->generation=optishade::vkowner::FindSwapchainGeneration(r->a,r->b,owners.chains);break;
 case VulkanEvent::EraseChain:owners.eraseChain(r->a);break;
 case VulkanEvent::EraseSurface:owners.eraseSurface(r->a);break;
 case VulkanEvent::EraseDevice:owners.eraseDevice(r->a);break;
 case VulkanEvent::EraseInstance:owners.eraseInstance(r->a);break;
 default:ok=false;break;}
 out->owner=owners.owner;return ok;
}

static bool RouteFrameAllowed(const FrameContext* f){
 std::lock_guard guard(ownerLock);const auto queue=owners.findQueue(f->queue);
 return owners.owner.chain==f->presentationOwner&&owners.owner.generation==f->presentationGeneration&&
 owners.owner.device==f->device&&queue.device==f->device&&queue.graphics;
}
