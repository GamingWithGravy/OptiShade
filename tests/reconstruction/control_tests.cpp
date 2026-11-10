#include "RuntimeControlProtocol.h"
#include "MfgControl.h"
#include "../../Beta/shared/NativeMfgControl.h"
#include "../../Beta/shared/PassiveFgCapabilityProbe.h"
#include "../../Beta/shared/ExternalFgTelemetry.h"
#include "../../Beta/installer/OptionalMFG/Source203040/native/nvidia_mfg_policy.h"
#ifdef _WIN32
#include "RuntimeControlPipe.h"
#endif
#include <iostream>
#include <stdexcept>
#include <memory>
#include <atomic>
using namespace optishade;
#define CHECK(x) if(!(x))throw std::runtime_error(#x)
int main(int argc,char** argv){try{
 {
  int lookups=0,observations=0;void* original=reinterpret_cast<void*>(uintptr_t(0x1234));
  const bool available=passive_fg::ProbeStateFunction(0,[&](void** out){++lookups;*out=original;return 0;},[&](int result,bool found){++observations;CHECK(result==0&&found);});
  CHECK(available&&lookups==1&&observations==1);
  const bool unavailable=passive_fg::ProbeStateFunction(0,[&](void** out){++lookups;*out=nullptr;return 1;},[&](int result,bool found){++observations;CHECK(result==1&&!found);});
  CHECK(!unavailable&&lookups==2&&observations==2);
 }
 {
  external_fg_telemetry::Recorder telemetry;
  auto sample=telemetry.RecordAcceptedOptions(1,1);
  CHECK(sample.maxAcceptedAdditionalFrames==1);
  sample=telemetry.RecordAcceptedOptions(1,2);
  CHECK(sample.lastAcceptedAdditionalFrames==2&&sample.maxAcceptedAdditionalFrames==2);
  sample=telemetry.RecordAcceptedOptions(0,0);
  CHECK(sample.lastAcceptedMode==0&&sample.lastAcceptedAdditionalFrames==0&&sample.maxAcceptedAdditionalFrames==2);
  sample=telemetry.RecordStateSample(1);
  sample=telemetry.RecordStateSample(3);
  sample=telemetry.RecordStateSample(2);
  CHECK(sample.maxFramesSinceStateQuery==3);
  sample=telemetry.RecordPresentCall(51,1000,0x1234);
  CHECK(sample.presentCallCount==1&&sample.lastPresentThreadId==51&&sample.lastPresentSwapchainId==0x1234);
  sample=telemetry.RecordStateCall(51,1016);
  CHECK(sample.stateQueryCount==1&&sample.lastStateThreadId==51);
  CHECK(sample.hasPresentSample&&sample.lastStateThreadMatchesPresent);
  CHECK(sample.lastStateAgeSincePresentMs==16&&sample.presentCallCountAtLastState==1);
  sample=telemetry.RecordStateCall(52,1033);
  CHECK(sample.stateQueryCount==2&&sample.hasStateInterval&&sample.lastStateIntervalMs==17);
  CHECK(sample.hasPresentSample&&!sample.lastStateThreadMatchesPresent);
  CHECK(telemetry.ShouldPersistBlockedState(2000,1));
  CHECK(!telemetry.ShouldPersistBlockedState(2500,1));
  CHECK(telemetry.ShouldPersistBlockedState(2500,2));
  CHECK(!telemetry.ShouldPersistBlockedState(2999,2));
  CHECK(telemetry.ShouldPersistBlockedState(3500,2));
 }
 if(argc>1&&std::string(argv[1])=="policy"){
  for(const char* channel:{"stable","beta","unknown"})for(unsigned family:{0u,20u,30u,40u,50u,60u})for(unsigned f=0;f<256;++f)
   std::cout<<channel<<","<<family<<","<<f<<","<<policy::Select(channel,family,f&1,f&2,f&4,f&8,f&16,f&32,f&64,f&128)<<"\n";
  return 0;
 }
 {
  mfg::Json liveJson={{"product","RTXMFG"},{"version",40},{"pid",42},{"processBirth",100},{"heartbeat",100},
   {"gpuFamily",1},{"safeMaximumMultiplier",6},{"bridgeReady",true},{"gameFrameGenerationOn",true},
   {"appliedFrameGenerationOn",true},{"activeWrapperObserved",true},{"dynamicMfgSupportKnown",true},
   {"dynamicMfgSupported",false},{"numFramesToGenerateMax",1},{"applied",true},{"pending",false},
   {"setOptionsAccepted",true},{"requestRevision",10},{"appliedRevision",10},{"appliedMultiplier",2},
   {"setOptionsResult",0},{"appliedMode","fixed"},{"reflexControlAvailable",false},
   {"dlssgPresetSelectionFrozen",true},{"dlssgPresetRestartRequired",false},{"dlssgPresetLatched",2},
   {"dlssgPresetObservedValid",true},{"dlssgPresetObserved",2},{"followGame",false},{"mode","fixed"},
   {"multiplier",2},{"dynamicTargetFrameRate",0},{"dlssgPresetRequested",2},{"vsyncMode",0},
   {"reflexFrameLimitFps",0},{"generatedOnlyDebug",false},{"intervalLoggingEnabled",true},
   {"dynamicExperimental56",false}};
  mfg::Settings saved;saved.followGame=false;saved.multiplier=2;saved.preset=2;mfg::Live parsed;
  CHECK(mfg::ReadLive(liveJson,42,100,101,saved,parsed));
  CHECK(parsed.runtimeMaximumMultiplier==2&&parsed.maxMultiplier==2&&parsed.policyMaximumMultiplier==6&&!parsed.canDynamic);
  auto unsupported=saved;unsupported.multiplier=3;mfg::Json persisted=mfg::Json::object();std::string error;
  CHECK(!mfg::MergeSettings(persisted,saved,unsupported,parsed,error));
  CHECK(error=="This MFG mode is not available from the current game backend.");
  liveJson["dynamicMfgSupported"]=true;liveJson["numFramesToGenerateMax"]=5;
  CHECK(mfg::ReadLive(liveJson,42,100,101,saved,parsed));
  CHECK(parsed.runtimeMaximumMultiplier==6&&parsed.maxMultiplier==6&&parsed.canDynamic);
  liveJson["safeMaximumMultiplier"]=4;
  CHECK(mfg::ReadLive(liveJson,42,100,101,saved,parsed));
  CHECK(parsed.runtimeMaximumMultiplier==6&&parsed.maxMultiplier==4&&parsed.policyMaximumMultiplier==4);
  const auto olderFourX=nvidia_mfg_policy::DecideCapacity(nvidia_mfg_policy::Tier::eFourX,true,1);
  CHECK(olderFourX.effectiveMaximumMultiplier==4);
  mfg::Live olderStatus;olderStatus.gpuFamily=30;olderStatus.minMultiplier=2;
  olderStatus.maxMultiplier=olderStatus.policyMaximumMultiplier=olderFourX.effectiveMaximumMultiplier;
  auto olderRequest=saved;olderRequest.multiplier=4;
  mfg::Json olderDocument=mfg::Json::object();error.clear();
  CHECK(mfg::CanPreconfigureFixed(true,olderStatus));
  CHECK(mfg::MergeAdapterSettings(true,olderDocument,saved,olderRequest,olderStatus,error));
  CHECK(olderDocument["multiplier"]==4&&olderDocument["followGame"]==false);
  CHECK(nvidia_mfg_policy::DecideCapacity(nvidia_mfg_policy::Tier::eUnknown,false,1).effectiveMaximumMultiplier==2);
 }
 {
  native_mfg::Control provider;provider.Observe(0x1234,7,5);auto baseline=provider.Read();
  native_mfg::UiDraft draft;draft.Observe(baseline);CHECK(!draft.dirty);
  CHECK(draft.Stage(baseline,3));CHECK(draft.dirty&&draft.desired==3);
  CHECK(draft.Submit(provider,baseline));CHECK(draft.awaiting&&!draft.dirty);
  auto request=provider.ForCall(0x1234,7);CHECK(request.desired==3);
  provider.Complete(request,3,0);auto accepted=provider.Read();draft.Observe(accepted);
  CHECK(!draft.awaiting&&!draft.dirty&&draft.desired==3&&accepted.acceptedGenerated==3);
  CHECK(draft.Stage(accepted,0));CHECK(draft.Submit(provider,accepted));
  request=provider.ForCall(0x1234,7);CHECK(request.desired==0);provider.Complete(request,0,0);
  accepted=provider.Read();draft.Observe(accepted);CHECK(!draft.awaiting&&draft.desired==0);
  CHECK(!draft.Stage(accepted,6));
  CHECK(draft.Stage(accepted,2));auto changed=accepted;provider.Observe(0x5678,7,5);draft.Observe(provider.Read());
  CHECK(draft.conflict&&draft.dirty);draft.Discard(provider.Read());CHECK(!draft.conflict&&!draft.dirty);
  // An untouched menu follows current provider ownership/revisions.
  provider.Observe(0x7890,8,5);auto refreshed=provider.Read();draft.Observe(refreshed);
  CHECK(!draft.conflict&&!draft.dirty&&draft.generation==refreshed.generation);
  CHECK(provider.Request(refreshed,4));draft.Observe(provider.Read());
  CHECK(!draft.conflict&&!draft.dirty&&draft.desired==4&&draft.preferredGenerated==4);
  auto external=provider.ForCall(0x7890,8);provider.Complete(external,4,0);draft.Observe(provider.Read());
  CHECK(draft.Stage(provider.Read(),2));CHECK(draft.Submit(provider,provider.Read()));
  provider.Observe(0x9990,8,5);draft.Observe(provider.Read());
  CHECK(draft.conflict&&!draft.awaiting&&draft.desired==2);
  draft.Observe(provider.Read());CHECK(draft.conflict); // Never auto-clear a superseded request.
  draft.Discard(provider.Read());CHECK(!draft.conflict&&!draft.dirty);
  CHECK(draft.Stage(provider.Read(),3));auto concurrent=provider.Read();CHECK(provider.Request(concurrent,1));
  draft.Observe(provider.Read());CHECK(draft.conflict&&draft.dirty&&draft.desired==3);
 }
 control::Observation state;auto& s=state.snapshot;s.detected=s.live=s.editable=s.verified=s.owned=s.sourceBuilt=true;s.identity="fixture-only";s.settings.followGame=false;s.settings.multiplier=2;s.status.bridgeReady=true;s.status.minMultiplier=2;s.status.maxMultiplier=4;s.status.savedRequestObserved=true;s.status.applied=s.status.setOptionsAccepted=true;s.status.appliedMultiplier=2;s.status.requestRevision=s.status.appliedRevision=7;s.renderingFamily=40;s.renderingLuid=123;
 auto before=s;CHECK(mfg::SameControlContext(s,before));
 // A queued MFG write must compare both the fresh provider snapshot and the
 // exact settings document captured by SaveNow, closing the status-cache gap.
 CHECK(mfg::MatchesSaveBaseline(before,s,before.settings));
 auto intervening=before.settings;intervening.multiplier=3;
 CHECK(!mfg::MatchesSaveBaseline(before,s,intervening)); // Config changed after cached status read.
 auto changedContext=before;changedContext.settings=intervening;
 CHECK(!mfg::MatchesSaveBaseline(before,changedContext,intervening));
 changedContext=before;++changedContext.status.requestRevision;
 CHECK(!mfg::MatchesSaveBaseline(before,changedContext,before.settings));
 ++s.deviceGeneration;CHECK(!mfg::SameControlContext(s,before));s=before;
 ++s.renderingLuid;CHECK(!mfg::SameControlContext(s,before));s=before;
 ++s.status.requestRevision;CHECK(!mfg::SameControlContext(s,before));s=before;
 int saves=0;uint32_t pid=42;std::string birth="123";
#ifdef _WIN32
 if(argc>1){
  if(std::string(argv[1])=="idle-fixture"){Sleep(20000);return 0;}
  pid=GetCurrentProcessId();FILETIME created{},exited{},kernel{},user{};
  CHECK(GetProcessTimes(GetCurrentProcess(),&created,&exited,&kernel,&user));
  birth=std::to_string((uint64_t(created.dwHighDateTime)<<32)|created.dwLowDateTime);
 }
#endif
 control::Endpoint endpoint(pid,birth,[&]{return state;},[&](const mfg::Settings&,const mfg::Snapshot&){++saves;return uint64_t(99);});
#ifdef _WIN32
 if(argc>1){auto errorFixture=std::make_shared<std::atomic<bool>>(false);control::PipeServer server(pid,birth,[&](const std::string& request){if(std::string(argv[1])=="pipe-error-fixture"){control::Json envelope;if(mfg::Parse(request,control::MaxRequest,envelope)){const auto operation=envelope.value("operation",std::string{});if(operation=="snapshot"&&!errorFixture->exchange(true))throw std::runtime_error("fixture handler failure");if(operation=="auto.configure")return std::string(control::MaxResponse+1,'x');}}return endpoint.Handle(request);});server.Start();Sleep(20000);server.Stop();return 0;}
#endif
 auto request=control::Json{{"schema",2},{"pid",42},{"birth","123"},{"id","one"},{"operation","snapshot"}};
 auto call=[&]{return control::Json::parse(endpoint.Handle(request.dump()));};
 CHECK(call()["mfg"]["stage"]=="game_fg_off");
 CHECK(call()["mfg"]["firstBlockingReason"]=="game_fg_off");
 CHECK(call()["mfg"]["installationProvider"].is_null()&&call()["mfg"]["sourceInput"].is_null()&&call()["mfg"]["policyDecision"].is_null());
 CHECK(call()["mfg"]["loadedProvider"]=="optishade-source-mfg"&&call()["mfg"]["renderingAdapter"]["luid"]=="123");
 CHECK(call()["mfg"]["frameGeneration"]["kind"]=="replacement_mfg_provider"&&call()["mfg"]["requestedMode"]=="fixed"&&call()["mfg"]["requestedMultiplier"]==2);
 control::Observation upstream=state;upstream.snapshot.sourceBuilt=false;upstream.snapshot.renderingLuid=0;upstream.snapshot.renderingFamily=0;
 const auto upstreamSnapshot=control::Snapshot(upstream);CHECK(upstreamSnapshot["loadedProvider"]=="rtxmfg-upstream");CHECK(upstreamSnapshot["renderingAdapter"].is_null());
 auto upstreamChanged=upstream.snapshot.settings;upstreamChanged.followGame=false;upstreamChanged.multiplier=4;
 int upstreamSaves=0;control::Endpoint upstreamEndpoint(pid,birth,[&]{return upstream;},[&](const mfg::Settings&,const mfg::Snapshot&){++upstreamSaves;return uint64_t(100);});
 control::Json upstreamRequest={{"schema",control::Version},{"pid",pid},{"birth",birth},{"id","upstream-null-generation"},{"operation","mfg.configure"},{"identity",upstream.snapshot.identity},{"revision",upstream.snapshot.status.requestRevision},{"baseline",control::Settings(upstream.snapshot.settings)},{"settings",control::Settings(upstreamChanged)},{"deviceGeneration",upstreamSnapshot["deviceGeneration"]},{"renderingAdapterLuid",upstreamSnapshot["renderingAdapterLuid"]}};
 auto upstreamCall=[&]{return control::Json::parse(upstreamEndpoint.Handle(upstreamRequest.dump()));};
 CHECK(upstreamSnapshot["deviceGeneration"].is_null());CHECK(upstreamCall()["code"]=="queued");CHECK(upstreamSaves==1);
 upstreamRequest["id"]="upstream-numeric-zero";upstreamRequest["deviceGeneration"]=0;CHECK(upstreamCall()["code"]=="conflict");CHECK(upstreamSaves==1);
 upstreamRequest["id"]="upstream-generation-changed";upstreamRequest["deviceGeneration"]=nullptr;upstream.snapshot.deviceGeneration=1;CHECK(upstreamCall()["code"]=="conflict");CHECK(upstreamSaves==1);
 s.status.gameFgOn=true;CHECK(call()["mfg"]["stage"]=="output_not_observed");
 s.status.appliedRevision=6;CHECK(call()["mfg"]["stage"]=="awaiting_acknowledgement");CHECK(call()["mfg"]["acceptedMultiplier"].is_null());CHECK(call()["mfg"]["acceptedRevision"].is_null());CHECK(call()["mfg"]["providerAppliedRevision"]==6);
 s.status.appliedRevision=7;s.status.savedRequestObserved=false;CHECK(call()["mfg"]["stage"]=="saved_request_not_observed");CHECK(call()["mfg"]["accepted"]==false);CHECK(call()["mfg"]["acceptedMultiplier"].is_null());
 s.status.savedRequestObserved=true;s.status.applied=false;CHECK(call()["mfg"]["stage"]=="request_not_accepted");CHECK(call()["mfg"]["acceptedMultiplier"].is_null());
 s.status.applied=true;CHECK(call()["mfg"]["stage"]=="output_not_observed");
 s.status.setOptionsAccepted=true;CHECK(call()["mfg"]["stage"]=="output_not_observed");
 s.status.realFpsMilli=30000;s.status.outputFpsMilli=60000;s.status.fpsAgeMs=25;
 CHECK(call()["mfg"]["stage"]=="output_not_observed");
 CHECK(call()["mfg"]["effectiveObservedRatio"].is_null());
 CHECK(call()["mfg"]["actualFramesPresented"]==0);
 s.status.actualFramesPresented=1;
 CHECK(call()["mfg"]["stage"]=="output_telemetry_observed");CHECK(call()["mfg"]["effectiveObservedRatio"]==2.0);CHECK(call()["mfg"]["accepted"]==true);CHECK(call()["mfg"]["acceptedMultiplier"]==2);
 s.status.fpsAgeMs=5001;CHECK(call()["mfg"]["stage"]=="output_not_observed");
 CHECK(call()["mfg"]["effectiveObservedRatio"].is_null());s.status.realFpsMilli=s.status.outputFpsMilli=0;
 CHECK(call()["code"]=="ok");CHECK(call()["mfg"]["effectiveObservedRatio"].is_null());
 request["schema"]=1;CHECK(call()["code"]=="unsupported_envelope");request["schema"]=2;
 request["birth"]="124";CHECK(call()["code"]=="wrong_session");request["birth"]="123";
 CHECK(control::Json::parse(endpoint.Handle("{\"schema\":1,\"schema\":1}"))["code"]=="malformed_request");
 CHECK(control::Json::parse(endpoint.Handle(std::string(17000,'x')))["code"]=="malformed_request");
 request["operation"]="mfg.configure";request["identity"]="fixture-only";request["revision"]=7;request["baseline"]=control::Settings(s.settings);request["deviceGeneration"]=control::Snapshot(state)["deviceGeneration"];request["renderingAdapterLuid"]=std::to_string(s.renderingLuid);
 auto changed=s.settings;changed.followGame=false;changed.multiplier=4;request["settings"]=control::Settings(changed);
 request["deviceGeneration"]=0;CHECK(call()["code"]=="conflict");request["deviceGeneration"]=nullptr;
 s.deviceGeneration=1;CHECK(call()["code"]=="conflict");s.deviceGeneration=0;
 request["deviceGeneration"]=s.deviceGeneration+1;CHECK(call()["code"]=="conflict");request["deviceGeneration"]=control::Snapshot(state)["deviceGeneration"];
 CHECK(call()["code"]=="queued");CHECK(call()["commandId"]==99);CHECK(saves==1);
 request["settings"]["multiplier"]=3;CHECK(call()["code"]=="request_id_reused");CHECK(saves==1);
 request["id"]="two";request["revision"]=6;CHECK(call()["code"]=="conflict");request["revision"]=7;
 request["settings"]["multiplier"]=6;CHECK(call()["code"]=="unavailable_mode");CHECK(saves==1);
 s.live=false;CHECK(call()["code"]=="provider_unavailable");request["operation"]="snapshot";CHECK(call()["mfg"]["acceptedMultiplier"].is_null());
 const auto pipeError=control::PipeError("internal_error",42,"123","command-1");CHECK(pipeError["schema"]==control::Version&&pipeError["pid"]==42&&pipeError["birth"]=="123"&&pipeError["id"]=="command-1");CHECK(control::PipeError("snapshot_too_large")["schema"]==control::Version);
 CHECK(std::string(policy::Select("stable",40,false,false,true,false,true,true))=="legacy");
 CHECK(std::string(policy::Select("stable",40,true,false,true,false,true,true))=="source");
 CHECK(std::string(policy::Select("beta",40,false,true,true,false,true,true))=="source");
 CHECK(std::string(policy::Select("stable",20,false,false,true,false,true,true))=="sm86");
 CHECK(std::string(policy::Select("beta",30,false,false,true,false,true,true))=="sm86");
 CHECK(std::string(policy::Select("stable",20,true,false,true,false,true,true))=="sm86");
 CHECK(std::string(policy::Select("beta",30,false,false,true,false,true,true,true,true))=="sm86");
 CHECK(std::string(policy::Select("beta",30,false,false,true,false,true,true,false,false))=="payload_missing");
 CHECK(std::string(policy::Select("stable",40,false,false,true,false,true,true))=="legacy");
 CHECK(std::string(policy::Select("beta",50,false,false,true,false,true,true))=="native");
 CHECK(std::string(policy::Select("beta",30,false,false,true,true,true,true))=="ambiguous_adapter");
 CHECK(std::string(policy::Select("beta",30,false,false,false,false,true,true))=="unsupported_game");
 std::cout<<"Control protocol rejection, session, replay, conflict, capability and unknown-output tests passed; no GPU execution.\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
