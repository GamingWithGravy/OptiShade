// OptiShade additions, GPL-3.0-or-later. Control-plane intent; owns no GPU work.
#pragma once
#include "MfgControl.h"
#include "RenderingCapability.h"
#include <array>
#include <mutex>

namespace optishade::automatic {
using Json=mfg::Json;
enum class Feature : unsigned {Nr, Upscaling, FrameGeneration, Count};
inline const char* Name(Feature feature){
    return feature==Feature::Nr?"nr":feature==Feature::Upscaling?"upscaling":"frameGeneration";
}
struct Intent {
    bool enabled=false;
    std::array<bool,3> automatic{};
};
struct Context {
    uint64_t luid=0,deviceGeneration=0,outputGeneration=0;
    std::string outputId,api,architecture,providerIdentity,modelIdentity,driverVersion,deviceIdentity,deviceGenerationSource;
    uint32_t view=0;
    bool Valid()const{return luid&&deviceGeneration&&outputGeneration&&!outputId.empty()&&!deviceIdentity.empty()&&!deviceGenerationSource.empty()&&!api.empty()&&api!="unknown"&&!architecture.empty()&&architecture!="unknown";}
    bool operator==(const Context& b)const{
        return luid==b.luid&&deviceGeneration==b.deviceGeneration&&outputGeneration==b.outputGeneration&&
            outputId==b.outputId&&api==b.api&&architecture==b.architecture&&view==b.view&&
            providerIdentity==b.providerIdentity&&modelIdentity==b.modelIdentity&&driverVersion==b.driverVersion&&deviceIdentity==b.deviceIdentity&&deviceGenerationSource==b.deviceGenerationSource;
    }
};
struct FeatureStatus {
    Evidence admitted=Evidence::Unknown,prepared=Evidence::Unknown,inputs=Evidence::Unknown;
    bool canConfigure=false,requestKnown=false,requested=false,accepted=false;
    bool gameControlled=false;
    bool recorded=false,gpuCompleted=false,composed=false,generated=false,presentSubmitted=false,displayVerified=false;
    bool failed=false,restartRequired=false;
    uint64_t controlRevision=0,explicitOffRevision=0;
    std::string route,reason;
};
struct Observation {Context context;std::array<FeatureStatus,3> features{};};
enum class ApplyCode {Accepted,Queued,Busy,Conflict,RestartRequired,Unavailable};
struct ApplyResult {ApplyCode code=ApplyCode::Unavailable;uint64_t revision=0;};
inline const char* Name(ApplyCode code){
    switch(code){case ApplyCode::Accepted:return "accepted";case ApplyCode::Queued:return "queued";
    case ApplyCode::Busy:return "busy";case ApplyCode::Conflict:return "conflict";
    case ApplyCode::RestartRequired:return "restart_required";default:return "unavailable";}
}
inline bool ReadIntent(const Json& j,Intent& out){
    if(!j.is_object()||j.size()!=4||!mfg::Bool(j,"enabled",out.enabled))return false;
    for(unsigned i=0;i<3;++i){std::string value;if(!mfg::String(j,Name(Feature(i)),value)||(value!="auto"&&value!="off"))return false;out.automatic[i]=value=="auto";}
    return true;
}
inline Json IntentJson(const Intent& value){
    Json result={{"enabled",value.enabled}};
    for(unsigned i=0;i<3;++i)result[Name(Feature(i))]=value.automatic[i]?"auto":"off";
    return result;
}
inline Json LuidJson(uint64_t value){return value?Json(std::to_string(value)):Json(nullptr);}
inline Json OutputJson(const std::string& value){return value.empty()?Json(nullptr):Json(value);}
inline Json EvidenceJson(Evidence value){return value==Evidence::Unknown?Json(nullptr):Json(value==Evidence::Yes);}
inline bool SameContext(const Json& request,const Context& context){
    uint64_t device=0,output=0,view=0;
    return mfg::U64(request,"deviceGeneration",device,0,UINT64_MAX)&&
        mfg::U64(request,"outputGeneration",output,0,UINT64_MAX)&&
        mfg::U64(request,"view",view,0,UINT32_MAX)&&view==context.view&&
        request.contains("renderingAdapterLuid")&&request.contains("outputId")&&request.contains("deviceIdentity")&&request.contains("deviceGenerationSource")&&
        request.contains("api")&&request["api"]==OutputJson(context.api)&&
        request.contains("architecture")&&request["architecture"]==OutputJson(context.architecture)&&
        request.contains("providerIdentity")&&request["providerIdentity"]==context.providerIdentity&&
        request.contains("modelIdentity")&&request["modelIdentity"]==context.modelIdentity&&
        request.contains("driverVersion")&&request["driverVersion"]==context.driverVersion&&
        request["deviceIdentity"]==OutputJson(context.deviceIdentity)&&request["deviceGenerationSource"]==context.deviceGenerationSource&&
        request["renderingAdapterLuid"]==LuidJson(context.luid)&&request["outputId"]==OutputJson(context.outputId)&&
        device==context.deviceGeneration&&output==context.outputGeneration;
}
inline const char* State(const Context& context,const FeatureStatus& status,bool desired){
    // Auto Off cannot disable an engine-owned stage. Keep real observed game
    // activity visible without inventing an OptiShade request or acceptance.
    if(status.gameControlled&&!status.canConfigure&&context.Valid()&&
        status.admitted==Evidence::Yes&&status.prepared==Evidence::Yes&&status.inputs==Evidence::Yes)
        return status.recorded||status.generated?"game_controlled_work_reported":"game_controlled";
    if(!desired)return status.requestKnown&&status.requested?"stop_pending":"off";
    if(!context.Valid())return "waiting_for_rendering_context";
    if(status.restartRequired)return "restart_required";
    if(status.admitted==Evidence::No)return "unsupported";
    if(status.prepared==Evidence::No)return "needs_setup";
    if(status.failed)return "failed";
    if(status.admitted!=Evidence::Yes||status.prepared!=Evidence::Yes)return "waiting_for_capability";
    if(status.inputs!=Evidence::Yes)return "waiting_for_game_inputs";
    if(status.gameControlled&&!status.canConfigure)return status.recorded||status.generated?"game_controlled_work_reported":"game_controlled";
    if(!status.accepted)return "request_not_accepted";
    if(status.displayVerified)return "output_verified";
    if(status.presentSubmitted)return "presentation_submitted";
    if(status.gpuCompleted)return "gpu_completed";
    if(status.recorded||status.generated)return "work_reported";
    return "accepted_output_unverified";
}

// One session decision delegates each feature to its existing owning runtime.
// A snapshot is read-only. Only Configure invokes setters; a manager holding
// current Play intent may retry a waiting plan after observing its new context.
class Controller {
    std::mutex mutex_;
    Observation last_{};
    Intent desired_{};
    bool initialized_=false;
    uint64_t revision_=0,epoch_=0,nrExplicitOffSeen_=0;
    std::array<bool,3> pending_{};
    std::array<uint64_t,3> submittedRevision_{};
    std::array<std::string,3> commandState_{};
    void Observe(const Observation& current){
        const bool contextChanged=!initialized_||!(current.context==last_.context);
        const auto priorPending=pending_;
        const auto priorSubmitted=submittedRevision_;
        // A model receipt or provider can become ready after its identity is
        // already known. Make that decision change a fresh plan so the existing
        // manager retries retained intent. Per-frame input/activity publication
        // does not churn plans or trigger repeated setter calls.
        bool planChanged=contextChanged;
        if(initialized_)for(unsigned i=0;i<3;++i){
            const auto& next=current.features[i];const auto& old=last_.features[i];
            planChanged|=next.admitted!=old.admitted||next.prepared!=old.prepared||
                next.canConfigure!=old.canConfigure||next.failed!=old.failed||
                next.restartRequired!=old.restartRequired||next.route!=old.route;
        }
        bool changed=planChanged;
        if(planChanged){++epoch_;pending_={};submittedRevision_={};commandState_={};}
        for(unsigned i=0;i<3;++i){
            const auto& next=current.features[i];const auto& old=last_.features[i];
            // An explicit Off also cancels a request that is still waiting for
            // preparation. Ordinary tuning/observation revisions are not Off.
            if(i==unsigned(Feature::Nr)&&next.explicitOffRevision>nrExplicitOffSeen_){
                if(initialized_&&desired_.automatic[i]&&next.explicitOffRevision!=priorSubmitted[i]){
                    desired_.automatic[i]=false;pending_[i]=false;commandState_[i]="manual_off";changed=true;
                }
                // Keep the process-scoped watermark through a temporarily
                // missing observation. Its later return is not a new action.
                nrExplicitOffSeen_=next.explicitOffRevision;
            }
            if(initialized_&&next.controlRevision!=old.controlRevision){
                changed=true;
                // A later explicit Off wins over a retained Auto request.
                // Suspension leaves the owner's requested bit set and does
                // not enter this branch. Our own matching acknowledgement is
                // also distinguished from an external/manual revision.
                // NR intent has a process-wide revision. FG revisions may
                // reset on provider ownership changes, so only carry a newer
                // Off across a binding refresh within the same known provider.
                const bool sameOwner=i==unsigned(Feature::Nr)||
                    (!current.context.providerIdentity.empty()&&current.context.providerIdentity==last_.context.providerIdentity);
                const bool comparable=!contextChanged||(sameOwner&&next.controlRevision>old.controlRevision);
                if(comparable&&next.requestKnown&&!next.requested&&desired_.automatic[i]&&
                    (old.requested||priorPending[i])&&next.controlRevision!=priorSubmitted[i]){
                    desired_.automatic[i]=false;pending_[i]=false;commandState_[i]="manual_off";
                }
            }
            if(pending_[i]&&next.requestKnown&&next.requested==(desired_.enabled&&desired_.automatic[i])&&
                (next.controlRevision!=old.controlRevision||next.controlRevision==submittedRevision_[i]))pending_[i]=false;
        }
        if(changed)++revision_;
        initialized_=true;last_=current;
    }
    Json ReadLocked()const{
        const auto& context=last_.context;
        Json result={{"revision",revision_},{"planId","plan-"+std::to_string(epoch_)},{"desired",IntentJson(desired_)},
            {"renderingAdapterLuid",LuidJson(context.luid)},{"deviceGeneration",context.deviceGeneration},
            {"outputId",OutputJson(context.outputId)},{"outputGeneration",context.outputGeneration},{"view",context.view},
            {"deviceIdentity",OutputJson(context.deviceIdentity)},{"deviceGenerationSource",context.deviceGenerationSource},
            {"api",context.api.empty()?Json(nullptr):Json(context.api)},{"architecture",context.architecture.empty()?Json(nullptr):Json(context.architecture)},
            {"providerIdentity",context.providerIdentity},{"modelIdentity",context.modelIdentity},{"driverVersion",context.driverVersion},
            {"state",!desired_.enabled?"off":context.Valid()?"requested":"waiting_for_rendering_context"},
            {"reason","Requested, accepted, recorded, GPU-completed and displayed output are separate observations."},
            {"activationScope","current_process_birth_only"},{"features",Json::object()}};
        bool waiting=false,failed=false,restart=false,allVerified=true,any=false;
        for(unsigned i=0;i<3;++i){
            const auto& value=last_.features[i];const bool requested=desired_.enabled&&desired_.automatic[i];
            const std::string state=!requested&&value.requestKnown&&value.requested&&!pending_[i]?"manual_control":State(context,value,requested);
            result["features"][Name(Feature(i))]={{"requested",requested},{"runtimeRequested",value.requestKnown?Json(value.requested):Json(nullptr)},
                {"accepted",value.accepted&&value.requestKnown&&value.requested==requested},{"route",value.route},{"state",state},{"reason",value.reason},{"controlRevision",value.controlRevision},{"explicitOffRevision",value.explicitOffRevision},
                {"command",commandState_[i]},{"pending",pending_[i]},
                {"admitted",EvidenceJson(value.admitted)},{"prepared",EvidenceJson(value.prepared)},{"inputs",EvidenceJson(value.inputs)},{"canConfigure",value.canConfigure},
                {"controlOwner",value.gameControlled?"game":value.canConfigure?"optishade":"unknown"},
                {"observed",{{"recorded",value.recorded},{"gpuCompleted",value.gpuCompleted},{"composed",value.composed},
                    {"generated",value.generated},{"presentSubmitted",value.presentSubmitted},{"displayVerified",value.displayVerified}}}};
            if(requested){any=true;allVerified&=value.displayVerified;waiting|=state.find("waiting_")==0||state=="needs_setup"||state=="request_not_accepted";
                failed|=state=="unsupported"||state=="failed";restart|=value.restartRequired;}
        }
        if(desired_.enabled&&context.Valid())result["state"]=restart?"restart_required":failed?"partial":waiting?"waiting_for_inputs_or_setup":any&&allVerified?"output_verified":"requested_output_unverified";
        return result;
    }
public:
    Json Read(const Observation& observation){std::lock_guard lock(mutex_);Observe(observation);return ReadLocked();}
    template<class Apply> Json Configure(const Json& request,const Observation& observation,Apply&& apply){
        std::lock_guard lock(mutex_);Observe(observation);
        auto response=[&](const char* code){return Json{{"code",code},{"auto",ReadLocked()}};};
        uint64_t revision=0;std::string plan;Intent requested;
        if(!mfg::U64(request,"revision",revision,0,UINT64_MAX)||!mfg::String(request,"planId",plan)||
            !request.contains("desired")||!ReadIntent(request["desired"],requested))return response("invalid_settings");
        if(revision!=revision_||plan!="plan-"+std::to_string(epoch_)||!SameContext(request,last_.context))return response("conflict");
        desired_=requested;++revision_;
        const char* code=last_.context.Valid()?"accepted":"waiting_for_rendering_context";
        // A later feature's restart/unavailable result must not hide a stale
        // baseline or busy owner that still needs the manager's bounded retry.
        auto priority=[](std::string_view value){
            return value=="conflict"?6:value=="busy"?5:value=="restart_required"?4:
                value=="unavailable"?3:value=="waiting_for_rendering_context"?2:value=="queued"?1:0;
        };
        auto promote=[&](const char* next){if(priority(next)>priority(code))code=next;};
        for(unsigned i=0;i<3;++i){
            const auto& feature=last_.features[i];const bool on=desired_.enabled&&desired_.automatic[i];
            commandState_[i].clear();
            // Off can stop an existing owner while its context is unavailable.
            // Enabling only delegates after real device/output admission and
            // preparation; the runtime still validates current frame inputs.
            if(on&&(!last_.context.Valid()||feature.admitted!=Evidence::Yes||feature.prepared!=Evidence::Yes))continue;
            if(!feature.canConfigure){if(on)commandState_[i]="unavailable";continue;}
            if(on&&feature.failed){commandState_[i]="failed";continue;}
            if(feature.restartRequired&&on){commandState_[i]="restart_required";promote("restart_required");continue;}
            if(feature.requestKnown&&feature.requested==on&&feature.accepted){commandState_[i]="already_requested";continue;}
            const auto applied=apply(Feature(i),on,feature.controlRevision);
            commandState_[i]=Name(applied.code);submittedRevision_[i]=applied.revision;
            pending_[i]=applied.code==ApplyCode::Queued;
            if(applied.code==ApplyCode::Accepted){last_.features[i].requestKnown=true;last_.features[i].requested=on;
                last_.features[i].controlRevision=applied.revision;last_.features[i].accepted=true;}
            else promote(Name(applied.code));
        }
        return response(code);
    }
};
}
