#include "VulkanAcquireDependency.h"
#include <cassert>

using namespace optishade::vulkan_sync;

int main() {
    AcquireDependencyTracker tracker;
    const Image image{1, 20, 3, 1};

    const auto acquire = tracker.RecordAcquire(image, Result::Timeout, 10, 0);
    assert(acquire == 0);
    assert(tracker.RecordAcquire(image, Result::OutOfDate, 10, 0) == 0);
    const auto token = tracker.RecordAcquire(image, Result::Suboptimal, 10, 0);
    assert(token != 0);
    assert(tracker.RecordAcquire(image, Result::Success, 40, 0) == 0); // duplicate live image acquisition
    assert(tracker.HasSemaphoreDependency(image, 10));
    assert(!tracker.HasSemaphoreDependency({2, 20, 3, 1}, 10));
    assert(!tracker.HasSemaphoreDependency({1, 21, 3, 1}, 10));
    assert(!tracker.HasSemaphoreDependency({1, 20, 4, 1}, 10));

    // Merely submitting later work to the same queue creates no proof.
    const Signal plainSignal{11, true, AllCommandsStage};
    const Batch plain{7, Api::Legacy, nullptr, 0, &plainSignal, 1};
    assert(tracker.ObserveSubmit(1, Result::Success, &plain, 1) == StateResult::Recorded);
    assert(!tracker.HasSemaphoreDependency(image, 11));

    // Suboptimal is an acquire/present status, not VK_SUCCESS for submit.
    const auto tokenSuboptimalSubmit = tracker.RecordAcquire({1, 20, 3, 7}, Result::Success, 17, 0);
    assert(tokenSuboptimalSubmit != 0);
    const Wait wait17{17, true, AllCommandsStage};
    const Batch suboptimalSubmit{7, Api::Legacy, &wait17, 1, &plainSignal, 1};
    assert(tracker.ObserveSubmit(1, Result::Suboptimal, &suboptimalSubmit, 1) == StateResult::IgnoredResult);
    assert(tracker.HasSemaphoreDependency({1, 20, 3, 7}, 17));
    assert(!tracker.HasSemaphoreDependency({1, 20, 3, 7}, 11));

    // Legacy waits must cover ALL_COMMANDS. The accepted wait consumes the
    // acquire semaphore even when its narrower scope cannot carry proof.
    const Wait earlyWait{10, true, 0x00000001ull};
    const Batch narrow{7, Api::Legacy, &earlyWait, 1, &plainSignal, 1};
    assert(tracker.ObserveSubmit(1, Result::Success, &narrow, 1) == StateResult::Recorded);
    assert(!tracker.HasSemaphoreDependency(image, 10));
    assert(!tracker.HasSemaphoreDependency(image, 11));

    // Failed submission is atomic: it cannot consume an acquire token or
    // publish a signal edge. A later accepted submission may carry it.
    const auto token2 = tracker.RecordAcquire({1, 20, 3, 2}, Result::Success, 12, 0);
    assert(token2 != 0);
    const Wait wait12{12, true, AllCommandsStage};
    const Batch rejected{7, Api::Legacy, &wait12, 1, &plainSignal, 1};
    assert(tracker.ObserveSubmit(1, Result::Failure, &rejected, 1) == StateResult::IgnoredResult);
    assert(tracker.HasSemaphoreDependency({1, 20, 3, 2}, 12));
    assert(tracker.ObserveSubmit(1, Result::Success, &rejected, 1) == StateResult::Recorded);
    assert(tracker.HasSemaphoreDependency({1, 20, 3, 2}, 11));

    // Separate VkSubmitInfo entries are processed in array order, allowing a
    // real wait->signal edge from one batch to feed the next batch.
    const auto token3 = tracker.RecordAcquire({1, 20, 3, 3}, Result::Success, 13, 0);
    assert(token3 != 0);
    const Wait wait13{13, true, AllCommandsStage};
    const Signal signal14{14, true, AllCommandsStage};
    const Wait wait14{14, true, AllCommandsStage};
    const Signal signal15{15, true, AllCommandsStage};
    const Batch batches[]{
        {8, Api::Legacy, &wait13, 1, &signal14, 1},
        {8, Api::Legacy, &wait14, 1, &signal15, 1}
    };
    assert(tracker.ObserveSubmit(1, Result::Success, batches, 2) == StateResult::Recorded);
    assert(!tracker.HasSemaphoreDependency({1, 20, 3, 3}, 14)); // consumed by batch 2
    assert(tracker.HasSemaphoreDependency({1, 20, 3, 3}, 15));

    // Sync2 must carry the full wait and signal stage scopes. Unsupported
    // extensions/device-group semantics and timeline semaphores fail closed.
    const auto token4 = tracker.RecordAcquire({1, 20, 3, 4}, Result::Success, 16, 0);
    assert(token4 != 0);
    const Wait wait16{16, true, AllCommandsStage};
    const Signal earlySignal{17, true, 0x00000001ull};
    const Batch partialSync2{9, Api::Synchronization2, &wait16, 1, &earlySignal, 1};
    assert(tracker.ObserveSubmit(1, Result::Success, &partialSync2, 1) == StateResult::Recorded);
    assert(!tracker.HasSemaphoreDependency({1, 20, 3, 4}, 17));

    const auto token5 = tracker.RecordAcquire({1, 20, 3, 5}, Result::Success, 18, 0);
    assert(token5 != 0);
    const Wait wait18{18, true, AllCommandsStage};
    const Signal signal19{19, true, AllCommandsStage};
    Batch sync2{9, Api::Synchronization2, &wait18, 1, &signal19, 1};
    assert(tracker.ObserveSubmit(1, Result::Success, &sync2, 1) == StateResult::Recorded);
    assert(tracker.HasSemaphoreDependency({1, 20, 3, 5}, 19));
    sync2.unsupportedPNext = true;
    assert(tracker.ObserveSubmit(1, Result::Success, &sync2, 1) == StateResult::InvalidIdentity);
    assert(!tracker.HasSemaphoreDependency({1, 20, 3, 5}, 18)); // successful but unmodelled submit cannot leave a reusable acquire proof
    sync2.unsupportedPNext = false;

    // Validate the whole accepted VkQueueSubmit before publishing any batch.
    // If a later batch has unsupported semantics, the real successful call may
    // already have consumed earlier waits; stale pre-call evidence must die.
    AcquireDependencyTracker unobservedSubmitTracker;
    const Image unobservedImage{12, 120, 4, 2};
    assert(unobservedSubmitTracker.RecordAcquire(unobservedImage, Result::Success, 1200, 0) != 0);
    const Wait unobservedWait{1200, true, AllCommandsStage};
    const Signal unobservedIntermediate{1201, true, AllCommandsStage};
    const Wait unobservedIntermediateWait{1201, true, AllCommandsStage};
    const Signal unobservedTerminal{1202, true, AllCommandsStage};
    Batch unobservedBatches[]{
        {40, Api::Legacy, &unobservedWait, 1, &unobservedIntermediate, 1},
        {40, Api::Synchronization2, &unobservedIntermediateWait, 1, &unobservedTerminal, 1, true}
    };
    assert(unobservedSubmitTracker.ObserveSubmit(12, Result::Success, unobservedBatches, 2) == StateResult::InvalidIdentity);
    assert(!unobservedSubmitTracker.HasSemaphoreDependency(unobservedImage, 1200));
    assert(!unobservedSubmitTracker.HasSemaphoreDependency(unobservedImage, 1201));
    assert(!unobservedSubmitTracker.HasSemaphoreDependency(unobservedImage, 1202));
    sync2.deviceGroup = true;
    assert(tracker.ObserveSubmit(1, Result::Success, &sync2, 1) == StateResult::InvalidIdentity);
    sync2.deviceGroup = false;
    const Wait timelineWait{19, false, AllCommandsStage};
    sync2.waits = &timelineWait;
    assert(tracker.ObserveSubmit(1, Result::Success, &sync2, 1) == StateResult::InvalidIdentity);

    // An acquire fence contributes only after its own signal is observed.
    const Image fenceImage{1, 20, 3, 6};
    assert(tracker.RecordAcquire(fenceImage, Result::Success, 0, 100) != 0);
    assert(tracker.ObserveFence(1, 100, Result::NotReady) == StateResult::IgnoredResult);
    assert(!tracker.HasObservedFenceProof(fenceImage));
    assert(tracker.ObserveFence(1, 100, Result::Success) == StateResult::Recorded);
    assert(tracker.HasObservedFenceProof(fenceImage));
    tracker.ObserveFenceReset(1, 100, Result::Success);
    assert(tracker.HasObservedFenceProof(fenceImage)); // completion was already observed

    const Image resetImage{1, 20, 3, 70};
    assert(tracker.RecordAcquire(resetImage, Result::Success, 101, 102) != 0);
    tracker.ObserveFenceReset(1, 102, Result::Success);
    assert(!tracker.HasObservedFenceProof(resetImage));
    assert(!tracker.HasSemaphoreDependency(resetImage, 101));

    // Ambiguous binary semaphore reuse invalidates evidence; retirement and
    // device teardown remove only the corresponding identity's records.
    const auto token6 = tracker.RecordAcquire({1, 20, 3, 8}, Result::Success, 200, 0);
    assert(token6 != 0);
    assert(tracker.RecordAcquire({1, 20, 3, 9}, Result::Success, 200, 0) == 0);
    assert(!tracker.HasSemaphoreDependency({1, 20, 3, 8}, 200));
    tracker.Retire({1, 20, 3, 5});
    assert(!tracker.HasSemaphoreDependency({1, 20, 3, 5}, 19));
    assert(tracker.RecordAcquire({1, 20, 4, 5}, Result::Success, 19, 0) == 0); // retirement is not wait-consumption proof
    const auto token7 = tracker.RecordAcquire({1, 30, 9, 0}, Result::Success, 210, 0);
    assert(token7 != 0);
    const Wait wait210{210, true, AllCommandsStage};
    const Signal signal211{211, true, AllCommandsStage};
    const Batch generationBatch{10, Api::Legacy, &wait210, 1, &signal211, 1};
    assert(tracker.ObserveSubmit(1, Result::Success, &generationBatch, 1) == StateResult::Recorded);
    tracker.RetireGeneration(1, 30, 9);
    assert(!tracker.HasSemaphoreDependency({1, 30, 9, 0}, 211));
    assert(tracker.RecordAcquire({1, 30, 10, 0}, Result::Success, 211, 0) == 0);

    // A present-wait binary semaphore is not reusable just because the queue
    // submit returned. Its exact presented image must be reacquired first.
    AcquireDependencyTracker presentTracker;
    const Image presented{3, 40, 1, 0};
    assert(presentTracker.RecordAcquire(presented, Result::Success, 300, 0) != 0);
    const Wait acquire300{300, true, AllCommandsStage};
    const Signal terminal400{400, true, AllCommandsStage};
    const Batch relay400{30, Api::Legacy, &acquire300, 1, &terminal400, 1};
    assert(presentTracker.ObserveSubmit(3, Result::Success, &relay400, 1) == StateResult::Recorded);
    const PresentWait firstPresentWaits[]{{400, true}, {401, true}}; // preserve unrelated caller waits
    const PresentItem firstPresent[]{{presented, 400, Result::Success}};
    assert(presentTracker.ObservePresent(3, Result::Success, firstPresent, 1,
        firstPresentWaits, 2, true) == StateResult::Recorded);
    assert(!presentTracker.HasSemaphoreDependency(presented, 400));

    // Re-signal before reacquiring the image fails closed and poisons the
    // terminal semaphore; another image's acquire cannot establish ownership.
    assert(presentTracker.RecordAcquire({3, 41, 1, 0}, Result::Success, 301, 0) != 0);
    const Wait acquire301{301, true, AllCommandsStage};
    const Batch prematureRelay{31, Api::Legacy, &acquire301, 1, &terminal400, 1};
    assert(presentTracker.ObserveSubmit(3, Result::Success, &prematureRelay, 1) == StateResult::Ambiguous);
    assert(!presentTracker.HasSemaphoreDependency({3, 41, 1, 0}, 400));

    // Correct reuse: reacquire the exact image, relay through a full-scope
    // dependency, wait the new terminal in present, then record that cycle.
    AcquireDependencyTracker reuseTracker;
    assert(reuseTracker.RecordAcquire(presented, Result::Success, 310, 0) != 0);
    const Wait acquire310{310, true, AllCommandsStage};
    const Signal terminal410{410, true, AllCommandsStage};
    const Batch firstRelay{32, Api::Legacy, &acquire310, 1, &terminal410, 1};
    assert(reuseTracker.ObserveSubmit(3, Result::Success, &firstRelay, 1) == StateResult::Recorded);
    const PresentWait presentWait410{410, true};
    const PresentItem present410{presented, 410, Result::Success};
    assert(reuseTracker.ObservePresent(3, Result::Success, &present410, 1,
        &presentWait410, 1, true) == StateResult::Recorded);
    assert(reuseTracker.RecordAcquire(presented, Result::Success, 311, 0) != 0);
    const Wait acquire311{311, true, AllCommandsStage};
    const Batch reusedRelay{33, Api::Legacy, &acquire311, 1, &terminal410, 1};
    assert(reuseTracker.ObserveSubmit(3, Result::Success, &reusedRelay, 1) == StateResult::Recorded);
    assert(reuseTracker.HasSemaphoreDependency(presented, 410));
    assert(reuseTracker.ObservePresent(3, Result::Success, &present410, 1,
        &presentWait410, 1, true) == StateResult::Recorded);

    // Per-swapchain failure after a partial present has unknown semaphore
    // consumption; the affected terminal cannot be silently reused.
    AcquireDependencyTracker failedPresentTracker;
    const Image failedPresentImage{4, 50, 2, 0};
    assert(failedPresentTracker.RecordAcquire(failedPresentImage, Result::Success, 320, 0) != 0);
    const Wait acquire320{320, true, AllCommandsStage};
    const Signal terminal420{420, true, AllCommandsStage};
    const Batch failedRelay{34, Api::Legacy, &acquire320, 1, &terminal420, 1};
    assert(failedPresentTracker.ObserveSubmit(4, Result::Success, &failedRelay, 1) == StateResult::Recorded);
    const PresentWait failedWait{420, true};
    const PresentItem failedItem{failedPresentImage, 420, Result::OutOfDate};
    assert(failedPresentTracker.ObservePresent(4, Result::Success, &failedItem, 1,
        &failedWait, 1, true) == StateResult::Ambiguous);
    assert(!failedPresentTracker.HasSemaphoreDependency(failedPresentImage, 420));

    // A multi-swapchain present may share waits. Each terminal remains tied
    // to the full batch of images, and both images must be reacquired before
    // either terminal can be signaled again.
    AcquireDependencyTracker multiTracker;
    const Image multiA{6, 70, 1, 0};
    const Image multiB{6, 71, 1, 1};
    assert(multiTracker.RecordAcquire(multiA, Result::Success, 600, 0) != 0);
    assert(multiTracker.RecordAcquire(multiB, Result::Success, 601, 0) != 0);
    const Wait multiAcquireWaits[]{{600, true, AllCommandsStage}, {601, true, AllCommandsStage}};
    const Signal multiSignals[]{{610, true, AllCommandsStage}, {611, true, AllCommandsStage}};
    const Batch multiRelay{36, Api::Legacy, multiAcquireWaits, 2, multiSignals, 2};
    assert(multiTracker.ObserveSubmit(6, Result::Success, &multiRelay, 1) == StateResult::Recorded);
    const PresentItem multiItems[]{{multiA, 610, Result::Suboptimal}, {multiB, 611, Result::Success}};
    const PresentWait multiWaits[]{{610, true}, {611, true}};
    assert(multiTracker.ObservePresent(6, Result::Success, multiItems, 2,
        multiWaits, 2, true) == StateResult::Recorded);
    assert(multiTracker.RecordAcquire(multiA, Result::Success, 602, 0) != 0);
    const Wait onlyA{602, true, AllCommandsStage};
    const Batch partialReacquire{37, Api::Legacy, &onlyA, 1, multiSignals, 2};
    assert(multiTracker.ObserveSubmit(6, Result::Success, &partialReacquire, 1) == StateResult::Ambiguous);
    assert(!multiTracker.HasSemaphoreDependency(multiA, 610));

    // Fence-based acquire proof can authorize a host-observed image before a
    // later full-scope signal; an unobserved fence cannot.
    AcquireDependencyTracker fenceRelayTracker;
    const Image fencePresented{5, 60, 1, 0};
    assert(fenceRelayTracker.RecordAcquire(fencePresented, Result::Success, 0, 500) != 0);
    assert(fenceRelayTracker.ObserveFence(5, 500, Result::Success) == StateResult::Recorded);
    const Signal terminal500{510, true, AllCommandsStage};
    const Batch hostRelay{35, Api::Legacy, nullptr, 0, &terminal500, 1, false, false,
        &fencePresented, 1};
    assert(fenceRelayTracker.ObserveSubmit(5, Result::Success, &hostRelay, 1) == StateResult::Recorded);
    const PresentWait fencePresentWait{510, true};
    const PresentItem fencePresentItem{fencePresented, 510, Result::Success};
    assert(fenceRelayTracker.ObservePresent(5, Result::Success, &fencePresentItem, 1,
        &fencePresentWait, 1, true) == StateResult::Recorded);

    tracker.EraseDevice(1);
    assert(!tracker.HasSemaphoreDependency({1, 20, 3, 2}, 11));
}
