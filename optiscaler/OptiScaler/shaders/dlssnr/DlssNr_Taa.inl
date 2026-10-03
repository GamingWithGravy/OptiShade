// Included inside DlssNr. Experimental synchronous SDR route from our ReShade runtime.
namespace Taa {
using Microsoft::WRL::ComPtr;
ComPtr<ID3D12Device> device;
ComPtr<ID3D12CommandAllocator> allocator;
ComPtr<ID3D12GraphicsCommandList> commands;
ComPtr<ID3D12Fence> fence;
ComPtr<ID3D12Resource> borrowedColor, borrowedDepth, borrowedMotion;
uint64_t epoch = 0, fenceValue = 0;
ULONGLONG lastCall = 0, lastRun = 0;
bool poisoned = false;
std::string status = "TAA compatibility uses the built-in estimated-guide provider. Use SDR and disable frame generation.";
optishade::nr_admission::Reasons statusReasons, contractReasons;
uint64_t callerQueueIdentity=0;
uint64_t producerRuntime=0,producerGeneration=0;
void Say(const char* value) {
    status=value;uint64_t suppressed=0;
    if(statusReasons.Permit(optishade::nr_admission::ReasonKey(value),callerQueueIdentity,0,GetTickCount64(),suppressed))
        LOG_INFO("TAA NR: {}; queue={:X}; repeated={}",value,callerQueueIdentity,suppressed);
}
bool Wait(ID3D12CommandQueue* queue) {
    if (FAILED(queue->Signal(fence.Get(), ++fenceValue))) return false;
    if (fence->GetCompletedValue() >= fenceValue)
        return fence->GetCompletedValue() != UINT64_MAX;
    // Wake on completion rather than adding Sleep(1) scheduling delay to each barrier.
    struct CompletionEvent {
        HANDLE handle = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        ~CompletionEvent() { if (handle) CloseHandle(handle); }
    };
    static thread_local CompletionEvent completion;
    if (!completion.handle || FAILED(fence->SetEventOnCompletion(fenceValue, completion.handle))) return false;
    const auto start = GetTickCount64();
    for (;;) {
        const DWORD result = WaitForSingleObject(completion.handle, 100);
        const auto completed = fence->GetCompletedValue();
        if (completed == UINT64_MAX || FAILED(device->GetDeviceRemovedReason())) return false;
        if (completed >= fenceValue) return true;
        if (result == WAIT_FAILED || GetTickCount64() - start >= 5000) return false;
    }
}
void Submit(const ostaa::Frame* input) {
    std::lock_guard<std::recursive_mutex> guard(g_nrMutex);
    const auto& cfg = *Config::Instance();
    if (!cfg.DlssNrEnabled.value_or_default() || !cfg.DlssNrTaaFallback.value_or_default()) return;
    const auto now = GetTickCount64();
    if (poisoned) { Say("Graphics submission failed. Restart MSFS before retrying TAA NR."); return; }
    if (!input || input->version != ostaa::Version || input->size != sizeof(ostaa::Frame)) { Say("TAA bridge version mismatch. Repair OptiShade."); return; }
    // Old generations and unowned helper callbacks cannot refresh the owner's
    // activity/status or reuse its temporal history after a resize/recreation.
    if (!input->runtime || !input->queue || !input->generation || input->generation < producerGeneration) return;
    if (input->generation == producerGeneration && producerRuntime && input->runtime != producerRuntime) return;
    const bool changed=input->runtime!=producerRuntime || input->generation!=producerGeneration;
    const bool gap = changed || !lastCall || now - lastCall > 500;
    if(changed){lastRun=0;producerRuntime=input->runtime;producerGeneration=input->generation;}
    lastCall = now;
    callerQueueIdentity=reinterpret_cast<uintptr_t>(input->queue);
    if (State::Instance().currentFG && State::Instance().currentFG->IsActive() && !State::Instance().currentFG->IsPaused()) { Say("Disable frame generation before testing TAA NR."); return; }
    if (!input->providerReady || !input->queue || !input->color || !input->depth || !input->motion) { Say(input->reason?input->reason:"Waiting for built-in guides, valid scene depth and an SDR D3D12 frame."); return; }
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
        return;
    }
    ComPtr<ID3D12Device> current;
    if (FAILED(queue->GetDevice(IID_PPV_ARGS(&current))) || queue->GetDesc().Type != D3D12_COMMAND_LIST_TYPE_DIRECT) {Say("TAA requires an available direct command queue.");return;}
    const auto queueIdentity = optishade::ReShadeDeviceIdentity(current.Get());
    if (!queueIdentity) { Say("TAA queue identity unavailable."); return; }
    if(g_nativeNrInputs.recent(reinterpret_cast<uint64_t>(queueIdentity.Get()),static_cast<unsigned>(c.Width),c.Height,now)){Say("Matching native upscaler inputs detected; TAA compatibility is standing aside.");return;}
    for (auto* resource : {color, depth, motion}) {
        ComPtr<ID3D12Device> owner;
        if (FAILED(resource->GetDevice(IID_PPV_ARGS(&owner))) || optishade::ReShadeDeviceIdentity(owner.Get()) != queueIdentity) { Say("TAA resources belong to different devices."); return; }
    }
    // Keep ReShade's device wrapper for descriptor creation and command recording.
    if (FAILED(color->GetDevice(IID_PPV_ARGS(&current)))) {Say("TAA colour device is unavailable.");return;}
    if (device && optishade::ReShadeDeviceIdentity(device.Get()) != queueIdentity) { Say("Graphics device changed. Restart MSFS before retrying TAA NR."); return; }
    device = current;
    if (!fence && FAILED(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)))) {Say("TAA completion fence creation failed.");return;}
    const auto waitStart = std::chrono::steady_clock::now();
    // Drain preceding ReShade/game work before touching the shared NR scratch set.
    if (!Wait(queue)) { poisoned = true; Say("TAA GPU synchronization failed."); return; }
    if (!allocator && FAILED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)))) {Say("TAA command allocator creation failed.");return;}
    if (!commands) {
        if (FAILED(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr, IID_PPV_ARGS(&commands)))) {Say("TAA command list creation failed.");return;}
        commands->Close();
    }
    if (FAILED(allocator->Reset()) || FAILED(commands->Reset(allocator.Get(), nullptr))) { poisoned = true;Say("TAA command reset failed. Restart MSFS.");return; }
    borrowedColor = color; borrowedDepth = depth; borrowedMotion = motion;
    auto* cmd = commands.Get();
    const auto shaderRead = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    Barrier(cmd, depth, shaderRead, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Barrier(cmd, motion, shaderRead, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    if (!g_compose) g_compose = std::make_unique<DlssNr_Dx12>("TAA neural rendering", device.Get());
    DlssNrFrameInfo frame {};
    frame.FinishedPicture = true; frame.IndependentCommands = true;
    frame.EstimatedTaaGuides = true;
    frame.ObservationOwner=input->runtime;frame.ObservationGeneration=input->generation;
    frame.OutputArrivalState = D3D12_RESOURCE_STATE_RENDER_TARGET;
    frame.ColourIsLinearHdr = false; frame.DepthInverted = input->reversedDepth != 0;
    frame.MvScaleX = static_cast<float>(c.Width); frame.MvScaleY = static_cast<float>(c.Height);
    frame.OutputWidth = static_cast<unsigned>(c.Width); frame.OutputHeight = c.Height;
    frame.RenderSubrectWidth = frame.OutputWidth; frame.RenderSubrectHeight = frame.OutputHeight;
    frame.Reset = gap || !lastRun || now - lastRun > 500;
    frame.SubmissionEpoch = ++epoch;
    const auto work = optishade::taa::TaaWorkingExtent(c.Width, c.Height);
    uint64_t suppressed = 0;
    const uint64_t extentKey = (c.Width << 32) | c.Height;
    if (contractReasons.Permit(optishade::nr_admission::ReasonKey("accepted working extent"), extentKey,
                               callerQueueIdentity, now, suppressed))
        LOG_INFO("TAA NR contract: native={}x{} working={}x{} depth={}x{} motion={}x{}; one pass; model motion scale={}x{}; matched residual={}; repeated={}",
                 c.Width, c.Height, work.width, work.height, d.Width, d.Height, m.Width, m.Height,
                 work.width, work.height, work.reduced(static_cast<unsigned>(c.Width), c.Height), suppressed);
    DlssNrNative::SetPrecision(cfg.DlssNrPrecision.value_or_default());
    const auto before = g_nr.successfulDispatches;
    g_compose->Dispatch(cmd, color, depth, motion, color, frame, queue);
    Barrier(cmd, motion, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, shaderRead);
    Barrier(cmd, depth, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, shaderRead);
    if (FAILED(cmd->Close())) { poisoned = true; Say("TAA command recording failed. Restart MSFS."); return; }
    // ReShade exposes the native queue but CreateCommandList on its device returns
    // a proxy. A native queue must never receive that proxy directly.
    ComPtr<IUnknown> unwrapped;
    ComPtr<ID3D12CommandList> submission;
    if (SUCCEEDED(cmd->QueryInterface(optishade::ReShadeUnwrappedObject,
            reinterpret_cast<void**>(unwrapped.GetAddressOf())))) {
        if (!unwrapped || FAILED(unwrapped.As(&submission))) {
            poisoned = true; Say("TAA native command-list hand-off failed."); return;
        }
    } else if (FAILED(cmd->QueryInterface(IID_PPV_ARGS(&submission)))) {
        poisoned = true; Say("TAA command-list submission interface unavailable."); return;
    }
    ID3D12CommandList* lists[] = {submission.Get()}; queue->ExecuteCommandLists(1, lists);
    FinishedPictureSubmitted(queue,1,lists);
    if (!Wait(queue)) { poisoned = true; Say("TAA GPU work did not finish. Restart MSFS."); return; }
    borrowedColor.Reset(); borrowedDepth.Reset(); borrowedMotion.Reset();
    static ULONGLONG lastTimingLog = 0;
    if (now - lastTimingLog >= 5000) {
        lastTimingLog = now;
        LOG_INFO("TAA NR synchronous frame cost: {:.2f} ms (includes recording and GPU waits)",
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - waitStart).count());
    }
    if (g_nr.successfulDispatches > before) {
        lastRun = now;
        Say(cfg.DlssNrApplyModel.value_or_default()
            ? (work.reduced(static_cast<unsigned>(c.Width), c.Height)
                ? "Windowed/ultrawide TAA NR evaluated and GPU work completed; matched residual at native output size (estimated motion)."
                : "TAA NR submitted and GPU work completed (experimental estimated motion).")
            : "TAA NR completed; model changes are hidden.");
    } else Say(g_nr.failed ? g_nr.reason : "Preparing the TAA neural model; no completed evaluation yet.");
}
}
std::string TaaFallbackStatus() {
    std::lock_guard<std::recursive_mutex> guard(g_nrMutex);
    if (GetTickCount64() - Taa::lastCall > 2000) return "Waiting for the owning renderer and built-in TAA guides. SDR / native D3D12 only.";
    return Taa::status;
}
