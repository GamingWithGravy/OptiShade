// Included inside namespace DlssNr. All entry points share the NR event gate.
namespace Late
{
using Microsoft::WRL::ComPtr;
struct Slot
{
    ComPtr<ID3D12Resource> depth, motion, linear, encoded, residual;
    ComPtr<ID3D12Fence> fence;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ID3D12CommandList* producer = nullptr; // identity only; never dereferenced
    DlssNrFrameInfo frame {};
    uint64_t ready = 0, done = 0, serial = 0;
    bool recording = false; // quarantine until recording and submission both succeed
    bool pending = false, submitted = false, residualOnly = false, sceneLinear = true, pairedTaaFg = false;
    D3D12_RESOURCE_STATES residualState = D3D12_RESOURCE_STATE_COPY_DEST;
};
struct Context {
std::array<Slot, 4> slots;
ComPtr<ID3D12Device> device;
uint64_t serial = 0, successes = 0;
std::string status = "Waiting for a finished picture.";
bool reset = true;
std::atomic<bool> tracking { false };
inline static constexpr GUID colorSpaceKey = { 0x34a31e7b, 0x84c5, 0x44ef, { 0xa7, 0x4d, 0x6b, 0xd3, 0x60, 0x8c, 0xe5, 0x22 } };

void Say(const char* message)
{
    if (status != message)
    {
        status = message;
        LOG_INFO("DLSS-NR finished picture: {}", message);
    }
}

bool Finished(const Slot& slot)
{
    return !slot.fence || (slot.fence->GetCompletedValue() != UINT64_MAX &&
                          slot.fence->GetCompletedValue() >= slot.done);
}

void Cancel()
{
    // Submitted copies may still be in flight; their fences still protect reuse.
    for (auto& slot : slots)
        if (slot.submitted)
            slot.pending = false;
    reset = true;
}

bool Clone(ComPtr<ID3D12Resource>& copy, ID3D12Resource* source)
{
    const auto want = source->GetDesc();
    if (want.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D || want.SampleDesc.Count != 1 ||
        want.DepthOrArraySize != 1 || want.MipLevels != 1)
        return false;
    if (copy)
    {
        const auto have = copy->GetDesc();
        if (have.Width != want.Width || have.Height != want.Height ||
            have.Format != TypedGuideFormat(want.Format))
            copy.Reset(); // caller checked the previous GPU fence
    }
    if (!copy)
        copy.Attach(CreateGuideClone(device.Get(), source));
    return copy != nullptr;
}

Slot* Acquire(ID3D12GraphicsCommandList* cmd)
{
    if (!cmd || State::Instance().swapchainInteropApi != SwapchainInteropApi::None)
    { Say("This option needs a native DirectX 12 game."); return nullptr; }
    ComPtr<ID3D12Device> currentDevice;
    if (FAILED(cmd->GetDevice(IID_PPV_ARGS(&currentDevice))))
        return nullptr;
    if (device && device != currentDevice)
    {
        Say("The graphics device changed. Restart the game to use this option.");
        return nullptr;
    }
    device = currentDevice;
    tracking.store(true);
    // Only the lightweight submission hook is needed, including when FG is disabled.
    ResTrack_Dx12::HookLateNrQueue(device.Get());
    Slot* next = nullptr;
    for (auto& slot : slots)
        if (!slot.pending && Finished(slot)) { next = &slot; break; }
    if (!next)
    {
        Say("Waiting for the previous picture to finish.");
        return nullptr;
    }
    auto& slot = *next;
    if (!slot.commands)
    {
        if (FAILED(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&slot.fence))) ||
            FAILED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&slot.allocator))) ||
            FAILED(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, slot.allocator.Get(), nullptr,
                                            IID_PPV_ARGS(&slot.commands))) || FAILED(slot.commands->Close()))
        {
            slot.commands.Reset(); slot.allocator.Reset(); slot.fence.Reset();
            Say("Could not prepare the finished-picture option.");
            return nullptr;
        }
    }
    return next;
}

