// Exercises the exact production RuntimeAuto class, not a second decision model.
#include "AutoCompatibility.h"
#include "RuntimeControlProtocol.h"
#include "RuntimeRenderContext.h"
#include "NativeMfgControl.h"
#include "NativeFgStateQuery.h"
#include "NativeFgStateQueryLock.h"
#include "ExternalFgTelemetry.h"
#include "NeuralRuntimeReceipt.h"
#include "RenderingGpuPolicy.h"
#include "NrDeferredEvents.h"
#include "NrSessionControl.h"
#include "NrObservation.h"
#include <filesystem>
#include <functional>
#include <iostream>
#include <atomic>

static uint64_t clockValue=100000;
static uint64_t GetTickCount64(){return clockValue;}
static uint32_t GetCurrentProcessId(){return 42;}
static uint32_t GetCurrentThreadId(){return 77;}
static std::pair<std::string,std::string> DlssgCallerSite(void*){return {"runtime_auto_tests.exe","0x0"};}
namespace optishade::mfg::file {static uint64_t Birth(){return 12345;}}
namespace fixture {
inline unsigned nrSets=0,sourceSaves=0,providerSetups=0,providerQueries=0;
inline bool nrRequested=false,nrBusy=false,persisted=false,memoryOverride=false;
inline uint64_t sourceDevice=0;
inline optishade::mfg::Snapshot provider;
}
namespace AmpereMfgLoader {inline void TrySetup(){++fixture::providerSetups;}}
namespace optishade::mfg {
struct TestWorker {unsigned Peek()const{return 0;}};
struct TestStatusService {
    TestWorker worker;
    Snapshot Read(unsigned)const{return fixture::provider;}
    uint64_t Save(const Settings& request,const Snapshot& baseline){
        if(!SameControlContext(fixture::provider,baseline))return 0;
        ++fixture::sourceSaves;fixture::provider.settings=request;
        ++fixture::provider.status.requestRevision;fixture::provider.status.pending=true;
        return fixture::sourceSaves;
    }
};
inline TestStatusService& UiStatus(){static TestStatusService service;return service;}
namespace source {inline bool BoundToDevice(uint64_t identity){return identity&&identity==fixture::sourceDevice;}}
}
namespace optishade::neural_preparation {
#include "preparation_snapshot.inc"
inline Snapshot publication;
class Service {
public:
    struct Worker {std::function<void()> ready;void Start(){if(ready)ready();}} worker;
    explicit Service(std::filesystem::path,std::function<void()> ready={}):worker{std::move(ready)}{}
    Snapshot Read()const{return publication;}
};
}
namespace DlssNr {
inline optishade::nr::DeferredEvents<unsigned> events([](const unsigned&){});
static optishade::nr_session::State Read(){
    const auto value=optishade::nr_observation::State().Read(GetTickCount64());
    return {value.requested,value.request,value.explicitOffRevision};
}
inline bool TryReadSessionState(optishade::nr_session::State& state){
    if(fixture::nrBusy)return false;
    return events.TryWithState([&]{state=Read();});
}
inline optishade::nr_session::Result TrySetSessionEnabled(bool enabled,uint64_t revision){
    if(fixture::nrBusy)return {};
    return optishade::nr_session::TrySet(events,enabled,revision,Read,[](bool requested){
        ++fixture::nrSets;fixture::nrRequested=requested;
        optishade::nr_observation::State().Request(requested,true,1,true);
    });
}
}
#include "runtime_auto_body.inc"

