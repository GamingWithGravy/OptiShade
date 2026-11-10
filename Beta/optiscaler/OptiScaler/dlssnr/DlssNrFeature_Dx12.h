#pragma once

#include <d3d12.h>
#include <sl.h>
#include <dxgi1_4.h>
#include <string>
#include "../../../shared/NrSessionControl.h"
#include <vector>
#include "SelfHelp.h"

#include <shaders/dlssnr/DlssNr_Common.h>
#include <nvsdk_ngx.h>

// DLSS 5 Neural Rendering, run over the upscaler's output.
//
// Neural Rendering is a post-process, not an upscaler and not a denoiser: it takes a finished frame plus
// depth and motion vectors and synthesises detail. NVIDIA ships no public integration for it, so it is
// driven directly through nvngx_dlssnr.dll as feature 18.
//
// OptiScaler is the right host for it because of one thing it knows that an external hook cannot: which
// NGX evaluate belongs to the upscaler and which to frame generation. Both are handed depth and motion
// vectors, so anything guessing from the parameter block alone attaches to both and runs the model twice
// per rendered frame. Here it is a lookup on the feature handle.
class Config;

namespace DlssNr
{
std::string VulkanBridgeStatus();

inline constexpr unsigned int MaxPassCount = 5;
inline constexpr unsigned int DefaultMaxPassCount = 3;

// The model runs immediately after the game's upscaler, before the interface is drawn. It is shown a
// display-referred proxy of that frame -- the sort of picture it was trained on -- and its answer is
// composed back over the untouched original.
// Runs the model over Output on the same command list, immediately after the upscaler has written it.
// Called only for upscaler evaluates -- never for frame generation, which is the whole point.
//
// Safe to call every frame; it builds what it needs on first use and disables itself for the session if
// anything fails, rather than retrying into a crash.
// timingQueue is the queue this command list will be executed on, when the caller knows it.
// State::currentCommandQueue only exists once a D3D12 swapchain has been created, which a Vulkan
// game never does -- so without this the pass runs and never reports what it cost.
// rayReconstruction identifies the feature for history reset and the SR-only deferred experiment.
// Placement and model cost controls are shared by SR and RR+SR.
void EvaluateAfterUpscale(ID3D12GraphicsCommandList* cmdList, NVSDK_NGX_Parameter* params,
                          ID3D12CommandQueue* timingQueue = nullptr, bool rayReconstruction = false,
                          unsigned long long submissionEpoch = 0, uint64_t outputOwner = 0);

// Runs the same pass over Color immediately before SR or RR+SR consumes it. The call is a no-op
// unless RunBeforeSR is enabled. Color is returned in its original readable state.
void EvaluateBeforeUpscale(ID3D12GraphicsCommandList* cmdList, NVSDK_NGX_Parameter* params,
                           ID3D12CommandQueue* timingQueue = nullptr,
                           unsigned long long submissionEpoch = 0, bool rayReconstruction = false, uint64_t outputOwner = 0);



// Frame generation titles tag their UI layer through Streamline; a copy of it makes the HUD mask
// exact at the finished frame. Called at tag time.




// The settings panel, drawn inside OptiScaler's menu.
void RenderMenu(::Config* config, float menuResScale);

// Clears the session failure latch, so a failure caused by transient thrash does not cost a restart.
void RetryAfterFailure();
void SetEnabled(bool enabled,const char* source="runtime-control");
optishade::nr_session::Result TrySetSessionEnabled(bool enabled,uint64_t expectedRevision);
bool TryReadSessionState(optishade::nr_session::State& state);
bool MemoryPressureStopped();
// Video memory was nearly full at the last check (NR kept running).
bool MemoryLow();
// A VR headset session is presenting (ReShade OpenXR layer heartbeat).
bool VrHeadsetActive();

std::string FinishedPictureStatus();
bool HasPairedTaaFgPending();
bool WaitForFinishedPicture();
void FinishedPictureResetCommandList(ID3D12CommandList* cmd);
void FinishedPictureCommandListFailed(ID3D12CommandList* cmd);
void FinishedPictureSubmitted(ID3D12CommandQueue* queue, UINT count, ID3D12CommandList* const* lists);
void ApplyToFinishedPicture(IDXGISwapChain* swapchain, ID3D12CommandQueue* queue);
void FinishedPictureColorSpace(IDXGISwapChain* swapchain, DXGI_COLOR_SPACE_TYPE colorSpace);


// Asks the model whether it will work on Direct3D 11 at all, once, and logs the answer.
//
// The bridge exists because of a claim nobody tested: "the model refuses on DX11, it answers
// FeatureNotSupported". Nothing in this project has ever called the snippet's own D3D11 entry points
// -- it exports ten of them, implemented in ngx_d3d11.cpp and sharing CreateFeatureCommon and
// EvaluateFeatureCommon with the D3D12 path. Nothing is created and nothing changes; it resolves the
// entry points and initialises on the game's own device, which is where a refusal would appear.
void ProbeD3D11(void* d3d11Device);

// What scale this game's buffer is on, measured from the untouched copy of each frame.
//
// A suggestion only. Nothing applies it: the menu shows it and the user takes it or does not, which
// keeps the number visible and adjustable rather than a value that moved on its own. Confidence is
// how settled recent readings are -- 1 means they agree, 0 means the scene is changing under the
// measurement and no single value would serve.
struct CalibrationReading
{
    float suggestion = 0.0f;

