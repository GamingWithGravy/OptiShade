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
static const Descriptor descriptor{sizeof(Descriptor),Abi,Simulator::Msfs2020,Api::Dx12,0};
static bool RouteFrameAllowed(const FrameContext*);
#include "adapter_exports.inl"

static bool RouteFrameAllowed(const FrameContext* f){
 PresentationRequest p;p.event=PresentationEvent::Generation;p.window=f->window;p.swapchain=f->presentationOwner;PresentationResult owner;
 if(!OptiShadeRoutePresentation(&p,sizeof(p),&owner,sizeof(owner))||!owner.accepted||owner.generation!=f->presentationGeneration)return false;
 SubmissionRequest r;r.event=SubmissionEvent::Query;r.command=f->command;SubmissionResult submission;
 if(!OptiShadeRouteSubmission(&r,sizeof(r),&submission,sizeof(submission)))return false;
 auto* queue=reinterpret_cast<ID3D12CommandQueue*>(submission.queue);
 bool valid=submission.device==f->device&&submission.queue==f->queue&&submission.epoch==f->submissionEpoch;
 if(queue)queue->Release();return valid;
}
