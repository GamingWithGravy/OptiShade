// CPU-only seams around the exact production preparation/connection owners.
// No graphics, pipe implementation, filesystem proof or model result is faked.
#include "LegacyNrGuideBridge.h"
#include "feed_ipc.h"
#include <atomic>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <vector>

static unsigned checks=0;
#define CHECK(value) do { ++checks; if(!(value)) throw std::runtime_error(#value); } while(false)
using DWORD=unsigned long;
using LONG=long;
using UINT64=uint64_t;
constexpr DWORD WAIT_OBJECT_0=0,WAIT_TIMEOUT=258,INFINITE=0xffffffffu;
struct FakeHandle {
    enum Kind {Thread,Pipe,Process,Event} kind;
    bool signaled=false,closed=false,terminated=false;
};
using HANDLE=FakeHandle*;
static std::vector<std::unique_ptr<FakeHandle>> handles;
static unsigned joins=0,closes=0,terminations=0,connects=0,activations=0;
static unsigned hostCloses=0,hostLosses=0,disables=0,feedDepth=0,blockingWaits=0;
static bool feedAvailable=true;
static HANDLE NewHandle(FakeHandle::Kind kind,bool signaled=false){
    handles.push_back(std::make_unique<FakeHandle>(FakeHandle{kind,signaled}));
    return handles.back().get();
}
static DWORD WaitForSingleObject(HANDLE handle,DWORD timeout){
    CHECK(handle&&!handle->closed);
    if(!handle->signaled&&timeout){++blockingWaits;throw std::runtime_error("preparation tried to wait for live work");}
    return handle->signaled?WAIT_OBJECT_0:WAIT_TIMEOUT;
}
static void CloseHandle(HANDLE handle){
    CHECK(handle&&!handle->closed);
    CHECK(handle->kind!=FakeHandle::Thread||handle->signaled);
    if(handle->kind==FakeHandle::Thread)++joins;
    handle->closed=true;++closes;
}
static void TerminateProcess(HANDLE handle,unsigned){
    CHECK(handle&&!handle->closed&&handle->kind==FakeHandle::Process);
    handle->terminated=handle->signaled=true;++terminations;
}
static void SetEvent(HANDLE handle){CHECK(handle&&!handle->closed);handle->signaled=true;}
static void ResetEvent(HANDLE handle){CHECK(handle&&!handle->closed);handle->signaled=false;}
static LONG InterlockedExchange(volatile LONG* location,LONG value){const auto previous=*location;*location=value;return previous;}
#if !defined(_MSC_VER)
template<size_t Size> static void strcpy_s(char (&destination)[Size],const char* source){
    CHECK(std::strlen(source)<Size);std::strcpy(destination,source);
}
#endif
template<class... Args> static void Log(const char*,Args...){}
namespace reshade::api {struct effect_runtime {unsigned identity;};}
static reshade::api::effect_runtime firstRuntime{1},secondRuntime{2};
static uint64_t g_runtime_generation=1,g_bound_last_render=0,clockTick=10000;
static bool g_reshade_gone=false;
static uint64_t GetTickCount64(){return clockTick;}
static bool LegacyCandidateRuntime(reshade::api::effect_runtime* runtime){return runtime!=nullptr;}
static bool FeedEnter(){if(!feedAvailable)return false;++feedDepth;return true;}
static void FeedLeave(){CHECK(feedDepth==1);--feedDepth;}
static optishade::legacy::SessionIntent g_session_intent;
static std::atomic<uint64_t> g_prepare_requested_revision{UINT64_MAX};
static bool SessionRequested(){return g_session_intent.Read().requested;}
static std::mutex g_observation_mutex;
static optishade::legacy::Snapshot g_observation;
static FeedPrepareAck g_preparation_observation{};
static uint64_t g_preparation_serial=0;
enum {LINK_IDLE,LINK_RUNNING,LINK_DONE,LINK_FAILED};
enum {JOB_CONNECT,JOB_ACTIVATE,JOB_BUILD};
struct HostState {
    HANDLE pipe=nullptr,hproc=nullptr;
    bool host_activated=false,built=false,disabled=false;
    uint64_t sent_n=0;
    FeedPrepareAck host_preparation{};
    uint32_t panel_w=0,panel_h=0;
    reshade::api::effect_runtime* runtime=nullptr;
};
struct HostLink {
    HANDLE thread=nullptr,pipe=nullptr,proc=nullptr,abort_event=nullptr;
    volatile LONG state=LINK_IDLE,abort=0;
    int job=JOB_CONNECT;
    uint64_t generation=0,activation_revision=0;
    FeedHello hello{};
    FeedPrepareAck preparation{};
    uint32_t panel_w=0,panel_h=0;
    DWORD ms=0;
    bool fatal=false;
    char why[192]{};
};
static HostState g;
static HostLink g_link;
static FeedAdapterIdentity CurrentAdapter(){return {g_observation.adapterLuid,g_observation.vendorId,g_observation.deviceId,1};}
static FeedHello CurrentHello(){return {FEED_IPC_MAGIC,FEED_IPC_VERSION,42,FEED_CLIENT_D3D11,0,CurrentAdapter(),12345,g_runtime_generation,g_observation.deviceIdentity};}
static bool HostAlive(){return g.hproc&&WaitForSingleObject(g.hproc,0)==WAIT_TIMEOUT;}
static const char* HostClientKindName(){return "fixture";}
static bool RetirePreparedLink();
static void HostClose(){++hostCloses;CHECK(RetirePreparedLink());}
static void FeedDisable(const char*){g.disabled=true;++disables;}
static void HostLost(const char*){++hostLosses;HostClose();FeedDisable("worker lost");}
// Worker launch is an OS seam only. Selection, retirement and result adoption
// run through the unchanged production functions inserted below.
static bool HostLinkStart(int job){
    CHECK(!g_link.thread);
    g_link.job=job;g_link.generation=g_runtime_generation;g_link.state=LINK_RUNNING;g_link.abort=0;
    g_link.thread=NewHandle(FakeHandle::Thread);
    if(!g_link.abort_event)g_link.abort_event=NewHandle(FakeHandle::Event);
    if(job==JOB_CONNECT){++connects;g_link.hello=CurrentHello();}
    else if(job==JOB_ACTIVATE){++activations;g_link.activation_revision=g_session_intent.Read().revision;}
    else throw std::runtime_error("unexpected texture-build job in preparation fixture");
    return true;
}