    // How much recent readings agree. This is steadiness, not correctness: a frozen frame agrees with
    // itself perfectly, so a loading screen scores full marks for a number that means nothing. Read it
    // together with usable.
    float steadiness = 0.0f;

    unsigned long long samples = 0;

    // Whether the scene is worth measuring at all. False when the frame is already tone mapped -- the
    // divisor does nothing there and the reading would be a meaningless 0.9 -- or when too little of
    // the picture is lit to say where the top of the range is. A dark cave gives a small number very
    // steadily, which is the trap this exists to close.
    bool usable = false;
    const char* why = "";
};

CalibrationReading Calibration();

// Whether the model is loaded and running, for the overlay.
bool IsRunning();
std::string TaaFallbackStatus();
// True while the TAA compatibility route has reported within the last 2 s.
bool TaaRouteSeen();
// Settings and runtime state that can make the picture flicker now, in plain language.
std::vector<optishade::selfhelp::Advice> FlickerSuspects();
// Whether the pre-FG TAA route observes the game's Streamline tags (see TaaPreFgObserver.h).
bool TaaPreFgObserver();
void TaaFgNewFrameToken(uint32_t frame);
void TaaFgBindOutput(IDXGISwapChain* swap,ID3D12CommandQueue* queue);
bool TaaFgPrepare(uint32_t marker,bool legacy,sl::ResourceTag* tags,uint32_t& view,uint32_t& producer);
void TaaFgTagsAccepted(uint32_t frame,uint32_t view,bool accepted);
void TaaFgInputsConsumed(uint32_t view,ID3D12Fence* fence,uint64_t value);
void TaaFgPresentReturned(uint32_t frame);
void TaaFgBeforePresent(IDXGISwapChain* swapchain,ID3D12CommandQueue* queue);
void TaaFgPresentResult(IDXGISwapChain* swapchain,HRESULT result);

void TaaFgLegacyPresent();
void TaaFgLegacyTags(ID3D12GraphicsCommandList* cmd,const sl::ResourceTag* tags,uint32_t count,uint32_t view);
void TaaFgAcceptedConstants(const sl::Constants& value,uint32_t frame,uint32_t view);
void TaaFgReset();
bool TaaFgBeginResize(ID3D12CommandQueue* queue);
void TaaFgEndResize(ID3D12CommandQueue* queue);
void TaaFgQueueIdleCompleted(ID3D12CommandQueue* queue, ID3D12Fence* fence, uint64_t value);
bool TaaFgReadyToRetire();
uint32_t TaaFgPendingCount();
void RetireCompletedTaaRecordings(bool resetHistory = true);
void TaaFgReleaseOutput(IDXGISwapChain* swap);
void TaaFgInvalidate(uint32_t view);
void TaaFgBeforeTags(ID3D12GraphicsCommandList* cmd,const sl::ResourceTag* tags,uint32_t count,uint32_t frame,uint32_t view);
// Private residual-upscaler status; separate from the NR model's own running status/time.
std::string DeferredDlssStatus();

// Why it is not, if it is not. Empty while it is running or has not been tried yet.
const char* FailureReason();

// What the game offers by way of exposure. Observed every frame whether or not the setting is on, so
// the menu can say whether turning it on would do anything here.
struct ExposureStatus
{
    unsigned long long seenFrames = 0;   // evaluates observed; 0 means nothing has run yet
    bool offeredNow = false;             // a texture on the most recent frame
    bool everOffered = false;            // a texture on any frame so far
    float exposure = 0.0f;               // last value read back, 0 if none
    float preExposure = 1.0f;
};

ExposureStatus GameExposureStatus();

// The white point the exposure meter has settled on, or 0 if it has not taken a reading yet. For the
// overlay, so the number in use is visible rather than inferred.

// What the pass last cost on the GPU, in milliseconds, or nothing if it has not been measured yet.
std::optional<double> LastGpuTime();

// What the white point meter last settled on, or 0 when it is not running. For the menu.


// Writes a run of consecutive frames, each as the upscaler produced it and again after the model's edit.
// The pair is a control: same frames, same run, one variable.
void RequestCapture(unsigned int frames);
bool CaptureInProgress();

enum class RetirementResult { Retired, PendingGpu };
// D3D12 swapchain resets may require a short bounded wait for output leases
// to retire. Other callers remain nonblocking by using the default timeout.
[[nodiscard]] RetirementResult Shutdown(uint32_t waitTimeoutMs = 0);
// Prepares a swapchain resize without refusing it when old NR command lists
// still hold exact resource leases. Those resources remain alive until a later
// dispatch can retire them and rebuild for the new output.
[[nodiscard]] RetirementResult PrepareForSwapchainResize();
} // namespace DlssNr



namespace osvtaa {struct Frame;}
namespace DlssNr {bool EvaluatePrivateVulkanBridge(ID3D12GraphicsCommandList*,ID3D12CommandQueue*,ID3D12Resource*,ID3D12Resource*,ID3D12Resource*,const osvtaa::Frame&);}

namespace DlssNr {
bool TaaFgProviderPrepare(IDXGISwapChain*,sl::ResourceTag*,uint32_t&,uint32_t&);
void TaaFgProviderCommit(IDXGISwapChain*);
}

namespace DlssNr { void TaaFgTraceStop(); }
