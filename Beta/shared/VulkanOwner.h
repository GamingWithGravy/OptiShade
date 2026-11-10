#pragma once
#include <cstdint>
#include <vector>
#include <algorithm>

namespace optishade::vkowner {
using Handle = uint64_t;
inline constexpr uint32_t NoPresentIndex = UINT32_MAX;
// Select the unique owner without splitting/reordering the application's batch.
// Shared waits, pNext arrays and per-swapchain results must retain their indexing.
template<class ChainHandle>
inline uint32_t PresentIndex(ChainHandle owner, uint32_t count, const ChainHandle* chains,
                             const uint32_t* images, uint32_t imageCount) {
    if (!owner || !count || !chains || !images) return NoPresentIndex;
    uint32_t found=NoPresentIndex;
    for(uint32_t i=0;i<count;++i) if(chains[i]==owner) {
        if(found!=NoPresentIndex || images[i]>=imageCount) return NoPresentIndex;
        found=i;
    }
    return found;
}
// Only consult per-chain output for results that define individual WSI outcomes.
// Device loss / allocation failure remains global even if stale outputs say success.
template<class Result>
inline Result PresentResult(Result aggregate,bool perChainDefined,const Result* results,
                            uint32_t index,uint32_t count) {
    return perChainDefined && results && index<count ? results[index] : aggregate;
}
// The hook serializes access. No Vulkan/Win32 calls or frame-age heuristics here.
class Registry {
public:
    struct Surface { Handle instance, surface, window; };
    struct Chain { Handle device, surface, chain, window, generation; };
    struct Queue { Handle device, queue; uint32_t family; bool graphics; };
    std::vector<Surface> surfaces;
    std::vector<Chain> chains;
    std::vector<Queue> queues;
    Chain owner{};
    uint64_t serial = 0;
    void surface(Handle instance, Handle surface, Handle window) {
        eraseSurface(surface);
        if (surfaces.size() < 256) surfaces.push_back({instance,surface,window});
    }
    Surface lookup(Handle surface) const {
        for (const auto& s: surfaces) if (s.surface == surface) return s;
        return {};
    }
    bool swapchain(Handle device, Handle surface, Handle chain, bool eligible, bool ownerAlive) {
        const auto s=lookup(surface);
        if (!s.window) return false;
        for (auto& existing : chains) {
            if (existing.device != device || existing.surface != surface || existing.chain != chain) continue;
            existing.window = s.window;
            if (eligible && (!owner.chain || !ownerAlive || owner.chain==chain ||
                             (owner.window==s.window && owner.device==device))) {
                owner=existing;
                return true;
            }
            return owner.chain==chain;
        }
        if (chains.size() >= 256) return false;
        Chain c{device,surface,chain,s.window,++serial}; chains.push_back(c);
        if (eligible && (!owner.chain || !ownerAlive || (owner.window==s.window && owner.device==device))) {
            owner=c; return true;
        }
        return false;
    }
    void queue(Handle device, Handle queue, uint32_t family, bool graphics) {
        for (auto& q:queues) if(q.queue==queue) {q={device,queue,family,graphics};return;}
        if(queues.size()<256) queues.push_back({device,queue,family,graphics});
    }
    Queue findQueue(Handle q) const { for(const auto& v:queues) if(v.queue==q)return v;return {}; }
    bool present(Handle queue, uint32_t count, const Handle* chains, const uint32_t* images,
                 uint32_t imageCount) const {
        const auto q=findQueue(queue);
        // Draw only on the owner image; the hook forwards the entire batch once.
        return PresentIndex(owner.chain,count,chains,images,imageCount)!=NoPresentIndex &&
               q.device==owner.device && q.graphics;
    }
    void eraseChain(Handle chain) {
        if(owner.chain==chain)owner={};
        chains.erase(std::remove_if(chains.begin(),chains.end(),[=](const Chain& c){return c.chain==chain;}),chains.end());
    }
    void eraseSurface(Handle surface) {
        if(owner.surface==surface)owner={};
        chains.erase(std::remove_if(chains.begin(),chains.end(),[=](const Chain& c){return c.surface==surface;}),chains.end());
        surfaces.erase(std::remove_if(surfaces.begin(),surfaces.end(),[=](const Surface& s){return s.surface==surface;}),surfaces.end());
    }
    void eraseDevice(Handle device) {
        if(owner.device==device)owner={};
        chains.erase(std::remove_if(chains.begin(),chains.end(),[=](const Chain& c){return c.device==device;}),chains.end());
        queues.erase(std::remove_if(queues.begin(),queues.end(),[=](const Queue& q){return q.device==device;}),queues.end());
    }
    void eraseInstance(Handle instance) {
        auto copy=surfaces;for(const auto& s:copy)if(s.instance==instance)eraseSurface(s.surface);
    }
};
// Resolve an exact logical-device/swapchain lifetime for diagnostics. A
// missing or duplicate match is deliberately unknown; never guess a generation
// from the numeric handle alone because Vulkan may reuse handles after destroy.
inline uint64_t FindSwapchainGeneration(Handle device, Handle swapchain,
                                       const std::vector<Registry::Chain>& chains) {
    if (!device || !swapchain) return 0;
    uint64_t generation = 0;
    for (const auto& chain : chains) {
        if (chain.device != device || chain.chain != swapchain) continue;
        if (!chain.generation || generation) return 0;
        generation = chain.generation;
    }
    return generation;
}
inline Handle FindQueueDevice(Handle queue, const std::vector<Registry::Queue>& queues) {
    if (!queue) return 0;
    Handle device = 0;
    for (const auto& entry : queues) {
        if (entry.queue != queue) continue;
        if (!entry.device || device) return 0;
        device = entry.device;
    }
    return device;
}
template<class ChainHandle>
inline bool DrawContract(bool ready, Handle queue, Handle ownerQueue, ChainHandle ownerChain,
                         uint32_t count, const ChainHandle* chains,const uint32_t* images,uint32_t imageCount) {
    return ready && queue && queue==ownerQueue &&
        PresentIndex(ownerChain,count,chains,images,imageCount)!=NoPresentIndex;
}
}
