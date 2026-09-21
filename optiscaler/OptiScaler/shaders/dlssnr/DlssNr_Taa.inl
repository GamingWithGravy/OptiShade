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
std::string status = "Enable OptiShade_TAA_Guides in Image effects. Use TAA, SDR and disable frame generation.";
void Say(const char* value) { if (status != value) { status = value; LOG_INFO("TAA NR: {}", value); } }
bool Wait(ID3D12CommandQueue* queue) {
    if (FAILED(queue->Signal(fence.Get(), ++fenceValue))) return false;
    const auto start = GetTickCount64();
    while (fence->GetCompletedValue() < fenceValue) {
        if (GetTickCount64() - start > 5000 || FAILED(device->GetDeviceRemovedReason())) return false;
        Sleep(1);
    }
    return fence->GetCompletedValue() != UINT64_MAX;
}
void Submit(const ostaa::Frame* input) {
    std::lock_guard<std::recursive_mutex> guard(g_nrMutex);
    const auto& cfg = *Config::Instance();
    if (!cfg.DlssNrEnabled.value_or_default() || !cfg.DlssNrTaaFallback.value_or_default()) return;
    const auto now = GetTickCount64();
    const bool gap = !lastCall || now - lastCall > 500;
    lastCall = now;
    if (poisoned) { Say("Graphics submission failed. Restart MSFS before retrying TAA NR."); return; }
    if (!input || input->version != ostaa::Version || input->size != sizeof(ostaa::Frame)) { Say("TAA bridge version mismatch. Repair OptiShade."); return; }
    if (now - g_lastNativeNrInput.load() < 2000) { Say("Native upscaler inputs detected; TAA fallback is standing aside."); return; }
    if (State::Instance().currentFG && State::Instance().currentFG->IsActive() && !State::Instance().currentFG->IsPaused()) { Say("Disable frame generation before testing TAA NR."); return; }
    if (!input->providerReady || !input->queue || !input->color || !input->depth || !input->motion) { Say("Waiting for enabled TAA guides, valid scene depth and an SDR D3D12 frame."); return; }
    auto* queue = static_cast<ID3D12CommandQueue*>(input->queue);
    auto* color = static_cast<ID3D12Resource*>(input->color);
    auto* depth = static_cast<ID3D12Resource*>(input->depth);
    auto* motion = static_cast<ID3D12Resource*>(input->motion);
    const auto c = color->GetDesc(), d = depth->GetDesc(), m = motion->GetDesc();
    const auto valid = [&](const D3D12_RESOURCE_DESC& r) {
        return r.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE2D && r.SampleDesc.Count == 1 &&
            r.DepthOrArraySize == 1 && r.MipLevels == 1 && r.Width == c.Width && r.Height == c.Height;
    };
    if (!valid(c) || !valid(d) || !valid(m) || !c.Width || !c.Height ||
        (c.Format != DXGI_FORMAT_R8G8B8A8_UNORM && c.Format != DXGI_FORMAT_B8G8R8A8_UNORM) ||
        d.Format != DXGI_FORMAT_R32_FLOAT || m.Format != DXGI_FORMAT_R16G16_FLOAT) {
        Say("TAA inputs have unsupported sizes or formats. SDR and full-resolution guides are required."); return;
    }
    ComPtr<ID3D12Device> current;
    if (FAILED(queue->GetDevice(IID_PPV_ARGS(&current))) || queue->GetDesc().Type != D3D12_COMMAND_LIST_TYPE_DIRECT) return;
    for (auto* resource : {color, depth, motion}) {
        ComPtr<ID3D12Device> owner;
        if (FAILED(resource->GetDevice(IID_PPV_ARGS(&owner))) || owner != current) { Say("TAA resources belong to different devices."); return; }
    }
    if (device && device != current) { Say("Graphics device changed. Restart MSFS before retrying TAA NR."); return; }
    device = current;
    if (!fence && FAILED(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)))) return;
    // Drain preceding ReShade/game work before touching the shared NR scratch set.
    if (!Wait(queue)) { poisoned = true; Say("TAA GPU synchronization failed."); return; }
    if (!allocator && FAILED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator)))) return;
    if (!commands) {
        if (FAILED(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr, IID_PPV_ARGS(&commands)))) return;
        commands->Close();
    }
    if (FAILED(allocator->Reset()) || FAILED(commands->Reset(allocator.Get(), nullptr))) { poisoned = true; return; }
    borrowedColor = color; borrowedDepth = depth; borrowedMotion = motion;
    auto* cmd = commands.Get();
    const auto shaderRead = D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    Barrier(cmd, depth, shaderRead, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Barrier(cmd, motion, shaderRead, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    if (!g_compose) g_compose = std::make_unique<DlssNr_Dx12>("TAA neural rendering", device.Get());
    DlssNrFrameInfo frame {};
    frame.FinishedPicture = true; frame.IndependentCommands = true;
    frame.OutputArrivalState = D3D12_RESOURCE_STATE_RENDER_TARGET;
    frame.ColourIsLinearHdr = false; frame.DepthInverted = input->reversedDepth != 0;
    frame.MvScaleX = static_cast<float>(c.Width); frame.MvScaleY = static_cast<float>(c.Height);
    frame.OutputWidth = static_cast<unsigned>(c.Width); frame.OutputHeight = c.Height;
    frame.RenderSubrectWidth = frame.OutputWidth; frame.RenderSubrectHeight = frame.OutputHeight;
    frame.Reset = gap || !lastRun || now - lastRun > 500;
    frame.SubmissionEpoch = ++epoch;
    DlssNrNative::SetPrecision(cfg.DlssNrPrecision.value_or_default());
    const auto before = g_nr.successfulDispatches;
    g_compose->Dispatch(cmd, color, depth, motion, color, frame, queue);
    Barrier(cmd, motion, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, shaderRead);
    Barrier(cmd, depth, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, shaderRead);
    if (FAILED(cmd->Close())) { poisoned = true; Say("TAA command recording failed. Restart MSFS."); return; }
    ID3D12CommandList* lists[] = {cmd}; queue->ExecuteCommandLists(1, lists);
    if (!Wait(queue)) { poisoned = true; Say("TAA GPU work did not finish. Restart MSFS."); return; }
    borrowedColor.Reset(); borrowedDepth.Reset(); borrowedMotion.Reset();
    if (g_nr.successfulDispatches > before) {
        lastRun = now;
        Say(cfg.DlssNrApplyModel.value_or_default() ? "TAA NR submitted and GPU work completed (experimental estimated motion)." : "TAA NR completed; model changes are hidden.");
    } else Say(g_nr.failed ? g_nr.reason : "Preparing the TAA neural model; no completed evaluation yet.");
}
}
std::string TaaFallbackStatus() {
    std::lock_guard<std::recursive_mutex> guard(g_nrMutex);
    if (GetTickCount64() - Taa::lastCall > 2000) return "Waiting for Image effects: enable OptiShade_TAA_Guides. SDR / native D3D12 only.";
    return Taa::status;
}
