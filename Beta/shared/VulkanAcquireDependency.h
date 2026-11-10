// OptiShade additions, GPL-3.0-or-later.
// CPU-only synchronization proof model for the XP12 Vulkan route. This header
// is deliberately not wired to Vulkan hooks or used to admit frame generation.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace optishade::vulkan_sync {

constexpr uint64_t AllCommandsStage = 0x00010000ull;
constexpr std::size_t MaxTokens = 64;
constexpr std::size_t MaxTrackedSemaphores = 128;
constexpr std::size_t MaxTokensPerSemaphore = 16;
constexpr std::size_t MaxSubmitBatches = 16;
constexpr std::size_t MaxBatchSemaphores = 32;
constexpr std::size_t MaxPresentImages = 8;

enum class Api { Legacy, Synchronization2 };
enum class Result { Success, Suboptimal, Timeout, NotReady, OutOfDate, Failure };
enum class StateResult { Recorded, IgnoredResult, InvalidIdentity, Capacity, Ambiguous };

struct Image {
    uint64_t device = 0;
    uint64_t swapchain = 0;
    uint64_t generation = 0;
    uint32_t index = 0;
    constexpr bool operator==(const Image& other) const {
        return device == other.device && swapchain == other.swapchain &&
               generation == other.generation && index == other.index;
    }
    constexpr bool Valid() const { return device && swapchain && generation; }
};

struct Wait {
    uint64_t semaphore = 0;
    bool binary = true;
    uint64_t stageMask = 0;
};
struct Signal {
    uint64_t semaphore = 0;
    bool binary = true;
    // Legacy queue-submit signals are implicitly at ALL_COMMANDS. Sync2
    // callers must supply their actual stageMask.
    uint64_t stageMask = AllCommandsStage;
};
struct Batch {
    uint64_t queue = 0;
    Api api = Api::Legacy;
    const Wait* waits = nullptr;
    std::size_t waitCount = 0;
    const Signal* signals = nullptr;
    std::size_t signalCount = 0;
    bool unsupportedPNext = false;
    bool deviceGroup = false;
    const Image* hostReadyImages = nullptr;
    std::size_t hostReadyImageCount = 0;
};
struct PresentWait {
    uint64_t semaphore = 0;
    bool binary = true;
};
struct PresentItem {
    Image image{};
    // The terminal signal semaphore selected for this image's presentation.
    // The observer must preserve the original VkPresentInfoKHR wait list.
    uint64_t terminalSemaphore = 0;
    Result result = Result::Success;
};

class AcquireDependencyTracker {
    struct Token {
        uint64_t id = 0;
        Image image{};
        uint64_t fence = 0;
        bool fenceObserved = false;
        bool active = false;
    };
    struct SemaphoreState {
        uint64_t device = 0;
        uint64_t handle = 0;
        std::array<uint64_t, MaxTokensPerSemaphore> tokens{};
        std::size_t count = 0;
        bool ambiguous = false;
    };
    struct TerminalState {
        uint64_t device = 0;
        uint64_t semaphore = 0;
        std::array<Image, MaxPresentImages> owners{};
        std::size_t ownerCount = 0;
        bool active = false;
        bool ambiguous = false;
    };
    struct ImageTerminal {
        Image image{};
        uint64_t semaphore = 0;
        bool active = false;
        bool ambiguous = false;
    };

    std::array<Token, MaxTokens> tokens_{};
    std::array<SemaphoreState, MaxTrackedSemaphores> semaphores_{};
    std::array<TerminalState, MaxTrackedSemaphores> terminals_{};
    std::array<ImageTerminal, MaxTokens> imageTerminals_{};
    uint64_t nextToken_ = 1;

