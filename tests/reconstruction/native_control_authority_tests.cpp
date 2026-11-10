#include "NativeMfgControl.h"
#include "../../Beta/optiscaler/OptiScaler/menu/native_mfg_ui_state.h"
#include "../../Beta/optiscaler/OptiScaler/menu/native_mfg_ui_state.h"
#include "../../Beta/optiscaler/OptiScaler/menu/native_mfg_ui_diagnostics.h"
#include "NativeFgStateQuery.h"
#include "NativeFgStateQueryLock.h"
#include "ExternalFgTelemetry.h"
#include "RuntimeRenderContext.h"
#include "StreamlineOptionsSnapshot.h"
#include <atomic>
#include <compare>
#include <functional>
#include <iostream>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#define _ReturnAddress() nullptr

static std::pair<std::string,std::string> DlssgCallerSite(void*){return {"fixture.dll","0x0"};}

static unsigned checks=0;
#define CHECK(x) do {++checks;if(!(x))throw std::runtime_error(std::string(#x)+" @"+std::to_string(__LINE__));} while(false)
#define LOG_WARN(...) ((void)0)
#define LOG_INFO(...) ((void)0)
#define LOG_ERROR(...) ((void)0)
#define LOG_TRACE(...) ((void)0)
static uint64_t now=100000;
static uint64_t GetTickCount64(){return now;}
static unsigned GetCurrentThreadId(){return 19;}
enum class FGInput {NoFG,DLSSG};
enum class FGOutput {NoFG,DLSSG};
enum API {NotSelected=0,DX11,DX12,Vulkan};
struct feature_version {unsigned major=0,minor=0,patch=0;auto operator<=>(const feature_version&)const=default;};
struct State {
    bool nativeGameFrameGeneration=false,externalFrameGeneration=false,optiMfgExternalController=false,dlssgGameDMFGSupported=true;
    API api=API::DX12;
    FGInput activeFgInput=FGInput::NoFG;FGOutput activeFgOutput=FGOutput::NoFG;
    feature_version streamlineVersion{2,7,1};
    std::optional<int> dlssgMfgMax=3;
    sl::DLSSGMode dlssgLastSetMode=sl::DLSSGMode::eOff;
    std::atomic<uint64_t> dlssgTemporalSignature{0};
    static State& Instance(){static State state;return state;}
};
template<class T> struct Setting {
    std::optional<T> data;
    bool has_value()const{return data.has_value();}
    T value()const{return data.value();}
    T value_or_default()const{return data.value_or(T{});}
    std::optional<T> value_for_config()const{return data;}
    void reset(){data.reset();}
    Setting& operator=(T value){data=value;return *this;}
};
struct Config {
    Setting<bool> FGDLSSGOverrideForceDMFG;
    Setting<int> FGDLSSGOverrideInterpolationCount;
    Setting<float> FGDLSSGFramerateTargetDMFG;
    unsigned writes=0;bool writeOkay=true;
    std::optional<int> savedRatio;bool savedDynamic=false;
    std::function<void()> duringSave;
#include "native_config_payload.inc"
    bool SaveIni(const NativeMfgSave* nativeMfg=nullptr);
    static Config* Instance(){static Config value;return &value;}
};
// Actual native-key serialization/restoration bodies run below. The INI
// container and final disk write are seams; SetOptions can interleave there.
struct SerializedIni {
    std::map<std::string,std::string> values;
    void SetValue(const char*,const char* key,const char* value){values[key]=value;}
};
static SerializedIni ini;
static const int absoluteFileName=0;
static std::string GetIntValue(std::optional<int> value){return value?std::to_string(*value):"auto";}
static std::string GetFloatValue(std::optional<float> value){return value?std::to_string(*value):"auto";}
static std::string GetBoolValue(std::optional<bool> value){return value?(*value?"true":"false"):"auto";}
static bool SaveOwnedIni(SerializedIni& value,int){
    auto& config=*Config::Instance();++config.writes;
    if(config.duringSave){auto f=std::move(config.duringSave);f();}
    if(!config.writeOkay)return false;
    const auto& count=value.values.at("OverrideInterpolationCount");
    config.savedRatio=count=="auto"?std::nullopt:std::optional<int>(std::stoi(count));
    config.savedDynamic=value.values.at("OverrideForceDMFG")=="true";
    return true;
}
bool Config::SaveIni(const NativeMfgSave* nativeMfg){
#include "native_config_values.inc"
#include "native_config_write.inc"
}
namespace MfgUnlock {static void TryApply(){}}
namespace fixture {
inline sl::DLSSGOptions sent{};
inline sl::Result result=sl::Result::eOk;
inline unsigned providerCalls=0,providerQueries=0,updates=0;
inline bool externalDynamic=true;
sl::Result Query(const sl::ViewportHandle&,sl::DLSSGState& state,const sl::DLSSGOptions*){
    ++providerQueries;
    state.numFramesToGenerateMax=3;state.numFramesActuallyPresented=2;
    if(state.structVersion>=4)state.bIsDynamicMFGSupported=externalDynamic?sl::eTrue:sl::eFalse;
    return result;
}
inline bool owned=false;
sl::Result Provider(const sl::ViewportHandle&,const sl::DLSSGOptions& options){++providerCalls;sent=options;return result;}
}
namespace optishade::external_fg {
template<class Function> struct Target {
    Function function;
    template<class Resolver> Target(Resolver,sl::Feature,const char*){
        if constexpr(std::is_same_v<Function,decltype(&slDLSSGGetState)>)function=&fixture::Query;
        else function=&fixture::Provider;
    }
    uint64_t NativeIdentity()const{return reinterpret_cast<uint64_t>(&fixture::Provider);}
};
}
namespace optishade::session {struct Journal {std::map<std::string,std::string> fields,criticalFields;unsigned criticalWrites=0;void Put(std::initializer_list<std::pair<const std::string,std::string>> values) {for(const auto& value:values)fields[value.first]=value.second;}void PutCritical(std::initializer_list<std::pair<const std::string,std::string>> values){++criticalWrites;for(const auto& value:values){fields[value.first]=value.second;criticalFields[value.first]=value.second;}}void PutResolvedProviderCall(std::initializer_list<std::pair<const std::string,std::string>> values){for(const auto& value:values)fields[value.first]=value.second;}};static Journal& State(){static Journal value;return value;}}
namespace optishade::native_mfg {
struct GuardedStateCall {sl::Result result=sl::Result::eErrorExceptionHandler;unsigned long exceptionCode=0;bool suppressedAfterFault=false;};
template<class Function> static GuardedStateCall InvokeGetStateGuarded(Function function,const sl::ViewportHandle& view,sl::DLSSGState& state,const sl::DLSSGOptions* options,std::atomic<bool>* faultLatch){
    GuardedStateCall outcome{};if(faultLatch&&faultLatch->load()){outcome.suppressedAfterFault=true;return outcome;}
    if(!function){outcome.result=sl::Result::eErrorFeatureMissing;return outcome;}
    try{outcome.result=function(view,state,options);}catch(...){outcome.exceptionCode=1;if(faultLatch)faultLatch->store(true);}
    return outcome;
}
static GuardedStateCall InvokeSetOptionsGuarded(decltype(&slDLSSGSetOptions) function,const sl::ViewportHandle& view,const sl::DLSSGOptions& options,std::atomic<bool>* faultLatch){
    GuardedStateCall outcome{};if(faultLatch&&faultLatch->load()){outcome.suppressedAfterFault=true;return outcome;}
    if(!function){outcome.result=sl::Result::eErrorFeatureMissing;return outcome;}
    try{outcome.result=function(view,options);}catch(...){outcome.exceptionCode=1;if(faultLatch)faultLatch->store(true);}
    return outcome;
}
}
static std::atomic<bool> dlssgStateProviderFaulted{false};
static void RecordDlssGStateProviderFault(const char* controlPath,const optishade::native_mfg::GuardedStateCall& fault){if(fault.exceptionCode)optishade::session::State().PutCritical({{"FGControlPath",controlPath},{"FGStateProviderFaulted","Yes"}});}
static void RecordDlssGOptionsProviderFault(const char* controlPath,const optishade::native_mfg::GuardedStateCall& fault){if(fault.exceptionCode)optishade::session::State().PutCritical({{"FGControlPath",controlPath},{"FGSetOptionsProviderFaulted","Yes"}});}
namespace magic_enum {template<class T> const char* enum_name(T){return "fixture";}}
struct ID3D12Fence {};
namespace DlssNr {
inline unsigned consumedFenceCalls=0;
inline ID3D12Fence* consumedFence=nullptr;
inline uint64_t consumedFenceValue=0;
static void TaaFgInputsConsumed(uint32_t,ID3D12Fence* fence,uint64_t value){if(!fence||!value)return;++consumedFenceCalls;consumedFence=fence;consumedFenceValue=value;}
}
struct StreamlineHooks {
    inline static decltype(&slDLSSGSetOptions) o_slDLSSGSetOptions=&fixture::Provider;
    inline static sl::RenderAPI renderApi=sl::RenderAPI::eD3D12;
    static sl::Result hkslDLSSGSetOptions(const sl::ViewportHandle&,const sl::DLSSGOptions&);
    static sl::Result ExternalOptions(const sl::ViewportHandle&,const sl::DLSSGOptions&);
    static sl::Result ExternalState(const sl::ViewportHandle&,sl::DLSSGState&,const sl::DLSSGOptions*);
    static sl::Result ResolveExternal(sl::Feature,const char*,void*&){return sl::Result::eOk;}
    static void applyMenuDlssgInterlock(sl::DLSSGOptions&,bool){}
    static void updateDlssgOptions(){++fixture::updates;}
};
#include "external_options_body.inc"
#include "external_state_body.inc"
// Persistence/logging is intentionally outside this CPU-only callback fixture.
// Production telemetry has its own source-contract assertions; keep the
// extracted request/authority body executable without importing Windows state.
static void RecordManagedDlssgOptions(const sl::DLSSGOptions&,const sl::DLSSGOptions&,
                                      sl::Result,const optishade::native_mfg::Snapshot&,
                                      bool,uint32_t,bool){}
