#include "NrObservation.h"
#include "NrSubmissionOutcome.h"
#include <iostream>
#include <stdexcept>
#include <string>

static unsigned checks=0;
#define CHECK(x) do{++checks;if(!(x))throw std::runtime_error(std::string(#x)+" @"+std::to_string(__LINE__));}while(0)

// The GPU bridge's invocation contract, with completion/failure injected. The
// callback orchestration and result classifier are the production helpers.
struct FakeTransport {
    bool start=true,copyCompletes=true,poisoned=false;
    unsigned callbacks=0;
    template<class Evaluate> bool Run(int*,Evaluate evaluate) {
        if(!start)return false;
        int queue=1,colour=2,depth=3,motion=4;
        ++callbacks;
        if(!evaluate(&queue,&colour,&depth,&motion)){poisoned=true;return false;}
        return copyCompletes;
    }
};

int main(){try{
    using namespace optishade;
    // Explicit commands and ordinary observations share this same owner, but
    // only an explicit Off annotates cancellation of a waiting Auto request.
    nr_observation::Tracker commands;commands.Request(false,true,10);
    const auto initial=commands.Read(1).request;
    commands.Request(false,true,10);CHECK(commands.Read(1).request==initial);
    commands.Request(false,true,11);CHECK(commands.Read(1).request==initial+1&&commands.Read(1).explicitOffRevision==0);
    commands.Request(false,true,11,true);
    const auto stopped=commands.Read(1);CHECK(stopped.request==initial+2&&stopped.explicitOffRevision==stopped.request&&!stopped.requested);
    commands.Request(false,true,11);CHECK(commands.Read(1).request==stopped.request);
    commands.Request(true,true,11,true);
    CHECK(commands.Read(1).request==stopped.request+1&&commands.Read(1).explicitOffRevision==stopped.explicitOffRevision);
    nr_observation::Tracker tracker;
    nr_observation::Owner owner{1,2,3,4,0,1920,1080,nr_observation::Route::EstimatedTAA};
    tracker.Request(true,true,1);
    uint64_t frame=0;
    auto result=[&](bool evaluate,bool compose,bool complete,bool modelFailed=false){
        nr_submission::Result out;
        out.runtime=owner.runtime;out.generation=owner.generation;out.view=owner.view;out.frame=++frame;
        out.ticket=tracker.Begin(owner,out.frame,100+out.frame);
        CHECK(out.ticket);
        if(evaluate)tracker.Evaluated(out.ticket,compose);
        out.submitted=true;out.gpuCompleted=complete;out.modelFailed=modelFailed;
        tracker.Submitted(out.ticket,owner.queue,102+out.frame,true);
        if(complete)tracker.Completed(out.ticket,owner.queue,0,std::nullopt);
        out.Observe(tracker.ReadTicket(out.ticket));
        return out;
    };
    int input=0;
    auto copy=[&](nr_submission::Result supplied,bool transportComplete=true){
        FakeTransport transport;transport.copyCompletes=transportComplete;
        unsigned evaluations=0;
        auto transaction=nr_submission::RunTransport(transport,&input,[&](int* queue,int* colour,int* depth,int* motion){
            CHECK(*queue==1&&*colour==2&&*depth==3&&*motion==4);
            ++evaluations;return supplied;
        });
        CHECK(evaluations==1&&transport.callbacks==1);
        CHECK(transport.poisoned==!supplied.SafeToCopy());
        return transaction;
    };
    // No provider, refused admission or NR disabled: transport may copy the
    // original, but it cannot become a successful inference transaction.
    auto absent=copy({});
    CHECK(absent.completed&&!absent.ComposedImageCopied());
    CHECK(std::string(absent.TransportStatus())=="Copy-back completed");
    CHECK(std::string(absent.inference.InferenceStatus()).find("No NR evaluation")!=std::string::npos);
    auto warming=copy(result(false,false,true));
    CHECK(warming.completed&&!warming.ComposedImageCopied());
    CHECK(!warming.inference.evaluated&&warming.inference.ticket);
    auto failed=copy(result(false,false,true,true));
    CHECK(failed.completed&&!failed.ComposedImageCopied());
    CHECK(std::string(failed.inference.InferenceStatus()).find("unavailable or failed")!=std::string::npos);
    auto hidden=copy(result(true,false,true));
    CHECK(hidden.completed&&!hidden.ComposedImageCopied()&&hidden.inference.evaluated);
    CHECK(std::string(hidden.inference.InferenceStatus()).find("composition hidden")!=std::string::npos);
    auto composed=result(true,true,true);
    auto success=copy(composed);
    CHECK(success.completed&&success.ComposedImageCopied());
    CHECK(std::string(success.inference.InferenceStatus())=="NR composition completed on GPU");
    CHECK(!copy(composed,false).ComposedImageCopied()); // Later D3D11 return copy failed.
    auto pending=copy(result(true,true,false));
    CHECK(!pending.completed&&!pending.ComposedImageCopied());
    auto unsafe=composed.Unsafe();CHECK(!unsafe.SafeToCopy());
    CHECK(!copy(unsafe).ComposedImageCopied());

    auto sample=tracker.ReadTicket(composed.ticket);CHECK(sample);
    CHECK(sample->completed&&sample->submitted&&sample->evaluated&&sample->composed);
    auto mismatched=composed;++mismatched.generation;mismatched.Observe(sample);
    CHECK(!mismatched.evaluated&&!mismatched.ComposedImage());
    mismatched=composed;++mismatched.runtime;mismatched.Observe(sample);CHECK(!mismatched.ComposedImage());
    mismatched=composed;++mismatched.view;mismatched.Observe(sample);CHECK(!mismatched.ComposedImage());
    mismatched=composed;++mismatched.frame;mismatched.Observe(sample);CHECK(!mismatched.ComposedImage());
    mismatched=composed;++mismatched.ticket;mismatched.Observe(sample);CHECK(!mismatched.ComposedImage());
    tracker.Request(true,true,2);
    CHECK(!tracker.ReadTicket(composed.ticket));
    composed.Observe(tracker.ReadTicket(composed.ticket));CHECK(!composed.ComposedImage());
    auto renewed=result(true,true,true);CHECK(tracker.ReadTicket(renewed.ticket));
    tracker.Begin(owner,++frame,200,true);CHECK(!tracker.ReadTicket(renewed.ticket));
    auto displaced=result(true,true,true);
    for(unsigned i=0;i<70;++i)tracker.Begin(owner,++frame,300+i);
    CHECK(!tracker.ReadTicket(displaced.ticket)); // Bounded pending ring cannot lend another frame's status.
    auto ended=result(true,true,true);tracker.Request(false,true,3);
    CHECK(!tracker.ReadTicket(ended.ticket));
    CHECK(!tracker.ReadTicket(0));

    FakeTransport refused;refused.start=false;unsigned invocations=0;
    auto beforeCallback=nr_submission::RunTransport(refused,&input,[&](int*,int*,int*,int*){
        ++invocations;return nr_submission::Result{};
    });
    CHECK(!beforeCallback.completed&&!beforeCallback.ComposedImageCopied()&&invocations==0);
    std::cout<<checks<<" NR ticket/transport callback checks passed; no D3D11/D3D12 GPU copy or model execution tested\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
