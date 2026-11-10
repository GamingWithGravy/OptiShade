#pragma once
#include <array>
#include <cstdint>
#include <memory>
#include <mutex>
#include <atomic>
namespace optishade::route {
// A domain is an output/eye history, not a frame or a command recording.
// Directory publication is synchronized across DX12 and Vulkan. No in-flight
// entry is evicted to admit a new target.
struct OutputKey {
    uint64_t device=0, owner=0, generation=0;
    uint32_t view=0, route=0;
    bool SameOutput(const OutputKey& b)const{return device==b.device && owner==b.owner && view==b.view && route==b.route;}
    bool operator==(const OutputKey& b) const {
        return device==b.device && owner==b.owner && generation==b.generation && view==b.view && route==b.route;
    }
};
class OutputDirectory {
public:
    static constexpr unsigned Capacity=32;
    struct Entry {bool used=false;OutputKey key{};bool retiring=false;};
private:
    std::array<Entry,Capacity> entries{};
    mutable std::mutex mutex;
public:
    std::atomic<unsigned> selected{0};
    std::array<Entry,Capacity> Snapshot()const{std::lock_guard lock(mutex);return entries;}
    OutputKey Key(unsigned index)const{std::lock_guard lock(mutex);return entries.at(index).key;}
    unsigned FindOrAdd(OutputKey key) {
        if (!key.device || !key.owner) return Capacity;
        std::lock_guard lock(mutex);
        for(unsigned i=1;i<Capacity;++i) if(entries[i].used && entries[i].key.SameOutput(key)) {
            if(entries[i].retiring || key.generation<entries[i].key.generation)return Capacity;
            entries[i].key=key;return i;
        }
        for(unsigned i=1;i<Capacity;++i) if(!entries[i].used){entries[i]={true,key};return i;}
        return Capacity;
    }
    // The owning runtime has stopped submitting. Keep its slot reserved until
    // the GPU lifetime owner has released the resources for this exact key.
    unsigned RetireOwner(uint64_t owner,uint32_t route) {
        if(!owner)return 0;
        std::lock_guard lock(mutex);unsigned count=0;
        for(unsigned i=1;i<Capacity;++i)if(entries[i].used&&entries[i].key.owner==owner&&entries[i].key.route==route){entries[i].retiring=true;++count;}
        return count;
    }
    bool CompleteRetirement(unsigned index,const OutputKey& key,bool resourcesReleased) {
        if(!resourcesReleased||index==0||index>=Capacity)return false;
        std::lock_guard lock(mutex);
        auto& entry=entries[index];
        if(!entry.used||!entry.retiring||!(entry.key==key))return false;
        entry={};unsigned expected=index;selected.compare_exchange_strong(expected,0);
        return true;
    }
};
template<class T> struct OutputStorage {
    std::array<std::unique_ptr<T>,OutputDirectory::Capacity> values{};
    std::mutex mutex;
    T& Get(unsigned index) {
        std::lock_guard lock(mutex);
        auto& value=values.at(index);
        if(!value)value=std::make_unique<T>();
        return *value;
    }
    // Only after the output's recording/fence owners have proved retirement.
    void Release(unsigned index) {
        std::unique_ptr<T> retired;
        {std::lock_guard lock(mutex);retired=std::move(values.at(index));}
        // COM destructors can reenter hooks. Never run them under storage's lock.
    }
};
}
