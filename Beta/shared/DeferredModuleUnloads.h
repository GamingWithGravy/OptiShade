#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <thread>

namespace optishade
{
// Loader hooks can run on several application threads. Keep deferred module
// handles without a lock or allocation so recording them cannot race with
// process-detach enumeration or deadlock under the Windows loader lock.
template <std::size_t Capacity>
class DeferredModuleUnloads final
{
public:
    DeferredModuleUnloads() noexcept
    {
        for (auto& slot : _modules)
            slot.store(nullptr, std::memory_order_relaxed);
    }

    [[nodiscard]] bool Defer(void* module) noexcept
    {
        if (module == nullptr)
            return false;

        _activeWriters.fetch_add(1, std::memory_order_acq_rel);
        if (_closed.load(std::memory_order_acquire))
        {
            _activeWriters.fetch_sub(1, std::memory_order_release);
            return false;
        }

        bool accepted = false;
        for (auto& slot : _modules)
        {
            void* present = slot.load(std::memory_order_acquire);
            if (present == module)
            {
                accepted = true;
                break;
            }
            if (present != nullptr)
                continue;

            void* expected = nullptr;
            if (slot.compare_exchange_strong(expected, module, std::memory_order_release,
                                             std::memory_order_acquire) ||
                expected == module)
            {
                accepted = true;
                if (expected == nullptr)
                    _generation.fetch_add(1, std::memory_order_release);
                break;
            }
        }

        if (!accepted)
            _capacityExceeded.store(true, std::memory_order_release);
        _activeWriters.fetch_sub(1, std::memory_order_release);
        return accepted;
    }

    // Call at teardown before enumerating. Once closed, later loader callbacks
    // leave their modules resident until OS process cleanup rather than racing
    // the teardown snapshot.
    void Close() noexcept
    {
        _closed.store(true, std::memory_order_release);
        while (_activeWriters.load(std::memory_order_acquire) != 0)
            std::this_thread::yield();
    }

    template <typename Visitor>
    void ForEach(Visitor&& visitor) const
    {
        std::array<void*, Capacity> snapshot{};
        std::size_t count = 0;
        for (;;)
        {
            while (_activeWriters.load(std::memory_order_acquire) != 0)
                std::this_thread::yield();
            const auto generation = _generation.load(std::memory_order_acquire);
            if (_activeWriters.load(std::memory_order_acquire) != 0)
                continue;

            count = 0;
            for (const auto& slot : _modules)
            {
                if (void* module = slot.load(std::memory_order_acquire))
                    snapshot[count++] = module;
            }

            if (_activeWriters.load(std::memory_order_acquire) == 0 &&
                _generation.load(std::memory_order_acquire) == generation)
                break;
        }

        for (std::size_t i = 0; i < count; ++i)
            visitor(snapshot[i]);
    }

    [[nodiscard]] bool CapacityExceeded() const noexcept
    {
        return _capacityExceeded.load(std::memory_order_acquire);
    }

    [[nodiscard]] bool IsClosed() const noexcept
    {
        return _closed.load(std::memory_order_acquire);
    }

private:
    std::array<std::atomic<void*>, Capacity> _modules{};
    mutable std::atomic<std::uint32_t> _activeWriters{0};
    std::atomic<std::uint64_t> _generation{0};
    std::atomic<bool> _capacityExceeded{false};
    std::atomic<bool> _closed{false};
};
} // namespace optishade
