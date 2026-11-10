#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <cstddef>

namespace optishade::input {
// Admission filter only. The input state's generation-checked HID slots remain
// authoritative. Writers publish under that state's mutex, before returning an
// opened handle. Ordinary filesystem/loader I/O never needs the input mutex.
template<std::size_t N> class HandleFilter {
    std::array<std::atomic<std::uintptr_t>,N> slots{};
public:
    static_assert(std::atomic<std::uintptr_t>::is_always_lock_free);
    void Publish(std::size_t index,std::uintptr_t handle){slots[index].store(handle,std::memory_order_release);}
    bool Contains(std::uintptr_t handle) const {
        if(!handle || handle==UINTPTR_MAX)return false;
        for(const auto& slot:slots)if(slot.load(std::memory_order_acquire)==handle)return true;
        return false;
    }
    void Clear(){for(auto& slot:slots)slot.store(0,std::memory_order_release);}
};
}
