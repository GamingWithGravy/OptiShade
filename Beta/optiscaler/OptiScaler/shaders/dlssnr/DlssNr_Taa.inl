// Included inside DlssNr. Experimental synchronous SDR route from our ReShade runtime.
bool NativeTaaFgContractOwnsFallback(uint64_t deviceIdentity, unsigned width, unsigned height);
namespace Taa {
using Microsoft::WRL::ComPtr;
// One private recording per frame in flight. A slot is reused only after its own
// fence value completed, and it keeps the borrowed inputs alive until then.
struct Slot {
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12Resource> color, depth, motion;
    uint64_t value = 0, ticket = 0, queue = 0;
    bool busy = false;
};
// Game-thread time spent inside Submit, reported every 5 s. This is the time NR
// adds to the game's render/main thread, separate from the GPU cost of the model.
struct ThreadCost {
    double totalMs = 0, maxMs = 0, waitMs = 0;
    unsigned frames = 0, waits = 0;
    ULONGLONG since = 0;
};
struct Context {
static constexpr unsigned kSlots = 3;
ComPtr<ID3D12Device> device;
std::array<Slot, kSlots> slots;
ComPtr<ID3D12Fence> fence;
ThreadCost cost;
uint64_t epoch = 0, fenceValue = 0;
ULONGLONG lastCall = 0, lastRun = 0;
bool poisoned = false;
std::string nativeFgStatus;
ULONGLONG nativeFgStatusAt=0;
std::string status = "TAA compatibility requires SDR. With FG enabled, a supported early native-FG frame contract is required.";
optishade::nr_admission::Reasons statusReasons, contractReasons;
uint64_t callerQueueIdentity=0;
uint64_t producerRuntime=0,producerGeneration=0;
void Say(const char* value) {
    status=value;uint64_t suppressed=0;
    if(statusReasons.Permit(optishade::nr_admission::ReasonKey(value),callerQueueIdentity,0,GetTickCount64(),suppressed))
        LOG_INFO("TAA NR: {}; queue={:X}; repeated={}",value,callerQueueIdentity,suppressed);
}
bool Borrowing() const {
    for (const auto& s : slots) if (s.busy || s.color || s.depth || s.motion) return true;
    return false;
}
template<class Function> void ForEachRecording(Function function) {
    for (auto& s : slots) if (s.commands) function(s.commands.Get());
}
// Records GPU completion and drops the borrowed inputs of every finished slot,
// oldest first so the observation tracker sees tickets in submission order.
void Reclaim() {
    if (!fence) return;
    const auto completed = fence->GetCompletedValue();
    if (completed == UINT64_MAX) { poisoned = true; return; }
    for (;;) {
        Slot* oldest = nullptr;
        for (auto& s : slots) if (s.busy && completed >= s.value && (!oldest || s.value < oldest->value)) oldest = &s;
        if (!oldest) return;
        optishade::nr_observation::State().Completed(oldest->ticket, oldest->queue, 0, std::nullopt);
        oldest->color.Reset(); oldest->depth.Reset(); oldest->motion.Reset();
        oldest->busy = false;
    }
}
bool WaitFor(uint64_t value) {
    if (fence->GetCompletedValue() >= value)
        return fence->GetCompletedValue() != UINT64_MAX;
    // Wake on completion rather than adding Sleep(1) scheduling delay to each barrier.
    struct CompletionEvent {
        HANDLE handle = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        ~CompletionEvent() { if (handle) CloseHandle(handle); }
    };
    static thread_local CompletionEvent completion;
    if (!completion.handle || FAILED(fence->SetEventOnCompletion(value, completion.handle))) return false;
    const auto start = GetTickCount64();
    for (;;) {
        const DWORD result = WaitForSingleObject(completion.handle, 100);
        const auto completed = fence->GetCompletedValue();
        if (completed == UINT64_MAX || FAILED(device->GetDeviceRemovedReason())) return false;
        if (completed >= value) return true;
        if (result == WAIT_FAILED || GetTickCount64() - start >= 5000) return false;
    }
}
void RecordCost(std::chrono::steady_clock::time_point started, double waitedMs, bool synchronous) {
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    const auto now = GetTickCount64();
    if (!cost.since) cost.since = now;
    cost.totalMs += ms; cost.maxMs = (std::max)(cost.maxMs, ms); cost.waitMs += waitedMs; ++cost.frames;
    if (waitedMs > 0) ++cost.waits;
    if (now - cost.since < 5000) return;
    LOG_INFO("TAA NR game-thread cost: avg {:.2f} ms, max {:.2f} ms over {} frames; GPU waits {:.2f} ms total on {} frames; mode={} ({} frames in flight)",
        cost.totalMs / cost.frames, cost.maxMs, cost.frames, cost.waitMs, cost.waits,
        synchronous ? "synchronous" : "pipelined", synchronous ? 1u : kSlots);
    cost = {};
    cost.since = now;
}
// synchronous: wait for this frame's GPU work before returning. Required when the
// caller copies the result across APIs (D3D11 bridge) or hands it to a VR compositor.
optishade::nr_submission::Result Submit(const ostaa::Frame* input, bool synchronous = true) {
    optishade::nr_submission::Result result;
    auto guard = g_nrEvents.Lock();
    const auto& cfg = *Config::Instance();
    if (!cfg.DlssNrEnabled.value_or_default()) return result;
    if (!optishade::nr_source::AllowsEstimated(cfg.SourcePolicy())) { Say("Source policy requires validated native temporal inputs; image-estimated guides are not submitted."); return result; }
    const auto now = GetTickCount64();
    if (poisoned) { Say("Graphics submission failed. Restart the game before retrying TAA NR."); return result.Unsafe(); }
    if (!input || input->version != ostaa::Version || input->size != sizeof(ostaa::Frame)) { Say("TAA bridge version mismatch. Repair OptiShade."); return result; }
    result.runtime=input->runtime;result.generation=input->generation;result.view=input->view;
    // Old generations and unowned helper callbacks cannot refresh the owner's
    // activity/status or reuse its temporal history after a resize/recreation.
    if (!input->runtime || !input->queue || !input->generation || input->generation < producerGeneration) return result;
    if (input->generation == producerGeneration && producerRuntime && input->runtime != producerRuntime) return result;
    const bool changed=input->runtime!=producerRuntime || input->generation!=producerGeneration;
    const bool gap = changed || !lastCall || now - lastCall > 500;
    if(changed){lastRun=0;producerRuntime=input->runtime;producerGeneration=input->generation;}
    lastCall = now;
    g_taaRouteUsed.store(true, std::memory_order_relaxed);
    callerQueueIdentity=reinterpret_cast<uintptr_t>(input->queue);
    RefreshUnobservedFgSignature();
    const auto& fgState=State::Instance();
    const bool managedFg=fgState.currentFG && fgState.currentFG->IsActive() && !fgState.currentFG->IsPaused();
    const auto nativeFgSignature=fgState.dlssgTemporalSignature.load(std::memory_order_relaxed);
    bool validatedNativeContract=false;
    if(!input->projection && !managedFg && optishade::taa::NativeCompositionAllowed(nativeFgSignature) &&
       input->queue && input->color){
        ComPtr<ID3D12Device> observedDevice;
        auto* observedQueue=static_cast<ID3D12CommandQueue*>(input->queue);
        auto* observedColor=static_cast<ID3D12Resource*>(input->color);
        if(SUCCEEDED(observedQueue->GetDevice(IID_PPV_ARGS(&observedDevice)))){
            const auto observedIdentity=optishade::ReShadeDeviceIdentity(observedDevice.Get());
            const auto observedExtent=observedColor->GetDesc();
            validatedNativeContract=observedIdentity&&NativeTaaFgContractOwnsFallback(
                reinterpret_cast<uint64_t>(observedIdentity.Get()),static_cast<unsigned>(observedExtent.Width),observedExtent.Height);
        }
    }
    if (!input->projection && optishade::taa::BlocksLateComposition(managedFg,nativeFgSignature,validatedNativeContract)) {
        lastRun=0; // Reset neural history on the first frame after FG is disabled.
        if(nativeFgStatusAt && now-nativeFgStatusAt<=500) Say(nativeFgStatus.c_str());
        else Say("Waiting for PresentStart marker for the current FG frame token. Late NR is not submitted.");
        return result;
    }
    // The game's own DLSS-G can run where OptiScaler's Streamline hooks never see
    // it (NVIDIA-updated plugins), leaving no signature above. Presents here then
    // include generated frames: NR would run on each one at several times its
    // cost and treat generated frames differently from real ones. Pause here;
    // the pre-FG route (DlssNr_TaaNativeFg.inl) takes over once a frame's
    // tagged inputs validate, which sets validatedNativeContract above.
    uint32_t externalMultiplier=0;
    const bool externalGenerating=!input->projection && !managedFg && !validatedNativeContract &&
        optishade::external_fg_status::Session().Generating(&externalMultiplier);
    static bool externalPauseLogged=false;
    if(externalGenerating){
        lastRun=0;
        if(!externalPauseLogged){externalPauseLogged=true;LOG_INFO("TAA NR paused: the game's frame generation is generating ({}x) outside OptiScaler's Streamline hooks; late TAA NR would run on generated frames",externalMultiplier);}
        Say(TaaPreFgObserver()
            ?"Frame generation is on: TAA NR runs before frame generation once the game's frame inputs are confirmed, and is paused until then."
            :"Frame generation is on, but compatible TAA inputs are not validated yet. NR will resume automatically when the frame contract is ready; if it stays paused, temporarily turn off the game's frame generation.");
        return result;
    }
    if(externalPauseLogged){externalPauseLogged=false;LOG_INFO("TAA NR resumed: the game's frame generation is no longer generating");}
    if(!input->projection && !managedFg && optishade::taa::NativeCompositionAllowed(nativeFgSignature) && !validatedNativeContract)
        Say("TAA NR fallback is active until a matching native-FG frame contract is available.");
    if (!input->providerReady || !input->queue || !input->color || !input->depth || !input->motion) { Say(input->reason?input->reason:"Waiting for built-in guides, valid scene depth and an SDR D3D12 frame."); return result; }
    auto* queue = static_cast<ID3D12CommandQueue*>(input->queue);
    auto* color = static_cast<ID3D12Resource*>(input->color);
    auto* depth = static_cast<ID3D12Resource*>(input->depth);
    auto* motion = static_cast<ID3D12Resource*>(input->motion);
    const auto c = color->GetDesc(), d = depth->GetDesc(), m = motion->GetDesc();
    if (const char* reason=optishade::nr_admission::TaaReason(c,d,m)) {
        Say(reason);uint64_t suppressed=0;
        if(contractReasons.Permit(optishade::nr_admission::ReasonKey(reason),callerQueueIdentity,0,now,suppressed)){
            LOG_INFO("TAA NR rejected native output {}x{}: {}; native envelope=3840x2160; bounded desktop envelope=5120x2160; aspect-preserving model extent <=3840x2160; repeated={}",c.Width,c.Height,reason,suppressed);
            const char* names[]={"colour","depth","motion"};unsigned index=0;
            for(auto* resource:{color,depth,motion}){const auto desc=resource->GetDesc();
                LOG_INFO("TAA {} resource={:X}; allocation={}x{} format={} dimension={} mip={} samples={}/{} array={} subresource=0",
                    names[index++],(uintptr_t)resource,desc.Width,desc.Height,(int)desc.Format,(int)desc.Dimension,desc.MipLevels,desc.SampleDesc.Count,desc.SampleDesc.Quality,desc.DepthOrArraySize);
            }
        }
        return result;
    }
    ComPtr<ID3D12Device> current;
    if (FAILED(queue->GetDevice(IID_PPV_ARGS(&current))) || queue->GetDesc().Type != D3D12_COMMAND_LIST_TYPE_DIRECT) {Say("TAA requires an available direct command queue.");return result;}
    const auto queueIdentity = optishade::ReShadeDeviceIdentity(current.Get());
    if (!queueIdentity) { Say("TAA queue identity unavailable."); return result; }
    if(g_nativeNrInputs.recent(reinterpret_cast<uint64_t>(queueIdentity.Get()),static_cast<unsigned>(c.Width),c.Height,now)){Say("Matching native upscaler inputs detected; TAA compatibility is standing aside.");return result;}
    for (auto* resource : {color, depth, motion}) {
        ComPtr<ID3D12Device> owner;
        if (FAILED(resource->GetDevice(IID_PPV_ARGS(&owner))) || optishade::ReShadeDeviceIdentity(owner.Get()) != queueIdentity) { Say("TAA resources belong to different devices."); return result; }
    }
    optishade::route::OutputScope outputScope(optishade::route::OutputKey{reinterpret_cast<uint64_t>(queueIdentity.Get()),input->runtime,input->generation,input->view,1});
    if(!outputScope){Say("NR output capacity reached; existing GPU histories are retained safely.");return result;}
    // Keep ReShade's device wrapper for descriptor creation and command recording.
    if (FAILED(color->GetDevice(IID_PPV_ARGS(&current)))) {Say("TAA colour device is unavailable.");return result;}
    if (device && optishade::ReShadeDeviceIdentity(device.Get()) != queueIdentity) { Say("Graphics device changed. Restart the game before retrying TAA NR."); return result; }
    device = current;
    if (!fence && FAILED(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)))) {Say("TAA completion fence creation failed.");return result;}
    const auto threadStart = std::chrono::steady_clock::now();
    double waitedMs = 0;
    // Each slot owns its allocator and list; same-queue ordering already places
    // our list after the producer's commands and before the game's next frame, so
    // the game thread never drains the GPU here. Never reuse an incomplete list.
    const auto priorCompletion = fence->GetCompletedValue();
    if (priorCompletion == UINT64_MAX || FAILED(device->GetDeviceRemovedReason())) {
        poisoned = true; Say("TAA graphics device is unavailable."); return result.Unsafe();
    }
    Reclaim();
    Slot* slot = nullptr;
    for (auto& s : slots) if (!s.busy) { slot = &s; break; }
    if (!slot) {
        // The GPU is a full ring behind. Wait for the oldest NR frame rather than
        // dropping NR from this one, which would show as flicker.
        Slot* oldest = &slots[0];
        for (auto& s : slots) if (s.value < oldest->value) oldest = &s;
        const auto waitStart = std::chrono::steady_clock::now();
        if (!WaitFor(oldest->value)) { poisoned = true; Say("TAA GPU work did not finish. Restart the game."); return result.Unsafe(); }
        waitedMs += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - waitStart).count();
        Reclaim();
        if (oldest->busy) { poisoned = true; Say("TAA GPU completion could not be confirmed. Restart the game."); return result.Unsafe(); }
        slot = oldest;
    }
    if (!slot->allocator && FAILED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&slot->allocator)))) {Say("TAA command allocator creation failed.");return result;}
    if (!slot->commands) {
        if (FAILED(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, slot->allocator.Get(), nullptr, IID_PPV_ARGS(&slot->commands)))) {Say("TAA command list creation failed.");return result;}
        slot->commands->Close();
    }
    if (FAILED(slot->allocator->Reset()) || FAILED(slot->commands->Reset(slot->allocator.Get(), nullptr))) { poisoned = true;Say("TAA command reset failed. Restart the game.");return result.Unsafe(); }
    optishade::nr_lifetime::Reset(slot->commands.Get());
    slot->color = color; slot->depth = depth; slot->motion = motion;
    auto* cmd = slot->commands.Get();
    const auto shaderRead = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    Barrier(cmd, depth, shaderRead, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Barrier(cmd, motion, shaderRead, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    if (!g_compose) g_compose = std::make_unique<DlssNr_Dx12>("TAA neural rendering", device.Get());
    DlssNrFrameInfo frame {};
    frame.FinishedPicture = true; frame.IndependentCommands = true;
    frame.EstimatedTaaGuides = true;
    frame.ObservationOwner=input->runtime;frame.ObservationGeneration=input->generation;frame.ObservationView=input->view;
    frame.OutputArrivalState = D3D12_RESOURCE_STATE_RENDER_TARGET;
    frame.ColourIsLinearHdr = false; frame.DepthInverted = input->reversedDepth != 0;
    frame.MvScaleX = static_cast<float>(c.Width); frame.MvScaleY = static_cast<float>(c.Height);
    frame.OutputWidth = static_cast<unsigned>(c.Width); frame.OutputHeight = c.Height;
    frame.RenderSubrectWidth = frame.OutputWidth; frame.RenderSubrectHeight = frame.OutputHeight;
    frame.Reset = gap || !lastRun || now - lastRun > 500;
    frame.SubmissionEpoch = ++epoch;
    result.frame=frame.SubmissionEpoch;frame.ObservationTicket=&result.ticket;
    const auto work = optishade::taa::TaaWorkingExtent(c.Width, c.Height);
    uint64_t suppressed = 0;
    const uint64_t extentKey = (c.Width << 32) | c.Height;
    if (contractReasons.Permit(optishade::nr_admission::ReasonKey("accepted working extent"), extentKey,
                               callerQueueIdentity, now, suppressed))
        LOG_INFO("TAA NR contract: native={}x{} working={}x{} depth={}x{} motion={}x{}; one pass; model motion scale={}x{}; matched residual={}; repeated={}",
                 c.Width, c.Height, work.width, work.height, d.Width, d.Height, m.Width, m.Height,
                 work.width, work.height, work.reduced(static_cast<unsigned>(c.Width), c.Height), suppressed);
    DlssNrNative::SetPrecision(cfg.DlssNrPrecision.value_or_default());
    g_compose->Dispatch(cmd, color, depth, motion, color, frame, queue);
    result.modelFailed=g_nr.failed;
    Barrier(cmd, motion, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, shaderRead);
    Barrier(cmd, depth, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, shaderRead);
    if (FAILED(cmd->Close())) { poisoned = true; Say("TAA command recording failed. Restart the game."); return result.Unsafe(); }
    // ReShade exposes the native queue but CreateCommandList on its device returns
    // a proxy. A native queue must never receive that proxy directly.
    ComPtr<IUnknown> unwrapped;
    ComPtr<ID3D12CommandList> submission;
    if (SUCCEEDED(cmd->QueryInterface(optishade::ReShadeUnwrappedObject,
            reinterpret_cast<void**>(unwrapped.GetAddressOf())))) {
        if (!unwrapped || FAILED(unwrapped.As(&submission))) {
            poisoned = true; Say("TAA native command-list hand-off failed."); return result.Unsafe();
        }
    } else if (FAILED(cmd->QueryInterface(IID_PPV_ARGS(&submission)))) {
        poisoned = true; Say("TAA command-list submission interface unavailable."); return result.Unsafe();
    }
    ID3D12CommandList* lists[] = {submission.Get()}; queue->ExecuteCommandLists(1, lists);
    result.submitted=true;const auto submittedAt=GetTickCount64();
    FinishedPictureSubmitted(queue,1,lists);
    // Signal after ExecuteCommandLists: this value covers exactly this slot's list.
    const bool signalled = SUCCEEDED(queue->Signal(fence.Get(), ++fenceValue));
    slot->value = fenceValue; slot->ticket = result.ticket; slot->queue = reinterpret_cast<uint64_t>(queue); slot->busy = true;
    auto& observations=optishade::nr_observation::State();
    observations.Submitted(result.ticket,reinterpret_cast<uint64_t>(queue),submittedAt,signalled);
    if (!signalled) { poisoned = true; Say("TAA completion signal failed. Restart the game."); return result.Unsafe(); }
    if (synchronous) {
        const auto waitStart = std::chrono::steady_clock::now();
        if (!WaitFor(slot->value)) { poisoned = true; Say("TAA GPU work did not finish. Restart the game."); return result.Unsafe(); }
        waitedMs += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - waitStart).count();
        // Reclaim records this exact list's completion before the ticket is read.
        Reclaim();
        result.gpuCompleted = !slot->busy;
    }
    result.Observe(observations.ReadTicket(result.ticket));
    RecordCost(threadStart, waitedMs, synchronous);
    if (result.evaluated && (result.gpuCompleted || !synchronous)) {
        lastRun = now;
        Say(result.composed
            ? (work.reduced(static_cast<unsigned>(c.Width), c.Height)
                ? "Windowed/ultrawide TAA NR evaluated; matched residual at native output size (estimated motion)."
                : "TAA NR submitted (experimental estimated motion).")
            : "TAA NR evaluated; model changes are hidden.");
    } else Say(g_nr.failed ? g_nr.reason : "Preparing the TAA neural model; no completed evaluation yet.");
    return result;
}
};
inline Context& Instance(){return optishade::route::OutputOwned<Context,6>();}
}
void RetireCompletedTaaRecordings(bool resetHistory){
    optishade::route::ForEachOutput([resetHistory]{auto& c=Taa::Instance();
        c.Reclaim();
        if(c.poisoned||c.Borrowing())return;
        if(c.fence&&(c.fence->GetCompletedValue()==UINT64_MAX||c.fence->GetCompletedValue()<c.fenceValue))return;
        // Sole-owner private lists: retirement prevents any replay of this generation.
        bool any=false;c.ForEachRecording([&](ID3D12GraphicsCommandList* list){optishade::nr_lifetime::RetirePrivate(list);any=true;});
        if(any&&resetHistory)c.lastRun=0;
    });
}
bool TaaRouteSeen() {
    auto guard = g_nrEvents.Lock();
    return GetTickCount64() - Taa::Instance().lastCall <= 2000;
}
std::string TaaFallbackStatus() {
    auto guard = g_nrEvents.Lock();
    if (GetTickCount64() - Taa::Instance().lastCall > 2000) return "Waiting for the owning renderer and built-in TAA guides. SDR / D3D12 or same-adapter D3D11 bridge.";
    return Taa::Instance().status;
}


