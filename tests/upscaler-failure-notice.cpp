#include "../shared/UpscalerFailureNotice.h"
#include <atomic>
#include <cassert>
#include <iostream>
#include <thread>
#include <vector>

using namespace optishade;
int main()
{
    const auto a = UpscalerFailureKey(UpscalerApi::Dx12, 7);
    const auto b = UpscalerFailureKey(UpscalerApi::Dx11, 7);
    const auto c = UpscalerFailureKey(UpscalerApi::Vulkan, 7);
    assert(a != b && a != c && b != c);
    UpscalerFailureGate<> gate;
    assert(gate.Observe(a, false, 0).notify);
    assert(gate.Observe(b, false, 0).notify);
    for (unsigned i = 1; i <= 100000; ++i)
    {
        const auto notice = gate.Observe(a, false, i % 9999);
        assert(!notice.notify && notice.failures == i + 1 && !notice.overflow);
    }
    auto reminder = gate.Observe(a, false, 10000);
    assert(reminder.notify && reminder.failures == 100002);
    assert(!gate.Observe(a, true, 10001).notify);
    auto nextEpisode = gate.Observe(a, false, 10002);
    assert(nextEpisode.notify && nextEpisode.failures == 1);
    assert(gate.Observe(b, false, 10002).failures == 2); // A's recovery did not clear B.
    gate.Retire(a);
    assert(gate.Observe(a, false, 10003).failures == 1);

    UpscalerFailureGate<2> full;
    assert(!full.Observe(a, false, 0).overflow);
    assert(!full.Observe(b, false, 0).overflow);
    auto overflow = full.Observe(c, false, 0);
    assert(overflow.overflow && overflow.notify && overflow.failures == 1);
    for (uint64_t key = 100; key < 10100; ++key)
    {
        auto notice = full.Observe(key, false, 1);
        assert(notice.overflow && !notice.notify);
        full.Retire(key); // Unknown retirement must not reset the aggregate bucket.
    }
    assert(full.Observe(a, false, 1).failures == 2); // No live eviction.
    full.Retire(a);
    auto admitted = full.Observe(c, false, 2);
    assert(!admitted.overflow && admitted.notify && admitted.failures == 1);

    // Thousands of short failure/recovery episodes still cannot flood the UI.
    UpscalerFailureGate<4, 8> churn;
    unsigned notices = 0;
    for (uint64_t key = 0; key < 10000; ++key)
    {
        notices += churn.Observe(key, false, 100).notify;
        churn.Retire(key);
    }
    assert(notices == 8);
    assert(!churn.Observe(a, false, 50).notify); // Clock rollback cannot replenish the budget.
    assert(churn.Observe(a, false, 10100).notify);

    UpscalerFailureGate<> concurrent;
    std::atomic<unsigned> total {0};
    std::vector<std::thread> workers;
    for (unsigned thread = 0; thread < 8; ++thread)
        workers.emplace_back([&, thread] {
            for (unsigned i = 0; i < 10000; ++i)
                total += concurrent.Observe(thread, false, 100).notify;
        });
    for (auto& worker : workers) worker.join();
    assert(total == 8);
    std::cout << "PASS: per-feature/API failure episodes, 100000 repeated failures, reminders, recovery/reuse, bounded identity overflow, churn budget and concurrent callers\n";
}
