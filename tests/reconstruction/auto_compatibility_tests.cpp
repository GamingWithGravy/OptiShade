#include "AutoCompatibility.h"
#include "RuntimeControlProtocol.h"
#include <iostream>
#include <stdexcept>

static unsigned checks=0;
#define CHECK(x) do{++checks;if(!(x))throw std::runtime_error(std::string(#x)+" @"+std::to_string(__LINE__));}while(0)
using namespace optishade;
using namespace optishade::automatic;
static Observation Ready(){
    Observation result;
    result.context.luid=123;result.context.deviceGeneration=7;result.context.outputId="output-3";
    result.context.outputGeneration=9;result.context.api="d3d12";result.context.architecture="x64";
    result.context.deviceIdentity="device-2";result.context.deviceGenerationSource="primary_output_binding";
    result.context.providerIdentity="provider-live";result.context.modelIdentity="model-live";result.context.driverVersion="driver-live";
    auto& nr=result.features[0];nr.admitted=nr.prepared=Evidence::Yes;nr.canConfigure=nr.requestKnown=true;
    nr.route="existing-neural-owner";
    return result;
}
static Json Request(const Json& snapshot,bool enabled=true){
    Json result={{"schema",2},{"pid",42},{"birth","123"},{"operation","auto.configure"},{"id","command-1"},
        {"desired",{{"enabled",enabled},{"nr","auto"},{"upscaling","off"},{"frameGeneration","off"}}}};
    for(const char* name:{"revision","planId","renderingAdapterLuid","deviceGeneration","outputId","outputGeneration","deviceIdentity","deviceGenerationSource","api","architecture","view","providerIdentity","modelIdentity","driverVersion"})result[name]=snapshot.at(name);
    return result;
}
int main(){try{
    Controller controller;Observation observation;unsigned calls=0;
    auto apply=[&](Feature feature,bool on,uint64_t baseline){
        ++calls;CHECK(feature==Feature::Nr);auto& nr=observation.features[0];CHECK(baseline==nr.controlRevision);
        nr.requested=on;nr.requestKnown=nr.accepted=true;++nr.controlRevision;
        return ApplyResult{ApplyCode::Accepted,nr.controlRevision};
    };
    auto empty=controller.Read(observation);CHECK(empty["state"]=="off");CHECK(calls==0);
    CHECK(empty["features"]["nr"]["admitted"].is_null());
    auto unknown=Request(empty);auto result=controller.Configure(unknown,observation,apply);
    CHECK(result["code"]=="waiting_for_rendering_context");CHECK(calls==0);
    CHECK(result["auto"]["desired"]["nr"]=="auto");CHECK(!result["auto"]["features"]["nr"]["accepted"].get<bool>());
    observation=Ready();auto live=controller.Read(observation);
    CHECK(controller.Configure(unknown,observation,apply)["code"]=="conflict");CHECK(calls==0);
    auto valid=Request(live);auto wrong=valid;wrong["renderingAdapterLuid"]="124";
    CHECK(controller.Configure(wrong,observation,apply)["code"]=="conflict");CHECK(calls==0);
    wrong=valid;wrong["deviceIdentity"]="another-device-same-GPU";
    CHECK(controller.Configure(wrong,observation,apply)["code"]=="conflict");CHECK(calls==0);
    for(const char* identity:{"api","architecture","view","providerIdentity","modelIdentity","driverVersion"}){
        wrong=valid;wrong[identity]=std::string_view(identity)=="view"?Json(42):Json("different-context");
        CHECK(controller.Configure(wrong,observation,apply)["code"]=="conflict");CHECK(calls==0);
        wrong=valid;wrong.erase(identity);CHECK(!SameContext(wrong,observation.context));
    }
    wrong=valid;wrong["desired"]["nr"]=true;
    CHECK(controller.Configure(wrong,observation,apply)["code"]=="invalid_settings");CHECK(calls==0);
    result=controller.Configure(valid,observation,apply);CHECK(result["code"]=="accepted");CHECK(calls==1);
    auto view=controller.Read(observation);CHECK(view["features"]["nr"]["accepted"].get<bool>());
    CHECK(view["features"]["nr"]["admitted"]==true&&view["features"]["nr"]["prepared"]==true&&view["features"]["nr"]["inputs"].is_null());
    CHECK(view["features"]["nr"]["state"]=="waiting_for_game_inputs");
    CHECK(!view["features"]["nr"]["observed"]["displayVerified"].get<bool>());
    observation.features[0].inputs=Evidence::Yes;
    observation.features[0].recorded=true;observation.features[0].gpuCompleted=true;
    observation.features[0].composed=true;view=controller.Read(observation);
    CHECK(view["features"]["nr"]["state"]=="gpu_completed");CHECK(view["state"]!="output_verified");
    // Reading observations, including a context refresh, cannot change Config.
    CHECK(calls==1);observation.context.outputGeneration++;view=controller.Read(observation);
    CHECK(view["desired"]["nr"]=="auto");CHECK(calls==1);
    observation.features[0].requested=false;observation.features[0].controlRevision++;
    view=controller.Read(observation);CHECK(view["desired"]["nr"]=="off");
    observation.features[0].failed=true;view=controller.Read(observation);
    CHECK(view["desired"]["nr"]=="off");CHECK(calls==1); // recovery preserves explicit Off
    Controller restarted;CHECK(restarted.Read(observation)["desired"]["enabled"]==false);
    observation.features[0].requested=true;
    CHECK(restarted.Read(observation)["features"]["nr"]["state"]=="manual_control");

    // A provider swap requires restart; no opportunistic replacement or setter.
    Controller restart;observation=Ready();observation.features[0].restartRequired=true;
    result=restart.Configure(Request(restart.Read(observation)),observation,apply);
    CHECK(result["code"]=="restart_required");CHECK(calls==1);
    Controller absent;observation=Ready();observation.features[0].prepared=Evidence::No;
    result=absent.Configure(Request(absent.Read(observation)),observation,apply);
    CHECK(result["auto"]["features"]["nr"]["state"]=="needs_setup");CHECK(calls==1);
    Controller unsupported;observation=Ready();observation.features[0].admitted=Evidence::No;
    result=unsupported.Configure(Request(unsupported.Read(observation)),observation,apply);
    CHECK(result["auto"]["features"]["nr"]["state"]=="unsupported");CHECK(calls==1);
    // An exact-identity receipt may be repaired later. The existing manager
    // retries on plan changes, so readiness must advance the plan even though
    // API/device/model/provider identities have not changed.
    {
        Controller late;auto waiting=Ready();waiting.features[0].prepared=Evidence::No;
        unsigned invoked=0;
        auto setter=[&](Feature feature,bool on,uint64_t revision){CHECK(feature==Feature::Nr&&on);++invoked;return ApplyResult{ApplyCode::Accepted,revision+1};};
        const auto before=late.Configure(Request(late.Read(waiting)),waiting,setter);
        CHECK(invoked==0);const auto oldPlan=before["auto"]["planId"];
        waiting.features[0].prepared=Evidence::Yes;
        const auto ready=late.Read(waiting);CHECK(ready["planId"]!=oldPlan);CHECK(invoked==0);
        CHECK(late.Configure(Request(before["auto"]),waiting,setter)["code"]=="conflict");CHECK(invoked==0);
        CHECK(late.Configure(Request(ready),waiting,setter)["code"]=="accepted");CHECK(invoked==1);
        const auto stablePlan=late.Read(waiting)["planId"];
        waiting.features[0].inputs=Evidence::Yes;waiting.features[0].recorded=true;waiting.features[0].gpuCompleted=true;
        CHECK(late.Read(waiting)["planId"]==stablePlan);CHECK(invoked==1);
    }
    {
        Controller waitingOff;auto waiting=Ready();waiting.features[0].prepared=Evidence::Unknown;
        const auto initial=waitingOff.Configure(Request(waitingOff.Read(waiting)),waiting,[](Feature,bool,uint64_t){CHECK(false);return ApplyResult{};});
        CHECK(initial["auto"]["desired"]["nr"]=="auto");
        // A tuning revision while already Off is not an explicit Off action.
        ++waiting.features[0].controlRevision;
        CHECK(waitingOff.Read(waiting)["desired"]["nr"]=="auto");
        waiting.features[0].explicitOffRevision=++waiting.features[0].controlRevision;
        CHECK(waitingOff.Read(waiting)["desired"]["nr"]=="off");
        waiting.features[0].prepared=Evidence::Yes;waiting.context.deviceGeneration++;
        CHECK(waitingOff.Read(waiting)["desired"]["nr"]=="off");
        const auto fresh=waitingOff.Read(waiting);
        const auto newOn=waitingOff.Configure(Request(fresh),waiting,[&](Feature,bool on,uint64_t revision){
            auto& nr=waiting.features[0];nr.requested=on;nr.accepted=true;nr.controlRevision=revision+1;
            return ApplyResult{ApplyCode::Accepted,nr.controlRevision};});
        CHECK(newOn["auto"]["desired"]["nr"]=="auto");
        waitingOff.Read(Observation{});
        CHECK(waitingOff.Read(waiting)["desired"]["nr"]=="auto");
    }
    Controller externalOwner;observation=Ready();
    auto& sr=observation.features[1];sr.admitted=sr.prepared=sr.inputs=Evidence::Yes;sr.gameControlled=sr.recorded=true;
    auto externalRequest=Request(externalOwner.Read(observation));externalRequest["desired"]["nr"]="off";externalRequest["desired"]["upscaling"]="auto";
    result=externalOwner.Configure(externalRequest,observation,[](Feature feature,bool on,uint64_t revision){CHECK(feature!=Feature::Upscaling&&!on);return ApplyResult{ApplyCode::Accepted,revision};});
    CHECK(result["auto"]["features"]["upscaling"]["state"]=="game_controlled_work_reported");
    CHECK(result["auto"]["features"]["upscaling"]["controlOwner"]=="game");
    CHECK(result["auto"]["features"]["upscaling"]["accepted"]==false);
    result=externalOwner.Configure(Request(externalOwner.Read(observation),false),observation,[](Feature feature,bool on,uint64_t revision){CHECK(feature!=Feature::Upscaling&&!on);return ApplyResult{ApplyCode::Accepted,revision};});
    CHECK(result["auto"]["features"]["upscaling"]["requested"]==false);
    CHECK(result["auto"]["features"]["upscaling"]["state"]=="game_controlled_work_reported");
    CHECK(result["auto"]["features"]["upscaling"]["accepted"]==false);

    // A second feature that needs a provider restart cannot suppress the
    // bounded retry of a busy or stale first owner in the same Auto operation.
    Controller partial;observation=Ready();
    auto& fg=observation.features[2];fg.admitted=fg.prepared=Evidence::Yes;fg.canConfigure=fg.restartRequired=true;
    for(const auto failure:{ApplyCode::Busy,ApplyCode::Conflict}){
        auto request=Request(partial.Read(observation));request["desired"]["frameGeneration"]="auto";
        unsigned attempts=0;
        result=partial.Configure(request,observation,[&](Feature feature,bool,uint64_t){CHECK(feature==Feature::Nr);++attempts;return ApplyResult{failure,0};});
        CHECK(result["code"]==Name(failure));CHECK(attempts==1);
        CHECK(result["auto"]["features"]["frameGeneration"]["state"]=="restart_required");
    }

    // Effective suspension and a new device retain the session request.
    Controller suspended;observation=Ready();
    result=suspended.Configure(Request(suspended.Read(observation)),observation,apply);
    observation.features[0].failed=true;view=suspended.Read(observation);
    CHECK(view["desired"]["nr"]=="auto");CHECK(view["features"]["nr"]["state"]=="failed");
    observation.context.deviceIdentity="device-3";observation.context.deviceGeneration++;
    view=suspended.Read(observation);CHECK(view["desired"]["nr"]=="auto");
    // NR's session revision is independent of output recreation. A genuine
    // later Off remains authoritative even if a device changes at the same time.
    observation.context.outputGeneration++;
    observation.features[0].requested=false;observation.features[0].controlRevision++;
    view=suspended.Read(observation);CHECK(view["desired"]["nr"]=="off");

    // The actual endpoint enforces birth/session and request-id replay before
    // calling the shared controller. A retried request has one side effect.
    Controller routed;observation=Ready();unsigned routedCalls=0;
    control::Endpoint endpoint(42,"123",[]{return control::Observation{};},[](const mfg::Settings&,const mfg::Snapshot&){return uint64_t(0);},
        {},[&]{return routed.Read(observation);},[&](const Json& request){return routed.Configure(request,observation,[&](Feature,bool,uint64_t){++routedCalls;return ApplyResult{ApplyCode::Queued,1};});});
    auto envelope=Request(routed.Read(observation));auto call=[&]{return Json::parse(endpoint.Handle(envelope.dump()));};
    envelope["birth"]="reused-pid";CHECK(call()["code"]=="wrong_session");CHECK(routedCalls==0);
    envelope["birth"]="123";const auto first=call();CHECK(first["code"]=="queued");CHECK(routedCalls==1);
    CHECK(call()==first);CHECK(routedCalls==1);
    envelope["desired"]["nr"]="off";CHECK(call()["code"]=="request_id_reused");CHECK(routedCalls==1);
    envelope=Request(routed.Read(observation),false);envelope["id"]="command-2";CHECK(call()["code"]=="queued");CHECK(routedCalls==2);
    std::cout<<checks<<" Auto intent, real-context CAS, absent-input/setup, explicit-Off, suspension, restart and endpoint replay checks passed (CPU policy/delegates; no GPU output).\n";
    return 0;
}catch(const std::exception& failure){std::cerr<<failure.what()<<'\n';return 1;}}