// PRODUCTION_LIFETIME_FUNCTIONS

static void SetIntent(bool requested){const auto before=g_session_intent.Read();CHECK(g_session_intent.Set(requested,before.revision));}
static void AutoPreparation(){g_prepare_requested_revision.store(g_session_intent.Read().revision);}
static void Reset(){
    CHECK(feedDepth==0);handles.clear();g={};g_link={};g_observation={};g_preparation_observation={};
    g_runtime_generation=3;g_observation.adapterLuid=0x12345678;
    g_observation.vendorId=0x10de;g_observation.deviceId=0x2684;g_observation.deviceIdentity=99;
    g_preparation_serial=0;g_reshade_gone=false;feedAvailable=true;g_bound_last_render=0;
    g_prepare_requested_revision.store(UINT64_MAX);SetIntent(false);
    joins=closes=terminations=connects=activations=hostCloses=hostLosses=disables=blockingWaits=0;
}
static FeedPrepareAck PreparationFor(const FeedHello& hello){
    FeedPrepareAck result{};result.adapter=hello.adapter;result.process_birth=hello.process_birth;
    result.device_generation=hello.device_generation;result.device_identity=hello.device_identity;
    result.family=40;result.compute_major=8;result.compute_minor=9;
    std::memset(result.model_hash,'A',64);std::memset(result.worker_hash,'B',64);
    std::strcpy(result.driver,"nvcuda-file:fixture");return result;
}
static void ReadyPreparation(){
    g.runtime=&firstRuntime;g.pipe=NewHandle(FakeHandle::Pipe);g.hproc=NewHandle(FakeHandle::Process);
    g_link.hello=CurrentHello();g_link.generation=g_runtime_generation;
    g.host_preparation=PreparationFor(g_link.hello);g_preparation_observation=g.host_preparation;
    AutoPreparation();
}
static void FinishConnect(bool result=true,bool exited=true){
    CHECK(g_link.job==JOB_CONNECT&&g_link.thread);
    g_link.thread->signaled=exited;g_link.state=result?LINK_DONE:LINK_FAILED;
    if(!g_link.pipe)g_link.pipe=NewHandle(FakeHandle::Pipe);
    if(!g_link.proc)g_link.proc=NewHandle(FakeHandle::Process);
    g_link.preparation=PreparationFor(g_link.hello);
}
static void NoFailureOrWait(){CHECK(!hostCloses&&!hostLosses&&!disables&&!blockingWaits&&!g.disabled);CHECK(feedDepth==0);}