    Token* FindToken(uint64_t id) {
        for (auto& token : tokens_) if (token.active && token.id == id) return &token;
        return nullptr;
    }
    const Token* FindToken(uint64_t id) const {
        for (const auto& token : tokens_) if (token.active && token.id == id) return &token;
        return nullptr;
    }
    SemaphoreState* FindSemaphore(uint64_t device, uint64_t handle, bool create) {
        for (auto& state : semaphores_)
            if (state.handle == handle && state.device == device) return &state;
        if (!create) return nullptr;
        for (auto& state : semaphores_) if (!state.handle) {
            state.device = device;
            state.handle = handle;
            return &state;
        }
        return nullptr;
    }
    const SemaphoreState* FindSemaphore(uint64_t device, uint64_t handle) const {
        for (const auto& state : semaphores_)
            if (state.handle == handle && state.device == device) return &state;
        return nullptr;
    }
    TerminalState* FindTerminal(uint64_t device, uint64_t handle, bool create) {
        for (auto& state : terminals_)
            if (state.semaphore == handle && state.device == device) return &state;
        if (!create) return nullptr;
        for (auto& state : terminals_) if (!state.semaphore) {
            state.device = device;
            state.semaphore = handle;
            return &state;
        }
        return nullptr;
    }
    ImageTerminal* FindImageTerminal(Image image, bool create) {
        for (auto& state : imageTerminals_) if (state.active && state.image == image) return &state;
        if (!create) return nullptr;
        for (auto& state : imageTerminals_) if (!state.active) {
            state = ImageTerminal{image, 0, true, false};
            return &state;
        }
        return nullptr;
    }
    const ImageTerminal* FindImageTerminal(Image image) const {
        for (const auto& state : imageTerminals_) if (state.active && state.image == image) return &state;
        return nullptr;
    }
    void QuarantineSemaphore(uint64_t device, uint64_t semaphore) {
        if (!device || !semaphore) return;
        if (auto* state = FindSemaphore(device, semaphore, true)) {
            state->tokens.fill(0);
            state->count = 0;
            state->ambiguous = true;
        }
        if (auto* terminal = FindTerminal(device, semaphore, true)) {
            terminal->owners.fill({});
            terminal->ownerCount = 0;
            terminal->active = false;
            terminal->ambiguous = true;
        }
    }
    void QuarantineImage(Image image) {
        if (!image.Valid()) return;
        if (auto* slot = FindImageTerminal(image, true)) {
            slot->ambiguous = true;
            if (slot->semaphore) QuarantineSemaphore(image.device, slot->semaphore);
        }
    }
    void QuarantineDeviceEvidence(uint64_t device) {
        if (!device) return;
        for (auto& token : tokens_)
            if (token.active && token.image.device == device) token = {};
        for (auto& state : semaphores_) if (state.device == device && state.handle) {
            state.tokens.fill(0);
            state.count = 0;
            state.ambiguous = true;
        }
        for (auto& terminal : terminals_) if (terminal.device == device && terminal.semaphore) {
            terminal.owners.fill({});
            terminal.ownerCount = 0;
            terminal.active = false;
            terminal.ambiguous = true;
        }
        for (auto& slot : imageTerminals_)
            if (slot.active && slot.image.device == device) slot.ambiguous = true;
    }
    void QuarantineUnobservedSubmit(uint64_t device, const Batch* batches, std::size_t count) {
        // The driver accepted a submit, but the observer cannot model all of
        // its effects. Keeping pre-call tokens would let a consumed binary acquire semaphore prove a later submission.
        // Invalidate this device's
        // current proof graph, then tombstone every visible wait/signal handle
        // so a later handle reuse cannot revive it. The runtime must stay
        // fail-closed until fresh, independently observed acquisitions arrive.
        QuarantineDeviceEvidence(device);
        if (!batches || count > MaxSubmitBatches) return;
        for (std::size_t b = 0; b < count; ++b) {
            const auto& batch = batches[b];
            if (batch.waitCount > MaxBatchSemaphores || batch.signalCount > MaxBatchSemaphores ||
                (batch.waitCount && !batch.waits) || (batch.signalCount && !batch.signals)) return;
            auto quarantine = [&](uint64_t semaphore) {
                if (!semaphore) return;
                if (auto* state = FindSemaphore(device, semaphore, true)) {
                    state->tokens.fill(0);
                    state->count = 0;
                    state->ambiguous = true;
                }
                if (auto* terminal = FindTerminal(device, semaphore, false)) {
                    terminal->owners.fill({});
                    terminal->ownerCount = 0;
                    terminal->active = false;
                    terminal->ambiguous = true;
                }
            };
            for (std::size_t i = 0; i < batch.waitCount; ++i) quarantine(batch.waits[i].semaphore);
            for (std::size_t i = 0; i < batch.signalCount; ++i) quarantine(batch.signals[i].semaphore);
        }
    }
    bool TokenForImage(uint64_t id, Image image) const {
        const auto* token = FindToken(id);
        return token && token->image == image;
    }
    void ConsumePresentedImage(Image image, const PresentWait* waits, std::size_t waitCount,
                               const PresentItem* items, std::size_t itemCount) {
        for (auto& token : tokens_) if (token.active && token.image == image) {
            for (auto& state : semaphores_) {
                bool linked = false;
                for (std::size_t i = 0; i < state.count; ++i) linked |= state.tokens[i] == token.id;
                if (!linked) continue;
                bool consumedByPresent = false;
                for (std::size_t w = 0; w < waitCount; ++w)
                    consumedByPresent |= waits[w].semaphore == state.handle;
                bool terminalWait = false;
                for (std::size_t i = 0; i < itemCount; ++i)
                    terminalWait |= items[i].terminalSemaphore == state.handle;
                state.tokens.fill(0);
                state.count = 0;
                // Waiting this semaphore consumes its binary signal. Aliased
                // proofs left behind on any other semaphore are no longer
                // reusable evidence and are quarantined instead.
                if (!consumedByPresent || !terminalWait) state.ambiguous = true;
            }
            token = {};
        }
    }
    static bool Accepted(Result result) { return result == Result::Success || result == Result::Suboptimal; }
    static bool ValidBatch(const Batch& batch) {
        if (!batch.queue || batch.unsupportedPNext || batch.deviceGroup ||
            batch.waitCount > MaxBatchSemaphores || batch.signalCount > MaxBatchSemaphores ||
            batch.hostReadyImageCount > MaxTokens ||
            (batch.waitCount && !batch.waits) || (batch.signalCount && !batch.signals)) return false;
        if (batch.hostReadyImageCount && !batch.hostReadyImages) return false;
        for (std::size_t i = 0; i < batch.waitCount; ++i)
            if (!batch.waits[i].semaphore || !batch.waits[i].binary) return false;
        for (std::size_t i = 0; i < batch.signalCount; ++i)
            if (!batch.signals[i].semaphore || !batch.signals[i].binary) return false;
        return true;
    }
    static bool FullDependency(const Batch& batch) {
        for (std::size_t i = 0; i < batch.waitCount; ++i)
            if ((batch.waits[i].stageMask & AllCommandsStage) == 0) return false;
        if (batch.api == Api::Synchronization2)
            for (std::size_t i = 0; i < batch.signalCount; ++i)
                if ((batch.signals[i].stageMask & AllCommandsStage) == 0) return false;
        return true;
    }
    static bool SignalDependencyFull(const Batch& batch) {
        if (batch.api == Api::Synchronization2)
            for (std::size_t i = 0; i < batch.signalCount; ++i)
                if ((batch.signals[i].stageMask & AllCommandsStage) == 0) return false;
        return true;
    }
    bool AddToken(SemaphoreState& state, uint64_t id) {
        if (state.ambiguous) return false;
        for (std::size_t i = 0; i < state.count; ++i) if (state.tokens[i] == id) return true;
        if (state.count == state.tokens.size()) {
            state.tokens.fill(0); state.count = 0; state.ambiguous = true;
            return false;
        }
        state.tokens[state.count++] = id;
        return true;
    }
public:
    // The semaphore and fence may both be supplied by the caller. A token is
    // created only for an image actually returned by a successful acquire.
    uint64_t RecordAcquire(Image image, Result result, uint64_t semaphore, uint64_t fence) {
        if (!Accepted(result)) return 0;
        if (!image.Valid() || (!semaphore && !fence)) return 0;
        if (const auto* imageTerminal = FindImageTerminal(image); imageTerminal && imageTerminal->ambiguous) return 0;
        for (const auto& token : tokens_)
            if (token.active && token.image == image) return 0;
        Token* slot = nullptr;
        for (auto& token : tokens_) if (!token.active) { slot = &token; break; }
        if (!slot) return 0;
        if (semaphore) {
            if (auto* terminal = FindTerminal(image.device, semaphore, false);
                terminal && (terminal->active || terminal->ambiguous)) return 0;
            auto* state = FindSemaphore(image.device, semaphore, true);
            if (!state) return 0;
            if (state->ambiguous || state->count) {
                state->tokens.fill(0); state->count = 0; state->ambiguous = true;
                return 0;
            }
        }
        if (fence) {
            for (const auto& token : tokens_)
                if (token.active && token.image.device == image.device && token.fence == fence)
                    return 0;
        }
        auto id = nextToken_++;
        if (!id) id = nextToken_++;
        *slot = Token{id, image, fence, false, true};
        if (semaphore) AddToken(*FindSemaphore(image.device, semaphore, false), id);
        return id;
    }

