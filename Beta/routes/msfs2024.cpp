#include "../shared/SimulatorRoute.h"
using namespace optishade::route;
#include "accepted_token_window.h"
static const Descriptor descriptor{sizeof(Descriptor),Abi,Simulator::Msfs2024,Api::Dx12,1};
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