#include "native_options_body.inc"
namespace optishade::mfg {
struct FixturePublication {struct State {bool owned=false;} state;};
struct FixtureService {struct Worker {std::shared_ptr<FixturePublication> Peek(){auto value=std::make_shared<FixturePublication>();value->state.owned=fixture::owned;return value;}} worker;};
static FixtureService& UiStatus(){static FixtureService service;return service;}
}
namespace OptiShadeMfgUI {
static optishade::native_mfg::UiDraft nativePanel;
#include "native_ui_authority.inc"
#include "native_ui_save.inc"
}

// Input and drawing are fixture seams; the production specialist-control body
// below must stage its mode through the same draft as the primary FG tiles.
namespace ImGui {
inline std::string click;
inline bool checkboxValue=false;
inline unsigned disabled=0;
inline void BeginDisabled(bool value=true){disabled+=value?1:0;}
inline void EndDisabled(){disabled=0;}
inline bool Button(const char* label){return !disabled&&click==label;}
inline bool Checkbox(const char* label,bool* value){if(!disabled&&click==label){*value=checkboxValue;return true;}return false;}
inline void TextWrapped(const char*,...){}
inline void SliderFloat(const char*,float*,float,float,const char*){}
inline void SameLine(float,float){}
}
static void ShowHelpMarker(const char*){}
static void AdvancedMode(){
    auto& state=State::Instance();auto* config=Config::Instance();
    const bool dlssgInputOrOutput=state.activeFgInput==FGInput::DLSSG||state.activeFgOutput==FGOutput::DLSSG;
#include "native_advanced_mode.inc"
}