    // A successful acquire with semantics the observer cannot translate may
    // have consumed or signaled synchronization objects invisibly. Discard the
    // device proof graph and tombstone its visible handles before continuing.
    StateResult ObserveUnmodelledAcquire(uint64_t device, Result result,
                                         uint64_t semaphore, uint64_t fence) {
        if (!Accepted(result)) return StateResult::IgnoredResult;
        if (!device) return StateResult::InvalidIdentity;
        QuarantineDeviceEvidence(device);
        QuarantineSemaphore(device, semaphore);
        if (fence) {
            for (auto& token : tokens_)
                if (token.active && token.image.device == device && token.fence == fence) token = {};
        }
        return StateResult::InvalidIdentity;
    }

    // Call once per fence whose status was individually observed as signaled.
    // A waitAll=false result must never be fanned out to every fence in the set.
    StateResult ObserveFence(uint64_t device, uint64_t fence, Result result) {
        if (result != Result::Success) return StateResult::IgnoredResult;
        if (!device || !fence) return StateResult::InvalidIdentity;
        bool found = false;
        for (auto& token : tokens_) if (token.active && token.image.device == device && token.fence == fence) {
            token.fenceObserved = true;
            found = true;
        }
        return found ? StateResult::Recorded : StateResult::IgnoredResult;
    }

