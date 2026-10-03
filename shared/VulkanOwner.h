#pragma once
#include <cstdint>
#include <vector>
#include <algorithm>

namespace optishade::vkowner {
using Handle = uint64_t;
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
        if (!s.window || chains.size() >= 256) return false;
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
        // Multi-swapchain batches are deliberately passed through, preserving
        // pNext/results/waits. Do not consume their shared binary semaphores.
        return owner.chain && count==1 && chains && images && chains[0]==owner.chain &&
               images[0]<imageCount && q.device==owner.device && q.graphics;
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
inline bool DrawContract(bool ready, Handle queue, Handle ownerQueue, Handle chain, Handle ownerChain,
                         uint32_t count, uint32_t image, uint32_t imageCount) {
    return ready && queue && queue==ownerQueue && ownerChain && chain==ownerChain && count==1 && image<imageCount;
}
}