int main(){try{
    // Auto can start preparation while the actual NR session remains Off.
    Reset();PollLegacyPreparation(&firstRuntime);CHECK(!connects&&!SessionRequested());
    AutoPreparation();PollLegacyPreparation(&firstRuntime);
    CHECK(connects==1&&!activations&&!SessionRequested());CHECK(g_link.state==LINK_RUNNING);
    PollLegacyPreparation(&firstRuntime);CHECK(connects==1&&!joins);
    FinishConnect();PollLegacyPreparation(&firstRuntime);
    CHECK(g.pipe&&g.hproc&&!g.host_activated&&g_link.thread==nullptr);
    CHECK(FeedPreparationMatches(g.host_preparation,g_link.hello));
    PollLegacyPreparation(&firstRuntime);CHECK(!activations&&!SessionRequested());
    SetIntent(true);CHECK(!HostConnectReady());CHECK(activations==1);
    g_link.state=LINK_DONE;g_link.panel_w=640;g_link.panel_h=480;
    const auto adoptedJoins=joins;CHECK(!HostConnectReady());CHECK(joins==adoptedJoins);
    g_link.thread->signaled=true;CHECK(HostConnectReady());
    CHECK(g.host_activated&&g.panel_w==640&&g.panel_h==480);NoFailureOrWait();

    // A destroyed runtime clears its pointer; the live prepared worker still
    // must retire before a replacement generation can be qualified.
    Reset();ReadyPreparation();const auto oldPipe=g.pipe,oldHost=g.hproc;
    g.runtime=nullptr;++g_runtime_generation;++g_observation.deviceIdentity;
    PollLegacyPreparation(&secondRuntime);
    CHECK(oldPipe->closed&&oldHost->closed&&oldHost->terminated);
    CHECK(!g.pipe&&!g.hproc&&g.runtime==&secondRuntime&&!g.host_activated);
    CHECK(!g_preparation_observation.adapter.valid&&g_preparation_serial==1);
    PollLegacyPreparation(&secondRuntime);CHECK(connects==1&&g_link.hello.device_generation==g_runtime_generation);
    CHECK(g_link.hello.device_identity==g_observation.deviceIdentity);NoFailureOrWait();

    // A pointer may be reused even without an intervening null runtime.
    for(unsigned mutation=0;mutation<4;++mutation){
        Reset();ReadyPreparation();const auto previous=g.pipe;
        if(mutation==0)++g_observation.deviceIdentity;
        if(mutation==1)++g_observation.adapterLuid;
        if(mutation==2)++g_observation.deviceId;
        if(mutation==3)++g_observation.vendorId;
        CHECK(!HostConnectReady());CHECK(previous->closed&&!activations&&!g.host_activated);
        NoFailureOrWait();
    }

    // Off cancellation remains sticky while a fresh Auto command arrives.
    // Result publication does not imply the background thread has exited.
    Reset();AutoPreparation();PollLegacyPreparation(&firstRuntime);
    g_link.pipe=NewHandle(FakeHandle::Pipe);g_link.proc=NewHandle(FakeHandle::Process);
    const auto pendingPipe=g_link.pipe,pendingProcess=g_link.proc,oldThread=g_link.thread;
    SetIntent(false);PollLegacyPreparation(&firstRuntime);
    CHECK(g_link.abort==1&&g_link.abort_event->signaled&&!pendingPipe->closed&&!joins);
    AutoPreparation();PollLegacyPreparation(&firstRuntime);
    CHECK(g_link.abort==1&&connects==1&&!pendingPipe->closed&&!pendingProcess->closed);
    FinishConnect(false,false);PollLegacyPreparation(&firstRuntime);
    CHECK(!oldThread->closed&&!pendingPipe->closed&&g_link.abort==1);
    oldThread->signaled=true;PollLegacyPreparation(&firstRuntime);
    CHECK(oldThread->closed&&pendingPipe->closed&&pendingProcess->closed&&pendingProcess->terminated);
    CHECK(g_link.state==LINK_IDLE&&g_link.abort==0&&!g_link.abort_event->signaled);
    PollLegacyPreparation(&firstRuntime);CHECK(connects==2&&!SessionRequested());NoFailureOrWait();

    // A newer same-value On cannot adopt a completed older activation.
    Reset();ReadyPreparation();SetIntent(true);CHECK(!HostConnectReady());
    const auto activationRevision=g_link.activation_revision;
    SetIntent(true);CHECK(g_session_intent.Read().revision!=activationRevision);
    g_link.state=LINK_DONE;g_link.thread->signaled=true;
    CHECK(!HostConnectReady());CHECK(!g.host_activated&&!g.pipe&&!g.hproc);NoFailureOrWait();

    // Context retirement also wins after the activation response is ready.
    Reset();ReadyPreparation();SetIntent(true);CHECK(!HostConnectReady());
    g_link.state=LINK_DONE;g_link.thread->signaled=true;++g_runtime_generation;
    CHECK(!HostConnectReady());CHECK(!g.host_activated&&!g.pipe&&!g.hproc);NoFailureOrWait();

    // The preparation helper never takes over the existing GPU transport owner.
    for(unsigned active=0;active<3;++active){
        Reset();ReadyPreparation();const auto pipe=g.pipe,process=g.hproc;
        if(active==0)g.host_activated=true;
        if(active==1)g.built=true;
        if(active==2)g.sent_n=1;
        CHECK(!RetirePreparedLink());CHECK(!pipe->closed&&!process->closed&&!terminations);NoFailureOrWait();
    }
    Reset();AutoPreparation();feedAvailable=false;PollLegacyPreparation(&firstRuntime);
    CHECK(!connects&&!feedDepth);feedAvailable=true;g_reshade_gone=true;PollLegacyPreparation(&firstRuntime);
    CHECK(!connects&&!feedDepth);NoFailureOrWait();
    std::cout<<"PASS: "<<checks<<" exact production legacy preparation lifetime checks (HostLinkJoin, RetirePreparedLink, HostConnectReady, PollLegacyPreparation): generation retirement, Off/fresh-Auto cancellation, finished-thread reaping, activation CAS, and active transport ownership. CPU Win32 seams only.\n";
    return 0;
}catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}}