    // Reset before an observed signal invalidates the acquire association.
    // Once signal completion was observed, the proof is an event and survives
    // a later reset; the fence handle itself is then detached from that token.
    void ObserveFenceReset(uint64_t device, uint64_t fence, Result result) {
        if (result != Result::Success) return;
        for (auto& token : tokens_) if (token.active && token.image.device == device && token.fence == fence) {
            if (!token.fenceObserved) {
                for (auto& state : semaphores_) {
                    bool linked = false;
                    for (std::size_t i = 0; i < state.count; ++i) linked |= state.tokens[i] == token.id;
                    if (linked) { state.tokens.fill(0); state.count = 0; state.ambiguous = true; }
                }
                token.active = false;
            }
            token.fence = 0;
        }
    }

    // Observe one successful original queue-submit call. Batches remain
    // separate and are processed in array order. Failure is atomic: it creates
    // no dependency edges. Same-queue submission order alone creates no token.
    StateResult ObserveSubmit(uint64_t device, Result result, const Batch* batches, std::size_t count) {
        // VkQueueSubmit and VkQueueSubmit2 only publish work on VK_SUCCESS.
        // VkSuboptimalKHR is a swapchain-acquire/present status, never a
        // successful queue-submit status for dependency propagation.
        if (result != Result::Success) return StateResult::IgnoredResult;
        if (!device) return StateResult::InvalidIdentity;
        if ((count && !batches) || count > MaxSubmitBatches) {
            QuarantineUnobservedSubmit(device, batches, count);
            return StateResult::InvalidIdentity;
        }
        for (std::size_t b = 0; b < count; ++b) {
            if (!ValidBatch(batches[b])) {
                QuarantineUnobservedSubmit(device, batches, count);
                return StateResult::InvalidIdentity;
            }
            const auto& batch = batches[b];
            for (std::size_t i = 0; i < batch.waitCount; ++i) {
                for (std::size_t j = i + 1; j < batch.waitCount; ++j)
                    if (batch.waits[i].semaphore == batch.waits[j].semaphore) {
                        QuarantineUnobservedSubmit(device, batches, count);
                        return StateResult::Ambiguous;
                    }
                for (std::size_t j = 0; j < batch.signalCount; ++j)
                    if (batch.waits[i].semaphore == batch.signals[j].semaphore) {
                        QuarantineUnobservedSubmit(device, batches, count);
                        return StateResult::Ambiguous;
                    }
            }
            for (std::size_t i = 0; i < batch.signalCount; ++i)
                for (std::size_t j = i + 1; j < batch.signalCount; ++j)
                    if (batch.signals[i].semaphore == batch.signals[j].semaphore) {
                        QuarantineUnobservedSubmit(device, batches, count);
                        return StateResult::Ambiguous;
                    }
        }

        // Work on a copy so capacity or malformed-state failures never leave
        // partially published edges from a multi-batch call.
        auto next = *this;
        bool observedAmbiguity = false;
        for (std::size_t b = 0; b < count; ++b) {
            const auto& batch = batches[b];
            std::array<uint64_t, MaxTokensPerSemaphore * MaxBatchSemaphores> carried{};
            std::size_t carriedCount = 0;
            for (std::size_t i = 0; i < batch.waitCount; ++i) {
                auto* state = next.FindSemaphore(device, batch.waits[i].semaphore, false);
                if (!state) continue;
                if (state->ambiguous) continue;
                for (std::size_t t = 0; t < state->count; ++t) {
                    const uint64_t id = state->tokens[t];
                    bool duplicate = false;
                    for (std::size_t c = 0; c < carriedCount; ++c) duplicate |= carried[c] == id;
                    if (!duplicate && carriedCount < carried.size()) carried[carriedCount++] = id;
                }
                // An accepted binary wait consumes the known signal, even when
                // its stage mask is too narrow to propagate a safe proof.
                state->tokens.fill(0); state->count = 0;
            }
            for (std::size_t i = 0; i < batch.signalCount; ++i) {
                const auto signal = batch.signals[i].semaphore;
                auto* state = next.FindSemaphore(device, signal, true);
                if (!state) {
                    QuarantineUnobservedSubmit(device, batches, count);
                    return StateResult::Capacity;
                }
                auto* terminal = next.FindTerminal(device, signal, false);
                if (state->ambiguous || (terminal && terminal->ambiguous)) continue;
                std::array<uint64_t, MaxTokensPerSemaphore * MaxBatchSemaphores> signalCarried = carried;
                std::size_t signalCarriedCount = carriedCount;
                for (std::size_t h = 0; h < batch.hostReadyImageCount; ++h) {
                    for (const auto& token : next.tokens_) {
                        if (!token.active || !token.fenceObserved || !(token.image == batch.hostReadyImages[h])) continue;
                        bool duplicate = false;
                        for (std::size_t c = 0; c < signalCarriedCount; ++c)
                            duplicate |= signalCarried[c] == token.id;
                        if (!duplicate && signalCarriedCount < signalCarried.size())
                            signalCarried[signalCarriedCount++] = token.id;
                    }
                }
                bool terminalSafe = true;
                if (terminal && terminal->active) {
                    for (std::size_t owner = 0; owner < terminal->ownerCount; ++owner) {
                        const Image image = terminal->owners[owner];
                        bool proved = false;
                        for (std::size_t c = 0; c < signalCarriedCount; ++c)
                            proved |= next.TokenForImage(signalCarried[c], image);
                        if (!proved) {
                            for (const auto& token : next.tokens_) {
                                if (!token.active || !(token.image == image) || !token.fenceObserved) continue;
                                bool duplicate = false;
                                for (std::size_t c = 0; c < signalCarriedCount; ++c)
                                    duplicate |= signalCarried[c] == token.id;
                                if (!duplicate && signalCarriedCount < signalCarried.size())
                                    signalCarried[signalCarriedCount++] = token.id;
                                proved = true;
                                break;
                            }
                        }
                        terminalSafe &= proved;
                    }
                    const bool dependenciesCoverSignal = carriedCount
                        ? FullDependency(batch)
                        : SignalDependencyFull(batch);
                    terminalSafe &= terminal->ownerCount != 0 && dependenciesCoverSignal && state->count == 0;
                    if (!terminalSafe) {
                        terminal->owners.fill(Image{});
                        terminal->ownerCount = 0;
                        terminal->active = false;
                        terminal->ambiguous = true;
                        state->tokens.fill(0);
                        state->count = 0;
                        state->ambiguous = true;
                        observedAmbiguity = true;
                        continue;
                    }
                    terminal->owners.fill(Image{});
                    terminal->ownerCount = 0;
                    terminal->active = false;
                }
                if (!signalCarriedCount || !(carriedCount ? FullDependency(batch) : SignalDependencyFull(batch))) continue;
                if (state->count) {
                    // A binary semaphore already carrying an unconsumed token
                    // cannot be overwritten or assigned a second signal.
                    state->tokens.fill(0); state->count = 0; state->ambiguous = true;
                    continue;
                }
                for (std::size_t t = 0; t < signalCarriedCount; ++t) {
                    if (!next.FindToken(signalCarried[t])) continue;
                    if (!next.AddToken(*state, signalCarried[t])) break;
                }
            }
        }
        *this = next;
        return observedAmbiguity ? StateResult::Ambiguous : StateResult::Recorded;
    }