// Resolve/pin is supplied by the fixture; forwarding and publication below are
// the unedited PassiveState body extracted from the product hook source.
namespace passive_fixture {
inline uint64_t provider=902;
inline bool available=true;
inline sl::Result result=sl::Result::eOk;
inline uint32_t maximum=3,interval=9;
inline sl::DLSSGState* seen=nullptr;
inline const sl::DLSSGOptions* seenOptions=nullptr;
inline sl::Result Query(const sl::ViewportHandle&,sl::DLSSGState& state,const sl::DLSSGOptions* options){
    ++fixture::providerQueries;seen=&state;seenOptions=options;
    if(result==sl::Result::eOk&&optishade::native_mfg::KnownState(state)){
        state.numFramesActuallyPresented=interval;
        if(state.structVersion>=2)state.numFramesToGenerateMax=maximum;
    }
    return result;
}
}
namespace optishade::external_fg {
template<class Function> class Target {
public:
    Function function=nullptr;
    template<class Resolver> Target(Resolver,sl::Feature,const char*){
        if(passive_fixture::available)function=&passive_fixture::Query;
    }
    uint64_t NativeIdentity()const{return passive_fixture::provider;}
};
}
namespace optishade::native_mfg {
struct GuardedStateCall {sl::Result result=sl::Result::eErrorExceptionHandler;unsigned long exceptionCode=0;bool suppressedAfterFault=false;};
template<class Function> static GuardedStateCall InvokeGetStateGuarded(Function function,const sl::ViewportHandle& view,sl::DLSSGState& state,const sl::DLSSGOptions* options,std::atomic<bool>* faultLatch){
    GuardedStateCall outcome{};if(faultLatch&&faultLatch->load()){outcome.suppressedAfterFault=true;return outcome;}
    if(!function){outcome.result=sl::Result::eErrorFeatureMissing;return outcome;}
    outcome.result=function(view,state,options);return outcome;
}
}
static std::atomic<bool> dlssgStateProviderFaulted{false};
static void RecordDlssGStateProviderFault(const char*,const optishade::native_mfg::GuardedStateCall&){}
struct StreamlineHooks {
    static sl::Result ResolveExternal(sl::Feature,const char*,void*&){return sl::Result::eOk;}
    static sl::Result PassiveState(const sl::ViewportHandle&,sl::DLSSGState&,const sl::DLSSGOptions*);
};
#include "passive_fg_body.inc"

