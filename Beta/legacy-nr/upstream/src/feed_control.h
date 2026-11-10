// OptiShade GPL-3.0-or-later. Same session protocol/Auto controller as native NR.
// This adapter snapshots metadata; its IPC thread never touches a graphics API.
#include <iterator>
#include "../../../shared/AutoCompatibility.h"
#include "../../../shared/RuntimeControlPipe.h"
#include "../../../shared/BackgroundStatus.h"
#include "feed_preparation.h"
namespace feed_control {
using Json=optishade::control::Json;
using namespace optishade;
static automatic::Controller controller;
static std::mutex mutex;
static control::Endpoint* endpoint=nullptr;
static control::PipeServer* server=nullptr;
static HMODULE pin=nullptr;
static bool failed=false;
static legacy::Snapshot Read(){legacy::Snapshot value;OptiShadeLegacyNrReadSnapshot(&value,sizeof(value));return value;}
static const char* Api(uint32_t api){
 switch(static_cast<reshade::api::device_api>(api)){
 case reshade::api::device_api::d3d10:return "d3d10";case reshade::api::device_api::d3d11:return "d3d11";
 case reshade::api::device_api::vulkan:return "vulkan";case reshade::api::device_api::opengl:return "opengl";
 default:return "unknown";
 }
}
struct PreparedSnapshot {
 uint64_t luid=0,device=0,generation=0,qualificationSerial=0;feed_preparation::Result verification;
 std::string clientIdentity;
};
class Preparation {
 feed_preparation::Verifier verifier_;
 neural_preparation::FileHash client_;
 PreparedSnapshot Refresh(){
  PreparedSnapshot result;const auto sample=Read();const auto now=GetTickCount64();
  if(g_reshade_gone||!sample.sampleTick||now<sample.sampleTick||now-sample.sampleTick>5000)return result;
  result.luid=sample.adapterLuid;result.device=sample.deviceIdentity;result.generation=sample.deviceGeneration;
  wchar_t name[32768]{};const auto count=GetModuleFileNameW(g_self,name,32768);
  if(!count||count>=32768)return result;
  mfg::file::Handle file(CreateFileW(name,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
    nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));
  const auto path=file?mfg::file::Final(file.value):std::filesystem::path{};
  if(path.empty())return result;
  const auto clientHash=client_.Read(path.parent_path(),path);
  if(clientHash.empty()){result.verification.prepared=Evidence::No;result.verification.reason="The loaded legacy transport file could not be verified.";return result;}
  result.clientIdentity="legacy-client-file:"+clientHash;
  FeedPrepareAck qualified{};
  {std::lock_guard lock(g_observation_mutex);qualified=g_preparation_observation;result.qualificationSerial=g_preparation_serial;}
  const FeedAdapterIdentity adapter{sample.adapterLuid,sample.vendorId,sample.deviceId,1};
  if(!FeedPreparationValid(qualified,adapter)||qualified.device_generation!=sample.deviceGeneration||qualified.device_identity!=sample.deviceIdentity){
   result.verification.reason="Waiting for the existing x64 worker's measured game/model preparation; NR remains Off.";return result;
  }
  // No 32-bit compute-driver query is needed. The same x64 worker independently
  // measured this adapter, and this metadata worker also checks all file hashes.
  result.verification=verifier_.Verify(GetCurrentProcess(),GetCurrentProcessId(),adapter,path.parent_path()/L"host64",&qualified);
  return result;
 }
public:
 using Worker=BackgroundStatus<PreparedSnapshot,unsigned>;
 Worker worker;
 Preparation():worker([this]{return Refresh();},[](unsigned,std::string&){return false;},std::chrono::milliseconds(1000)){}
 PreparedSnapshot Current(const legacy::Snapshot& current)const{
  const auto publication=worker.Peek();const auto now=Worker::NowMs();
  uint64_t serial=0;{std::lock_guard lock(g_observation_mutex);serial=g_preparation_serial;}
  if(publication->state.qualificationSerial!=serial||!publication->readError.empty()||!publication->sampledAtMs||now<publication->sampledAtMs||
     now-publication->sampledAtMs>3000||publication->state.luid!=current.adapterLuid||
     publication->state.device!=current.deviceIdentity||publication->state.generation!=current.deviceGeneration)return {};
  return publication->state;
 }
};
// One process-lifetime metadata worker, independently pinned. Runtime destroy
// cannot join a large file read on the rendering thread. The existing orphan
// cleanup thread stops it after ReShade unload, outside the loader lock.
static Preparation* preparation=nullptr;
static HMODULE preparationPin=nullptr;
static automatic::Observation Observe(){
 const auto s=Read();automatic::Observation value;
 const auto prepared=preparation?preparation->Current(s):PreparedSnapshot{};
 const auto now=GetTickCount64();const bool recent=!g_reshade_gone&&s.sampleTick&&now>=s.sampleTick&&now-s.sampleTick<=5000;
 if(recent){
  value.context.luid=s.adapterLuid;value.context.deviceGeneration=s.deviceGeneration;value.context.outputGeneration=s.outputGeneration;
  value.context.deviceIdentity=s.deviceIdentity?"legacy-device-"+std::to_string(s.deviceIdentity):"";
  value.context.deviceGenerationSource="legacy_runtime_binding";
  value.context.outputId=s.outputIdentity?"legacy-output-"+std::to_string(s.outputIdentity):"";
  value.context.api=Api(s.api);value.context.architecture=sizeof(void*)==4?"x86":"x64";
  value.context.providerIdentity=prepared.clientIdentity;
  if(!prepared.verification.workerIdentity.empty())value.context.providerIdentity+="/"+prepared.verification.workerIdentity;
  value.context.modelIdentity=prepared.verification.modelIdentity;value.context.driverVersion=prepared.verification.driver;
 }
 auto& nr=value.features[static_cast<unsigned>(automatic::Feature::Nr)];
 nr.canConfigure=!g_reshade_gone;nr.requestKnown=true;nr.requested=s.requested!=0;nr.controlRevision=s.requestRevision;
 nr.accepted=s.requestRevision==s.acceptedRevision;nr.explicitOffRevision=s.requested?0:s.requestRevision;
 const bool api=std::string(Api(s.api))!="unknown";
 nr.admitted=!recent?Evidence::Unknown:!api||s.vendorId!=0x10de?Evidence::No:prepared.verification.hardware;
 nr.prepared=recent?prepared.verification.prepared:Evidence::Unknown;
 nr.inputs=recent&&s.guidesReady?Evidence::Yes:Evidence::Unknown;
 nr.failed=s.failed!=0;
 nr.route="legacy_same_adapter_worker";
 nr.reason=s.failed?"Legacy worker/transport failed; original game output retained":
  !prepared.verification.Ready()?prepared.verification.reason.empty()?"Background model and rendering architecture verification is pending":prepared.verification.reason:
  s.feedActive?"GPU transport active; NR inference and displayed output are not verified by this transport":
  s.requested?"Waiting for current guides and same-adapter worker/model negotiation":"Current-session NR intent is Off";
 // Transported frame counts do not set NR recorded/completed/composed bits.
 for(unsigned i=1;i<3;++i){auto& feature=value.features[i];feature.admitted=Evidence::No;feature.route="unavailable";
  feature.reason="This legacy NR owner does not implement an Auto upscaling or frame-generation delegate";}
 return value;
}
static Json Nr(){
 const auto s=Read();return {{"state",s.requested?s.feedActive?"transport_active":"waiting":"off"},
  {"route","legacy_same_adapter_worker"},{"requested",s.requested!=0},{"requestRevision",s.requestRevision},
  {"acceptedRevision",s.acceptedRevision},{"effectiveRevision",0},{"guidesReady",s.guidesReady!=0},
  {"transportedFrames",s.transportedFrames},{"recorded",false},{"submitted",false},{"completed",false},{"composed",false},
  {"inferenceVerified",false},{"outputVerified",false},
  {"outputEvidence","Transport completion alone does not prove NR inference or visible processed output"}};
}
static automatic::ApplyResult Apply(automatic::Feature feature,bool on,uint64_t revision){
 if(feature!=automatic::Feature::Nr)return {automatic::ApplyCode::Unavailable,revision};
 if(!OptiShadeLegacyNrSetSessionIntent(on?1u:0u,revision))return {automatic::ApplyCode::Conflict,g_session_intent.Read().revision};
 return {automatic::ApplyCode::Queued,g_session_intent.Read().revision};
}
static Json ConfigureAuto(const Json& request){
 auto response=controller.Configure(request,Observe(),Apply);
 const auto code=response.value("code",std::string{});
 if(code=="accepted"||code=="queued"||code=="unavailable"||code=="waiting_for_rendering_context"){
  const auto current=controller.Read(Observe());const auto& desired=current["desired"];
  const bool wanted=desired.value("enabled",false)&&desired.value("nr",std::string{})=="auto";
  g_prepare_requested_revision.store(wanted?g_session_intent.Read().revision:UINT64_MAX,std::memory_order_release);
 }
 return response;
}
static Json ConfigureNr(const Json& request){
 const auto observation=Observe();uint64_t revision=0;bool requested=false;
 if(!mfg::U64(request,"revision",revision,0,UINT64_MAX)||!request.contains("settings")||
    !request["settings"].is_object()||request["settings"].size()!=1||!mfg::Bool(request["settings"],"enabled",requested))return {{"code","invalid_settings"}};
 if(!automatic::SameContext(request,observation.context)||revision!=observation.features[0].controlRevision)return {{"code","conflict"}};
 if(requested&&(!observation.context.Valid()||observation.features[0].admitted!=Evidence::Yes||observation.features[0].prepared!=Evidence::Yes))return {{"code","provider_unavailable"}};
 const auto applied=Apply(automatic::Feature::Nr,requested,revision);
 return {{"code",automatic::Name(applied.code)},{"nr",Nr()},{"auto",controller.Read(Observe())}};
}
}
static void StartLegacyControl(){
 using namespace feed_control;std::lock_guard lock(mutex);if(server||failed||g_reshade_gone)return;
 try{
  FILETIME birth{},exit{},kernel{},user{};
  if(!GetProcessTimes(GetCurrentProcess(),&birth,&exit,&kernel,&user))return;
  if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(&StartLegacyControl),&pin))return;
  if(!preparation){
   if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(&StartLegacyControl),&preparationPin)){
    FreeLibrary(pin);pin=nullptr;return;
   }
   preparation=new Preparation();preparation->worker.Start();
  }
  endpoint=new optishade::control::Endpoint(GetCurrentProcessId(),std::to_string((uint64_t(birth.dwHighDateTime)<<32)|birth.dwLowDateTime),[]{
   optishade::control::Observation result;result.snapshot.message="This legacy NR process does not own a frame-generation provider";return result;
  },[](const auto&,const auto&){return uint64_t(0);},Nr,[]{return controller.Read(Observe());},[](const Json& request){
   return ConfigureAuto(request);
  },ConfigureNr);
  server=new optishade::control::PipeServer(GetCurrentProcessId(),std::to_string((uint64_t(birth.dwHighDateTime)<<32)|birth.dwLowDateTime),[](const std::string& request){return endpoint->Handle(request);});
  server->Start();
 }catch(...){
  delete server;server=nullptr;delete endpoint;endpoint=nullptr;failed=true;
  if(preparation&&!preparation->worker.Started()){delete preparation;preparation=nullptr;}
  if(!preparation&&preparationPin){FreeLibrary(preparationPin);preparationPin=nullptr;}
  if(pin){FreeLibrary(pin);pin=nullptr;}
 }
}
static bool StopLegacyControl(bool orphan){
 using namespace feed_control;std::lock_guard lock(mutex);const bool retained=pin!=nullptr;
 if(server){server->Stop();delete server;server=nullptr;}
 delete endpoint;endpoint=nullptr;
 if(orphan&&preparation){preparation->worker.Stop();delete preparation;preparation=nullptr;}
 if(orphan&&preparationPin){FreeLibrary(preparationPin);preparationPin=nullptr;}
 if(pin&&!orphan){FreeLibrary(pin);pin=nullptr;}
 // Unexpected teardown keeps the last owned reference, instead of releasing
 // possibly the only reference while this callback is still executing.
 return orphan&&retained;
}
