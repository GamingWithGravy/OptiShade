#include "../../Beta/shared/DeferredModuleUnloads.h"

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

int main()
{
    optishade::DeferredModuleUnloads<16> modules;
    if (modules.Defer(nullptr) || modules.CapacityExceeded())
    {
        std::fprintf(stderr, "null module was accepted or marked capacity overflow\n");
        return 1;
    }

    constexpr std::size_t threadCount = 8;
    constexpr std::size_t handlesPerThread = 8;
    std::atomic<unsigned> failures{0};
    std::mutex observedMutex;
    std::set<void*> observed;
    std::atomic<bool> writersDone{false};

    std::thread reader([&]
    {
        while (!writersDone.load(std::memory_order_acquire))
        {
            std::set<void*> snapshot;
            modules.ForEach([&](void* module)
            {
                if (module == nullptr || !snapshot.insert(module).second)
                    failures.fetch_add(1, std::memory_order_relaxed);
            });
            std::lock_guard lock(observedMutex);
            observed.insert(snapshot.begin(), snapshot.end());
        }
    });

    std::vector<std::thread> writers;
    for (std::size_t threadIndex = 0; threadIndex < threadCount; ++threadIndex)
    {
        writers.emplace_back([&]
        {
            for (unsigned repeat = 0; repeat < 256; ++repeat)
            {
                for (std::size_t handleIndex = 0; handleIndex < handlesPerThread; ++handleIndex)
                {
                    const auto value = 0x1000u + static_cast<std::uintptr_t>(handleIndex + 1u);
                    void* const handle = reinterpret_cast<void*>(value);
                    if (!modules.Defer(handle))
                        failures.fetch_add(1, std::memory_order_relaxed);
                }
            }
        });
    }

    for (auto& writer : writers)
        writer.join();
    writersDone.store(true, std::memory_order_release);
    reader.join();

    modules.Close();
    if (!modules.IsClosed() || modules.Defer(reinterpret_cast<void*>(0x1001u)))
    {
        std::fprintf(stderr, "closed registry accepted another module\n");
        return 2;
    }

    std::set<void*> finalSnapshot;
    modules.ForEach([&](void* module) { finalSnapshot.insert(module); });
    {
        std::lock_guard lock(observedMutex);
        observed.insert(finalSnapshot.begin(), finalSnapshot.end());
    }
    if (failures.load(std::memory_order_relaxed) != 0 || finalSnapshot.size() != handlesPerThread ||
        modules.CapacityExceeded())
    {
        std::fprintf(stderr, "concurrent defer/snapshot failed (handles=%zu, failures=%u)\n",
                     finalSnapshot.size(), failures.load(std::memory_order_relaxed));
        return 3;
    }

    // Repeated handles across threads must converge to one slot per module.
    for (std::size_t i = 0; i < handlesPerThread; ++i)
    {
        if (observed.find(reinterpret_cast<void*>(0x1001u + i)) == observed.end())
        {
            std::fprintf(stderr, "concurrent snapshot missed a deferred module\n");
            return 4;
        }
    }

    optishade::DeferredModuleUnloads<2> bounded;
    if (!bounded.Defer(reinterpret_cast<void*>(1u)) || !bounded.Defer(reinterpret_cast<void*>(2u)) ||
        bounded.Defer(reinterpret_cast<void*>(3u)) || !bounded.CapacityExceeded() ||
        !bounded.Defer(reinterpret_cast<void*>(1u)))
    {
        std::fprintf(stderr, "bounded registry did not preserve handles safely at capacity\n");
        return 4;
    }

    bounded.Close();
    if (!bounded.IsClosed() || !bounded.CapacityExceeded() || bounded.Defer(reinterpret_cast<void*>(3u)))
    {
        std::fprintf(stderr, "capacity/closed registry state was not retained\n");
        return 5;
    }

    std::puts("Deferred module unload registry concurrency and capacity tests passed.");
    return 0;
}
