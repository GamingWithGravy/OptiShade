// OptiShade additions, GPL-3.0-or-later. Versioned control plane; no GPU ownership.
#pragma once
#include "MfgControl.h"
#include "ProviderPolicy.generated.h"
#include "OptiShadeVersion.h"
#include <functional>
#include <deque>
namespace optishade::control {
using Json=mfg::Json;
constexpr unsigned Version=2, MaxRequest=16384, MaxResponse=32768;
struct Observation {mfg::Snapshot snapshot;uint64_t completed=0;std::string saveState,message;};
inline Json Settings(const mfg::Settings& s){return {{"followGame",s.followGame},{"overrideOff",s.overrideOff},{"mode",s.followGame?"follow":s.dynamic?"dynamic":"fixed"},{"multiplier",s.multiplier},{"dynamicTargetFrameRate",s.targetFps},{"dlssgPreset",s.preset},{"reflexFrameLimitFps",s.reflexLimit},{"vsyncMode",s.vsyncMode}};}
inline Json PipeError(const char* code,uint32_t pid=0,const std::string& birth={},const std::string& id={}){
 Json result={{"schema",Version},{"code",code}};
 if(pid)result["pid"]=pid;
 if(!birth.empty())result["birth"]=birth;
 if(!id.empty()&&id.size()<=128)result["id"]=id;
 return result;
}
inline Json Snapshot(const Observation& o){
 const auto& s=o.snapshot;const auto& v=s.status;
 const auto stage=mfg::CapabilityStage(s);
 const bool acknowledged=mfg::HasCurrentAcknowledgement(s);
 const bool outputTelemetry=s.live&&mfg::HasFreshOutputTelemetry(v);
 const Json ratio=outputTelemetry?Json(double(v.outputFpsMilli)/v.realFpsMilli):Json(nullptr);
 const Json provider=(s.detected&&s.verified)?Json(s.sourceBuilt?"optishade-source-mfg":"rtxmfg-upstream"):Json(nullptr);
 const Json adapter=(s.live&&s.sourceBuilt&&s.renderingLuid)?Json{{"luid",std::to_string(s.renderingLuid)},{"family",s.renderingFamily},{"deviceGeneration",s.deviceGeneration},{"evidence","source_provider_live_status"}}:Json(nullptr);
 const Json frameGeneration=(s.detected&&s.verified&&s.owned)?Json{{"kind","replacement_mfg_provider"},{"gameEnabled",s.live?Json(v.gameFgOn):Json(nullptr)}}:Json(nullptr);
 const Json requestedMultiplier=s.settings.followGame?Json(nullptr):Json(s.settings.multiplier);
 const Json firstBlock=std::string(stage)=="output_telemetry_observed"?Json(nullptr):Json(stage);
 return {{"provider",provider.is_null()?Json("unknown"):provider},
  {"installationProvider",nullptr},{"installationProviderEvidence","installer receipt is not available in this runtime snapshot"},
  {"loadedProvider",provider},{"loadedProviderVerified",s.detected&&s.verified},{"providerEvidence",s.detected?(s.verified?"loaded module identity verified":"loaded module detected but unverified"):"provider not observed"},
  {"stage",stage},{"firstBlockingReason",firstBlock},{"verified",s.verified},{"owned",s.owned},{"fresh",s.live},{"editable",s.editable},{"identity",s.identity},
  {"renderingAdapter",adapter},{"renderingAdapterLuid",adapter.is_null()?Json(nullptr):Json(std::to_string(s.renderingLuid))},{"deviceGeneration",s.deviceGeneration?Json(s.deviceGeneration):Json(nullptr)},{"renderingFamily",s.renderingFamily?Json(s.renderingFamily):Json(nullptr)},
  {"renderingAdapterEvidence",adapter.is_null()?"actual rendering adapter is not reported by the current provider":"source provider live device binding"},
  {"policyDecision",nullptr},{"policyDecisionEvidence","installer decision receipt is not available in this runtime snapshot"},
  {"frameGeneration",frameGeneration},{"sourceInput",nullptr},{"sourceInputEvidence","source-frame identity is not reported by the current provider"},
  {"desired",Settings(s.settings)},{"requestedMode",s.settings.followGame?"follow":s.settings.dynamic?"dynamic":"fixed"},{"requestedMultiplier",requestedMultiplier},{"requestRevision",s.live?Json(v.requestRevision):Json(nullptr)},
  {"accepted",acknowledged},
  {"acceptedRevision",acknowledged?Json(v.appliedRevision):Json(nullptr)},
  {"providerAppliedRevision",s.live?Json(v.appliedRevision):Json(nullptr)},
  {"acceptedMultiplier",acknowledged?Json(v.appliedMultiplier):Json(nullptr)},
  {"inputAccepted",s.live&&v.bridgeReady},{"actualFramesPresented",s.live?Json(v.actualFramesPresented):Json(nullptr)},
  {"effectiveObservedRatio",ratio},{"sampleAgeMs",outputTelemetry?Json(v.fpsAgeMs):Json(nullptr)},{"latestOutputSampleAgeMs",outputTelemetry?Json(v.fpsAgeMs):Json(nullptr)},
  {"outputVerification","ratio is telemetry, not proof of distinct generated images"},{"reason",s.message},
  {"command",{{"completed",o.completed},{"state",o.saveState},{"message",o.message}}}};
}
class Endpoint {
 uint32_t pid_;std::string birth_;
 std::function<Observation()> read_;std::function<Json()> nr_,autoRead_;
 std::function<Json(const Json&)> autoConfigure_,nrConfigure_;
 std::function<uint64_t(const mfg::Settings&,const mfg::Snapshot&)> save_;
 struct Replay{std::string id,request,response;};std::deque<Replay> replay_;
public:
 Endpoint(uint32_t pid,std::string birth,std::function<Observation()> read,std::function<uint64_t(const mfg::Settings&,const mfg::Snapshot&)> save,std::function<Json()> nr={},std::function<Json()> automaticRead={},std::function<Json(const Json&)> automaticConfigure={},std::function<Json(const Json&)> nrConfigure={}):pid_(pid),birth_(std::move(birth)),read_(std::move(read)),nr_(std::move(nr)),autoRead_(std::move(automaticRead)),autoConfigure_(std::move(automaticConfigure)),nrConfigure_(std::move(nrConfigure)),save_(std::move(save)){}
 std::string Handle(const std::string& text){
  Json j;auto response=[&](const char* code){return Json{{"schema",Version},{"pid",pid_},{"birth",birth_},{"code",code}};};
  if(!mfg::Parse(text,MaxRequest,j))return response("malformed_request").dump();
  uint32_t schema=0,pid=0;std::string op,id,birth;
  if(!mfg::U32(j,"schema",schema,Version,Version)||!mfg::U32(j,"pid",pid,pid_,pid_)||!mfg::String(j,"operation",op)||!mfg::String(j,"id",id)||id.empty()||id.size()>128)return response("unsupported_envelope").dump();
  if(op!="discover"&&(!mfg::String(j,"birth",birth)||birth!=birth_))return response("wrong_session").dump();
  if(op=="discover"){auto r=response("ok");r["operations"]={"discover","snapshot","mfg.configure"};if(autoConfigure_)r["operations"].push_back("auto.configure");if(nrConfigure_)r["operations"].push_back("nr.configure");r["policyVersion"]=policy::Version;r["commandSemantics"]="queued is not saved; saved is not provider acceptance; acceptance is not visible output";return r.dump();}
  if(op=="snapshot"){auto r=response("ok");r["mfg"]=Snapshot(read_());r["nr"]=nr_?nr_():Json(nullptr);r["auto"]=autoRead_?autoRead_():Json(nullptr);return r.dump();}
  for(const auto& old:replay_)if(old.id==id)return old.request==text?old.response:response("request_id_reused").dump();
  if(op=="auto.configure"||op=="nr.configure"){
   const auto& configure=op=="auto.configure"?autoConfigure_:nrConfigure_;
   if(!configure)return response("unsupported_operation").dump();
   const auto details=configure(j);auto r=response("internal_error");
   if(details.is_object())for(auto it=details.begin();it!=details.end();++it)if(it.key()!="schema"&&it.key()!="pid"&&it.key()!="birth")r[it.key()]=it.value();
   const auto result=r.dump();const auto code=r.value("code",std::string{});
   if(code=="accepted"||code=="queued"||code=="waiting_for_rendering_context"||code=="restart_required"){
    replay_.push_back({id,text,result});if(replay_.size()>64)replay_.pop_front();
   }
   return result;
  }
  if(op!="mfg.configure")return response("unsupported_operation").dump();
  auto current=read_();auto& s=current.snapshot;
  if(!s.live||!s.editable||!s.verified||!s.owned)return response("provider_unavailable").dump();
  std::string identity;uint64_t revision=0,generation=0;mfg::Settings baseline,requested;
  if(!mfg::String(j,"identity",identity)||!mfg::U64(j,"revision",revision,0,UINT64_MAX)||!j.contains("baseline")||!j.contains("settings")||!j["baseline"].is_object()||!j["settings"].is_object()||!mfg::ReadSettings(j["baseline"],baseline)||!mfg::ReadSettings(j["settings"],requested))return response("invalid_settings").dump();
  if(!j.contains("deviceGeneration")||!j.contains("renderingAdapterLuid"))return response("invalid_context").dump();
  const auto& requestedGeneration=j["deviceGeneration"];
  const bool generationMatches=s.deviceGeneration==0?requestedGeneration.is_null():
   (mfg::U64(j,"deviceGeneration",generation,1,UINT64_MAX)&&generation==s.deviceGeneration);
  if(!generationMatches)return response("conflict").dump();
  if(identity!=s.identity||revision!=s.status.requestRevision||j["renderingAdapterLuid"]!=(s.renderingLuid?Json(std::to_string(s.renderingLuid)):Json(nullptr))||!mfg::SameRequest(baseline,s.settings))return response("conflict").dump();
  Json validated;std::string reason;
  if(!mfg::MergeAdapterSettings(s.sourceBuilt,validated,s.settings,requested,s.status,reason)){auto r=response("unavailable_mode");r["reason"]=reason;return r.dump();}
  const auto queued=save_(requested,s);auto r=response(queued?"queued":"busy");r["commandId"]=queued;
  auto result=r.dump();if(queued){replay_.push_back({id,text,result});if(replay_.size()>64)replay_.pop_front();}return result;
 }
};
}
