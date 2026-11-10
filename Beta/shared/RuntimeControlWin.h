// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include "MfgBackgroundStatus.h"
#include "RuntimeControlPipe.h"
#include "NrObservation.h"
#include "NativeMfgControl.h"
#include "NeuralRuntimePreparationWin.h"
#include "RuntimeRenderContext.h"
#include "XPlaneVulkanProcess.h"
#include "../optiscaler/OptiScaler/framegen/dlssg/AmpereMfgLoader.h"
#include "../optiscaler/OptiScaler/dlssnr/DlssNrFeature_Dx12.h"

namespace optishade::control {
class RuntimeAuto {
    automatic::Controller controller_;
    const uint32_t processId_=GetCurrentProcessId();
    const uint64_t processBirth_=mfg::file::Birth();
    const bool xp12Native_;
    neural_preparation::Service preparation_;
    struct Bound {
        runtime_render::Snapshot render;
        neural_preparation::Snapshot preparation;
        automatic::Observation observation;
        mfg::Snapshot provider;
        native_mfg::Snapshot native;
        nr_observation::Snapshot nr;
        bool nativeBound=false,sourceBound=false,xp12Native=false;
        vulkan_fg::Qualification vulkan;
    };
    static bool NativeBound(const Bound& bound,uint64_t now){
        const auto& sample=bound.render.native;const auto& state=bound.native;const auto& prepared=bound.preparation;
        return runtime_render::NativeCapabilityBound(bound.render,state,now)&&prepared.fresh&&
            state.maximum>=1&&state.maximum<=6&&prepared.device==sample.device&&prepared.luid==sample.luid&&
            prepared.providerImageHashed&&prepared.nativeProvider==sample.provider&&prepared.nativeGeneration==sample.generation;
    }
    Bound Observe(){
        Bound bound;const auto now=GetTickCount64();bound.render=runtime_render::State().Read();
        bound.preparation=preparation_.Read();
        auto& service=mfg::UiStatus();bound.provider=service.Read(service.worker.Peek());
        bound.native=native_mfg::Session().Read();
        auto& observation=bound.observation;
        bound.xp12Native=xp12Native_||bound.render.vulkanFg.xplaneNative;
        const bool current=bound.render.Fresh(now)&&(!bound.xp12Native||bound.render.vulkanFg.xplaneNative);
        if(current)observation.context=bound.render.context;
        const bool preparedCurrent=current&&bound.preparation.fresh&&bound.preparation.device==bound.render.device.identity&&bound.preparation.luid==bound.render.device.luid;
        if(preparedCurrent){observation.context.modelIdentity=bound.preparation.modelIdentity;observation.context.driverVersion=bound.preparation.driver;}
        auto& nr=observation.features[unsigned(automatic::Feature::Nr)];
        nr.route="game-bound NR candidate";nr.canConfigure=true;
        nr_session::State request;
        if(DlssNr::TryReadSessionState(request)){
            nr.requestKnown=true;nr.requested=request.requested;nr.controlRevision=request.revision;nr.explicitOffRevision=request.explicitOffRevision;
            nr.accepted=true; // Session intent only; model work is separate below.
        }
        if(preparedCurrent){nr.admitted=bound.preparation.hardware;nr.prepared=bound.preparation.prepared;nr.reason=bound.preparation.reason;}
        else nr.reason="Waiting for current rendering-device and model preparation evidence.";
        uint64_t outputEvidenceAt=0;
        // A positive result must come from this output's existing lane. No
        // all-output claim is made for NGX/ReShade owners not mapped to it yet.
        if(current&&nr_observation::State().TryReadForOutput(now,bound.render.device.identity,bound.render.output,
             bound.render.context.outputGeneration,bound.render.context.view,bound.nr)&&bound.nr.owner.runtime){
            const auto& value=bound.nr;nr.route=nr_observation::Name(value.owner.route);
            const bool sameRequest=value.request==nr.controlRevision;
            if(sameRequest)outputEvidenceAt=std::max({value.evaluated?value.evaluatedAt:0,
                value.completed?value.completedAt:0,value.submitted?value.submittedAt:0});
            const bool recentRecord=sameRequest&&value.evaluated&&value.effective==nr.controlRevision&&
                value.evaluatedAt&&now>=value.evaluatedAt&&now-value.evaluatedAt<1500;
            nr.inputs=recentRecord||value.recent?Evidence::Yes:Evidence::Unknown;
            nr.recorded=recentRecord&&value.request==nr.controlRevision&&
                (value.output.observed&(1u<<unsigned(optishade::route::OutputStage::NrRecorded)));
            nr.gpuCompleted=value.recent&&value.completed&&value.request==nr.controlRevision;
            nr.composed=nr.gpuCompleted&&value.composed;nr.failed=value.fenceSignalFailed;
            const auto stage=unsigned(optishade::route::OutputStage::PresentSubmitted);
            nr.presentSubmitted=nr.recorded&&(value.output.observed&(1u<<stage))&&!(value.output.failed&(1u<<stage));
        }
        // ReShade owners and a D3D11 transport use their own runtime/generation
        // keys. A direct backbuffer-resource match can associate their exact
        // existing ticket with this output without guessing the newest lane.
        const auto& linked=bound.render.nr;
        if(current&&(linked.ticket||linked.failed)&&linked.revision==nr.controlRevision&&linked.sampledAt&&
           linked.sampledAt>=outputEvidenceAt&&now>=linked.sampledAt&&now-linked.sampledAt<1500){
            const auto ticket=nr_observation::State().ReadTicket(linked.ticket);
            if(ticket&&ticket->revision==nr.controlRevision){
                nr.route=nr_observation::Name(ticket->owner.route);
                nr.inputs=ticket->evaluated?Evidence::Yes:Evidence::Unknown;
                nr.recorded=ticket->evaluated;nr.gpuCompleted=ticket->completed;
                nr.composed=ticket->completed&&ticket->composed&&linked.compositionReachedOutput;
                nr.failed=linked.failed||(ticket->output.failed&(1u<<unsigned(optishade::route::OutputStage::Submitted)));
                const auto stage=unsigned(optishade::route::OutputStage::PresentSubmitted);
                nr.presentSubmitted=nr.recorded&&(ticket->output.observed&(1u<<stage))&&!(ticket->output.failed&(1u<<stage));
                nr.reason="Exact NR ticket associated with a resource of the current primary output; composition/copy-back is reported separately from presentation and scanout.";
            }else if(!linked.ticket&&linked.failed){
                nr.inputs=Evidence::Unknown;nr.recorded=nr.gpuCompleted=nr.composed=nr.presentSubmitted=false;
                nr.failed=true;nr.reason="The current NR transaction failed before an evaluation ticket was available; the failed colour resource belongs to this output and request.";
            }
        }
        auto& sr=observation.features[unsigned(automatic::Feature::Upscaling)];
        sr.route="game reconstruction input";
        sr.reason="The game must create its upscaling route; this owner has no independent enable callback. Existing game settings are retained.";
        const auto& gameSr=bound.render.upscaling;
        if(current&&gameSr.device==bound.render.device.identity&&gameSr.luid==bound.render.device.luid&&
           gameSr.sampledAt&&now>=gameSr.sampledAt&&now-gameSr.sampledAt<=1500){
            sr.route="game-controlled "+gameSr.backend;sr.admitted=sr.prepared=Evidence::Yes;
            sr.gameControlled=true;
            // Game evaluation is activity, never an OptiShade request or acknowledgement.
            sr.inputs=gameSr.succeeded?Evidence::Yes:Evidence::Unknown;sr.recorded=gameSr.succeeded;
            sr.failed=!gameSr.succeeded&&!gameSr.missingInput;
            // A successful game feature evaluation is device-bound evidence.
            // It does not identify the feature's final swapchain/output image.
            sr.reason="The existing game reconstruction owner selected this backend and evaluated on the rendering device. Final output association, GPU completion and scanout are unverified.";
        }
        auto& fg=observation.features[unsigned(automatic::Feature::FrameGeneration)];
        const auto& provider=bound.provider;
        bound.sourceBound=current&&provider.sourceBuilt&&provider.live&&provider.verified&&provider.owned&&
            provider.renderingLuid==bound.render.device.luid&&provider.deviceGeneration&&
            mfg::source::BoundToDevice(bound.render.device.identity);
        bound.nativeBound=NativeBound(bound,now);
        if(bound.xp12Native){
            auto& owner=bound.render.vulkanFg;
            if(preparedCurrent&&!bound.preparation.executableHash.empty())
                owner.binding.executableIdentity=bound.preparation.executable+":"+bound.preparation.executableHash;
            bound.vulkan=vulkan_fg::Assess(owner,{},now,processId_,processBirth_);
            fg.route="XP12 native Vulkan FG admission";
            // A preparatory contract never becomes a callable provider. The
            // Vulkan route has no native FG input/presentation delegate yet.
            fg.admitted=bound.vulkan.phase==vulkan_fg::Phase::Unsupported?Evidence::No:Evidence::Unknown;
            fg.prepared=owner.providerAvailable==Evidence::No?Evidence::No:Evidence::Unknown;
            fg.reason=vulkan_fg::Name(bound.vulkan.reason);
            fg.restartRequired=bound.vulkan.phase==vulkan_fg::Phase::Retiring;
            bound.nativeBound=bound.sourceBound=false;
            // Publishing Vulkan status must not dispatch to the D3D12 NR
            // session setter or claim that a helper's request belongs here.
            nr={};
            nr.route="XP12 Vulkan NR bridge";
            nr.reason="The existing Vulkan NR bridge retains its own controls; this Auto connection only publishes inactive Vulkan FG qualification.";
            sr={};sr.route="XP12 game reconstruction";
            sr.reason="No game-owned reconstruction evaluation has been associated with this Vulkan output.";
        }else if(provider.detected){
            // An installed compatibility owner is retained. A failed owner
            // does not authorize silently replacing its DLL with native FG.
            fg.route=provider.sourceBuilt?"owned source MFG":"owned compatibility MFG";
            fg.prepared=provider.verified&&provider.owned?Evidence::Yes:Evidence::No;
            fg.reason=provider.message;fg.controlRevision=provider.status.requestRevision;
            fg.requestKnown=provider.verified&&provider.owned;
            fg.requested=!provider.settings.overrideOff&&(provider.settings.followGame?provider.status.gameFgOn:provider.settings.multiplier>1);
            fg.canConfigure=provider.editable&&bound.sourceBound;
            fg.admitted=bound.sourceBound&&policy::AllowsSourceFamily(provider.renderingFamily)?Evidence::Yes:Evidence::Unknown;
            if(bound.sourceBound&&!policy::AllowsSourceFamily(provider.renderingFamily))fg.admitted=Evidence::No;
            fg.inputs=bound.sourceBound&&provider.status.bridgeReady?Evidence::Yes:Evidence::Unknown;
            fg.accepted=bound.sourceBound&&provider.status.savedRequestObserved&&provider.status.setOptionsAccepted&&
                !provider.status.pending&&provider.status.appliedRevision==provider.status.requestRevision&&
                provider.status.appliedFgOn==fg.requested;
            // Upstream status has no renderer LUID/device binding. Its existing
            // manual save route remains available; Auto cannot invent a match.
            if(!provider.sourceBuilt)fg.reason="Compatibility provider retained; its current status lacks an exact rendering-device binding for Auto.";
            observation.context.providerIdentity=provider.identity;
        }else if(bound.nativeBound){
            const auto& native=bound.native;
            fg.route=bound.render.native.passive?"passive native DLSS-G":"native DLSS-G callback";
            fg.admitted=fg.prepared=Evidence::Yes;fg.canConfigure=!bound.render.native.passive&&native.controllable;
            fg.gameControlled=bound.render.native.passive;
            fg.controlRevision=native.revision;fg.requestKnown=native.dynamic||native.desired>=0||native.attempted;
            fg.requested=native.dynamic||native.desired>0||(native.desired<0&&native.acceptedGenerated>0);
            fg.accepted=native.attempted&&native.result==0&&!native.pending&&native.acceptedRevision==native.revision;
            fg.failed=native.attempted&&native.result!=0;
            fg.restartRequired=bound.render.native.passive;
            fg.reason=bound.render.native.passive?
                "Real native capability observed without changing game calls; compatibility-provider preparation requires a subsequent game start.":
                "Requests use the game's next options callback. Provider state intervals do not prove complete inputs, generated images or scanout.";
            observation.context.providerIdentity=bound.preparation.providerIdentity;
        }else{
            fg.route="waiting for native FG pipeline";
            fg.reason="No fresh provider capability is bound to the current accepted Streamline device and primary output.";
        }
        return bound;
    }
    automatic::ApplyResult Apply(Bound& bound,automatic::Feature feature,bool on,uint64_t revision){
        using Code=automatic::ApplyCode;automatic::ApplyResult result{Code::Unavailable,revision};
        if(bound.xp12Native)return result; // No D3D12 feature dispatch for this Vulkan route.
        auto apply=[&]{
            if(feature==automatic::Feature::Nr){
                const auto request=DlssNr::TrySetSessionEnabled(on,revision);
                result={request.code==nr_session::Code::Accepted?Code::Accepted:request.code==nr_session::Code::Conflict?Code::Conflict:Code::Busy,request.revision};return;
            }
            if(feature!=automatic::Feature::FrameGeneration)return;
            if(bound.render.vulkanFg.xplaneNative)return; // No native Vulkan FG activation delegate.
            if(bound.provider.detected){
                auto& service=mfg::UiStatus();const auto current=service.Read(service.worker.Peek());
                if(!mfg::SameControlContext(current,bound.provider)||current.status.requestRevision!=revision){result.code=Code::Conflict;return;}
                if(!bound.sourceBound||!mfg::source::BoundToDevice(bound.render.device.identity)){result.code=Code::Unavailable;return;}
                auto request=current.settings;
                request.overrideOff=!on;
                if(on){
                    // Preserve a currently selected valid mode. Re-enabling
                    // from Off starts with the provider's conservative 2x.
                    if(request.followGame||request.multiplier<2||request.multiplier>current.status.maxMultiplier){request.followGame=false;request.dynamic=false;request.multiplier=2;}
                }else {request.followGame=true;request.dynamic=false;}
                Json checked;std::string reason;
                if(!mfg::MergeAdapterSettings(current.sourceBuilt,checked,current.settings,request,current.status,reason)){result.code=Code::Unavailable;return;}
                result.code=service.Save(request,current)?Code::Queued:Code::Busy;return;
            }
            const auto current=native_mfg::Session().Read();
            if(!bound.nativeBound||bound.render.native.passive){result.code=bound.render.native.passive?Code::RestartRequired:Code::Unavailable;return;}
            if(current.generation!=bound.native.generation||current.provider!=bound.native.provider||current.view!=bound.native.view||current.revision!=revision){result.code=Code::Conflict;return;}
            const int generated=on?(current.dynamic?-1:current.desired>0?current.desired:1):0;
            if(!native_mfg::Session().Request(current,generated,on&&current.dynamic)){result.code=Code::Conflict;return;}
            result={Code::Queued,native_mfg::Session().Read().revision};
        };
        if(!on&&feature==automatic::Feature::Nr){apply();return result;}
        const auto applied=runtime_render::State().WithCurrent(bound.render,GetTickCount64(),apply);
        if(applied==runtime_render::Apply::Busy)result.code=Code::Busy;
        else if(applied==runtime_render::Apply::Changed)result.code=Code::Conflict;
        return result;
    }
    static Json VulkanCapability(const Bound& bound){
        const auto& owner=bound.render.vulkanFg;const auto& identity=owner.binding;
        const auto& qualification=bound.vulkan;const auto now=GetTickCount64();
        return {{"kind","xp12_native_vulkan_fg"},{"scope","inactive_admission_contract"},
            {"applicable",bound.xp12Native},{"state",vulkan_fg::Name(qualification.phase)},
            {"reason",vulkan_fg::Name(qualification.reason)},{"ownerBound",qualification.ownerBound},{"canActivate",false},
            {"pid",identity.pid},{"processBirth",std::to_string(identity.birth)},
            {"executableIdentity",identity.executableIdentity},{"api","vulkan"},
            {"renderingAdapterLuid",automatic::LuidJson(identity.luid)},{"device",identity.device},
            {"output",identity.output},{"generation",identity.generation},{"queue",identity.queue},{"queueFamily",identity.queueFamily},
            {"format",identity.format},{"colourSpace",identity.colourSpace},{"width",identity.width},{"height",identity.height},{"layers",identity.layers},
            {"view",identity.viewKnown?Json(identity.view):Json(nullptr)},{"viewKnown",identity.viewKnown},
            {"viewCount",identity.viewCount?Json(identity.viewCount):Json(nullptr)},
            {"projection",identity.viewKnown?Json(identity.projection):Json(nullptr)},{"surfaceMetadataValid",owner.surfaceMetadataValid},
            {"providerIdentity",identity.providerIdentity},{"sourceIdentity",identity.sourceIdentity},{"sourceGeneration",identity.sourceGeneration},
            {"providerDelegateAvailable",owner.providerAvailable==Evidence::Unknown?Json(nullptr):Json(owner.providerAvailable==Evidence::Yes)},
            {"sampleAgeMs",owner.sampledAt&&now>=owner.sampledAt?Json(now-owner.sampledAt):Json(nullptr)},
            {"engineInputsVerified",false},{"inputLeaseVerified",false},{"providerPresentationVerified",false},
            {"generatedOutputVerified",false},{"displayVerified",false}};
    }
    static Json Capability(const Bound& bound){
        const auto& live=bound.render;const auto& prepared=bound.preparation;
        const bool known=bound.nativeBound;const auto now=GetTickCount64();
        return {{"kind","native_streamline_dlssg"},{"observed",known},{"passive",known&&live.native.passive},
            {"api",live.context.api},{"architecture",live.context.architecture},{"vendorId",live.device.vendor},{"deviceId",live.device.id},
            {"renderingFamily",live.computeKnown?Json(live.computeFamily):Json(nullptr)},
            {"computeMajor",live.computeKnown?Json(live.computeMajor):Json(nullptr)},{"computeMinor",live.computeKnown?Json(live.computeMinor):Json(nullptr)},
            {"renderingAdapterLuid",automatic::LuidJson(live.device.luid)},{"deviceIdentity",automatic::OutputJson(live.context.deviceIdentity)},
            {"deviceGeneration",live.context.deviceGeneration},{"deviceGenerationSource",live.context.deviceGenerationSource},
            {"outputId",automatic::OutputJson(live.context.outputId)},{"outputGeneration",live.context.outputGeneration},{"view",known?Json(bound.native.view):Json(nullptr)},
            {"executable",prepared.executable},{"executableSha256",prepared.executableHash},
            {"driverVersion",prepared.driver},
            {"providerIdentity",prepared.providerIdentity},{"providerFileSha256",prepared.providerFileHash},{"providerImageHashed",prepared.providerImageHashed},
            {"providerFilePath",prepared.providerFilePath},
            {"maximumAdditionalFrames",known?Json(bound.native.maximum):Json(nullptr)},
            {"sampleAgeMs",live.native.sampledAt&&now>=live.native.sampledAt?Json(now-live.native.sampledAt):Json(nullptr)},
            {"evidence","forwarded_game_get_state"},{"inputEvidence","not_established_by_capability_query"},{"outputEvidence","not_established_by_capability_query"}};
    }
public:
    explicit RuntimeAuto(std::filesystem::path component,bool sourceReserved=false,bool xp12Native=false):
        xp12Native_(xp12Native),preparation_(std::move(component),[sourceReserved,xp12Native]{if(!sourceReserved&&!xp12Native)AmpereMfgLoader::TrySetup();}){}
    void Start(){preparation_.worker.Start();}
    Json Read(){auto bound=Observe();auto result=controller_.Read(bound.observation);result["nativeFgCapability"]=Capability(bound);result["vulkanFgQualification"]=VulkanCapability(bound);return result;}
    Json Configure(const Json& request){auto bound=Observe();return controller_.Configure(request,bound.observation,[&](automatic::Feature feature,bool on,uint64_t revision){return Apply(bound,feature,on,revision);});}
    Json ConfigureNr(const Json& request){
        bool enabled=false;uint64_t revision=0;
        if(!request.contains("settings")||!request["settings"].is_object()||!mfg::Bool(request["settings"],"enabled",enabled)||
           !mfg::U64(request,"revision",revision,0,UINT64_MAX))return {{"code","invalid_settings"}};
        auto bound=Observe();
        if(!automatic::SameContext(request,bound.observation.context))return {{"code","conflict"}};
        if(enabled&&!bound.observation.context.Valid())return {{"code","waiting_for_rendering_context"}};
        const auto result=Apply(bound,automatic::Feature::Nr,enabled,revision);
        return {{"code",automatic::Name(result.code)},{"requestRevision",result.revision},{"activationScope","current_process_birth_only"}};
    }
};
inline Json NrSnapshot(){
 nr_session::State request;if(!DlssNr::TryReadSessionState(request))return {{"state","busy"}};
 nr_observation::Snapshot nr;if(!nr_observation::State().TryRead(GetTickCount64(),nr))return {{"state","busy"}};
 return {{"state",nr.recent?"recent":"not_recent"},{"route",nr_observation::Name(nr.owner.route)},
    {"requested",request.requested},{"requestRevision",request.revision},{"explicitOffRevision",request.explicitOffRevision},{"effectiveRevision",nr.effective},
    {"recorded",nr.evaluated},{"submitted",nr.submitted},{"completed",nr.completed},{"composed",nr.composed},{"visibleRequested",nr.visible},
    {"recordedFrame",nr.frame},{"completedFrame",nr.completedFrame},{"recordedTicket",nr.ticket},{"completedTicket",nr.completedTicket},
    {"sampleAgeMs",nr.age==UINT64_MAX?Json(nullptr):Json(nr.age)},{"gpuMilliseconds",nr.gpuMilliseconds?Json(*nr.gpuMilliseconds):Json(nullptr)},
    {"scope","most_recent_observed_lane; Auto selects its exact primary output separately"},
    {"outputEvidence","composition and submission observations do not certify scanout or continuity"}};
}
inline void StartRuntimeControl(bool sourceReserved=false) noexcept {
 static std::atomic<bool> started{false};if(started.exchange(true))return;
 try{
  // Process-lifetime workers never join from DllMain or use GPU objects on IPC.
  HMODULE self=nullptr;
  if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,reinterpret_cast<LPCWSTR>(&StartRuntimeControl),&self))return;
  wchar_t path[32768]{};const auto count=GetModuleFileNameW(self,path,32768);
  if(!count||count>=32768)return;
  mfg::file::Handle image(CreateFileW(path,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
  if(!image)return;const auto component=mfg::file::Final(image.value).parent_path();if(component.empty())return;
  auto* automatic=new RuntimeAuto(component,sourceReserved,
      xplane_layer::ProcessRoute().xplane&&xplane_layer::UsesNativeEffects(xplane_layer::CurrentRoute()));automatic->Start();
  auto* endpoint=new Endpoint(GetCurrentProcessId(),std::to_string(mfg::file::Birth()),[]{
   auto& service=mfg::UiStatus();auto value=service.worker.Peek();Observation result;
   result.snapshot=service.Read(value);result.completed=value->completedRequest;result.message=value->saveMessage;
   result.saveState=value->save==SaveProgress::Saved?"saved":value->save==SaveProgress::Failed?"failed":"none";return result;
  },[](const mfg::Settings& request,const mfg::Snapshot& baseline){return mfg::UiStatus().Save(request,baseline);},NrSnapshot,
  [automatic]{return automatic->Read();},[automatic](const Json& request){return automatic->Configure(request);},
  [automatic](const Json& request){return automatic->ConfigureNr(request);});
  auto* server=new PipeServer(GetCurrentProcessId(),std::to_string(mfg::file::Birth()),[endpoint](const std::string& request){return endpoint->Handle(request);});server->Start();
 }catch(...){/* Control transport failure cannot stop graphics or change providers. */}
}
}
