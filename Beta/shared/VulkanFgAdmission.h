// OptiShade additions, GPL-3.0-or-later. Inactive native Vulkan FG admission.
// Scalar contracts only: the existing Vulkan route retains all objects,
// submission ordering, output/eye generations and retirement responsibility.
#pragma once
#include "RenderingCapability.h"
#include "FormatViewContract.h"
#include <cstdint>
#include <string>

namespace optishade::vulkan_fg {
enum class Phase { Waiting, Unsupported, Qualified, Retiring, Cancelled };
enum class Source { Unknown, EngineTemporal, CoreEstimated };
enum class Reason {
    WaitingForOwner, StaleOwner, WrongProcess, RetiredOwner, CancelledRequest,
    WrongBinding, MissingView, UnsupportedSurface, ProviderUnavailable,
    WaitingForProvider, WrongProvider, WaitingForSource, WrongSource,
    MissingInputs, MissingSubmission, MissingPresentation, Qualified
};
inline const char* Name(Phase phase){
    switch(phase){case Phase::Waiting:return "waiting";case Phase::Unsupported:return "unsupported";
        case Phase::Qualified:return "qualified";case Phase::Retiring:return "retiring";case Phase::Cancelled:return "cancelled";}
    return "waiting";
}
inline const char* Name(Reason reason){
    switch(reason){
    case Reason::WaitingForOwner:return "Waiting for the actual XP12 Vulkan presentation owner.";
    case Reason::StaleOwner:return "The Vulkan owner sample is stale; a prior output cannot qualify a new frame.";
    case Reason::WrongProcess:return "The process identity does not match the current XP12 session.";
    case Reason::RetiredOwner:return "The existing Vulkan owner is retiring or has lost its device.";
    case Reason::CancelledRequest:return "The qualification belongs to a cancelled or superseded request.";
    case Reason::WrongBinding:return "Device, output, view, format or source generation changed; qualification must be repeated.";
    case Reason::MissingView:return "An exact engine view/eye has not been associated with this Vulkan output.";
    case Reason::UnsupportedSurface:return "This output format, colour space, extent or view is outside the admitted contract.";
    case Reason::ProviderUnavailable:return "XP12 Vulkan frame generation is unavailable: Streamline is not integrated before Vulkan device creation, and no supported per-frame engine colour/depth/motion/timing source is exposed to this route.";
    case Reason::WaitingForProvider:return "Waiting for a provider capability bound to this exact Vulkan device and output.";
    case Reason::WrongProvider:return "The observed provider identity differs from the selected provider.";
    case Reason::WaitingForSource:return "Waiting for the engine's frame and temporal-input identity.";
    case Reason::WrongSource:return "Estimated NR guides or another frame source cannot establish native Vulkan FG inputs.";
    case Reason::MissingInputs:return "Engine colour, depth, motion and frame timing are not a complete current input bundle.";
    case Reason::MissingSubmission:return "The existing owner has not established the input lease and submission dependency.";
    case Reason::MissingPresentation:return "A provider presentation contract has not been bound to the existing output owner.";
    case Reason::Qualified:return "The inactive source contract is complete; provider integration and physical output qualification remain required.";
    }
    return "Waiting for qualification.";
}

// Raw format/colour-space identifiers remain API-specific. Matching is exact;
// support is supplied by the existing format/view policy, never guessed here.
struct Binding {
    uint32_t pid=0;
    uint64_t birth=0,device=0,luid=0,output=0,generation=0,queue=0;
    uint32_t queueFamily=UINT32_MAX,format=0,colourSpace=0,width=0,height=0,layers=0;
    uint32_t view=UINT32_MAX,viewCount=0;
    bool viewKnown=false,projection=false;
    uint64_t sourceGeneration=0;
    std::string executableIdentity,providerIdentity,sourceIdentity;
    bool operator==(const Binding&)const=default;
    bool OwnerKnown()const {
        return pid&&birth&&device&&luid&&output&&generation&&queue&&queueFamily!=UINT32_MAX&&
            format&&width&&height&&layers;
    }
};
struct Owner {
    Binding binding;
    uint64_t sampledAt=0,requestRevision=0,sourceFrame=0;
    bool xplaneNative=false,graphicsQueue=false,presentObserved=false;
    bool surfaceMetadataValid=false;
    bool retiring=false,cancelled=false;
    Evidence surface=Evidence::Unknown;
    // This is a delegate capability, not DLL presence or GPU model support.
    Evidence providerAvailable=Evidence::Unknown;
};
struct Inputs {
    Binding binding;
    uint64_t sampledAt=0,requestRevision=0,frame=0;
    Source source=Source::Unknown;
    bool providerBound=false,colour=false,depth=false,motion=false,timing=false;
    bool inputLease=false,submissionDependency=false,presentationContract=false;
};
struct Qualification {
    Phase phase=Phase::Waiting;
    Reason reason=Reason::WaitingForOwner;
    bool ownerBound=false;
    // Deliberately constant: this contract is not an activation delegate.
    bool canActivate=false;
};
inline bool Fresh(uint64_t tick,uint64_t now){return tick&&now>=tick&&now-tick<=3000;}
inline Qualification Assess(const Owner& current,const Inputs& input,uint64_t now,
                            uint32_t processId,uint64_t processBirth){
    auto result=[](Phase phase,Reason reason,bool owner=false){return Qualification{phase,reason,owner,false};};
    if(current.cancelled)return result(Phase::Cancelled,Reason::CancelledRequest);
    if(current.retiring)return result(Phase::Retiring,Reason::RetiredOwner);
    if(!current.xplaneNative||!current.binding.OwnerKnown()||!current.graphicsQueue||!current.presentObserved)
        return result(Phase::Waiting,Reason::WaitingForOwner);
    if(!processId||!processBirth||current.binding.pid!=processId||current.binding.birth!=processBirth)
        return result(Phase::Unsupported,Reason::WrongProcess);
    if(!Fresh(current.sampledAt,now))return result(Phase::Waiting,Reason::StaleOwner);
    if(!current.surfaceMetadataValid||current.surface==Evidence::No)return result(Phase::Unsupported,Reason::UnsupportedSurface,true);
    if(current.providerAvailable==Evidence::No)return result(Phase::Unsupported,Reason::ProviderUnavailable,true);
    if(current.providerAvailable!=Evidence::Yes||!input.providerBound||!Fresh(input.sampledAt,now))
        return result(Phase::Waiting,Reason::WaitingForProvider,true);
    if(current.requestRevision!=input.requestRevision)return result(Phase::Cancelled,Reason::CancelledRequest,true);
    if(current.binding.providerIdentity.empty()||input.binding.providerIdentity!=current.binding.providerIdentity)
        return result(Phase::Unsupported,Reason::WrongProvider,true);
    if(!(input.binding==current.binding))return result(Phase::Waiting,Reason::WrongBinding,true);
    if(!format_view::ValidateView({current.binding.output,current.binding.generation,
       current.binding.view,current.binding.viewCount,current.binding.projection,current.binding.viewKnown}))
        return result(Phase::Waiting,Reason::MissingView,true);
    if(current.surface!=Evidence::Yes)return result(Phase::Waiting,Reason::UnsupportedSurface,true);
    if(current.binding.executableIdentity.empty()||current.binding.sourceIdentity.empty()||!current.binding.sourceGeneration||!input.frame||!current.sourceFrame)
        return result(Phase::Waiting,Reason::WaitingForSource,true);
    if(input.frame!=current.sourceFrame)return result(Phase::Waiting,Reason::WrongBinding,true);
    if(input.source!=Source::EngineTemporal)return result(input.source==Source::Unknown?Phase::Waiting:Phase::Unsupported,Reason::WrongSource,true);
    if(!input.colour||!input.depth||!input.motion||!input.timing)return result(Phase::Waiting,Reason::MissingInputs,true);
    if(!input.inputLease||!input.submissionDependency)return result(Phase::Waiting,Reason::MissingSubmission,true);
    if(!input.presentationContract)return result(Phase::Waiting,Reason::MissingPresentation,true);
    return result(Phase::Qualified,Reason::Qualified,true);
}
}
