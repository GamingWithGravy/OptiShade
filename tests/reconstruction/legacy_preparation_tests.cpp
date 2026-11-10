#include "AutoCompatibility.h"
#include "RuntimeControlProtocol.h"
#include "LegacyNrGuideBridge.h"
#include "feed_ipc.h"
#include <atomic>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
using namespace optishade;
static legacy::SessionIntent g_session_intent;
static std::atomic<uint64_t> g_prepare_requested_revision{UINT64_MAX};
static uint64_t acknowledged=0;
static bool OptiShadeLegacyNrSetSessionIntent(uint32_t requested,uint64_t revision){return g_session_intent.Set(requested!=0,revision);}
namespace feed_control {
using Json=control::Json;
static automatic::Controller controller;
static automatic::Observation facts;
static automatic::Observation Observe(){
 auto value=facts;const auto session=g_session_intent.Read();auto& nr=value.features[0];
 nr.requestKnown=true;nr.requested=session.requested;nr.controlRevision=session.revision;
 nr.explicitOffRevision=session.requested?0:session.revision;nr.accepted=acknowledged==session.revision;
 return value;
}
static Json Nr(){return {{"requested",g_session_intent.Read().requested}};}
// PRODUCTION_CONTROL_FUNCTIONS
}
using Json=mfg::Json;
static Json Request(const Json& baseline,bool enabled=true){
 Json request={{"revision",baseline.at("revision")},{"planId",baseline.at("planId")},
  {"desired",{{"enabled",enabled},{"nr",enabled?"auto":"off"},{"upscaling","off"},{"frameGeneration","off"}}}};
 for(const auto key:{"renderingAdapterLuid","deviceGeneration","outputGeneration","outputId","deviceIdentity",
   "deviceGenerationSource","api","architecture","view","providerIdentity","modelIdentity","driverVersion"})request[key]=baseline.at(key);
 return request;
}
static Json NrRequest(const Json& baseline,bool enabled){
 auto request=Request(baseline);request["revision"]=g_session_intent.Read().revision;
 request["settings"]={{"enabled",enabled}};request.erase("planId");request.erase("desired");return request;
}
int main(){
 try{
  static_assert(sizeof(FeedHello)==68&&sizeof(FeedPrepareAck)==510&&sizeof(FeedAdapterAck)==32);
  auto& facts=feed_control::facts;
  facts.context.luid=0x12345678;facts.context.deviceGeneration=3;facts.context.outputGeneration=4;
  facts.context.deviceIdentity="game-device-99";facts.context.deviceGenerationSource="legacy_runtime_binding";
  facts.context.outputId="game-output-42";facts.context.api="d3d11";facts.context.architecture="x86";
  facts.features[0].canConfigure=true;
  // The client has no compute-driver evidence. Real ConfigureAuto must still
  // publish preparation intent while leaving the actual NR session Off.
  auto baseline=feed_control::controller.Read(feed_control::Observe());
  auto response=feed_control::ConfigureAuto(Request(baseline));
  CHECK(response.at("code")=="accepted");CHECK(!g_session_intent.Read().requested);
  CHECK(FeedWantsPreparation(g_prepare_requested_revision.load(),false,g_session_intent.Read().revision));
  CHECK(facts.features[0].admitted==Evidence::Unknown&&facts.features[0].prepared==Evidence::Unknown);

  const FeedAdapterIdentity adapter{0x12345678,0x10de,0x2684,1};
  FeedHello hello{FEED_IPC_MAGIC,FEED_IPC_VERSION,42,FEED_CLIENT_D3D11,0,adapter,12345,3,99};
  FeedPrepareAck prepared{};prepared.adapter=adapter;prepared.process_birth=12345;
  prepared.device_generation=3;prepared.device_identity=99;prepared.family=40;prepared.compute_major=8;prepared.compute_minor=9;
  std::memset(prepared.model_hash,'A',64);std::memset(prepared.worker_hash,'B',64);std::strcpy(prepared.driver,"nvcuda-file:fixture");
  CHECK(FeedPreparationMatches(prepared,hello));
  CHECK(FeedBindingCurrent(hello,adapter,3,99));
  CHECK(!FeedBindingCurrent(hello,adapter,4,99)); // destroy/recreate with g.runtime cleared
  CHECK(!FeedBindingCurrent(hello,adapter,3,100)); // recreated device, reused native pointer
  auto replacedAdapter=adapter;++replacedAdapter.luid;
  CHECK(!FeedBindingCurrent(hello,replacedAdapter,3,99));
  CHECK(!FeedBindingCurrent(hello,adapter,0,0));
  std::vector<int> events;
  auto start=[&](const FeedPrepareAck& candidate,bool activate){
   events.clear();return FeedActivatePrepared(hello,candidate,42,42,[&]{events.push_back(1);return activate;},
    [&](const FeedAdapterIdentity& requested,FeedAdapterIdentity& actual){events.push_back(2);actual=requested;return true;},
    [&]{events.push_back(3);return true;});
  };
  CHECK(start(prepared,false).status==FEED_ADAPTER_ACTIVATION_CANCELLED);
  CHECK(events==std::vector<int>({1})); // no device/model creation before activation
  auto bad=prepared;bad.status=FEED_ADAPTER_NGX_UNAVAILABLE;
  CHECK(start(bad,true).status==FEED_ADAPTER_NGX_UNAVAILABLE&&events.empty());
  bad=prepared;++bad.adapter.luid;CHECK(!FeedPreparationMatches(bad,hello));
  CHECK(start(bad,true).status==FEED_ADAPTER_NGX_UNAVAILABLE&&events.empty());
  bad=prepared;++bad.process_birth;CHECK(start(bad,true).status==FEED_ADAPTER_NGX_UNAVAILABLE&&events.empty());
  bad=prepared;++bad.device_generation;CHECK(start(bad,true).status==FEED_ADAPTER_NGX_UNAVAILABLE&&events.empty());
  bad=prepared;++bad.device_identity;CHECK(start(bad,true).status==FEED_ADAPTER_NGX_UNAVAILABLE&&events.empty());
  bad=prepared;bad.model_hash[64]='X';CHECK(!FeedPreparationMatches(bad,hello));
  bad=prepared;bad.worker_hash[3]='Z';CHECK(!FeedPreparationMatches(bad,hello));
  bad=prepared;bad.driver[127]='X';CHECK(!FeedPreparationMatches(bad,hello));
  bad=prepared;bad.family=0;CHECK(!FeedPreparationMatches(bad,hello));

  // Current matching x64 metadata enables the same controller's bounded retry.
  // The tests supply metadata; no physical GPU or model result is asserted.
  auto waiting=feed_control::controller.Read(feed_control::Observe());
  facts.features[0].admitted=facts.features[0].prepared=Evidence::Yes;
  facts.context.modelIdentity="pinned-model:fixture";facts.context.providerIdentity="legacy-host-file:fixture";
  facts.context.driverVersion=prepared.driver;
  auto ready=feed_control::controller.Read(feed_control::Observe());
  CHECK(ready.at("planId")!=waiting.at("planId"));
  CHECK(feed_control::ConfigureAuto(Request(waiting)).at("code")=="conflict");
  response=feed_control::ConfigureAuto(Request(ready));CHECK(response.at("code")=="queued");
  const auto activation=g_session_intent.Read();CHECK(activation.requested);
  CHECK(FeedActivationCurrent(activation.requested,activation.revision,activation.revision));
  CHECK(start(prepared,true).status==FEED_ADAPTER_READY&&events==std::vector<int>({1,2,3}));
  acknowledged=activation.revision;

  // A later same-value command cannot accept an earlier activation result.
  CHECK(g_session_intent.Set(true,activation.revision));
  auto newer=g_session_intent.Read();CHECK(!FeedActivationCurrent(newer.requested,newer.revision,activation.revision));
  baseline=feed_control::controller.Read(feed_control::Observe());
  CHECK(feed_control::ConfigureNr(NrRequest(baseline,false)).at("code")=="queued");
  CHECK(!g_session_intent.Read().requested);
  CHECK(!FeedWantsPreparation(g_prepare_requested_revision.load(),false,g_session_intent.Read().revision));
  CHECK(!FeedActivationCurrent(false,g_session_intent.Read().revision,activation.revision));
  auto off=feed_control::controller.Read(feed_control::Observe());CHECK(off["desired"]["nr"]=="off");

  // Explicit Off while already Off cancels a pending new preparation as well.
  facts.features[0].admitted=facts.features[0].prepared=Evidence::Unknown;
  baseline=feed_control::controller.Read(feed_control::Observe());
  CHECK(feed_control::ConfigureAuto(Request(baseline)).at("code")=="accepted");
  const auto pendingAt=g_prepare_requested_revision.load();CHECK(FeedWantsPreparation(pendingAt,false,g_session_intent.Read().revision));
  baseline=feed_control::controller.Read(feed_control::Observe());
  CHECK(feed_control::ConfigureNr(NrRequest(baseline,false)).at("code")=="queued");
  CHECK(!FeedWantsPreparation(pendingAt,false,g_session_intent.Read().revision));
  off=feed_control::controller.Read(feed_control::Observe());CHECK(off["desired"]["nr"]=="off");
  CHECK(!FeedWantsPreparation(UINT64_MAX,false,0));
  std::cout<<"PASS: exact legacy Auto/NR configure bodies + production v13 preparation/activation gate: unknown x86 capability bootstrap, current CAS, same-adapter identity, birth/generation rejection, activation ordering, newer action and Off retirement. CPU only; no Windows pipes or GPU execution.\n";
  return 0;
 }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}