static unsigned checks=0;
#define CHECK(value) do {++checks;if(!(value)){std::cerr<<#value<<" @"<<__LINE__<<'\n';return 1;}}while(false)
using Json=optishade::mfg::Json;
using optishade::Evidence;
static optishade::runtime_render::Device device{101,202,0x10de,0x2684,0,false,"NVIDIA GeForce RTX 4090"};
static void Publish(){optishade::runtime_render::State().Publish(device,303,5,"d3d12",0,GetTickCount64(),{1001,1002});}
static void Prepare(){
    auto& value=optishade::neural_preparation::publication;value={};
    value.device=device.identity;value.luid=device.luid;value.fresh=true;
    value.hardware=value.prepared=Evidence::Yes;value.modelIdentity="compat-model:verified";
    value.driver="nvcuda-file:32.0.15.8180";value.executable="Renderer.exe";value.executableHash=std::string(64,'A');
}
static void Native(bool passive=false,uint32_t view=0){
    optishade::runtime_render::State().StreamlineDevice(device);
    optishade::native_mfg::Session().Observe(passive_fixture::provider,view,3,!passive);
    const auto state=optishade::native_mfg::Session().Read();
    optishade::runtime_render::State().NativeState(state.provider,state.generation,view,11,GetTickCount64(),passive);
    auto& prepared=optishade::neural_preparation::publication;
    prepared.nativeProvider=state.provider;prepared.nativeGeneration=state.generation;prepared.providerImageHashed=true;
    prepared.providerFileHash=std::string(64,'B');prepared.providerIdentity="streamline-dlssg-file:"+prepared.providerFileHash;
    prepared.providerFilePath="C:\\Games\\Title\\sl.dlss_g.dll";
}
static Json Request(const Json& snapshot,bool nr,bool sr,bool fg,bool enabled=true){
    Json request;
    for(const char* key:{"revision","planId","renderingAdapterLuid","deviceGeneration","outputGeneration","outputId",
                        "deviceIdentity","deviceGenerationSource","api","architecture","view","providerIdentity","modelIdentity","driverVersion"})request[key]=snapshot.at(key);
    request["desired"]={{"enabled",enabled},{"nr",nr?"auto":"off"},{"upscaling",sr?"auto":"off"},{"frameGeneration",fg?"auto":"off"}};
    return request;
}
int main(){
    using namespace optishade;
    nr_observation::State().Request(false,true,1);
    control::RuntimeAuto runtime("component");
    auto value=runtime.Read();
    CHECK(value["state"]=="off"&&value["renderingAdapterLuid"].is_null());
    CHECK(value["features"]["nr"]["runtimeRequested"]==false&&fixture::nrSets==0&&fixture::sourceSaves==0);
    auto reply=runtime.Configure(Request(value,true,false,false));
    CHECK(reply["code"]=="waiting_for_rendering_context"&&!fixture::nrRequested&&fixture::nrSets==0);
    Publish();Prepare();neural_preparation::publication.hardware=Evidence::No;
    value=runtime.Read();reply=runtime.Configure(Request(value,true,false,false));
    CHECK(reply["auto"]["features"]["nr"]["state"]=="unsupported"&&!fixture::nrRequested);
    neural_preparation::publication.hardware=Evidence::Yes;
    value=runtime.Read();const auto stale=Request(value,true,false,false);
    reply=runtime.Configure(stale);
    CHECK(reply["code"]=="accepted"&&fixture::nrRequested&&fixture::nrSets==1);
    value=runtime.Read();
    CHECK(value["features"]["nr"]["accepted"]==true&&value["features"]["nr"]["observed"]["gpuCompleted"]==false);
    CHECK(runtime.Configure(stale)["code"]=="conflict"&&fixture::nrSets==1);
    const auto oldModel=Request(value,true,false,false);neural_preparation::publication.modelIdentity="compat-model:replacement";
    CHECK(runtime.Configure(oldModel)["code"]=="conflict"&&fixture::nrSets==1);
    auto nrState=DlssNr::Read();DlssNr::TrySetSessionEnabled(false,nrState.revision);
    value=runtime.Read();CHECK(value["desired"]["nr"]=="off"&&!fixture::nrRequested);
    auto manual=Request(value,true,false,false);manual["revision"]=DlssNr::Read().revision;manual["settings"]={{"enabled",true}};
    CHECK(runtime.ConfigureNr(manual)["code"]=="accepted"&&fixture::nrRequested&&!fixture::persisted&&!fixture::memoryOverride);
    CHECK(runtime.ConfigureNr(manual)["code"]=="conflict");
    value=runtime.Read();CHECK(value["features"]["nr"]["state"]=="manual_control");
    reply=runtime.Configure(Request(value,true,false,false));CHECK(reply["code"]=="accepted");

    // The newest observation may be a helper. Only this output's exact lane is eligible.
    auto& tracker=nr_observation::State();
    nr_observation::Owner primary{101,707,303,5,0,1920,1080,nr_observation::Route::EstimatedTAA};
    auto helper=primary;helper.runtime=999;
    auto ticket=tracker.Begin(helper,1,GetTickCount64());tracker.Evaluated(ticket,true);tracker.Completed(ticket,707,0,{});
    CHECK(runtime.Read()["features"]["nr"]["observed"]["gpuCompleted"]==false);
    ticket=tracker.Begin(primary,2,GetTickCount64());tracker.Evaluated(ticket,true);
    value=runtime.Read();CHECK(value["features"]["nr"]["observed"]["recorded"]==true&&value["features"]["nr"]["observed"]["gpuCompleted"]==false);
    tracker.Submitted(ticket,707,GetTickCount64(),true);
    CHECK(runtime.Read()["features"]["nr"]["observed"]["gpuCompleted"]==false);
    tracker.Completed(ticket,707,1000,0.5);tracker.PresentSubmitted(ticket,0,true);
    value=runtime.Read();CHECK(value["features"]["nr"]["observed"]["gpuCompleted"]==true&&value["features"]["nr"]["observed"]["composed"]==true);
    CHECK(value["features"]["nr"]["observed"]["presentSubmitted"]==true&&value["features"]["nr"]["observed"]["displayVerified"]==false);
    const auto newer=tracker.Begin(helper,3,GetTickCount64());tracker.Evaluated(newer,false);
    CHECK(runtime.Read()["features"]["nr"]["observed"]["gpuCompleted"]==true);
    runtime_render::State().Publish(device,304,6,"d3d12",0,GetTickCount64());
    CHECK(runtime.Read()["features"]["nr"]["observed"]["gpuCompleted"]==false);

    // The real D3D11 bridge evaluates on its private D3D12 device and the
    // ReShade guide owner has a different runtime/generation from the output.
    // Only a real output resource plus an exact existing ticket joins them.
    runtime_render::State().Publish(device,313,15,"d3d11",0,GetTickCount64(),{1001,1002});
    auto bridgeOwner=primary;bridgeOwner.device=404;bridgeOwner.runtime=990;bridgeOwner.generation=17;
    const auto bridgeTicket=tracker.Begin(bridgeOwner,4,GetTickCount64());
    tracker.Evaluated(bridgeTicket,true);tracker.Submitted(bridgeTicket,708,GetTickCount64(),true);
    tracker.Completed(bridgeTicket,708,0,{});
    const auto bridgeRevision=DlssNr::Read().revision;
    CHECK(runtime.Read()["features"]["nr"]["observed"]["gpuCompleted"]==false);
    CHECK(!runtime_render::State().NrOutput(808,bridgeTicket,bridgeRevision,true,GetTickCount64()));
    CHECK(runtime_render::State().NrOutput(1001,bridgeTicket,bridgeRevision,false,GetTickCount64()));
    value=runtime.Read();CHECK(value["features"]["nr"]["observed"]["gpuCompleted"]==true&&value["features"]["nr"]["observed"]["composed"]==false);
    CHECK(runtime_render::State().NrOutput(1001,bridgeTicket,bridgeRevision,true,GetTickCount64()));
    value=runtime.Read();CHECK(value["features"]["nr"]["observed"]["composed"]==true&&value["features"]["nr"]["observed"]["presentSubmitted"]==false);
    auto bridgeHelper=bridgeOwner;bridgeHelper.runtime=991;
    const auto helperTicket=tracker.Begin(bridgeHelper,5,GetTickCount64());tracker.Evaluated(helperTicket,false);
    CHECK(!runtime_render::State().NrOutput(808,helperTicket,bridgeRevision,false,GetTickCount64()));
    CHECK(runtime_render::State().Read().nr.ticket==bridgeTicket);
    CHECK(!runtime_render::State().NrOutput(1001,0,bridgeRevision,false,GetTickCount64()));
    CHECK(runtime.Read()["features"]["nr"]["observed"]["composed"]==true);

    // An older bridge result cannot obscure a newer direct evaluation, and a
    // typed failure before Begin is bound to the request that produced it.
    ++clockValue;auto mappedPrimary=primary;mappedPrimary.runtime=313;mappedPrimary.generation=15;
    const auto directTicket=tracker.Begin(mappedPrimary,6,GetTickCount64());tracker.Evaluated(directTicket,false);
    value=runtime.Read();CHECK(value["features"]["nr"]["observed"]["recorded"]==true&&value["features"]["nr"]["observed"]["gpuCompleted"]==false);
    ++clockValue;CHECK(runtime_render::State().NrOutput(1001,0,bridgeRevision,false,GetTickCount64(),true));
    value=runtime.Read();CHECK(value["features"]["nr"]["state"]=="failed"&&value["features"]["nr"]["observed"]["recorded"]==false);
    nrState=DlssNr::Read();DlssNr::TrySetSessionEnabled(false,nrState.revision);
    nrState=DlssNr::Read();DlssNr::TrySetSessionEnabled(true,nrState.revision);
    value=runtime.Read();reply=runtime.Configure(Request(value,true,false,false));
    CHECK(runtime.Read()["features"]["nr"]["observed"]["recorded"]==false);
    CHECK(runtime.Read()["features"]["nr"]["state"]!="failed");
    const auto freshTicket=tracker.Begin(bridgeOwner,7,GetTickCount64());tracker.Evaluated(freshTicket,true);tracker.Completed(freshTicket,708,0,{});
    CHECK(runtime_render::State().NrOutput(1002,freshTicket,DlssNr::Read().revision,true,GetTickCount64()));
    CHECK(runtime.Read()["features"]["nr"]["observed"]["composed"]==true);
    clockValue+=1500;runtime_render::State().Publish(device,313,15,"d3d11",0,GetTickCount64(),{1001,1002});
    CHECK(runtime.Read()["features"]["nr"]["observed"]["gpuCompleted"]==false);
    runtime_render::State().Publish(device,313,16,"d3d11",0,GetTickCount64(),{1101,1102});
    CHECK(runtime_render::State().Read().nr.ticket==0);
    CHECK(!runtime_render::State().NrOutput(1001,freshTicket,DlssNr::Read().revision,true,GetTickCount64()));
    Publish();Prepare();

    // Successful game reconstruction remains game-owned even while Auto is Off.
    runtime_render::State().Upscaling(device,501,"native DLSS-SR",true,false,GetTickCount64());
    value=runtime.Read();reply=runtime.Configure(Request(value,false,false,false,false));value=runtime.Read();
    CHECK(value["features"]["upscaling"]["controlOwner"]=="game");
    CHECK(value["features"]["upscaling"]["state"]=="game_controlled_work_reported");
    CHECK(value["features"]["upscaling"]["runtimeRequested"].is_null()&&value["features"]["upscaling"]["accepted"]==false);
    CHECK(value["features"]["upscaling"]["observed"]["recorded"]==true&&value["features"]["upscaling"]["observed"]["gpuCompleted"]==false);
    clockValue+=1501;Publish();CHECK(runtime.Read()["features"]["upscaling"]["observed"]["recorded"]==false);

    Native();value=runtime.Read();
    CHECK(value["nativeFgCapability"]["observed"]==true&&value["nativeFgCapability"]["maximumAdditionalFrames"]==3);
    CHECK(value["nativeFgCapability"]["driverVersion"]=="nvcuda-file:32.0.15.8180");
    CHECK(value["features"]["frameGeneration"]["canConfigure"]==true&&value["features"]["frameGeneration"]["runtimeRequested"].is_null());
    reply=runtime.Configure(Request(value,false,false,true));
    CHECK(reply["code"]=="queued");
    auto native=native_mfg::Session().Read();CHECK(native.desired==1&&native.pending&&!native.attempted);
    value=runtime.Read();CHECK(value["features"]["frameGeneration"]["accepted"]==false);
    native_mfg::Session().Complete(native,1,0);value=runtime.Read();
    CHECK(value["features"]["frameGeneration"]["accepted"]==true&&value["features"]["frameGeneration"]["inputs"].is_null());
    CHECK(value["features"]["frameGeneration"]["observed"]["generated"]==false&&value["features"]["frameGeneration"]["observed"]["displayVerified"]==false);
    // Auto reuses an explicitly selected managed Dynamic mode; accepted
    // Dynamic does not require a fabricated fixed generated-frame count.
    native_mfg::Session().Observe(passive_fixture::provider,0,3,true,true,true);
    CHECK(native_mfg::Session().Request(native_mfg::Session().Read(),-1,true));
    value=runtime.Read();reply=runtime.Configure(Request(value,false,false,true));
    CHECK(reply["code"]=="queued"&&native_mfg::Session().Read().dynamic);
    native_mfg::Session().Complete(native_mfg::Session().Read(),0,0,true);
    value=runtime.Read();CHECK(value["features"]["frameGeneration"]["runtimeRequested"]==true&&value["features"]["frameGeneration"]["accepted"]==true);
    neural_preparation::publication.fresh=false;CHECK(runtime.Read()["nativeFgCapability"]["observed"]==false);
    neural_preparation::publication.fresh=true;neural_preparation::publication.providerImageHashed=false;
    CHECK(runtime.Read()["nativeFgCapability"]["observed"]==false);
    neural_preparation::publication.providerImageHashed=true;++neural_preparation::publication.nativeGeneration;
    CHECK(runtime.Read()["nativeFgCapability"]["observed"]==false);
    Native(false,1);CHECK(runtime.Read()["nativeFgCapability"]["observed"]==false);
    Native();auto other=device;other.identity=999;other.luid=888;runtime_render::State().StreamlineDevice(other);
    CHECK(runtime.Read()["nativeFgCapability"]["observed"]==false);
    Native();clockValue+=3001;CHECK(runtime.Read()["nativeFgCapability"]["observed"]==false);Publish();Prepare();

    Native(true);value=runtime.Read();native=native_mfg::Session().Read();
    reply=runtime.Configure(Request(value,false,false,true));
    CHECK(reply["auto"]["features"]["frameGeneration"]["state"]=="restart_required");
    CHECK(native_mfg::Session().Read().revision==native.revision&&value["features"]["frameGeneration"]["canConfigure"]==false);
    CHECK(value["features"]["frameGeneration"]["controlOwner"]=="game");
    fixture::provider.detected=true;fixture::provider.identity="installed-other-provider";
    value=runtime.Read();CHECK(value["features"]["frameGeneration"]["route"]=="owned compatibility MFG"&&value["features"]["frameGeneration"]["prepared"]==false);
    reply=runtime.Configure(Request(value,false,false,true));CHECK(fixture::sourceSaves==0);
    fixture::provider={};

    auto& source=fixture::provider;source.detected=source.verified=source.owned=source.live=source.editable=source.sourceBuilt=true;
    source.identity="owned-source-sha";source.renderingLuid=device.luid;source.deviceGeneration=81;source.renderingFamily=40;
    source.settings.followGame=false;source.settings.multiplier=4;source.status.gpuFamily=40;
    source.status.maxMultiplier=source.status.policyMaximumMultiplier=6;source.status.minMultiplier=1;
    source.status.bridgeReady=true;fixture::sourceDevice=device.identity;
    value=runtime.Read();reply=runtime.Configure(Request(value,false,false,true));
    CHECK(reply["code"]=="queued"&&fixture::sourceSaves==1&&source.settings.multiplier==4);
    CHECK(runtime.Read()["features"]["frameGeneration"]["accepted"]==false);
    source.status.pending=false;source.status.savedRequestObserved=source.status.setOptionsAccepted=source.status.appliedFgOn=true;
    source.status.appliedRevision=source.status.requestRevision;
    CHECK(runtime.Read()["features"]["frameGeneration"]["accepted"]==true);
    source.renderingLuid=909;value=runtime.Read();reply=runtime.Configure(Request(value,false,false,true));
    CHECK(fixture::sourceSaves==1&&value["features"]["frameGeneration"]["canConfigure"]==false);
    source.renderingLuid=device.luid;fixture::sourceDevice=909;
    CHECK(runtime.Read()["features"]["frameGeneration"]["canConfigure"]==false);
    fixture::provider={};fixture::sourceDevice=0;

    // The real passive game callback forwards once, keeps the caller and options,
    // and invalidates Auto evidence immediately after a genuine query failure.
    Publish();runtime_render::State().StreamlineDevice(device);
    sl::DLSSGState state;state.structVersion=2;sl::DLSSGOptions options;
    const auto queries=fixture::providerQueries;
    CHECK(StreamlineHooks::PassiveState(sl::ViewportHandle(0),state,&options)==sl::Result::eOk);
    CHECK(fixture::providerQueries==queries+1&&passive_fixture::seen==&state&&passive_fixture::seenOptions==&options);
    CHECK(state.structVersion==2&&state.numFramesActuallyPresented==9&&runtime_render::State().Read().native.intervalFrames==9);
    const auto readOnly=native_mfg::Session().Read();
    CHECK(!native_mfg::Control::CanConfigure(readOnly));
    CHECK(!native_mfg::Session().Request(readOnly,1)&&native_mfg::Session().Read().revision==readOnly.revision);
    passive_fixture::result=sl::Result::eErrorFeatureMissing;
    CHECK(StreamlineHooks::PassiveState(sl::ViewportHandle(0),state,&options)==sl::Result::eErrorFeatureMissing);
    CHECK(fixture::providerQueries==queries+2&&runtime_render::State().Read().native.provider==0);
    passive_fixture::result=sl::Result::eOk;state.structVersion=1;
    CHECK(StreamlineHooks::PassiveState(sl::ViewportHandle(0),state,&options)==sl::Result::eOk&&state.structVersion==1);
    CHECK(!native_mfg::Session().Read().known); // no v1 capability tail is invented
    state.structVersion=99;
    CHECK(StreamlineHooks::PassiveState(sl::ViewportHandle(0),state,&options)==sl::Result::eOk&&runtime_render::State().Read().native.provider==0);
    passive_fixture::available=false;
    CHECK(StreamlineHooks::PassiveState(sl::ViewportHandle(0),state,&options)==sl::Result::eErrorFeatureMissing&&fixture::providerQueries==queries+4);
    const auto& missingProvider=optishade::session::State().critical;
    CHECK(missingProvider.at("FGStateQueryStage")=="Passive provider function unavailable");
    CHECK(missingProvider.at("FGProviderFunctionAvailable")=="No");
    CHECK(missingProvider.at("FGPresentSampleSource")=="Streamline provider Present boundary");

    // Direct NR commands pass through the actual endpoint's process envelope and
    // replay cache to this production bridge; a repeated ID cannot run it twice.
    Publish();Prepare();control::RuntimeAuto endpointRuntime("component");
    control::Endpoint endpoint(17,"birth-17",[]{return control::Observation{};},[](const auto&,const auto&){return 0;},{},
        [&]{return endpointRuntime.Read();},[&](const Json& command){return endpointRuntime.Configure(command);},
        [&](const Json& command){return endpointRuntime.ConfigureNr(command);});
    value=endpointRuntime.Read();auto command=Request(value,true,false,false);
    command["settings"]={{"enabled",true}};command["revision"]=DlssNr::Read().revision;
    command["schema"]=2;command["pid"]=17;command["birth"]="other";command["id"]="native-nr-one";command["operation"]="nr.configure";
    const auto sets=fixture::nrSets;
    CHECK(Json::parse(endpoint.Handle(command.dump()))["code"]=="wrong_session"&&fixture::nrSets==sets);
    command["birth"]="birth-17";const auto first=endpoint.Handle(command.dump());
    CHECK(Json::parse(first)["code"]=="accepted"&&fixture::nrSets==sets+1);
    CHECK(endpoint.Handle(command.dump())==first&&fixture::nrSets==sets+1);
    runtime_render::State().Invalidate(0);value=endpointRuntime.Read();
    command=Request(value,false,false,false,false);command["revision"]=DlssNr::Read().revision;command["settings"]={{"enabled",false}};
    CHECK(endpointRuntime.ConfigureNr(command)["code"]=="accepted"&&!fixture::nrRequested);
    control::RuntimeAuto reserved("component",true);reserved.Start();CHECK(fixture::providerSetups==0);
    control::RuntimeAuto existing("component",false);existing.Start();CHECK(fixture::providerSetups==1);
    CHECK(!fixture::persisted&&!fixture::memoryOverride);

    // A waiting Auto request survives ordinary Off-valued tuning observations.
    // A new explicit Off command while the owner is already Off cancels it.
    Publish();Prepare();neural_preparation::publication.prepared=Evidence::No;
    control::RuntimeAuto waiting("component");value=waiting.Read();
    reply=waiting.Configure(Request(value,true,false,false));
    CHECK(waiting.Read()["desired"]["nr"]=="auto"&&!fixture::nrRequested);
    tracker.Request(false,true,22);
    CHECK(waiting.Read()["desired"]["nr"]=="auto");
    nrState=DlssNr::Read();const auto waitingRevision=nrState.revision;
    CHECK(DlssNr::TrySetSessionEnabled(false,waitingRevision).code==nr_session::Code::Accepted);
    CHECK(DlssNr::Read().revision>waitingRevision&&DlssNr::Read().explicitOffRevision==DlssNr::Read().revision);
    CHECK(waiting.Read()["desired"]["nr"]=="off");
    CHECK(DlssNr::TrySetSessionEnabled(true,waitingRevision).code==nr_session::Code::Conflict&&!fixture::nrRequested);

    // Eligibility can become ready under the same exact identity strings; its
    // decision epoch must cause the manager to submit a new bounded command.
    value=waiting.Read();reply=waiting.Configure(Request(value,true,false,false));
    const auto pending=waiting.Read();neural_preparation::publication.prepared=Evidence::Yes;
    value=waiting.Read();CHECK(value["planId"]!=pending["planId"]);
    CHECK(value["modelIdentity"]==pending["modelIdentity"]&&value["driverVersion"]==pending["driverVersion"]);
    CHECK(waiting.Configure(Request(pending,true,false,false))["code"]=="conflict");
    CHECK(waiting.Configure(Request(value,true,false,false))["code"]=="accepted"&&fixture::nrRequested);

    // Actual receipt validator uses pinned model families, not installation GPU
    // name numbers or a prior process's candidate LUID for runtime admission.
    const auto& model=neural_policy::Models[0];
    Json receipt={{"schema",1},{"modelSha256",model.sha256},{"executable","Renderer.exe"},{"executableSha256",std::string(64,'A')},
                  {"architecture","x64"},{"variant",model.variant},{"evidence","inventory_candidate"}};
    neural_receipt::Facts facts{"Renderer.exe",std::string(64,'A'),"x64",std::string(model.sha256),50};
    CHECK(neural_receipt::Validate(receipt,facts).bound);
    facts.renderingFamily=40;CHECK(!neural_receipt::Validate(receipt,facts).bound);
    facts.renderingFamily=50;facts.executable="Other.exe";CHECK(!neural_receipt::Validate(receipt,facts).bound);
    facts.executable="Renderer.exe";receipt["executableSha256"]=std::string(64,'C');CHECK(!neural_receipt::Validate(receipt,facts).bound);
    CHECK(gpu_policy::DriverFileIdentity(32,0,15,8180)=="nvcuda-file:32.0.15.8180");
    CHECK(gpu_policy::DriverFileIdentity(32,0,15,8181)!=gpu_policy::DriverFileIdentity(32,0,15,8180));
    CHECK(gpu_policy::DriverFileIdentity(0,0,0,0).empty()&&gpu_policy::DriverFileIdentity(65536,0,0,0).empty());

    // The XP12 native Vulkan process is explicit at startup. A private DXGI
    // helper before the real Vulkan owner cannot admit D3D12 NR/FG controls.
    Publish();Prepare();Native();
    source.detected=source.verified=source.owned=source.live=source.editable=source.sourceBuilt=true;
    source.identity="owned-source-sha";source.renderingLuid=device.luid;source.deviceGeneration=81;source.renderingFamily=40;
    source.settings.followGame=false;source.settings.multiplier=4;source.status.gpuFamily=40;
    source.status.maxMultiplier=source.status.policyMaximumMultiplier=6;source.status.minMultiplier=1;
    source.status.bridgeReady=true;fixture::sourceDevice=device.identity;
    const auto priorNativeRevision=native_mfg::Session().Read().revision;
    const auto priorNrSets=fixture::nrSets,priorFgSaves=fixture::sourceSaves,priorSetups=fixture::providerSetups;
    control::RuntimeAuto xp12("component",false,true);xp12.Start();
    value=xp12.Read();CHECK(value["renderingAdapterLuid"].is_null());
    CHECK(value["vulkanFgQualification"]["applicable"]==true&&value["vulkanFgQualification"]["state"]=="waiting");
    CHECK(value["features"]["nr"]["runtimeRequested"].is_null());
    CHECK(xp12.Configure(Request(value,true,true,true))["code"]=="waiting_for_rendering_context");
    auto xpCommand=Request(value,false,false,false,false);xpCommand["revision"]=0;xpCommand["settings"]={{"enabled",false}};
    CHECK(xp12.ConfigureNr(xpCommand)["code"]=="unavailable");
    CHECK(fixture::nrSets==priorNrSets&&fixture::sourceSaves==priorFgSaves&&fixture::providerSetups==priorSetups);
    CHECK(native_mfg::Session().Read().revision==priorNativeRevision);
    vulkan_fg::Owner vk;vk.xplaneNative=vk.graphicsQueue=vk.presentObserved=vk.surfaceMetadataValid=true;
    vk.sampledAt=GetTickCount64();vk.providerAvailable=Evidence::No;
    auto& identity=vk.binding;identity.pid=42;identity.birth=12345;identity.device=device.identity;identity.luid=device.luid;
    identity.output=800;identity.generation=51;identity.queue=810;identity.queueFamily=2;
    identity.format=44;identity.width=1920;identity.height=1080;identity.layers=1;
    runtime_render::State().Publish(device,800,51,"vulkan",UINT32_MAX,GetTickCount64(),{},&vk);
    value=xp12.Read();CHECK(value["api"]=="vulkan"&&value["view"]==UINT32_MAX);
    CHECK(value["vulkanFgQualification"]["state"]=="unsupported"&&value["vulkanFgQualification"]["ownerBound"]==true);
    CHECK(value["vulkanFgQualification"]["canActivate"]==false&&value["vulkanFgQualification"]["view"].is_null());
    reply=xp12.Configure(Request(value,true,true,true));value=xp12.Read();
    CHECK(value["features"]["frameGeneration"]["state"]=="unsupported");
    CHECK(value["features"]["frameGeneration"]["route"]=="XP12 native Vulkan FG admission"&&
          value["features"]["frameGeneration"]["canConfigure"]==false);
    CHECK(value["features"]["nr"]["runtimeRequested"].is_null()&&value["features"]["upscaling"]["accepted"]==false);
    xpCommand=Request(value,true,false,false);xpCommand["revision"]=0;xpCommand["settings"]={{"enabled",true}};
    CHECK(xp12.ConfigureNr(xpCommand)["code"]=="unavailable");
    CHECK(fixture::nrSets==priorNrSets&&fixture::sourceSaves==priorFgSaves&&fixture::providerSetups==priorSetups);
    const auto beforeFormat=Request(value,true,true,true);++vk.binding.format;
    runtime_render::State().Publish(device,800,51,"vulkan",UINT32_MAX,GetTickCount64(),{},&vk);
    CHECK(xp12.Configure(beforeFormat)["code"]=="conflict");
    const auto vkOutput=xp12.Read()["outputId"];
    Publish();CHECK(xp12.Read()["api"]=="vulkan"&&xp12.Read()["outputId"]==vkOutput);
    runtime_render::State().RetireVulkan(800);value=xp12.Read();
    CHECK(value["renderingAdapterLuid"].is_null()&&value["vulkanFgQualification"]["state"]=="retiring");
    CHECK(!value["nativeFgCapability"]["observed"].get<bool>());
    CHECK(fixture::nrSets==priorNrSets&&fixture::sourceSaves==priorFgSaves);
    CHECK(native_mfg::Session().Read().revision==priorNativeRevision);
    std::cout<<checks<<" production native Auto/passive callback checks passed; no Windows, GPU or presentation qualification.\n";
}