void Arm(Slot& slot, ID3D12GraphicsCommandList* cmd)
{
    slot.producer = cmd;
    ID3D12GraphicsCommandList* real = nullptr;
    if (Util::CheckForRealObject(__FUNCTION__, cmd, (IUnknown**) &real)) slot.producer = real;
    slot.serial = ++serial;
    slot.ready = slot.done + 1;
    slot.done = slot.ready;
    slot.submitted = false;
    slot.pending = true;
}

void Capture(ID3D12GraphicsCommandList* cmd, NVSDK_NGX_Parameter* params, bool rr)
{
    if (!params) return;
    auto* depth = GetResource(params, NVSDK_NGX_Parameter_Depth, "DLSSD.Depth");
    auto* motion = GetResource(params, NVSDK_NGX_Parameter_MotionVectors, "DLSSD.MotionVectors");
    auto* output = GetResource(params, NVSDK_NGX_Parameter_Output, "DLSSD.Output");
    if (!depth || !motion || !output)
    { Cancel(); Say("Waiting for the game's depth and movement data."); return; }
    auto* next = Acquire(cmd);
    if (!next) return;
    auto& slot = *next;
    if (!Clone(slot.depth, depth) || !Clone(slot.motion, motion))
    { Say("The game's depth or movement data is not supported."); return; }
    slot.residualOnly = false;
    slot.pairedTaaFg = false;
    // Copy at the NGX seam, where guide states and lifetimes are defined. Keep typed,
    // shader-readable copies until both the producing queue and NR have finished.
    for (auto pair : { std::pair { depth, slot.depth.Get() }, std::pair { motion, slot.motion.Get() } })
    {
        Barrier(cmd, pair.first, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_SOURCE);
        cmd->CopyResource(pair.second, pair.first);
        Barrier(cmd, pair.first, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        // The copy returns to COPY_DEST after the late dispatch.
    }
    slot.frame = {};
    auto& frame = slot.frame;
    unsigned flags = 0, gameReset = 0;
    params->Get(NVSDK_NGX_Parameter_DLSS_Feature_Create_Flags, &flags);
    params->Get(NVSDK_NGX_Parameter_Reset, &gameReset);
    frame.Reset = gameReset != 0;
    frame.DepthInverted = (flags & NVSDK_NGX_DLSS_Feature_Flags_DepthInverted) != 0;
    frame.MotionVectorsLowResolution = (flags & NVSDK_NGX_DLSS_Feature_Flags_MVLowRes) != 0;
    frame.RayReconstruction = rr;
    frame.OutputWidth = (unsigned) output->GetDesc().Width;
    frame.OutputHeight = output->GetDesc().Height;
    params->Get(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width, &frame.RenderSubrectWidth);
    params->Get(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, &frame.RenderSubrectHeight);
    params->Get(NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_X, &frame.DepthSubrectBaseX);
    params->Get(NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_Y, &frame.DepthSubrectBaseY);
    params->Get(NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_X, &frame.MotionSubrectBaseX);
    params->Get(NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_Y, &frame.MotionSubrectBaseY);
    params->Get(NVSDK_NGX_Parameter_MV_Scale_X, &frame.MvScaleX);
    params->Get(NVSDK_NGX_Parameter_MV_Scale_Y, &frame.MvScaleY);
    frame.ColourIsLinearHdr = false;
    frame.IndependentCommands = true;
    frame.FinishedPicture = true;
    frame.OutputArrivalState = D3D12_RESOURCE_STATE_PRESENT;
    frame.SubmissionEpoch = State::Instance().frameCount;
    Arm(slot, cmd);
}

bool CaptureResidual(ID3D12GraphicsCommandList* cmd, ID3D12Resource* clean, ID3D12Resource* residual,
                     float scale, bool sceneLinear)
{
    auto* next = Acquire(cmd);
    if (!next) return false;
    auto& slot = *next;
    if (!Clone(slot.residual, residual))
    { Say("The upscaled changes could not be saved."); return false; }
    Barrier(cmd, residual, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    cmd->CopyResource(slot.residual.Get(), residual);
    Barrier(cmd, residual, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    slot.frame = {};
    slot.frame.OutputWidth = (unsigned) clean->GetDesc().Width;
    slot.frame.OutputHeight = clean->GetDesc().Height;
    slot.frame.PreExposure = scale;
    slot.frame.SubmissionEpoch = State::Instance().frameCount;
    slot.residualOnly = true;
    slot.sceneLinear = sceneLinear;
    slot.pairedTaaFg = false;
    slot.residualState = D3D12_RESOURCE_STATE_COPY_DEST;
    Arm(slot, cmd);
    return true;
}

bool HasPairedTaaFgPending()
{
    return std::any_of(slots.begin(), slots.end(),
        [](const Slot& slot) { return slot.pending && slot.submitted && slot.pairedTaaFg; });
}

void CancelPairedTaaFg()
{
    for (auto& slot : slots)
    {
        if (!slot.pairedTaaFg) continue;
        slot.pending = false;
        slot.pairedTaaFg = false;
    }
}

bool CapturePairedTaaFgResidual(ID3D12GraphicsCommandList* cmd,
                                ID3D12Resource* original,
                                ID3D12Resource* edited,
                                D3D12_RESOURCE_STATES editedState,
                                uint64_t submissionEpoch,
                                uintptr_t presentationOwner,
                                uint64_t presentationGeneration)
{
    if (!cmd || !original || !edited || !g_compose) return false;
    auto* next = Acquire(cmd);
    if (!next) return false;
    auto& slot = *next;
    const auto desc = edited->GetDesc();
    if (desc.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D || desc.SampleDesc.Count != 1 ||
        desc.DepthOrArraySize != 1 || desc.MipLevels != 1 || desc.Width > UINT32_MAX)
        return false;

    if (slot.residual)
    {
        const auto have = slot.residual->GetDesc();
        if (have.Width != desc.Width || have.Height != desc.Height ||
            have.Format != DXGI_FORMAT_R16G16B16A16_FLOAT)
            slot.residual.Reset();
    }
    if (!slot.residual)
    {
        slot.residual.Attach(CreateScratch(device.Get(), DXGI_FORMAT_R16G16B16A16_FLOAT,
                                           static_cast<unsigned>(desc.Width), desc.Height));
        slot.residualState = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
    }
    if (!slot.residual) return false;

    if (slot.residualState != D3D12_RESOURCE_STATE_UNORDERED_ACCESS)
        Barrier(cmd, slot.residual.Get(), slot.residualState, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    Barrier(cmd, original, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    if (editedState != D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE)
        Barrier(cmd, edited, editedState, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);

    DlssNrConstants encode {};
    encode.Mode = 5;
    encode.Width = static_cast<unsigned>(desc.Width);
    encode.Height = desc.Height;
    encode.WhitePoint = 1.0f;
    encode.TransferStrength = 0.0f;
    encode.MaxRatio = std::clamp(Config::Instance()->DlssNrMaxRatio.value_or_default(), 1.0f, 8.0f);
    const bool encoded = g_compose->DispatchResidualPass(cmd, encode, original, edited, nullptr, nullptr,
                                                         slot.residual.Get(), true);

    if (editedState != D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE)
        Barrier(cmd, edited, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, editedState);
    Barrier(cmd, original, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    if (!encoded)
    {
        slot.residualState = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
        return false;
    }
    Barrier(cmd, slot.residual.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    slot.residualState = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    slot.frame = {};
    slot.frame.OutputWidth = static_cast<unsigned>(desc.Width);
    slot.frame.OutputHeight = desc.Height;
    slot.frame.PreExposure = 1.0f;
    slot.frame.SubmissionEpoch = submissionEpoch;
    slot.frame.ObservationOwner = presentationOwner;
    slot.frame.ObservationGeneration = presentationGeneration;
    slot.residualOnly = true;
    slot.sceneLinear = false;
    slot.pairedTaaFg = true;
    Arm(slot, cmd);
    return true;
}

};
inline Context& Instance(){return optishade::route::OutputOwned<Context,5>();}
bool CaptureResidual(ID3D12GraphicsCommandList* cmd,ID3D12Resource* clean,ID3D12Resource* residual,float scale,bool linear){return Instance().CaptureResidual(cmd,clean,residual,scale,linear);}
} // namespace Late

void FinishedPictureResetCommandList(ID3D12CommandList* cmd)
{
    optishade::nr_lifetime::Reset(cmd);
    optishade::route::SubmissionRequest recording;recording.event=optishade::route::SubmissionEvent::Reset;recording.command=reinterpret_cast<uint64_t>(cmd);
    optishade::route::SubmissionResult recorded;optishade::route::Submission(recording,recorded);
    if (!cmd) return;
    NrSubmissionEvent event;
    event.commands.emplace_back(cmd);
    g_nrEvents.Post(std::move(event));
}

void FinishedPictureCommandListFailed(ID3D12CommandList* cmd)
{
    if (!cmd) return;
    NrSubmissionEvent event;event.commands.emplace_back(cmd);
    g_nrEvents.Post(std::move(event));
}

bool WaitForFinishedPicture()
{
    auto lock = g_nrEvents.Lock();
    const auto deadline=GetTickCount64()+5000;
    bool ready=true;
    optishade::route::ForEachOutput([&]{
        if(!ready||!Late::Instance().tracking.load())return;
        Late::Instance().Cancel();
        for(auto& slot:Late::Instance().slots){
            if(!slot.submitted||Late::Instance().Finished(slot))continue;
            const auto now=GetTickCount64();if(now>=deadline){ready=false;return;}
            HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr);
            if(!event){ready=false;return;}
            const auto hr=slot.fence->SetEventOnCompletion(slot.done,event);
            ready=SUCCEEDED(hr)&&WaitForSingleObject(event,static_cast<DWORD>(deadline-now))==WAIT_OBJECT_0;
            CloseHandle(event);if(!ready)return;
        }
    });
    return ready;
}

std::string FinishedPictureStatus()
{
    auto lock = g_nrEvents.Lock();
    return Late::Instance().status;
}

bool HasPairedTaaFgPending()
{
    auto lock = g_nrEvents.Lock();
    return Late::Instance().HasPairedTaaFgPending();
}

void FinishedPictureSubmitted(ID3D12CommandQueue* queue, UINT count, ID3D12CommandList* const* lists)
{
    if(queue&&lists&&count<=1024)for(UINT i=0;i<count;++i){
        // ExecuteCommandLists is the authoritative submitted-list boundary,
        // including private native lists whose Close bypasses a wrapper hook.
        optishade::nr_lifetime::Closed(lists[i]);
        optishade::nr_lifetime::Submitted(queue,lists[i]);
    }
    if(lists&&count<=1024){for(UINT i=0;i<count;++i){
        optishade::route::SubmissionRequest r;r.event=optishade::route::SubmissionEvent::Observe;r.queue=reinterpret_cast<uint64_t>(queue);r.command=reinterpret_cast<uint64_t>(lists[i]);optishade::route::SubmissionResult out;optishade::route::Submission(r,out);
    }}

    if (!queue || !lists || !count || count > 1024) return;
    NrSubmissionEvent event;
    event.queue = queue;
    event.observedAt = GetTickCount64();
    event.commands.reserve(count);
    for (UINT i = 0; i < count; ++i) event.commands.emplace_back(lists[i]);
    g_nrEvents.Post(std::move(event));
}

// Called only by the serialized event gate. Drained before recording reuse,
// slot cancellation, inspection and queue waits, and again before leaving NR.
// A delayed Signal conservatively includes subsequent queue work; it must never
// be interpreted as proof that the GPU has already finished.
void ConsumeNrOutputSubmissionEvent(const NrSubmissionEvent& event);
void ConsumeNrSubmissionEvent(const NrSubmissionEvent& event) {
    if(event.frameToken){ConsumeNrFrameNotification(event);return;}
    if(event.commands.empty())return;
    optishade::route::ForEachOutput([&]{ConsumeNrOutputSubmissionEvent(event);});
}
void ConsumeNrOutputSubmissionEvent(const NrSubmissionEvent& event)
{
    if (!event.queue) {
        auto* cmd = event.commands.front().Get();
        if (g_nr.featurePendingSubmission) g_nr.featureCreation.Abandoned(cmd);
        for (unsigned pass=1;pass<DlssNr::MaxPassCount;++pass)
            if (g_nr.passPendingSubmission[pass]) g_nr.passCreation[pass].Abandoned(cmd);
        if (g_gpuTime) g_gpuTime->ResetRecording(cmd);
        if (g_ngxTime) g_ngxTime->ResetRecording(cmd);
        if (!Late::Instance().tracking.load()) return;
        for (auto& slot : Late::Instance().slots)
            if (slot.pending && !slot.submitted && slot.producer == cmd)
            {
                slot.pending = false;
                slot.done = slot.ready - 1; // discarded recording: no GPU signal was promised
                Late::Instance().reset = true;
            }
        return;
    }
    auto* queue = event.queue.Get();
    std::vector<ID3D12CommandList*> commands;
    commands.reserve(event.commands.size());
    for (const auto& command : event.commands) commands.push_back(command.Get());
    auto* lists = commands.data();
    const auto count = static_cast<UINT>(commands.size());
    if (g_nr.featurePendingSubmission) g_nr.featureCreation.Submitted(queue,count,lists);
    for (unsigned pass=1;pass<DlssNr::MaxPassCount;++pass)
        if (g_nr.passPendingSubmission[pass]) g_nr.passCreation[pass].Submitted(queue,count,lists);
    if (g_gpuTime) g_gpuTime->Submitted(queue, count, lists, event.observedAt);
    if (g_ngxTime) g_ngxTime->Submitted(queue, count, lists, event.observedAt);
    if (!Late::Instance().tracking.load()) return;
    for (auto& slot : Late::Instance().slots)
        if (slot.pending && !slot.submitted)
            for (UINT i = 0; i < count; ++i)
                if (lists[i] == slot.producer)
                {
                    // Signal after ExecuteCommandLists, never when merely recording the copy.
                    slot.submitted = true;
                    if (FAILED(queue->Signal(slot.fence.Get(), slot.ready)))
                    {
                        // The copy already executed. Keep its unsignalled fence protecting
                        // the slot instead of treating this as a discarded recording.
                        slot.pending = false;
                        Late::Instance().Say("The graphics queue stopped. Restart the game to retry.");
                    }
                    break;
                }
}

void FinishedPictureColorSpace(IDXGISwapChain* swapchain, DXGI_COLOR_SPACE_TYPE colorSpace)
{
    swapchain->SetPrivateData(Late::Instance().colorSpaceKey, sizeof(colorSpace), &colorSpace);
}

void ApplyOutputToFinishedPicture(IDXGISwapChain* swapchain, ID3D12CommandQueue* queue)
{
    auto lock = g_nrEvents.Lock();
    if (!Config::Instance()->DlssNrEnabled.value_or_default())
    {
        Late::Instance().Cancel();
        return;
    }
    const bool pairedPending = std::any_of(Late::Instance().slots.begin(), Late::Instance().slots.end(),
        [](const Late::Slot& slot) { return slot.pending && slot.submitted && slot.pairedTaaFg; });
    if (!Config::Instance()->DlssNrFinishedPicture.value_or_default() && !pairedPending)
    {
        Late::Instance().Cancel();
        return;
    }
    if (!swapchain || !queue || State::Instance().swapchainInteropApi != SwapchainInteropApi::None)
        return;
    Late::ComPtr<IDXGISwapChain3> sc;
    Late::ComPtr<ID3D12Resource> color;
    Late::ComPtr<ID3D12Device> currentDevice;
    if (FAILED(swapchain->QueryInterface(IID_PPV_ARGS(&sc))) ||
        FAILED(sc->GetBuffer(sc->GetCurrentBackBufferIndex(), IID_PPV_ARGS(&color))) ||
        FAILED(queue->GetDevice(IID_PPV_ARGS(&currentDevice))) || currentDevice != Late::Instance().device)
        return;
    const auto desc = color->GetDesc();
    auto colorSpace = desc.Format == DXGI_FORMAT_R16G16B16A16_FLOAT
        ? DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709 : DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
    UINT colorSpaceSize = sizeof(colorSpace);
    swapchain->GetPrivateData(Late::Instance().colorSpaceKey, &colorSpaceSize, &colorSpace);
    const bool pq = colorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
    const bool scrgb = colorSpace == DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709;
    const bool sdr = colorSpace == DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709;
    if ((!sdr && !pq && !scrgb) ||
        (scrgb && desc.Format != DXGI_FORMAT_R16G16B16A16_FLOAT) ||
        (!scrgb && desc.Format != DXGI_FORMAT_R8G8B8A8_UNORM && desc.Format != DXGI_FORMAT_R10G10B10A2_UNORM))
    {
        Late::Instance().Cancel();
        Late::Instance().Say("This screen colour format is not supported.");
        return;
    }
    Late::Slot* latest = nullptr;
    const auto epoch = State::Instance().frameCount;
    const auto presentationOwner = optishade::taa::SwapchainIdentity(swapchain);
    DXGI_SWAP_CHAIN_DESC ownerDesc{};
    const auto presentationGeneration = presentationOwner && SUCCEEDED(swapchain->GetDesc(&ownerDesc))
        ? MenuOverlayDx::PrimarySwapchainGeneration(ownerDesc.OutputWindow, swapchain) : 0;
    const bool residualOnly = Config::Instance()->DlssNrRunBeforeSr.value_or_default() ||
                              Config::Instance()->DlssNrDeferredDlss.value_or_default();
    for (auto& slot : Late::Instance().slots)
    {
        if (!slot.pending || !slot.submitted)
            continue;
        if (epoch < slot.frame.SubmissionEpoch || epoch - slot.frame.SubmissionEpoch > 1)
        {
            slot.pending = false;
            Late::Instance().reset = true;
            continue;
        }
        if (slot.pairedTaaFg && (!presentationOwner || !presentationGeneration ||
            slot.frame.ObservationOwner != presentationOwner ||
            slot.frame.ObservationGeneration != presentationGeneration))
        {
            // A carrier is valid only for the exact ownership generation that
            // owned the HUD-less/real-output pair. Identity + generation closes
            // both recreated-swapchain and pointer-reuse/ABA transitions.
            slot.pending = false;
            Late::Instance().reset = true;
            continue;
        }
        const bool routeMatches = slot.pairedTaaFg || slot.residualOnly == residualOnly;
        if (routeMatches && slot.frame.OutputWidth == desc.Width && slot.frame.OutputHeight == desc.Height &&
            (!latest || slot.serial > latest->serial))
            latest = &slot;
    }
    if (!latest)
        return; // loading screen, another swapchain, or this real frame was already consumed
    auto& slot = *latest;
    // Drop other submitted evaluates from this picture, not their in-flight resources.
    for (auto& other : Late::Instance().slots)
        if (other.submitted && other.serial <= slot.serial)
            other.pending = false;
    slot.recording = true;
    if (FAILED(queue->Wait(slot.fence.Get(), slot.ready)) || FAILED(slot.allocator->Reset()) ||
        FAILED(slot.commands->Reset(slot.allocator.Get(), nullptr)))
    {
        Late::Instance().reset = true;
        Late::Instance().Say("Could not prepare the finished picture.");
        return;
    }
    optishade::nr_lifetime::Reset(slot.commands.Get());
    auto* cmd = slot.commands.Get();
    if (!g_compose)
        g_compose = std::make_unique<DlssNr_Dx12>("Neural Rendering", Late::Instance().device.Get());
    const auto before = g_nr.successfulDispatches;
    bool appliedResidual = false;
    if (slot.residualOnly)
    {
        if (slot.encoded && (slot.encoded->GetDesc().Width != desc.Width ||
            slot.encoded->GetDesc().Height != desc.Height || slot.encoded->GetDesc().Format != desc.Format))
            slot.encoded.Reset();
        if (!slot.encoded)
            slot.encoded.Attach(CreateScratch(Late::Instance().device.Get(), desc.Format, (unsigned) desc.Width, desc.Height));
        if (slot.encoded && Config::Instance()->DlssNrApplyModel.value_or_default())
        {
            if (slot.residualState != D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE)
                Barrier(cmd, slot.residual.Get(), slot.residualState, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            Barrier(cmd, color.Get(), D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            DlssNrConstants apply {};
            apply.Mode = pq ? 4 : scrgb ? 3 : 2;
            apply.Width = (unsigned) desc.Width; apply.Height = desc.Height;
            apply.WhitePoint = slot.frame.PreExposure;
            apply.TransferStrength = slot.sceneLinear ? 1.0f : 0.0f;
            apply.MaxRatio = std::clamp(Config::Instance()->DlssNrMaxRatio.value_or_default(), 1.0f, 8.0f);
            appliedResidual = g_compose->DispatchResidualPass(cmd, apply, color.Get(), nullptr,
                slot.residual.Get(), nullptr, slot.encoded.Get(), true);
            if (appliedResidual)
            {
                Barrier(cmd, slot.encoded.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
                Barrier(cmd, color.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
                cmd->CopyResource(color.Get(), slot.encoded.Get());
                Barrier(cmd, color.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                Barrier(cmd, slot.encoded.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            }
            Barrier(cmd, color.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_PRESENT);
            if (slot.residualState != D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE)
                Barrier(cmd, slot.residual.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, slot.residualState);
        }
    }
    else
    {
        auto frame = slot.frame;
        frame.ColourIsLinearHdr = pq || scrgb;
        // Absolute display encodings: 203-nit reference white, in 80-nit scRGB units.
        frame.WhitePointOverride = (pq || scrgb) ? 203.0f / 80.0f : 0.0f;
        frame.Reset |= Late::Instance().reset;
        frame.SubmissionEpoch = epoch;
        frame.ObservationOwner=reinterpret_cast<uintptr_t>(swapchain);
        Barrier(cmd, slot.depth.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        Barrier(cmd, slot.motion.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        DlssNrNative::SetPrecision(Config::Instance()->DlssNrPrecision.value_or_default());
        ID3D12Resource* nrColor = color.Get();
        bool colorReady = true;
        DlssNrConstants conversion {};
        conversion.Width = (unsigned) desc.Width;
        conversion.Height = desc.Height;
        if (pq)
        {
            auto ensure = [&](Late::ComPtr<ID3D12Resource>& resource, DXGI_FORMAT format) {
                if (resource && (resource->GetDesc().Width != desc.Width || resource->GetDesc().Height != desc.Height ||
                                 resource->GetDesc().Format != format)) resource.Reset();
                if (!resource) resource.Attach(CreateScratch(Late::Instance().device.Get(), format, (unsigned) desc.Width, desc.Height));
                return resource != nullptr;
            };
            colorReady = ensure(slot.linear, DXGI_FORMAT_R16G16B16A16_FLOAT) && ensure(slot.encoded, desc.Format);
            if (colorReady)
            {
                Barrier(cmd, color.Get(), D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                colorReady = g_compose->DispatchResidualPass(cmd, conversion, color.Get(), nullptr, nullptr, nullptr,
                                                           slot.linear.Get(), true);
                Barrier(cmd, color.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_PRESENT);
                // Dispatch reads the converted colour; its transition out of UAV orders the conversion.
                nrColor = slot.linear.Get();
                frame.OutputArrivalState = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
            }
        }
        if (colorReady)
            g_compose->Dispatch(cmd, nrColor, slot.depth.Get(), slot.motion.Get(), nrColor, frame, queue);
        if (pq && colorReady && g_nr.successfulDispatches > before && Config::Instance()->DlssNrApplyModel.value_or_default())
        {
            conversion.Mode = 1;
            Barrier(cmd, slot.linear.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            Barrier(cmd, color.Get(), D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            if (g_compose->DispatchResidualPass(cmd, conversion, slot.linear.Get(), nullptr, color.Get(), nullptr,
                                               slot.encoded.Get(), true))
            {
                Barrier(cmd, slot.encoded.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
                Barrier(cmd, color.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
                cmd->CopyResource(color.Get(), slot.encoded.Get());
                Barrier(cmd, color.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                Barrier(cmd, slot.encoded.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            }
            Barrier(cmd, color.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_PRESENT);
            Barrier(cmd, slot.linear.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        }
        Barrier(cmd, slot.motion.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
        Barrier(cmd, slot.depth.Get(), D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
    }
    if (FAILED(cmd->Close()))
    {
        Late::Instance().Say("Could not finish the picture. Restart the game to retry.");
        slot.pending = true; // quarantine the slot; do not reuse possibly recorded NR resources
        slot.submitted = false;
        return;
    }
    ID3D12CommandList* lists[] = { cmd };
    queue->ExecuteCommandLists(1, lists);
    FinishedPictureSubmitted(queue,1,lists);
    slot.done = slot.ready + 1;
    if (FAILED(queue->Signal(slot.fence.Get(), slot.done)))
    {
        Late::Instance().Say("The graphics queue stopped. Restart the game to retry.");
        return;
    }
    slot.recording = false;
    // A paired FG carrier belongs to exactly one real frame. Mark it consumed
    // after its apply commands are queued; the fence still prevents slot reuse
    // until that GPU work has completed.
    if (slot.pairedTaaFg)
        slot.pending = false;
    const bool ran = slot.residualOnly ? appliedResidual : g_nr.successfulDispatches > before;
    Late::Instance().reset = !ran;
    Late::Instance().Say(!Config::Instance()->DlssNrApplyModel.value_or_default() ? "NR changes are hidden." :
        ran ? (slot.pairedTaaFg ? "Applying paired TAA/NR changes to the real frame." :
        slot.residualOnly ? "Applying the pre-SR changes to the finished picture." :
        "Applying NR to the finished picture.") : "Preparing NR for the finished picture.");
    if (ran && (++Late::Instance().successes == 1 || Late::Instance().successes % 300 == 0))
        LOG_INFO("DLSS-NR finished picture: {} frames, {}x{}, FG {}", Late::Instance().successes,
                 desc.Width, desc.Height, State::Instance().currentFG &&
                 State::Instance().currentFG->IsActive() && !State::Instance().currentFG->IsPaused());
}

void ApplyToFinishedPicture(IDXGISwapChain* swapchain, ID3D12CommandQueue* queue){auto lock=g_nrEvents.Lock();optishade::route::ForEachOutput([&]{ApplyOutputToFinishedPicture(swapchain,queue);});}