struct GpuInformation {uint64_t luid=0;std::string name;};
namespace optishade::actual_gpu {inline std::optional<GpuInformation> current;static auto Current(){return current;}}
#include "native_gpu_selector.inc"

static uint64_t ProviderIdentity(){return reinterpret_cast<uint64_t>(&fixture::Provider);}
static void Observe(bool controllable=true,bool dynamic=true){
    auto& context=optishade::runtime_render::State();
    const optishade::runtime_render::Device device{101,202,0x10de,0x2484,0,false,"Rendering device"};
    context.Publish(device,303,4,"d3d12",7,now);context.StreamlineDevice(device);
    optishade::native_mfg::Session().Observe(ProviderIdentity(),7,3,controllable,true,dynamic);
    const auto state=optishade::native_mfg::Session().Read();
    context.NativeState(state.provider,state.generation,7,1,now,!controllable);
}
static void Call(sl::DLSSGMode mode=sl::DLSSGMode::eOn,unsigned generated=1){sl::DLSSGOptions options{};options.mode=mode;options.numFramesToGenerate=generated;CHECK(StreamlineHooks::hkslDLSSGSetOptions(sl::ViewportHandle(7),options)==fixture::result);}
static void StageAndSave(int desired,bool dynamic=false){
    auto& control=optishade::native_mfg::Session();auto& draft=OptiShadeMfgUI::nativePanel;
    draft.Observe(control.Read());CHECK(draft.Stage(control.Read(),desired,dynamic));
    CHECK(OptiShadeMfgUI::NativeCanSave());CHECK(OptiShadeMfgUI::SaveNative(*Config::Instance()));
}
static void CompleteDraft(){OptiShadeMfgUI::nativePanel.Observe(optishade::native_mfg::Session().Read());CHECK(!OptiShadeMfgUI::nativePanel.awaiting);}