    // Model one vkQueuePresentKHR call without changing its complete wait list.
    // A terminal semaphore is associated with every image in the successful
    // present batch, so a shared/multi-swapchain wait cannot be recycled until
    // all those exact images have been reacquired and proven through a relay.
    StateResult ObservePresent(uint64_t device, Result globalResult,
                               const PresentItem* items, std::size_t itemCount,
                               const PresentWait* waits, std::size_t waitCount,
                               bool perResultsKnown, bool unsupportedPNext = false,
                               bool deviceGroup = false) {
        if (!device) return StateResult::InvalidIdentity;
        auto next = *this;
        auto quarantineCandidates = [&]() {
            for (std::size_t w = 0; waits && w < waitCount && w < MaxBatchSemaphores; ++w) {
                const auto semaphore = waits[w].semaphore;
                bool candidate = next.FindTerminal(device, semaphore, false) != nullptr;
                if (const auto* state = next.FindSemaphore(device, semaphore)) candidate |= state->count != 0 || state->ambiguous;
                for (std::size_t i = 0; items && i < itemCount && i < MaxPresentImages; ++i)
                    candidate |= items[i].terminalSemaphore == semaphore;
                if (candidate) next.QuarantineSemaphore(device, semaphore);
            }
            for (std::size_t i = 0; items && i < itemCount && i < MaxPresentImages; ++i)
                next.QuarantineImage(items[i].image);
            *this = next;
        };
        if ((items == nullptr) || itemCount == 0 || itemCount > MaxPresentImages ||
            waitCount > MaxBatchSemaphores || (waitCount && !waits) ||
            unsupportedPNext || deviceGroup) {
            quarantineCandidates();
            return StateResult::InvalidIdentity;
        }
        if (!Accepted(globalResult)) {
            quarantineCandidates();
            return StateResult::IgnoredResult;
        }
        if (perResultsKnown)
            for (std::size_t i = 0; i < itemCount; ++i)
                if (!Accepted(items[i].result)) {
                    quarantineCandidates();
                    return StateResult::Ambiguous;
                }

        auto hasWait = [&](uint64_t semaphore) {
            for (std::size_t i = 0; i < waitCount; ++i)
                if (waits[i].semaphore == semaphore && waits[i].binary) return true;
            return false;
        };
        for (std::size_t i = 0; i < itemCount; ++i) {
            const auto& item = items[i];
            if (!item.image.Valid() || item.image.device != device || !item.terminalSemaphore ||
                !hasWait(item.terminalSemaphore) ||
                !next.HasSemaphoreDependency(item.image, item.terminalSemaphore)) {
                quarantineCandidates();
                return StateResult::InvalidIdentity;
            }
            for (std::size_t j = i + 1; j < itemCount; ++j)
                if (item.image.swapchain == items[j].image.swapchain) {
                    quarantineCandidates();
                    return StateResult::Ambiguous;
                }
            auto* slot = next.FindImageTerminal(item.image, false);
            if (slot && (slot->ambiguous || (slot->semaphore && slot->semaphore != item.terminalSemaphore))) {
                quarantineCandidates();
                return StateResult::Ambiguous;
            }
        }
        for (std::size_t i = 0; i < waitCount; ++i) {
            if (!waits[i].semaphore || !waits[i].binary) {
                quarantineCandidates();
                return StateResult::InvalidIdentity;
            }
            for (std::size_t j = i + 1; j < waitCount; ++j)
                if (waits[i].semaphore == waits[j].semaphore) {
                    quarantineCandidates();
                    return StateResult::Ambiguous;
                }
            const auto* state = next.FindSemaphore(device, waits[i].semaphore);
            if (!state) continue;
            if (state->ambiguous) {
                quarantineCandidates();
                return StateResult::Ambiguous;
            }
            for (std::size_t t = 0; t < state->count; ++t) {
                const auto* token = next.FindToken(state->tokens[t]);
                if (!token) continue;
                bool matched = false;
                for (std::size_t p = 0; p < itemCount; ++p)
                    matched |= items[p].image == token->image;
                if (!matched) {
                    quarantineCandidates();
                    return StateResult::Ambiguous;
                }
            }
        }
        for (std::size_t i = 0; i < itemCount; ++i) {
            const auto semaphore = items[i].terminalSemaphore;
            bool first = true;
            for (std::size_t j = 0; j < i; ++j) first &= items[j].terminalSemaphore != semaphore;
            if (!first) continue;
            auto* terminal = next.FindTerminal(device, semaphore, true);
            if (!terminal) {
                quarantineCandidates();
                return StateResult::Capacity;
            }
            if (terminal->active || terminal->ambiguous) {
                quarantineCandidates();
                return StateResult::Ambiguous;
            }
            terminal->owners.fill(Image{});
            terminal->ownerCount = itemCount;
            terminal->active = true;
            for (std::size_t p = 0; p < itemCount; ++p) terminal->owners[p] = items[p].image;
        }
        for (std::size_t i = 0; i < itemCount; ++i) {
            auto* slot = next.FindImageTerminal(items[i].image, true);
            if (!slot) {
                quarantineCandidates();
                return StateResult::Capacity;
            }
            if (slot->ambiguous || (slot->semaphore && slot->semaphore != items[i].terminalSemaphore)) {
                quarantineCandidates();
                return StateResult::Ambiguous;
            }
            slot->semaphore = items[i].terminalSemaphore;
        }
        // Every original present wait is consumed by the accepted operation.
        // Only tracked acquire tokens have image/terminal owners; unrelated
        // binary waits remain opaque but are never removed from the API call.
        for (std::size_t i = 0; i < waitCount; ++i)
            if (auto* state = next.FindSemaphore(device, waits[i].semaphore, false)) {
                state->tokens.fill(0);
                state->count = 0;
            }
        for (std::size_t i = 0; i < itemCount; ++i)
            next.ConsumePresentedImage(items[i].image, waits, waitCount, items, itemCount);
        *this = next;
        return StateResult::Recorded;
    }

