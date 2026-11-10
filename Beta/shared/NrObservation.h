#pragma once
#include <array>
#include <cstdint>
#include <mutex>
#include <optional>
#include "SimulatorRouteHost.h"
#include "OutputLifecycle.h"
#include "LastSession.h"

namespace optishade::nr_observation {
enum class Route : uint32_t { Unknown, NativeD3D12, BeforeSR, FinishedPicture, EstimatedTAA, NativeVulkan, EstimatedVulkan, PreFgTAA };
struct InputProvenance {const char* colour;const char* depth;const char* motion;const char* stage;};
inline InputProvenance Provenance(Route route) {
    switch(route){
    case Route::PreFgTAA:return {"InterceptedTemporalIntegration","InterceptedTemporalIntegration","InterceptedTemporalIntegration","HUD-less source before native FG"};
    case Route::EstimatedTAA:return {"Intercepted game image","Intercepted scene depth","ImageEstimated","ReShade SDR compatibility image"};
    case Route::EstimatedVulkan:return {"Intercepted game image","Intercepted scene depth","ImageEstimated","Vulkan compatibility image"};
    case Route::BeforeSR:return {"InterceptedTemporalIntegration","InterceptedTemporalIntegration","InterceptedTemporalIntegration","Before reconstruction"};
    case Route::FinishedPicture:return {"InterceptedTemporalIntegration","InterceptedTemporalIntegration","InterceptedTemporalIntegration","Finished reconstruction image"};
    case Route::NativeD3D12:case Route::NativeVulkan:return {"InterceptedTemporalIntegration","InterceptedTemporalIntegration","InterceptedTemporalIntegration","Native evaluation seam"};
    default:return {"Unavailable","Unavailable","Unavailable","Unknown"};
    }
}
struct Owner {
    uint64_t device=0, queue=0, runtime=0, generation=0, view=0;
    uint32_t width=0, height=0;
    Route route=Route::Unknown;
    bool operator==(const Owner& b) const {
        return device==b.device && queue==b.queue && runtime==b.runtime && generation==b.generation &&
            view==b.view && width==b.width && height==b.height && route==b.route;
    }
};
struct Snapshot {
    Owner owner;
    optishade::route::OutputTicket output;
    uint64_t request=0, explicitOffRevision=0, effective=0, ticket=0, frame=0, evaluatedAt=0, completedAt=0;
    uint64_t completedFrame=0, completedTicket=0, queue=0, frequency=0, age=0;
    bool requested=false, visible=false, evaluated=false, completed=false, composed=false;
    bool recent=false, submitted=false, fenceSignalFailed=false;
    uint64_t submittedFrame=0,submittedAt=0,submissionQueue=0;
    std::optional<double> gpuMilliseconds;
};
// Exact per-call evidence. Reading a ticket never substitutes the newest lane's
// result, and stale request/owner epochs cannot be revived by a delayed callback.
struct TicketSnapshot {
    Owner owner;
    optishade::route::OutputTicket output;
    uint64_t revision=0,frame=0;
    bool evaluated=false,composed=false,submitted=false,completed=false;
};
// Bounded evidence, not a configuration object. Callers still own Config and admission.
// Tickets carry their revision and owner; late completion cannot satisfy a newer request.
class Tracker {
    struct Pending { uint64_t id=0, revision=0, frame=0, at=0, ownerEpoch=0; unsigned slot=0; bool evaluated=false, composed=false; optishade::route::OutputTicket output{}; bool completionCounted=false; };
    struct Lane { Snapshot value; uint64_t used=0, config=0, timingAt=0; };
    std::array<Lane,8> lanes{};
    std::array<Pending,64> pending{};
    std::mutex mutex;
    uint64_t serial=0, revision=0, explicitOffRevision=0, requestKey=0, completedRecords=0;
    bool requested=false, visible=false;
public:
    void Request(bool on, bool apply, uint64_t key, bool explicitCommand=false) {
        std::lock_guard<std::mutex> lock(mutex);
        if(!explicitCommand && on==requested && apply==visible && key==requestKey) return;
        requested=on; visible=apply; requestKey=key; ++revision;
        // A new explicit Off can cancel waiting Auto even while already Off.
        // Ordinary per-frame reads and look changes never manufacture it.
        if(explicitCommand&&!on)explicitOffRevision=revision;
        for(auto& lane:lanes) {
            lane.value.request=revision; lane.value.requested=on; lane.value.visible=apply;
            lane.value.evaluated=lane.value.completed=lane.value.composed=lane.value.submitted=lane.value.fenceSignalFailed=false;
            lane.value.submittedFrame=lane.value.submittedAt=lane.value.submissionQueue=0;
            lane.value.gpuMilliseconds.reset();
        }
    }
    uint64_t Begin(const Owner& owner, uint64_t frame, uint64_t now, bool reset=false) {
        std::lock_guard<std::mutex> lock(mutex);
        if(!requested || !owner.device) return 0;
        unsigned slot=0; bool found=false;
        for(unsigned i=0;i<lanes.size();++i) if(lanes[i].used && lanes[i].value.owner==owner){slot=i;found=true;break;}
        if(!found) for(unsigned i=1;i<lanes.size();++i) if(lanes[i].used<lanes[slot].used) slot=i;
        auto& lane=lanes[slot];
        if(!found || reset) {
            // A temporal-model reset invalidates pending history, not proof of
            // an already completed frame in the same native-FG owner. Preserve
            // that timestamp without extending its normal 1500ms expiry.
            // Request/owner changes still invalidate evidence immediately.
            const bool keepCompleted=found && owner.route==Route::PreFgTAA &&
                lane.value.request==revision && lane.value.completed;
            if(!keepCompleted){lane.value={};lane.value.owner=owner;lane.timingAt=0;}
            lane.config=++serial;
        }
        else if(!lane.config) lane.config=++serial;
        auto& v=lane.value;
        v.request=revision; v.requested=requested;v.visible=visible;
        v.ticket=++serial;v.frame=frame;lane.used=serial;
        pending[serial%pending.size()]={serial,revision,frame,now,lane.config,slot,false,false};
        auto& output=pending[serial%pending.size()].output;
        output.ticket=serial;output.owner=owner.runtime?owner.runtime:owner.device;
        output.generation=owner.generation?owner.generation:lane.config;output.frame=static_cast<uint32_t>(frame);output.view=static_cast<uint32_t>(owner.view);
        output.observed=(1u<<unsigned(optishade::route::OutputStage::Requested))|(1u<<unsigned(optishade::route::OutputStage::ContractComplete));
        return serial;
    }
    void Evaluated(uint64_t ticket, bool composed) {
        std::lock_guard<std::mutex> lock(mutex);
        auto& p=pending[ticket%pending.size()];
        if(!ticket || p.id!=ticket || p.revision!=revision) return;
        auto& v=lanes[p.slot].value;
        if(v.request!=p.revision || lanes[p.slot].config!=p.ownerEpoch) return;
        p.evaluated=true;p.composed=composed;
        p.output.observed|=1u<<unsigned(optishade::route::OutputStage::NrRecorded);
        v.evaluated=true;v.evaluatedAt=p.at;v.effective=p.revision;
    }
    // Called only after the owning command list reached ExecuteCommandLists.
    void Submitted(uint64_t ticket,uint64_t queue,uint64_t now,bool fenceSignalSucceeded) {
        std::lock_guard<std::mutex> lock(mutex);
        auto& p=pending[ticket%pending.size()];
        if(!ticket||p.id!=ticket||p.revision!=revision)return;
        auto& lane=lanes[p.slot];if(lane.config!=p.ownerEpoch||lane.value.request!=p.revision)return;
        p.output.observed|=1u<<unsigned(optishade::route::OutputStage::Submitted);
        if(!fenceSignalSucceeded)p.output.failed|=1u<<unsigned(optishade::route::OutputStage::Submitted);
        auto& v=lane.value;v.submitted=true;v.submittedFrame=p.frame;v.submittedAt=now;v.submissionQueue=queue;v.fenceSignalFailed=!fenceSignalSucceeded;
    }
    void Completed(uint64_t ticket, uint64_t queue, uint64_t frequency, std::optional<double> ms) {
        std::lock_guard<std::mutex> lock(mutex);
        auto& p=pending[ticket%pending.size()];
        if(!ticket || p.id!=ticket || !p.evaluated || p.revision!=revision || !requested) return;
        auto& v=lanes[p.slot].value;
        if(v.request!=p.revision || lanes[p.slot].config!=p.ownerEpoch) return;
        if(!p.completionCounted){p.completionCounted=true;++completedRecords;}
        if(ticket<v.completedTicket)return;
        if(ticket==v.completedTicket){if(queue)v.queue=queue;if(frequency)v.frequency=frequency;if(ms){v.gpuMilliseconds=ms;lanes[p.slot].timingAt=p.at;}return;}
        p.output.observed|=1u<<unsigned(optishade::route::OutputStage::GpuCompleted);
        v.completedTicket=ticket;v.completed=true;v.composed=p.composed;v.completedAt=p.at;v.completedFrame=p.frame;
        const auto provenance=Provenance(v.owner.route);
        optishade::session::State().Put({{"Device",std::to_string(v.owner.device)},{"Generation",std::to_string(v.owner.generation)},
            {"SourceColour",provenance.colour},{"SourceDepth",provenance.depth},{"SourceMotion",provenance.motion},{"NRInputStage",provenance.stage},
            {"NRCompletedFrame",std::to_string(p.frame)},{"NRCompletedTicketCount",std::to_string(completedRecords)},
            {"NRRequestRevision",std::to_string(p.revision)},{"NRViewport",std::to_string(v.owner.view)},
            {"NRRoute",std::to_string(unsigned(v.owner.route))},{"NRStage",p.composed?"GPU completed; composition recorded":"GPU completed"},
            {"SubmissionStage",v.submitted?"Submitted":"Not observed"},{"GPUCompletion","Completed"},{"LastSuccessfulTicket",std::to_string(ticket)}});

        v.queue=queue;if(frequency)v.frequency=frequency;if(ms){v.gpuMilliseconds=ms;lanes[p.slot].timingAt=p.at;}
    }
    // Timing often becomes available several frames after composition. Do not
    // discard a valid delayed GPU measurement merely because a newer frame in
    // the same owner lane has already completed.
    void Timing(uint64_t ticket, uint64_t frequency, std::optional<double> ms) {
        std::lock_guard<std::mutex> lock(mutex);
        auto& p=pending[ticket%pending.size()];
        if(!ticket || p.id!=ticket || !p.evaluated || p.revision!=revision || !requested) return;
        auto& v=lanes[p.slot].value;
        if(v.request!=p.revision || lanes[p.slot].config!=p.ownerEpoch) return;
        if(frequency)v.frequency=frequency;
        if(ms){v.gpuMilliseconds=ms;lanes[p.slot].timingAt=p.at;}
    }
    void PresentSubmitted(uint64_t ticket,int64_t result,bool success){
        std::lock_guard<std::mutex> lock(mutex);auto& p=pending[ticket%pending.size()];
        if(!ticket||p.id!=ticket||p.revision!=revision)return;
        const auto stage=unsigned(optishade::route::OutputStage::PresentSubmitted);
        p.output.observed|=1u<<stage;p.output.result[stage]=result;if(!success)p.output.failed|=1u<<stage;
    }
    std::optional<TicketSnapshot> ReadTicket(uint64_t ticket) {
        std::lock_guard<std::mutex> lock(mutex);
        const auto& p=pending[ticket%pending.size()];
        if(!ticket || !requested || p.id!=ticket || p.revision!=revision)return std::nullopt;
        const auto& lane=lanes[p.slot];
        if(lane.config!=p.ownerEpoch || lane.value.request!=p.revision)return std::nullopt;
        const bool submitted=(p.output.observed & (1u<<unsigned(optishade::route::OutputStage::Submitted)))!=0;
        return TicketSnapshot{lane.value.owner,p.output,p.revision,p.frame,
                              p.evaluated,p.composed,submitted,p.completionCounted};
    }
    uint64_t CompletedRecords() { std::lock_guard<std::mutex> lock(mutex); return completedRecords; }
    Snapshot Read(uint64_t now) {
        std::lock_guard<std::mutex> lock(mutex);return ReadLocked(now);
    }
    bool TryRead(uint64_t now,Snapshot& result) {
        std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);if(!lock.owns_lock())return false;
        result=ReadLocked(now);return true;
    }
    // Select from the existing bounded lanes by the actual output owner. A
    // newer helper window/eye must never supply the primary output's evidence.
    bool TryReadForOutput(uint64_t now,uint64_t device,uint64_t runtime,uint64_t generation,uint32_t view,Snapshot& result) {
        std::unique_lock<std::mutex> lock(mutex,std::try_to_lock);if(!lock.owns_lock())return false;
        unsigned slot=0;bool found=false;
        for(unsigned i=0;i<lanes.size();++i){const auto& owner=lanes[i].value.owner;
            if(lanes[i].used&&device&&runtime&&generation&&owner.device==device&&owner.runtime==runtime&&
               owner.generation==generation&&owner.view==view&&(!found||lanes[i].used>lanes[slot].used)){slot=i;found=true;}}
        if(found)result=ReadLaneLocked(slot,now);
        else {result={};result.request=revision;result.explicitOffRevision=explicitOffRevision;result.requested=requested;result.visible=visible;result.age=UINT64_MAX;}
        return true;
    }
private:
    Snapshot ReadLocked(uint64_t now) {
        unsigned slot=0;for(unsigned i=1;i<lanes.size();++i)if(lanes[i].used>lanes[slot].used)slot=i;
        return ReadLaneLocked(slot,now);
    }
    Snapshot ReadLaneLocked(unsigned slot,uint64_t now) {
        auto result=lanes[slot].value;
        const auto& p=pending[result.ticket%pending.size()];if(p.id==result.ticket)result.output=p.output;
        // Session intent exists before the first accepted render lane. Its CAS
        // revision must not revert to zero merely because no model ran yet.
        result.request=revision;result.explicitOffRevision=explicitOffRevision;result.requested=requested;result.visible=visible;
        result.age=result.completedAt && now>=result.completedAt ? now-result.completedAt : UINT64_MAX;
        result.recent=requested && result.completed && result.request==revision && result.age<1500;
        if(!result.recent || !lanes[slot].timingAt || now<lanes[slot].timingAt || now-lanes[slot].timingAt>=1500) result.gpuMilliseconds.reset();
        return result;
    }
};
inline Tracker& State(){return optishade::route::Owned<Tracker,15>();}
inline const char* Name(Route route){switch(route){case Route::PreFgTAA:return "TAA compatibility / pre-FG producer";case Route::NativeD3D12:return "native D3D12";case Route::BeforeSR:return "before SR";case Route::FinishedPicture:return "finished picture";case Route::EstimatedTAA:return "estimated TAA";case Route::NativeVulkan:return "native Vulkan";case Route::EstimatedVulkan:return "estimated Vulkan";default:return "unobserved";}}
}

