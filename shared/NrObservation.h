#pragma once
#include <array>
#include <cstdint>
#include <mutex>
#include <optional>

namespace optishade::nr_observation {
enum class Route : uint32_t { Unknown, NativeD3D12, BeforeSR, FinishedPicture, EstimatedTAA, NativeVulkan, EstimatedVulkan };
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
    uint64_t request=0, effective=0, ticket=0, frame=0, evaluatedAt=0, completedAt=0;
    uint64_t completedFrame=0, completedTicket=0, queue=0, frequency=0, age=0;
    bool requested=false, visible=false, evaluated=false, completed=false, composed=false;
    bool recent=false;
    std::optional<double> gpuMilliseconds;
};
// Bounded evidence, not a configuration object. Callers still own Config and admission.
// Tickets carry their revision and owner; late completion cannot satisfy a newer request.
class Tracker {
    struct Pending { uint64_t id=0, revision=0, frame=0, at=0, ownerEpoch=0; unsigned slot=0; bool evaluated=false, composed=false; };
    struct Lane { Snapshot value; uint64_t used=0, config=0; };
    std::array<Lane,8> lanes{};
    std::array<Pending,64> pending{};
    std::mutex mutex;
    uint64_t serial=0, revision=0, requestKey=0;
    bool requested=false, visible=false;
public:
    void Request(bool on, bool apply, uint64_t key) {
        std::lock_guard<std::mutex> lock(mutex);
        if(on==requested && apply==visible && key==requestKey) return;
        requested=on; visible=apply; requestKey=key; ++revision;
        for(auto& lane:lanes) {
            lane.value.request=revision; lane.value.requested=on; lane.value.visible=apply;
            lane.value.evaluated=lane.value.completed=lane.value.composed=false;
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
        if(!found || reset) {lane.value={};lane.value.owner=owner;lane.config=++serial;}
        else if(!lane.config) lane.config=++serial;
        auto& v=lane.value;
        v.request=revision; v.requested=requested;v.visible=visible;
        v.ticket=++serial;v.frame=frame;lane.used=serial;
        pending[serial%pending.size()]={serial,revision,frame,now,lane.config,slot,false,false};
        return serial;
    }
    void Evaluated(uint64_t ticket, bool composed) {
        std::lock_guard<std::mutex> lock(mutex);
        auto& p=pending[ticket%pending.size()];
        if(!ticket || p.id!=ticket || p.revision!=revision) return;
        auto& v=lanes[p.slot].value;
        if(v.request!=p.revision || lanes[p.slot].config!=p.ownerEpoch) return;
        p.evaluated=true;p.composed=composed;
        v.evaluated=true;v.evaluatedAt=p.at;v.effective=p.revision;
    }
    void Completed(uint64_t ticket, uint64_t queue, uint64_t frequency, std::optional<double> ms) {
        std::lock_guard<std::mutex> lock(mutex);
        auto& p=pending[ticket%pending.size()];
        if(!ticket || p.id!=ticket || !p.evaluated || p.revision!=revision || !requested) return;
        auto& v=lanes[p.slot].value;
        if(v.request!=p.revision || lanes[p.slot].config!=p.ownerEpoch || ticket<v.completedTicket) return;
        if(ticket==v.completedTicket){if(queue)v.queue=queue;if(frequency)v.frequency=frequency;if(ms)v.gpuMilliseconds=ms;return;}
        v.completedTicket=ticket;v.completed=true;v.composed=p.composed;v.completedAt=p.at;v.completedFrame=p.frame;
        v.queue=queue;v.frequency=frequency;v.gpuMilliseconds=ms;
    }
    Snapshot Read(uint64_t now) {
        std::lock_guard<std::mutex> lock(mutex);
        unsigned slot=0;for(unsigned i=1;i<lanes.size();++i)if(lanes[i].used>lanes[slot].used)slot=i;
        auto result=lanes[slot].value;
        result.requested=requested;result.visible=visible;
        result.age=result.completedAt && now>=result.completedAt ? now-result.completedAt : UINT64_MAX;
        result.recent=requested && result.completed && result.request==revision && result.age<1500;
        if(!result.recent) result.gpuMilliseconds.reset();
        return result;
    }
};
inline Tracker& State(){static Tracker value;return value;}
inline const char* Name(Route route){switch(route){case Route::NativeD3D12:return "native D3D12";case Route::BeforeSR:return "before SR";case Route::FinishedPicture:return "finished picture";case Route::EstimatedTAA:return "estimated TAA";case Route::NativeVulkan:return "native Vulkan";case Route::EstimatedVulkan:return "estimated Vulkan";default:return "unobserved";}}
}