int main(){try{
    using namespace optishade;
    CHECK(std::string(native_mfg_ui::CapabilityQueryDetail("Provider query skipped: caller is not synchronized with Present")).find("DLSS-G GetState away from its Present thread")!=std::string::npos);
    CHECK(std::string(native_mfg_ui::CapabilityQueryDetail("Provider query skipped: no Present thread has been observed")).find("before OptiShade observed a rendered Present")!=std::string::npos);
    CHECK(native_mfg_ui::CapabilityQueryDetail("unrelated status")[0]=='\0');
    {
        runtime_render::Context diagnosticContext;
        diagnosticContext.NativeUnavailable("Provider query skipped: caller is not synchronized with Present");
        CHECK(diagnosticContext.Read().nativeUnavailableReason=="Provider query skipped: caller is not synchronized with Present");
        diagnosticContext.NativeUnavailable();
        CHECK(diagnosticContext.Read().nativeUnavailableReason=="Provider query skipped: caller is not synchronized with Present");
    }
    auto& control=native_mfg::Session();auto& draft=OptiShadeMfgUI::nativePanel;auto& config=*Config::Instance();
    draft.dirty=true;draft.awaiting=1;CHECK(std::string(OptiShadeMfgUI::NativeSaveBlockedReason()).find("applying")!=std::string::npos);CHECK(std::string(OptiShadeMfgUI::NativeSaveFooterStatus()).find("Applying")!=std::string::npos);
    draft.awaiting=0;draft.conflict=true;CHECK(std::string(OptiShadeMfgUI::NativeSaveBlockedReason()).find("provider state changed")!=std::string::npos);CHECK(std::string(OptiShadeMfgUI::NativeSaveFooterStatus()).find("reload draft")!=std::string::npos);
    draft.conflict=false;draft.dirty=false;CHECK(std::string(OptiShadeMfgUI::NativeSaveBlockedReason()).find("No unsaved")!=std::string::npos);
    {
        State::Instance().dlssgLastSetMode=sl::DLSSGMode::eOff;
        sl::DLSSGOptions redundantOff{};redundantOff.mode=sl::DLSSGMode::eOff;redundantOff.numFramesToGenerate=0;
        const auto callsBefore=fixture::providerCalls;
        CHECK(StreamlineHooks::hkslDLSSGSetOptions(sl::ViewportHandle(7),redundantOff)==sl::Result::eOk);
        CHECK(fixture::providerCalls==callsBefore);
    }
    Observe(false);auto passive=control.Read();draft.dirty=true;
    CHECK(std::string(OptiShadeMfgUI::NativeSaveBlockedReason()).find("fresh native frame-generation control")!=std::string::npos);
    CHECK(std::string(OptiShadeMfgUI::NativeSaveFooterStatus()).find("Waiting for live FG control")!=std::string::npos);
    CHECK(native_mfg::Control::Fresh(passive));CHECK(!native_mfg::Control::CanConfigure(passive));
    CHECK(native_mfg::ClassifyAvailability(true,false,native_mfg::GraphicsApi::Direct3D12,3,false)==native_mfg::AvailabilityReason::ObservationOnly);
    CHECK(native_mfg_ui::CapabilityRangeDetail(1).find("one generated frame (2x)")!=std::string::npos);
    CHECK(native_mfg_ui::CapabilityRangeDetail(1).find("has not exposed 3x or higher")!=std::string::npos);
    CHECK(native_mfg_ui::CapabilityRangeDetail(3).find("2x to 4x")!=std::string::npos);
    CHECK(!control.Request(passive,1));CHECK(!native_mfg::Control::BoundToCall(passive,ProviderIdentity(),7,native_mfg::Control::Now()));
    draft.Observe(passive);CHECK(!draft.Stage(passive,1));draft.desired=1;draft.dirty=true;
    CHECK(!OptiShadeMfgUI::NativeCanSave());CHECK(!OptiShadeMfgUI::SaveNative(config));CHECK(config.writes==0&&!control.Read().pending);
    Observe();draft.Discard(control.Read());
    {
        auto state=control.Read();state.maximum=1;
        const auto live=runtime_render::State().Read();
        CHECK(native_mfg_ui::ControlBlocker(state,false,false,live,now)==std::string("The live provider supports 2x frame generation; higher multipliers are limited to its reported maximum."));
        auto mismatch=live;mismatch.native.provider++;
        CHECK(native_mfg_ui::ControlBlocker(state,false,false,mismatch,now)==std::string("The capability report and settings callback belong to different providers."));
        CHECK(native_mfg_ui::ControlBlocker(state,true,false,live,now)==std::string("A compatibility MFG provider owns this session."));
    }
    CHECK(control.Read().generation!=passive.generation);CHECK(!control.Request(passive,1));

    // At revision zero, callbacks still use committed startup Config. A draft
    // must never escape through that fallback while Save is writing to disk.
    config.FGDLSSGOverrideInterpolationCount=1;config.FGDLSSGOverrideForceDMFG=false;
    CHECK(draft.Stage(control.Read(),3));config.writeOkay=false;config.duringSave=[]{Call();ini.values["UnrelatedConcurrentSetting"]="preserved";};
    CHECK(!OptiShadeMfgUI::SaveNative(config));
    CHECK(fixture::sent.numFramesToGenerate==1&&config.FGDLSSGOverrideInterpolationCount.value()==1);
    CHECK(control.Read().revision==0&&!control.Read().pending&&draft.dirty);
    CHECK(ini.values["OverrideInterpolationCount"]=="1"&&ini.values["UnrelatedConcurrentSetting"]=="preserved");
    config.writeOkay=true;config.duringSave=[]{Call();runtime_render::State().Invalidate(303);};
    CHECK(!OptiShadeMfgUI::SaveNative(config));
    CHECK(fixture::sent.numFramesToGenerate==1&&config.savedRatio==1&&config.FGDLSSGOverrideInterpolationCount.value()==1);
    CHECK(control.Read().revision==0&&!control.Read().pending&&draft.dirty);
    Observe();draft.Discard(control.Read());CHECK(draft.Stage(control.Read(),3));
    config.duringSave=[]{Call();};CHECK(OptiShadeMfgUI::SaveNative(config));
    CHECK(fixture::sent.numFramesToGenerate==1&&config.savedRatio==3&&config.FGDLSSGOverrideInterpolationCount.value()==3);
    CHECK(ini.values["OverrideInterpolationCount"]=="3");
    CHECK(SaveOwnedIni(ini,absoluteFileName)&&config.savedRatio==3);
    Call();CHECK(fixture::sent.numFramesToGenerate==3);CompleteDraft();
    Observe(false);Observe();draft.Discard(control.Read());

    // Existing saved Dynamic/ratio settings retain startup meaning. The first
    // explicit Follow/disable action must retire that legacy fallback too.
    config.FGDLSSGOverrideForceDMFG=true;config.FGDLSSGOverrideInterpolationCount=2;
    Call();CHECK(fixture::sent.mode==sl::DLSSGMode::eDynamic&&control.Read().revision==0);
    ImGui::click="Force Dynamic MFG";ImGui::checkboxValue=false;AdvancedMode();ImGui::click.clear();
    CHECK(draft.dirty&&!draft.dynamic);config.writeOkay=false;config.duringSave=[]{Call();};
    CHECK(!OptiShadeMfgUI::SaveNative(config));
    CHECK(fixture::sent.mode==sl::DLSSGMode::eDynamic&&config.FGDLSSGOverrideForceDMFG.value_or_default()&&control.Read().revision==0);
    CHECK(ini.values["OverrideForceDMFG"]=="true");
    config.writeOkay=true;config.duringSave=[]{Call();};CHECK(OptiShadeMfgUI::SaveNative(config));
    CHECK(fixture::sent.mode==sl::DLSSGMode::eDynamic&&!config.FGDLSSGOverrideForceDMFG.value_or_default());
    Call();CHECK(fixture::sent.mode==sl::DLSSGMode::eOn&&fixture::sent.numFramesToGenerate==1);CompleteDraft();

    // New fixed tiles, the retained dynamic switch, and Follow game overwrite
    // one another only through the same saved/revisioned native request.
    StageAndSave(3);CHECK(config.savedRatio==3&&!config.savedDynamic);Call();
    CHECK(fixture::sent.mode==sl::DLSSGMode::eOn&&fixture::sent.numFramesToGenerate==3);CompleteDraft();
    const auto writes=config.writes;ImGui::click="Force Dynamic MFG";ImGui::checkboxValue=true;AdvancedMode();ImGui::click.clear();
    CHECK(draft.dynamic&&draft.dirty);CHECK(config.writes==writes&&!config.FGDLSSGOverrideForceDMFG.value_or_default());
    CHECK(control.Read().desired==3&&!control.Read().dynamic);
    CHECK(OptiShadeMfgUI::SaveNative(config));CHECK(config.savedDynamic&&!config.savedRatio);
    Call();CHECK(fixture::sent.mode==sl::DLSSGMode::eDynamic);CHECK(control.Read().dynamic&&!control.Read().pending);CompleteDraft();
    CHECK(native_mfg_ui::ToggleEnabled(true,true,-1,0,true));
    CHECK(!native_mfg_ui::ToggleEnabled(false,false,-1,2,false));
    CHECK(native_mfg_ui::ToggleEnabled(false,true,-1,2,false));
    CHECK(!native_mfg_ui::ToggleEnabled(false,true,0,2,false));
    CHECK(native_mfg_ui::ToggleEnabled(false,true,2,0,false));
    CHECK(native_mfg_ui::CanStageInitialRequest(false,false,false,false));
    CHECK(!native_mfg_ui::CanStageInitialRequest(true,false,false,false));
    CHECK(!native_mfg_ui::CanStageInitialRequest(false,true,false,false));
    CHECK(!native_mfg_ui::CanStageInitialRequest(false,false,true,false));
    CHECK(!native_mfg_ui::CanStageInitialRequest(false,false,false,true));
    {
        native_mfg::UiDraft queued;native_mfg::Snapshot absent;
        CHECK(queued.StagePending(absent,1));
        CHECK(queued.pendingProvider&&queued.dirty&&!queued.initialized&&queued.desired==1);
        CHECK(native_mfg_ui::ToggleEnabled(false,false,queued.desired,0,false,queued.pendingProvider));
        native_mfg::Control liveControl;liveControl.Observe(77,9,1,true,false,false);
        const auto live=liveControl.Read();queued.Observe(live,false);
        CHECK(queued.pendingProvider&&!queued.initialized&&queued.dirty);
        queued.Observe(live,true);
        CHECK(queued.initialized&&!queued.pendingProvider&&queued.dirty&&!queued.conflict);
        CHECK(queued.generation==live.generation&&queued.revision==live.revision);
        CHECK(queued.Submit(liveControl,live)&&liveControl.Read().pending);
    }
    {
        // A game can expose DLSS-G capability before OptiShade binds it to
        // the active rendered output. The tester may stage 2x; Save & Go
        // remains unavailable until the binding is verified.
        native_mfg::Control unboundControl;unboundControl.Observe(88,4,1,true,false,false);
        const auto live=unboundControl.Read();native_mfg::UiDraft unbound;
        CHECK(unbound.StagePending(live,1));
        CHECK(unbound.pendingProvider&&unbound.dirty&&!unbound.initialized);
        unbound.Observe(live,false);
        CHECK(unbound.pendingProvider&&!unbound.initialized&&unbound.dirty);
        unbound.Observe(live,true);
        CHECK(unbound.initialized&&!unbound.pendingProvider&&unbound.dirty&&!unbound.conflict);
        CHECK(unbound.generation==live.generation&&unbound.revision==live.revision);
        CHECK(unbound.Submit(unboundControl,live)&&unboundControl.Read().pending);
    }
    {
        native_mfg::UiDraft waiting;native_mfg::Snapshot active;
        active.provider=44;active.generation=3;active.revision=8;active.sampledAt=native_mfg::Control::Now();
        active.maximum=2;active.acceptedGenerated=1;active.known=true;active.controllable=true;
        waiting.Discard(active);auto staleActive=active;staleActive.sampledAt=native_mfg::Control::Now()-3001;
        CHECK(native_mfg_ui::StageOffWhileWaiting(waiting,staleActive));CHECK(waiting.desired==0&&!waiting.dynamic&&waiting.dirty);
        CHECK(active.desired==-1&&active.acceptedGenerated==1);
        auto replaced=staleActive;replaced.generation++;CHECK(!native_mfg_ui::StageOffWhileWaiting(waiting,replaced));
        replaced=staleActive;replaced.revision++;CHECK(!native_mfg_ui::StageOffWhileWaiting(waiting,replaced));
        waiting.Discard(active);active.acceptedGenerated=0;CHECK(!native_mfg_ui::StageOffWhileWaiting(waiting,active));
    }
    ImGui::click="Follow game's frame-generation mode";AdvancedMode();ImGui::click.clear();
    CHECK(draft.dirty&&!draft.dynamic&&draft.desired==-1);CHECK(OptiShadeMfgUI::SaveNative(config));
    CHECK(!config.savedDynamic&&!config.savedRatio);Call(sl::DLSSGMode::eOn,2);
    CHECK(fixture::sent.mode==sl::DLSSGMode::eOn&&fixture::sent.numFramesToGenerate==2);CompleteDraft();
    StageAndSave(0);Call();CHECK(fixture::sent.mode==sl::DLSSGMode::eOff&&!control.Read().pending);CompleteDraft();
    StageAndSave(-1,true);Call(sl::DLSSGMode::eOff);CHECK(fixture::sent.mode==sl::DLSSGMode::eOff&&control.Read().pending);
    Call();CHECK(fixture::sent.mode==sl::DLSSGMode::eDynamic&&!control.Read().pending);CompleteDraft();
    State::Instance().api=API::Vulkan;Call();CHECK(fixture::sent.mode==sl::DLSSGMode::eOn&&fixture::sent.numFramesToGenerate==1);
    State::Instance().api=API::DX12;Call();CHECK(fixture::sent.mode==sl::DLSSGMode::eDynamic);
    StageAndSave(2);Call();CHECK(!control.Read().dynamic&&fixture::sent.mode==sl::DLSSGMode::eOn&&fixture::sent.numFramesToGenerate==2);CompleteDraft();

    // Unknown option layouts are forwarded unchanged. A Dynamic override is
    // explicitly refused, so the menu receives a result instead of waiting.
    StageAndSave(-1,true);sl::DLSSGOptions unknown{};unknown.structVersion=99;
    unknown.mode=sl::DLSSGMode::eOn;unknown.numFramesToGenerate=2;
    CHECK(StreamlineHooks::hkslDLSSGSetOptions(sl::ViewportHandle(7),unknown)==sl::Result::eOk);
    CHECK(fixture::sent.structVersion==99&&fixture::sent.mode==sl::DLSSGMode::eOn&&fixture::sent.numFramesToGenerate==2);
    CHECK(control.Read().attempted&&control.Read().result==static_cast<int>(sl::Result::eErrorInvalidParameter));
    CompleteDraft();CHECK(!draft.awaiting);

    // Rejection and stale UI owners retain their drafts and never bypass the
    // compatibility owner or save an uncallable passive request to disk.
    StageAndSave(3);fixture::result=sl::Result::eErrorInvalidParameter;Call();
    CHECK(control.Read().pending&&control.Read().result!=0);CompleteDraft();fixture::result=sl::Result::eOk;
    CHECK(draft.Stage(control.Read(),2));fixture::owned=true;const auto beforeOwned=config.writes;
    CHECK(!OptiShadeMfgUI::NativeCanSave());CHECK(!OptiShadeMfgUI::SaveNative(config));CHECK(config.writes==beforeOwned);fixture::owned=false;
    config.writeOkay=false;const auto beforeFailed=control.Read().revision;
    CHECK(!OptiShadeMfgUI::SaveNative(config));CHECK(control.Read().revision==beforeFailed&&config.FGDLSSGOverrideInterpolationCount.value()==3);config.writeOkay=true;
    config.duringSave=[]{Observe(false);};const auto savedRatio=config.savedRatio;
    CHECK(!OptiShadeMfgUI::SaveNative(config));CHECK(config.savedRatio==savedRatio&&!control.Read().pending);
    CHECK(!native_mfg::Control::CanConfigure(control.Read()));
    Observe();draft.Discard(control.Read());
    auto unbound=runtime_render::State().Read();
    CHECK(runtime_render::NativeCapabilityBound(unbound,control.Read(),now));
    unbound.native.view=9;CHECK(!runtime_render::NativeCapabilityBound(unbound,control.Read(),now));
    unbound=runtime_render::State().Read();unbound.native.device=999;CHECK(!runtime_render::NativeCapabilityBound(unbound,control.Read(),now));
    unbound=runtime_render::State().Read();unbound.native.generation+=1;CHECK(!runtime_render::NativeCapabilityBound(unbound,control.Read(),now));
    runtime_render::State().Invalidate(303);CHECK(!OptiShadeMfgUI::NativeOwnerAvailable(control.Read()));
    Observe();draft.Discard(control.Read());CHECK(draft.Stage(control.Read(),2));
    const auto beforeRetirement=config.savedRatio;config.duringSave=[]{runtime_render::State().Invalidate(303);};
    CHECK(!OptiShadeMfgUI::SaveNative(config));CHECK(config.savedRatio==beforeRetirement&&!control.Read().pending);
    Observe();draft.Discard(control.Read());
    StageAndSave(-1,true);Call();CompleteDraft();Observe(true,false);
    CHECK(!control.Read().dynamic&&control.Read().desired==-1&&control.Read().pending);
    CHECK(!control.Request(control.Read(),-1,true));Call();CHECK(!control.Read().pending);
    auto stale=control.Read();stale.sampledAt=native_mfg::Control::Now()-3001;CHECK(!native_mfg::Control::CanConfigure(stale));

    // A provider reporting Dynamic on the qualified external route cannot
    // create a writable Dynamic mode: that delegate exposes fixed/off/follow.
    Observe();State::Instance().externalFrameGeneration=true;
    sl::DLSSGState externalState{};externalState.structVersion=4;
    const auto queriesBeforeUnsafe=fixture::providerQueries;
    CHECK(StreamlineHooks::ExternalState(sl::ViewportHandle(7),externalState,nullptr)==sl::Result::eErrorFeatureMissing);
    CHECK(fixture::providerQueries==queriesBeforeUnsafe);
    CHECK(optishade::session::State().fields["FGStateQueryStage"]=="Provider query skipped: no Present thread has been observed");
    CHECK(optishade::session::State().fields["FGStateQueryCount"]=="1");
    CHECK(optishade::external_fg_telemetry::Session().RecordStateCall(17,99950).stateQueryCount==2);
    CHECK(StreamlineHooks::ExternalState(sl::ViewportHandle(7),externalState,nullptr)==sl::Result::eErrorFeatureMissing);
    CHECK(fixture::providerQueries==queriesBeforeUnsafe);
    CHECK(optishade::session::State().fields["FGStateQueryCount"]=="1");
    optishade::external_fg_telemetry::Session().RecordPresentCall(18,99900,0x1234);
    CHECK(StreamlineHooks::ExternalState(sl::ViewportHandle(7),externalState,nullptr)==sl::Result::eErrorFeatureMissing);
    CHECK(fixture::providerQueries==queriesBeforeUnsafe);
    CHECK(optishade::session::State().fields["FGStateQueryStage"]=="Provider query skipped: caller is not synchronized with Present");
    optishade::external_fg_telemetry::Session().RecordPresentCall(19,99901,0x5678);
    CHECK(StreamlineHooks::ExternalState(sl::ViewportHandle(7),externalState,nullptr)==sl::Result::eOk);
    CHECK(fixture::providerQueries==queriesBeforeUnsafe+1);
    CHECK(optishade::session::State().fields["FGStateCallerThreadId"]=="19");
    CHECK(optishade::session::State().fields["FGStateQueryCount"]=="5");
    CHECK(optishade::session::State().criticalWrites==3);
    CHECK(optishade::session::State().criticalFields["FGStateQueryStage"]=="Provider call pending");
    CHECK(optishade::session::State().criticalFields["FGStateResult"]=="Pending");
    CHECK(optishade::session::State().criticalFields["FGPresentSwapchainId"]=="22136");
    CHECK(optishade::session::State().fields["FGStateQueryStage"]=="Provider call completed");
    CHECK(optishade::session::State().fields["FGStateThreadMatchesLastPresent"]=="Yes");
    CHECK(optishade::session::State().fields["FGPresentSampleSource"]=="Streamline provider Present boundary");
    CHECK(externalState.bIsDynamicMFGSupported==sl::eTrue);
    CHECK(control.Read().controllable&&!control.Read().dynamicSupported);
    CHECK(!control.Request(control.Read(),-1,true));
    CHECK(control.Request(control.Read(),-1));Call(sl::DLSSGMode::eDynamic);
    CHECK(fixture::sent.mode==sl::DLSSGMode::eDynamic&&!control.Read().pending);
    // An explicit external-provider request must activate MFG even when the
    // game's own options packet remains Off on every frame.
    CHECK(control.Request(control.Read(),2));Call(sl::DLSSGMode::eOff);
    CHECK(fixture::sent.mode==sl::DLSSGMode::eOn&&fixture::sent.numFramesToGenerate==2&&!control.Read().pending);
    CHECK(control.Request(control.Read(),0));Call(sl::DLSSGMode::eOn,2);
    CHECK(fixture::sent.mode==sl::DLSSGMode::eOff&&!control.Read().pending);
    ID3D12Fence d3dFence{};externalState.inputsProcessingCompletionFence=&d3dFence;
    externalState.lastPresentInputsProcessingCompletionFenceValue=44;
    CHECK(StreamlineHooks::ExternalState(sl::ViewportHandle(7),externalState,nullptr)==sl::Result::eOk);
    CHECK(DlssNr::consumedFenceCalls==1);
    CHECK(DlssNr::consumedFence==&d3dFence);
    CHECK(DlssNr::consumedFenceValue==44);
    StreamlineHooks::renderApi=sl::RenderAPI::eVulkan;
    externalState.inputsProcessingCompletionFence=reinterpret_cast<void*>(uintptr_t(0x1234));
    externalState.lastPresentInputsProcessingCompletionFenceValue=99;
    CHECK(StreamlineHooks::ExternalState(sl::ViewportHandle(7),externalState,nullptr)==sl::Result::eOk);
    CHECK(DlssNr::consumedFenceCalls==1);
    StreamlineHooks::renderApi=sl::RenderAPI::eD3D12;
    State::Instance().externalFrameGeneration=false;

    // Once a state callback faults, no managed or external SetOptions route
    // may re-enter that provider; this is fail-closed containment, not recovery.
    const auto providerCallsBeforeFault=fixture::providerCalls;
    dlssgStateProviderFaulted.store(true,std::memory_order_release);
    sl::DLSSGOptions afterFault{};
    CHECK(StreamlineHooks::hkslDLSSGSetOptions(sl::ViewportHandle(7),afterFault)==sl::Result::eErrorExceptionHandler);
    CHECK(fixture::providerCalls==providerCallsBeforeFault);
    State::Instance().externalFrameGeneration=true;
    CHECK(StreamlineHooks::ExternalOptions(sl::ViewportHandle(7),afterFault)==sl::Result::eErrorExceptionHandler);
    CHECK(fixture::providerCalls==providerCallsBeforeFault);
    State::Instance().externalFrameGeneration=false;
    dlssgStateProviderFaulted.store(false,std::memory_order_release);

    // Reproduce the old startup race: a valid, measured Vulkan owner is still
    // ineligible for the D3D12 optional loader; this does not consume an attempt.
    runtime_render::Context rendering;runtime_render::Device device{101,202,0x10de,0x2484,0,false,"invented name, never parsed"};
    rendering.Publish(device,303,4,"vulkan",0,now);rendering.Compute(101,202,true,8,6,30);
    CHECK(!runtime_render::CompatibilityMfgSetupContextReady(rendering.Read(),now));
    rendering.Publish(device,303,4,"d3d11",0,now);CHECK(!runtime_render::CompatibilityMfgSetupContextReady(rendering.Read(),now));
    rendering.Publish(device,303,4,"d3d12",0,now);CHECK(runtime_render::CompatibilityMfgSetupContextReady(rendering.Read(),now));
    CHECK(!runtime_render::CompatibilityMfgSetupContextReady(rendering.Read(),now+3001));
    rendering.Compute(101,202,false,0,0,0);CHECK(!runtime_render::CompatibilityMfgSetupContextReady(rendering.Read(),now));
    rendering.Compute(101,202,true,7,5,20);CHECK(runtime_render::CompatibilityMfgSetupContextReady(rendering.Read(),now));
    auto xp12=rendering.Read();xp12.vulkanFg.xplaneNative=true;CHECK(!runtime_render::CompatibilityMfgSetupContextReady(xp12,now));

    // Compile the actual menu selector. A misleading product name, helper
    // adapter, or incomplete compute observation cannot admit the provider.
    runtime_render::State().Publish(device,303,4,"d3d12",0,now);
    actual_gpu::current=GpuInformation{202,"primary"};CHECK(RenderingGpu(State::Instance()).luid==202);
    CHECK(!OptionalMfgRenderingGpu(State::Instance()));
    runtime_render::State().Compute(999,888,true,8,6,30);CHECK(!OptionalMfgRenderingGpu(State::Instance()));
    runtime_render::State().Compute(101,202,true,8,6,30);CHECK(OptionalMfgRenderingGpu(State::Instance()));
    auto amd=device;amd.vendor=0x1002;amd.identity=404;amd.luid=505;amd.name="RTX 4090";
    runtime_render::State().Publish(amd,606,5,"d3d12",0,now);runtime_render::State().Compute(404,505,true,8,9,40);
    CHECK(!OptionalMfgRenderingGpu(State::Instance()));
    actual_gpu::current.reset();CHECK(RenderingGpu(State::Instance()).luid==0);
    runtime_render::State().Invalidate(606);CHECK(!OptionalMfgRenderingGpu(State::Instance()));
    std::cout<<checks<<" native control authority / production callback+UI-body checks passed; no Windows, GPU or display qualification.\n";
    return 0;
}catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}}