    bool HasSemaphoreDependency(Image image, uint64_t semaphore) const {
        if (!image.Valid() || !semaphore) return false;
        const auto* state = FindSemaphore(image.device, semaphore);
        if (!state || state->ambiguous) return false;
        for (std::size_t i = 0; i < state->count; ++i) {
            const auto* token = FindToken(state->tokens[i]);
            if (token && token->image == image) return true;
        }
        return false;
    }
    bool HasObservedFenceProof(Image image) const {
        for (const auto& token : tokens_)
            if (token.active && token.image == image && token.fenceObserved) return true;
        return false;
    }
    void Retire(Image image) {
        for (auto& slot : imageTerminals_) if (slot.active && slot.image == image) {
            slot.ambiguous = true;
            if (slot.semaphore) {
                if (auto* state = FindSemaphore(image.device, slot.semaphore, false)) {
                    state->tokens.fill(0); state->count = 0; state->ambiguous = true;
                }
                if (auto* terminal = FindTerminal(image.device, slot.semaphore, false)) {
                    terminal->owners.fill(Image{}); terminal->ownerCount = 0;
                    terminal->active = false; terminal->ambiguous = true;
                }
            }
        }
        for (auto& terminal : terminals_) if (terminal.active && terminal.device == image.device) {
            bool ownsImage = false;
            for (std::size_t i = 0; i < terminal.ownerCount; ++i) ownsImage |= terminal.owners[i] == image;
            if (ownsImage) {
                terminal.owners.fill(Image{}); terminal.ownerCount = 0;
                terminal.active = false; terminal.ambiguous = true;
                if (auto* state = FindSemaphore(image.device, terminal.semaphore, false)) {
                    state->tokens.fill(0); state->count = 0; state->ambiguous = true;
                }
            }
        }
        for (auto& token : tokens_) if (token.active && token.image == image) {
            // Retirement is not proof that a queued signal or presentation
            // wait completed. Quarantine every semaphore still carrying this
            // generation's token until device teardown establishes ownership
            // has ended; never make the handle look reusable by forgetting it.
            for (auto& state : semaphores_) {
                bool linked = false;
                for (std::size_t i = 0; i < state.count; ++i) linked |= state.tokens[i] == token.id;
                if (linked) { state.tokens.fill(0); state.count = 0; state.ambiguous = true; }
            }
            token = {};
        }
    }
    void RetireGeneration(uint64_t device, uint64_t swapchain, uint64_t generation) {
        if (!device || !swapchain || !generation) return;
        for (auto& token : tokens_)
            if (token.active && token.image.device == device && token.image.swapchain == swapchain &&
                token.image.generation == generation)
                Retire(token.image);
        for (auto& slot : imageTerminals_)
            if (slot.active && slot.image.device == device && slot.image.swapchain == swapchain &&
                slot.image.generation == generation)
                Retire(slot.image);
        for (auto& terminal : terminals_) if (terminal.active && terminal.device == device) {
            for (std::size_t i = 0; i < terminal.ownerCount; ++i)
                if (terminal.owners[i].swapchain == swapchain && terminal.owners[i].generation == generation) {
                    Retire(terminal.owners[i]);
                    break;
                }
        }
    }
    void EraseDevice(uint64_t device) {
        if (!device) return;
        for (auto& token : tokens_) if (token.active && token.image.device == device) token = {};
        for (auto& state : semaphores_) if (state.device == device) state = {};
        for (auto& state : terminals_) if (state.device == device) state = {};
        for (auto& state : imageTerminals_) if (state.active && state.image.device == device) state = {};
    }
};
}
