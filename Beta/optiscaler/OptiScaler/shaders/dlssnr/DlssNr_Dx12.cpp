#include <map>
#include "../../../../shared/NativeFgRetry.h"
#include "pch.h"
#include "../../../../shared/PrivateD3D11NrBridge.h"
#include "../../../../shared/NrSubmissionOutcome.h"
#include <misc/ActualRenderGpu.h>
#include "../../../../shared/NativeFgLifetime.h"
#include <format>
#include "../../../../shared/GpuProgressTrace.h"
#include "../../../../shared/ProducerDependencies.h"
#include "../../../../shared/NativeFgRetry.h"
#include "../../../../shared/ExternalFgObserver.h"
#include "../../../../shared/NrRecordingDevice.h"
#include "../../../../shared/PrivateNrSubmission.h"
#include "../../../../shared/SimulatorRouteHost.h"
#include "../../../../shared/NeuralModelPath.h"
#include "../../../../shared/BaseMipCopy.h"
#include "../../../../shared/NrMemoryBudget.h"
#include "../../../../shared/TaaFgAdmission.h"
#include <dlssnr/ExternalFgStatus.h>
#include <dlssnr/TaaPreFgObserver.h>
#include "../../../../shared/TaaFgHookPolicy.h"
#include "../../../../shared/OptiShadeVersion.h"
#include <dlssnr/NrMemoryGuard.h>
#include "../../../../shared/TaaOutputRetirement.h"
#include "../../../../shared/TaaNativeFgContract.h"
extern "C" __declspec(dllexport) bool OptiShadeTaaRequested();
#include "../../../../shared/DiagnosticRateLimit.h"
#include <dlssnr/NrObservationConfig.h>
#include "../../../../shared/D3D12FrameContext.h"
#include "../../../../shared/D3D12Capabilities.h"
#include <dlssnr/PassProfiles.h>

#include "../../../../shared/NrDeferredEvents.h"
#include "../../../../shared/NrCreationCompletion.h"
#include <set>
#include <atomic>
#include <wrl/client.h>
#include <dxgi1_4.h>
#include <resource_tracking/ResTrack_Dx12.h>

#include <dlssnr/DlssNr.h>
#include <dlssnr/DlssNrNative.h>
#include <dlssnr/ResidualFg.h>
#include <DirectXMath.h>


#include <dlssnr/DlssNr_Capture.h>
#include <dlssnr/DlssNr_Proxy.h>
#include <dlssnr/DlssNr_ExposureScan.h>

#include "DlssNr_Dx12.h"
#include "DlssNr_ActiveColor.h"
#include "DlssNr_Guides.h"
#include "DlssNr_SeamClock.h"

#include <Config.h>
#include <State.h>
#include <Util.h>
#include <menu/menu_overlay_dx.h>

#include <proxies/NVNGX_Proxy.h>
#include <hooks/D3D12_Hooks.h>
#include <gpu_time/GpuTime_Dx12.h>
#include "DlssNr_GpuTime.h"

#include <mutex>
#include <algorithm>
#include <cstring>
#include "precompile/DlssNr_Shader.h"
#include "precompile/dlssnr_residual_Shader.h"
#include "precompile/dlssnr_finished_color_Shader.h"
#include "DlssNr_ResidualPair.h"
#include "../output_scaling/OS_Dx12.h"
#include "../../../../shared/TaaBridge.h"
#include "../../../../shared/VulkanNeuralBridge.h"
#include "../../../../shared/TaaRoutePolicy.h"
#include "../../../../shared/DeferredSrQuality.h"

#define g_nativeNrInputs (optishade::route::Owned<optishade::taa::NativeInputs,2>())

namespace DlssNr {
struct NrSubmissionEvent {
    Microsoft::WRL::ComPtr<ID3D12CommandQueue> queue; // null means recording reset
    std::vector<Microsoft::WRL::ComPtr<ID3D12CommandList>> commands;
    uint64_t observedAt = 0;
    std::optional<uint32_t> frameToken;
    std::shared_ptr<sl::Constants> constants;
    uint32_t viewport = 0;
};
void ConsumeNrSubmissionEvent(const NrSubmissionEvent& event);
void ConsumeNrFrameNotification(const NrSubmissionEvent& event);
void RetireCompletedPrivateRecordings();
}

namespace
{
// ReShade's OpenXR layer reports every headset frame (OptiShadeXrFrame). A
// session counts as running while frames arrived within the last 1.5 s, so a
// crashed or ended session without an xrEndSession still times out.
std::atomic<ULONGLONG> g_headsetFrameAt{0};
bool HeadsetPresenting()
{
    const ULONGLONG at = g_headsetFrameAt.load(std::memory_order_relaxed);
    return at && GetTickCount64() - at < 1500;
}
bool NrOffInHeadset()
{
    return HeadsetPresenting() && !Config::Instance()->DlssNrInVrHeadset.value_or_default();
}
// NGX result codes, by name.
//
// A user's log recently read "init 0x-452FFFFF", which is an int formatted as hex and is
// undiagnosable by anyone. It was 0xBAD00001, FeatureNotSupported -- a complete answer, printed as
// noise. Names cost nothing and turn a bug report into a diagnosis.
const char* NgxResultName(unsigned int r)
{
    switch (r)
    {
    case 0x1: return "Success";
    case 0xBAD00001: return "FAIL_FeatureNotSupported";
    case 0xBAD00002: return "FAIL_PlatformError";
    case 0xBAD00003: return "FAIL_FeatureAlreadyExists";
    case 0xBAD00004: return "FAIL_FeatureNotFound";
    case 0xBAD00005: return "FAIL_InvalidParameter";
    case 0xBAD00006: return "FAIL_ScratchBufferTooSmall";
    case 0xBAD00007: return "FAIL_NotInitialized";
    case 0xBAD00008: return "FAIL_UnsupportedInputFormat";
    case 0xBAD00009: return "FAIL_RWFlagMissing";
    case 0xBAD0000A: return "FAIL_MissingInput";
    case 0xBAD0000B: return "FAIL_UnableToInitializeFeature";
    case 0xBAD0000C: return "FAIL_OutOfDate";
    case 0xBAD0000D: return "FAIL_OutOfGPUMemory";
    case 0xBAD0000E: return "FAIL_UnsupportedFormat";
    case 0xBAD0000F: return "FAIL_UnableToWriteToAppDataPath";
    case 0xBAD00010: return "FAIL_UnsupportedParameter";
    case 0xBAD00011: return "FAIL_Denied";
    case 0xBAD00012: return "FAIL_NotImplemented";
    default: return "unknown";
    }
}

// Does the driver's own nvngx.dll dispatch Neural Rendering?
//
// The trick is that correct parameters are not needed to find out, because the KIND of failure is
// the answer. A dispatcher that has never heard of feature 18 rejects it before looking at anything:
//
//   FeatureNotFound / FeatureNotSupported / NotImplemented -- the driver does not route it, and the
//       forwarder is necessary rather than merely tolerated.
//   MissingInput / InvalidParameter / UnsupportedParameter -- the driver DOES route it. It reached
//       the feature, which then complained about the arguments. That is the win: it means the whole
//       forwarder, and the per-game copy of the model, can go.
//   Success -- better still, though not expected from an empty parameter block.
//
// Once per session, and only when asked for.
void ProbeProxyDispatch(ID3D12GraphicsCommandList* cmdList)
{
    static bool done = false;

    if (done)
        return;

    done = true;

    if (!NVNGXProxy::IsDx12Inited())
    {
        LOG_INFO("DLSS-NR proxy probe: the driver's nvngx is not initialised here, nothing to ask");
        return;
    }

    const auto allocate = NVNGXProxy::D3D12_AllocateParameters();
    const auto destroy = NVNGXProxy::D3D12_DestroyParameters();
    const auto create = NVNGXProxy::D3D12_CreateFeature();
    const auto release = NVNGXProxy::D3D12_ReleaseFeature();

    if (allocate == nullptr || create == nullptr)
    {
        LOG_INFO("DLSS-NR proxy probe: the driver's nvngx does not export what the probe needs");
        return;
    }

    NVSDK_NGX_Parameter* params = nullptr;

    if (allocate(&params) != NVSDK_NGX_Result_Success || params == nullptr)
    {
        LOG_INFO("DLSS-NR proxy probe: could not allocate a parameter block");
        return;
    }

    // Feature 18, and a feature that certainly does not exist, asked the same way.
    //
    // A single result cannot answer this. "UnableToInitializeFeature" for 18 looks like the
    // dispatcher having found the feature and failed to start it on an empty parameter block -- but
    // it might equally be what this dispatcher says about anything it cannot set up. The control
    // settles it: if a nonsense id comes back differently, the difference is knowledge of feature
    // 18. If both come back the same, the first result meant nothing.
    NVSDK_NGX_Handle* handle = nullptr;
    const auto result = (unsigned int) create(cmdList, (NVSDK_NGX_Feature) 18, params, &handle);

    if (handle != nullptr && release != nullptr)
        release(handle);

    NVSDK_NGX_Handle* controlHandle = nullptr;
    const auto control =
        (unsigned int) create(cmdList, (NVSDK_NGX_Feature) 200, params, &controlHandle);

    if (controlHandle != nullptr && release != nullptr)
        release(controlHandle);

    LOG_INFO("DLSS-NR proxy probe: feature 18 -> 0x{:X} ({}), control feature 200 -> 0x{:X} ({})",
             result, NgxResultName(result), control, NgxResultName(control));

    const bool rejectedOutright =
        result == 0xBAD00004 || result == 0xBAD00001 || result == 0xBAD00012;

    if (result == control)
        LOG_INFO("DLSS-NR proxy probe: both answers identical, so this says nothing about feature 18 "
                 "-- the driver treats it exactly as it treats a feature that does not exist");
    else if (rejectedOutright)
        LOG_INFO("DLSS-NR proxy probe: feature 18 is rejected outright -- the driver does not route "
                 "it and the forwarder is required");
    else
        LOG_INFO("DLSS-NR proxy probe: feature 18 answers differently from a nonexistent one, so the "
                 "driver knows it -- the forwarder and the per-game model copy could both go");

    if (destroy != nullptr)
        destroy(params);
}

// Everything the model is reached through. The snippet refuses callers whose module path does not
// contain "nvngx.dll", so the calls are made from a small library named for exactly that reason and
// shipped beside OptiScaler; see nvngx.dll_dlssnr.dll.
using PFN_NrCreate = void*(__cdecl*) (const wchar_t*, const wchar_t*, ID3D12Device*,
                                      ID3D12GraphicsCommandList*, void*, unsigned int, unsigned int, int,
                                      float, int, float, float, float, int, int);
using PFN_NrEvaluate = int(__cdecl*) (ID3D12GraphicsCommandList*, void*, void*, ID3D12Resource*,
                                      ID3D12Resource*, ID3D12Resource*, ID3D12Resource*, unsigned int,
                                      unsigned int, unsigned int, unsigned int, unsigned int, unsigned int,
                                      unsigned int, unsigned int, unsigned int, unsigned int, int, int, float,
                                      int, float, float, float, int, float, float);
using PFN_NrRelease = void(__cdecl*) (void*);
using PFN_NrSetExtras = void(__cdecl*) (void*, float, ID3D12Resource*, ID3D12Resource*, ID3D12Resource*,
                                        unsigned int, unsigned int, unsigned int, unsigned int);
using PFN_NrSetFloatSlot = void(__cdecl*) (int);
using PFN_NrProbeFloat = void(__cdecl*) (void*, const char*, float, int);

// One per back buffer, so an allocator is never reset while its frame is still in flight.

using DlssNr::Profiles::NrPassTuning;
using DlssNr::Profiles::PassPreset;
using DlssNr::Profiles::PassStyle;
using DlssNr::Profiles::PassTuning;

struct NrState
{
    unsigned long long successfulDispatches = 0;
    HMODULE forwarder = nullptr;
    PFN_NrCreate create = nullptr;
    PFN_NrEvaluate evaluate = nullptr;
    PFN_NrRelease release = nullptr;
    PFN_NrSetExtras setExtras = nullptr;
    PFN_NrSetFloatSlot setFloatSlot = nullptr;
    PFN_NrProbeFloat probeFloat = nullptr;
    bool floatSlotKnown = false;

    // The scaling-ratio probe, resolved alongside the other forwarder entry points.
    int (*queryRatio)(const wchar_t*, void*, unsigned int, float*) = nullptr;
    const int* lastRatioStage = nullptr;
    int* lastInit = nullptr;
    int* lastCreate = nullptr;
    const char* (*lastModelError)() = nullptr;
    std::string modelError;

    NVSDK_NGX_Parameter* capabilityParams = nullptr;
    // Each temporal feature owns its mutable NGX table for its entire lifetime.
    NVSDK_NGX_Parameter* passParams[DlssNr::MaxPassCount] = {};
    Microsoft::WRL::ComPtr<IUnknown> capabilityDevice;
    void* feature = nullptr;
    bool featurePendingSubmission = false;
    bool featureFirstEvaluationPending = false;
    optishade::nr::CreationCompletion featureCreation;
    unsigned long long featureCreateEpoch = 0;

    // A feature per extra pass, each with its own temporal history.
    //
    // One feature run three times in a frame is told three frames passed with nothing moving between
    // them, so its history fights every pass after the first -- which is what "loses detail on later
    // passes" was. Separate features each see one frame per frame, which is the contract they were
    // built for.
    //
    // It is also the only reading that fits the one clue we have about how this is done elsewhere:
    // that implementation's memory grows with the pass count, and reusing a single feature cannot do
    // that. A feature apiece can, because each carries its own history.
    //
    // Indexed by pass, so [0] is unused and the first extra pass is [1]. Wasting one pointer keeps
    // every index here equal to the pass number it belongs to. Extra features are created on a
    // build-only invocation and first evaluated on a later command list.
    void* passFeature[DlssNr::MaxPassCount] = {};
    bool passFirstEvaluationPending[DlssNr::MaxPassCount] = {};
    bool passNeedsReset[DlssNr::MaxPassCount] = {};
    bool passCreateFailed[DlssNr::MaxPassCount] = {};
    bool passPendingSubmission[DlssNr::MaxPassCount] = {};
    // Game lists already submitted when each model was created. A submitted
    // list is closed, so it cannot hold that model's work; recording again
    // needs a Reset, which starts a new lease.
    std::vector<std::weak_ptr<optishade::nr_lifetime::Lease>> passBirthClosed[DlssNr::MaxPassCount];
    optishade::nr::CreationCompletion passCreation[DlssNr::MaxPassCount];
    unsigned long long passCreateEpoch[DlssNr::MaxPassCount] = {};

    // The model cannot read and write one resource, so the frame is staged through these.
    ID3D12Resource* colorCopy = nullptr;
    ID3D12Resource* output = nullptr;

    // The second half of the model-output ping-pong. The base proxy stays immutable: pass 0 writes
    // output (A), pass 1 writes this (B), and pass 2 writes A again. Only the final answer is composed.
    ID3D12Resource* passScratch = nullptr;
    bool passScratchFailed = false;

    // The frame as the upscaler wrote it. The resolve adds the model's edit to this rather than
    // reconstructing it by inverting the tone curve, which is what turned every light in the frame into
    // a string of coloured cells.
    ID3D12Resource* hdrCopy = nullptr;

    // Compact origin-zero pre-SR image, only needed when Color has allocation padding. All codec,
    // hold and capture paths then see the real raster. UAV at rest, retired with the scratch set.
    ID3D12Resource* activeColor = nullptr;

    // The frame shrunk for the model, when it is working below full resolution.
    ID3D12Resource* colorSmall = nullptr;

    // Supersampling (working scale > 1): the Output Scaling upsampler used to enlarge the proxy to the
    // model's larger-than-native working size with a real filter instead of the box minifier. Created
    // lazily on the first super-native frame, released in Shutdown; sizes from the resources each call,
    // so a resolution change needs no rebuild.
    OS_Dx12* superUp = nullptr;

    // Supersampling down-leg: the native-sized buffer the Nx model answer is averaged into, and the
    // downscaler that does it. With superUp this lands the super-native answer at native for a 1:1
    // composite (no aliased minify). nrScaler is the filter both were built with, so a changed
    // DlssNrScalingDownscaler rebuilds them.
    ID3D12Resource* outputNative = nullptr;
    OS_Dx12* superDown = nullptr;
    Scaler nrScaler = Scaler::Count;

    // ResidualAcrossRR v2 (design/pre-sr-multipass.md "Across-RR residual"). With RunBeforeSR + the
    // game's Ray Reconstruction both on, the pre-SR seam runs the model but leaves Color untouched:
    // the resolve writes residualEdited instead of the game buffer
    // and dlssnr_residual.hlsl's Accumulate samples the game's active motion-vector rectangle
    // layer by those MVs and blends (residualEdited - hdrCopy) in at ResidualBlend -> the new
    // residualHistory. The per-frame ray-trace noise term of that delta averages to zero; the
    // enhancement persists. The post-SR shader samples the signed history at output resolution.
    // residualPair binds the result to its command list, parameters and output; every new pre
    // seam invalidates the old result. residualHistoryIndex ping-pongs the two history textures.
    ID3D12Resource* residualEdited = nullptr;      // resolve output on the pre-SR seam (render size)
    ID3D12Resource* residualHistory[2] = {};       // accumulated enhancement layer, ping-pong (render size)
    ID3D12Resource* residualComposed = nullptr;    // Apply output = RR frame + delta (output size)
    unsigned int residualHistoryIndex = 0;         // which residualHistory holds the latest layer
    bool residualHistoryPrimed = false;            // false -> take the current delta whole (post-reset)
    bool residualStoreValid = false;
    bool residualModeActive = false;
    unsigned residualOutputWidth = 0, residualOutputHeight = 0;
    DXGI_FORMAT residualOutputFormat = DXGI_FORMAT_UNKNOWN;
    DlssNrResidualPair residualPair;

    // Frame hold (design/frame-hold.md): a persistent copy of the output taken on hold-on and restored
    // over the live output before the encode reads it while held, so a setting change re-renders the
    // same frame. heldWhitePoint is the snapshot used while held -- measurement is suspended.
    ID3D12Resource* heldColor = nullptr;
    bool heldActive = false;
    unsigned int heldWidth = 0;
    unsigned int heldHeight = 0;
    DXGI_FORMAT heldFormat = DXGI_FORMAT_UNKNOWN;
    float heldWhitePoint = 1.0f;

    unsigned int workWidth = 0;
    unsigned int workHeight = 0;

    // The white point meter.
    //
    // A 64x64 grid of tile luminances, copied to a readback buffer and looked at a few frames later.
    // Four buffers deep rather than one: the copy is recorded into the game's own command list and
    // there is no fence here to wait on, so the only thing making a read safe is that the frame it
    // came from is long retired. Three frames of distance is what the meter this replaces used.
    //
    // A stale read costs a slightly wrong float that the average below absorbs. A read of a buffer
    // still being written would cost the same, which is why the value is smoothed rather than used
    // raw.
    ID3D12Resource* meter = nullptr;
    ID3D12Resource* meterReadback[4] = {};

    // The calibration grid: what scale the game's buffer is on, measured from the untouched copy.
    // Its own surface and ring rather than sharing the meter's, because the two run at different
    // sizes -- the meter fetches one texel and this reads the whole frame.
    ID3D12Resource* calib = nullptr;
    ID3D12Resource* calibReadback[4] = {};
    unsigned long long calibFrames = 0;

    // The last few answers, so the menu can say how settled the number is. A suggestion taken during
    // a fade or a loading screen is worth less than one taken while standing still, and the spread
    // across recent frames is what tells them apart.
    static constexpr unsigned int kCalibHistory = 32;
    float calibHistory[kCalibHistory] = {};
    unsigned int calibCount = 0;
    float calibSuggestion = 0.0f;
    float calibSteadiness = 0.0f;
    bool calibUsable = false;
    const char* calibWhy = "measuring...";
    bool calibPassthrough = false;

    // Whether the frame that filled each readback slot actually had an exposure texture bound.
    //
    // The meter writes tile 0 from whatever sits in the exposure slot, and DispatchPass substitutes
    // the source picture when nothing is bound -- so without this the "exposure" read back is the red
    // channel of the frame's top-left pixel. In Cyberpunk, which supplies no exposure texture, that
    // pixel is scene content: it moved by up to 272x between consecutive frames and drove the white
    // point from 0.18 to 74. That is the whole frame flashing in luminance.
    //
    // The grid is read three frames after it is written, so the flag has to travel with the slot
    // rather than being asked of the current frame.
    bool meterExposureValid[4] = {};
    unsigned int meterSlot = 0;
    unsigned long long meterFrames = 0;

    // Whether the setting was on last frame, so the off->on edge can be caught.
    //
    // Deliberately the SETTING and not `wantExposure`: the texture itself comes and goes between
    // frames and holding the last good value across those gaps is the whole point of the field below.
    // Only the user turning the option back on means "anything held is from an unknown time ago".
    bool exposureSettingWasOn = false;

    // The game's exposure, as last read back, and the pre-exposure that goes with it. Held rather
    // than defaulted: the texture comes and goes between frames and a fallback to 1.0 on the gaps
    // would be a flicker source.
    float gameExposure = 0.0f;
    float gamePreExposure = 1.0f;

    // What the game OFFERS, as opposed to what has been read. Recorded from the parameter block every
    // frame whether or not the setting is on, and deliberately so: the menu has to be able to answer
    // "would this do anything here?" before the user turns it on, and reading a pointer for null costs
    // nothing. Whether it was ever offered is kept separately from whether it was offered this frame,
    // because games drop it on transitions -- GTA V dropped it three times in one session -- and one
    // absent frame is not the same answer as never.
    bool exposureOfferedNow = false;
    bool exposureEverOffered = false;
    unsigned long long exposureFrames = 0;

    // Cloned unconditionally when running at present, and only for typeless formats otherwise.
    ID3D12Resource* depthClone = nullptr;
    ID3D12Resource* motionClone = nullptr;

    // The constant-depth probe's surface. Separate from depthClone on purpose: it is defined by
    // never having been written, and sharing a surface with a mode that writes would destroy that.
    ID3D12Resource* depthConstant = nullptr;

    unsigned int width = 0;
    unsigned int height = 0;
    bool beforeUpscale = false;
    bool rayReconstruction = false;
    bool reset = true;
    // A swapchain resize can complete before every command-list generation that
    // referenced NR surfaces has retired. Keep those surfaces parked on their
    // exact leases, then rebuild them at the first NR frame after the resize.
    bool resizeRebuildPending = false;
    // Start of the current wait for a previous model generation to retire, and
    // the last time its pending lease states were logged.
    ULONGLONG rebuildWaitStartMs = 0;
    ULONGLONG rebuildWaitLogMs = 0;

    // Dimensions of the guides as the upscaler handed them over, kept for the present path, which runs
    // long after that call has returned.
    unsigned int guideWidth = 0;
    unsigned int guideHeight = 0;

    // How the game encodes its guides, as the game itself reports it. Captured with the guides, since
    // the finished-frame path runs long after the upscaler's call has returned.
    bool guideDepthInverted = false;
    float guideMvScaleX = 1.0f;
    float guideMvScaleY = 1.0f;

    // The values each live feature was created with. Preset and style may differ per layer; the
    // remaining strengths are intentionally shared by the stack.
    unsigned int builtPreset[DlssNr::MaxPassCount] = {};
    float builtIntensity = 0.0f;
    NrPassTuning builtPassTuning[DlssNr::MaxPassCount] {};
    unsigned int builtStyle[DlssNr::MaxPassCount] = {};
    float builtLocalStructure = 0.0f;
    float builtLocalTone = 0.0f;
    float builtSkinStructure = 0.0f;
    bool builtAutoMask = false;
    unsigned long long settledAt = 0;

    // Once something fails there is no recovering it mid-session, and retrying every frame turns a
    // failure into a crash. It stays off and says why.
    bool failed = false;
    const char* reason = "";
};

struct NrTimingDomain {ID3D12Device* device=nullptr;ID3D12CommandQueue* queue=nullptr;unsigned width=0,height=0;bool taa=false,finished=false;};
struct NrEngineState {
 uint64_t outputGeneration=0;
 uint64_t tuningGeneration=0;
 std::unique_ptr<DlssNr_Dx12> compose;std::unique_ptr<DlssNrGpuTime> gpuTime,ngxTime;
 NrTimingDomain timingDomain;std::optional<double> lastNgxTime,lastGpuTime;
 capture::FrameCapture capture;unsigned long long frames=0;
 DlssNrSeamClock seamClock;std::filesystem::path dllDir;
 NrPassTuning pendingTuning[DlssNr::MaxPassCount]{};
 unsigned pendingPreset[DlssNr::MaxPassCount]{},pendingStyle[DlssNr::MaxPassCount]{};
 unsigned pendingPasses=0,lastPrecision=0,lastFinishedMode=0;ULONGLONG tuningChangedAt=0;
 ULONGLONG lastNativeEvaluationAt=0;
 ULONGLONG switchedOffAt=0;  // first frame NR was seen off; 0 while on or nothing is held
 // A new frame size must hold for a few frames before the running model is
 // replaced (see kExtentSettleFrames).
 unsigned settleWidth=0,settleHeight=0,settleWorkWidth=0,settleWorkHeight=0,settleFrames=0;
 // "Log when it changes" memory, per output: VR alternates eyes every frame,
 // so one shared copy logged these lines on every frame.
 struct { bool valid=false,depthInverted=false; float mvScaleX=0,mvScaleY=0; unsigned guideW=0,guideH=0,frameW=0,frameH=0; } loggedGuides;
 int loggedColour=-1;
 int loggedVrScale=0;
};
struct NrMemoryWarningState {bool low=false;};
struct NrMemoryState {
 bool deviceLost=false,stopped=false,overrideBudget=false,adapterLuidValid=false;
 optishade::nr::BudgetCheck check;
 optishade::nr::memory_guard::Recovery recovery;
 Microsoft::WRL::ComPtr<IDXGIFactory4> factory;
 Microsoft::WRL::ComPtr<IDXGIAdapter3> adapter;
 LUID adapterLuid{};
 bool QueryMemory(ID3D12Device* device,DXGI_QUERY_VIDEO_MEMORY_INFO& memory){
  if(!device)return false;
  if(!factory&&FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))))return false;
  const auto current=device->GetAdapterLuid();
  if(!adapter||!adapterLuidValid||adapterLuid.LowPart!=current.LowPart||adapterLuid.HighPart!=current.HighPart){
   adapter.Reset();
   if(FAILED(factory->EnumAdapterByLuid(current,IID_PPV_ARGS(&adapter))))return false;
   adapterLuid=current;adapterLuidValid=true;
  }
  return SUCCEEDED(adapter->QueryVideoMemoryInfo(0,DXGI_MEMORY_SEGMENT_GROUP_LOCAL,&memory));
 }
};
#define g_nr (optishade::route::OutputOwned<NrState,0>())
#define g_compose (optishade::route::OutputOwned<NrEngineState,1>().compose)

// What the pass costs on the GPU, for the breakdown in the overlay.
#define g_gpuTime (optishade::route::OutputOwned<NrEngineState,1>().gpuTime)

#define g_timingDomain (optishade::route::OutputOwned<NrEngineState,1>().timingDomain)

// A second timer, around the model's evaluate and nothing else.
//
// The first one brackets the whole pass, which is the number the menu shows and the right one for
// "what does this feature cost". It is the wrong number for deciding what to optimise: the 4.10 ms at
// full model resolution and 2.24 ms at half were both whole-pass, and both included this pass's own
// encode and resolve at DISPLAY resolution plus the guide copies, none of which move when the model's
// resolution does. Fitting a fixed term to those two points therefore attributes our own unchanging
// work to NGX overhead.
//
// Splitting them says how much of the pass is the model and how much is ours -- and ours is the half
// we can actually do something about.
#define g_ngxTime (optishade::route::OutputOwned<NrEngineState,1>().ngxTime)
#define g_lastNgxTime (optishade::route::OutputOwned<NrEngineState,1>().lastNgxTime)
#define g_lastGpuTime (optishade::route::OutputOwned<NrEngineState,1>().lastGpuTime)

// Writes matched before/after frames on request, so comparisons stop depending on video.
#define g_capture (optishade::route::OutputOwned<NrEngineState,1>().capture)

// Cleared once per run, so a session's captures are its own and nothing accumulates across launches.
void ClearCaptureDirectory()
{
    static bool cleared = false;

    if (cleared)
        return;

    cleared = true;

    std::error_code ec;
    const auto dir = Util::DllPath().remove_filename() / "dlssnr-capture";

    if (std::filesystem::exists(dir, ec))
    {
        std::filesystem::remove_all(dir, ec);

        if (ec)
            LOG_WARN("DLSS-NR could not clear {}: {}", dir.string(), ec.message());
    }
}

#define g_frames (optishade::route::OutputOwned<NrEngineState,1>().frames)

// Logical frame identity for deferred pairing; feature readiness keeps the raw submission counter.
#define g_nrSeamClock (optishade::route::OutputOwned<NrEngineState,1>().seamClock)

// Dropping a file named dlssnr-capture.trigger beside OptiScaler requests a capture, so a session can
// be asked for one from outside the game -- no alt-tab, no menu. Checked once a second, effectively.
void CheckCaptureTrigger()
{
    if ((g_frames % 60) != 0)
        return;

    std::error_code ec;
    const auto trigger = Util::DllPath().remove_filename() / "dlssnr-capture.trigger";

    if (std::filesystem::exists(trigger, ec))
    {
        std::filesystem::remove(trigger, ec);
        DlssNr::RequestCapture(capture::kMaxFrames);
        LOG_INFO("DLSS-NR capture requested by trigger file");
    }
}

// The encoded mean is aimed here. Mid-grey rather than anything brighter: the model has to see both the
// shadow detail it might lift and the highlights it must not blow out.
constexpr float kTargetEncodedMean = 0.45f;

// How fast the derived value follows the scene. Readings arrive a few times a second, and an exposure
// that lunges at every cut is worse than one that arrives a moment late.
constexpr float kWhitePointBlend = 0.25f;

// Recomputes the white point from a measured mean. Inverting the encode for the white point that puts
// that mean at the target gives wp = mean * (1 - t^g) / t^g.
float WhitePointForMean(float meanLuma)
{
    const float encoded = powf(kTargetEncodedMean, 2.2f);
    const float ratio = encoded / (1.0f - encoded);
    const float wp = meanLuma / ratio;
    // A black frame between scenes would otherwise drive this to zero and divide the next frame by it.
    return wp < 0.01f ? 0.01f : (wp > 10000.0f ? 10000.0f : wp);
}

#define g_dllDir (optishade::route::OutputOwned<NrEngineState,1>().dllDir)

const char* SelectedModelFile()
{
    return "nvngx_dlssnr.dll";
}

std::optional<std::filesystem::path> FindSelectedModel()
{
    return optishade::model_path::Select(Util::ExePath().parent_path(),g_dllDir);
}

// Loads the forwarder that owns the calls into the snippet.
bool EnsureForwarder()
{
    if (g_nr.forwarder != nullptr)
        return g_nr.create != nullptr && g_nr.evaluate != nullptr;

    if (g_dllDir.empty())
        g_dllDir = Util::DllPath().remove_filename();

    // Beside OptiScaler first, then beside the executable: someone dropping this into a game folder may
    // reasonably put it in either place.
    auto found = Util::FindFilePath(g_dllDir, "nvngx.dll_dlssnr.dll");

    if (!found.has_value())
        found = Util::FindFilePath(Util::ExePath().remove_filename(), "nvngx.dll_dlssnr.dll");

    if (!found.has_value())
    {
        LOG_ERROR("nvngx.dll_dlssnr.dll not found beside OptiScaler ({}) or the game executable",
                  g_dllDir.string());
        g_nr.reason = "nvngx.dll_dlssnr.dll is missing";
        return false;
    }

    // FindFilePath hands back the file itself, not the directory holding it.
    const auto path = found.value();
    g_nr.forwarder = LoadLibraryW(path.wstring().c_str());

    if (g_nr.forwarder == nullptr)
    {
        LOG_ERROR("nvngx.dll_dlssnr.dll found at {} but would not load, error {}", path.string(),
                  GetLastError());
        g_nr.reason = "nvngx.dll_dlssnr.dll would not load";
        return false;
    }

    g_nr.queryRatio = (int (*)(const wchar_t*, void*, unsigned int, float*)) GetProcAddress(
        g_nr.forwarder, "dlssnr_query_scaling_ratio");
    g_nr.lastRatioStage = (const int*) GetProcAddress(g_nr.forwarder, "dlssnr_last_ratio_stage");

    g_nr.create = (PFN_NrCreate) GetProcAddress(g_nr.forwarder, "dlssnr_call_create");
    g_nr.evaluate = (PFN_NrEvaluate) GetProcAddress(g_nr.forwarder, "dlssnr_call_evaluate_v2");
    g_nr.release = (PFN_NrRelease) GetProcAddress(g_nr.forwarder, "dlssnr_call_release");
    // Optional: an older forwarder simply lacks it, and the model runs as before.
    g_nr.setExtras = (PFN_NrSetExtras) GetProcAddress(g_nr.forwarder, "dlssnr_call_set_extras");
    g_nr.setFloatSlot = (PFN_NrSetFloatSlot) GetProcAddress(g_nr.forwarder, "dlssnr_call_set_float_slot");
    g_nr.probeFloat = (PFN_NrProbeFloat) GetProcAddress(g_nr.forwarder, "dlssnr_call_probe_float");
    g_nr.lastInit = (int*) GetProcAddress(g_nr.forwarder, "dlssnr_call_last_init");
    g_nr.lastCreate = (int*) GetProcAddress(g_nr.forwarder, "dlssnr_call_last_create");
    g_nr.lastModelError = (const char*(*)()) GetProcAddress(g_nr.forwarder, "dlssnr_call_error");

    if (g_nr.create == nullptr || g_nr.evaluate == nullptr)
    {
        g_nr.reason = "Update nvngx.dll_dlssnr.dll from the complete release (NR v2 exports required)";
        return false;
    }

    LOG_INFO("DLSS-NR forwarder loaded from {}", path.string());
    return true;
}

// The model needs the driver core's own capability block: it carries the snippet and preset callbacks a
// feature expects at create time, which a freshly allocated block does not have.
void DiscoverFloatSlot(NVSDK_NGX_Parameter* params);
void ReportScalingRatios();

bool EnsureCapabilityParams(ID3D12Device* device)
{
    auto identity = optishade::ReShadeDeviceIdentity(device);
    if (!identity) {
        g_nr.reason = "Neural backend device identity is unavailable";
        return false;
    }
    if (g_nr.capabilityParams != nullptr) {
        if (g_nr.capabilityDevice.Get() == identity.Get()) return true;
        g_nr.reason = "Neural runtime belongs to another device; restart before changing rendering devices";
        return false;
    }
    const auto caps = optishade::QueryD3D12Capabilities(device);
    LOG_INFO("Neural backend preflight: vendor={:04X}, device={:04X}, LUID={:08X}:{:08X}, native16={}, waves={}, health={:08X}",
        caps.vendor, caps.device, (UINT)caps.adapter.HighPart, caps.adapter.LowPart,
        optishade::EvidenceLabel(caps.native16), optishade::EvidenceLabel(caps.waves), (UINT)caps.health);
    if (const char* reason = optishade::NvidiaNeuralPreflight(caps)) {
        g_nr.reason = reason;
        return false;
    }

    if (!NVNGXProxy::IsDx12Inited() && !NVNGXProxy::InitDx12(device))
    {
        g_nr.reason = "the NGX core would not initialise";
        return false;
    }

    if (NVNGXProxy::D3D12_GetCapabilityParameters() == nullptr)
    {
        g_nr.reason = "the NGX core has no capability parameters";
        return false;
    }

    if (NVNGXProxy::D3D12_GetCapabilityParameters()(&g_nr.capabilityParams) != NVSDK_NGX_Result_Success ||
        g_nr.capabilityParams == nullptr)
    {
        g_nr.capabilityParams = nullptr;
        g_nr.reason = "the NGX core refused its capability parameters";
        return false;
    }

    g_nr.capabilityDevice = identity;

    // Before anything is written to it, work out where this block keeps floats.
    DiscoverFloatSlot(g_nr.capabilityParams);

    // Ask the model what scaling ratio it wants, once, for every quality level it might accept.
    //
    // Read-only and answered before any feature exists. The point is to find out whether NVIDIA's own
    // performance mode for this model is reachable: the snippet has ComputeScalingRatioCommon and the
    // kernel table has _ds, _upsample and _upsample_tilesync variants of every fused Swin block, which
    // together suggest the model can run its interior below display resolution natively -- rather than
    // being handed a picture we shrank ourselves, which costs an extra resample of the edit on the way
    // back and quantises the Swin grid to a lattice we chose rather than the one it was trained on.
    ReportScalingRatios();
    return true;
}

// What the model says it wants to run at, per quality level. Logged once, used for nothing yet.
//
// Answered by the snippet's own callback rather than chosen by us. If it answers, NVIDIA ships a
// performance mode for Neural Rendering and the resolution slider is a worse hand-rolled version of
// it. If it does not, the slider is all there is and that is worth knowing too.
void ReportScalingRatios()
{
    if (g_nr.queryRatio == nullptr || g_nr.capabilityParams == nullptr)
        return;

    auto snippet = FindSelectedModel();

    if (!snippet.has_value())
        return;

    static const char* kNames[] = { "MaxPerf",         "Balanced",    "MaxQuality",
                                    "UltraPerformance", "UltraQuality", "DLAA" };

    char line[512] = {};
    size_t used = 0;
    bool any = false;

    for (unsigned int q = 0; q < 6; ++q)
    {
        float ratio = -1.0f;
        const int rc = g_nr.queryRatio(snippet->wstring().c_str(), g_nr.capabilityParams, q, &ratio);
        int written = 0;

        if (rc == 1)
        {
            any = true;
            written = snprintf(line + used, sizeof(line) - used, "%s=%.4f ", kNames[q], ratio);
        }
        else if (rc == -1)
        {
            written = snprintf(line + used, sizeof(line) - used, "%s=refused ", kNames[q]);
        }

        if (written > 0)
            used += (size_t) written;
    }

    if (any)
        LOG_INFO("DLSS-NR the model's own scaling ratios: {}", line);
    else
        LOG_INFO("DLSS-NR scaling ratio callback not published by this snippet (stage {})",
                 g_nr.lastRatioStage != nullptr ? *g_nr.lastRatioStage : -1);
}

// Works out which vtable slot this parameter block keeps floats in, by writing a known value through
// each candidate and asking for it back through the header's typed getter. Only a slot that returns the
// value it was given is accepted.
//
// Slot 1 is where the public header declares the float overload, so it is tried first and wins wherever
// that assumption holds. It does not hold for the driver's own block: every float written there reads
// back as FAIL_UnsupportedParameter while every uint lands, which is why intensity, local structure,
// local tone and skin structure never did anything.
void DiscoverFloatSlot(NVSDK_NGX_Parameter* params)
{
    if (g_nr.floatSlotKnown || params == nullptr || g_nr.probeFloat == nullptr ||
        g_nr.setFloatSlot == nullptr)
        return;

    g_nr.floatSlotKnown = true;

    static const char* kProbeKey = "DLSSNR.OptiScalerFloatProbe";
    static const int kCandidates[] = { 1, 2, 5, 6, 7, 4, 3, 0 };
    const float expected = 0.375f; // exact in binary, so the round trip is exact or it is wrong

    for (int slot : kCandidates)
    {
        float readBack = 0.0f;
        g_nr.probeFloat(params, kProbeKey, expected, slot);

        if (params->Get(kProbeKey, &readBack) == NVSDK_NGX_Result_Success && readBack == expected)
        {
            g_nr.setFloatSlot(slot);
            LOG_INFO("DLSS-NR float parameters go through vtable slot {}", slot);
            return;
        }
    }

    LOG_ERROR("DLSS-NR could not find the float setter: intensity, local structure, local tone and skin "
              "structure will have no effect. The uint parameters still apply.");
}

// Switching inject points changes the surface format underneath the scratch set: the finished frame
// works in the swapchain's format, the pre-frame-generation path in the upscaler's. A stale set either
// clamps linear HDR into an 8-bit texture -- wrong brightness until something forces a rebuild -- or
// hands CopyResource mismatched formats, which fails silently and makes the whole pass appear to do
// nothing. So the set is torn down whenever the format it was built for is not the format needed now.
// Retired features/surfaces hold the exact recordings that could consume them.
// A frame counter, present count or time delay is never a release condition.
struct NrRetired
{
    void* feature = nullptr;
    ID3D12Resource* resource = nullptr;
    NVSDK_NGX_Parameter* parameters = nullptr;
    std::vector<optishade::nr_lifetime::Use> uses;
    // GPU work finished but the game never reset the list. Still parked and
    // released only on real retirement; it no longer blocks a rebuild.
    bool deferred = false;
};

// An idle previous model that is parked but no longer blocks creation.
static bool BlocksNrRebuild(const NrRetired& item) { return item.feature != nullptr && !item.deferred; }

#define g_nrRetired (optishade::route::OutputOwned<std::vector<NrRetired>,3>())

void ParkNrFeature(void*& feature)
{
    if (feature == nullptr)
        return;

    NrRetired r;
    optishade::nr_lifetime::Active().Collect();
    r.uses=optishade::nr_lifetime::Active().items;
    r.feature = feature;
    for (unsigned pass=0; pass<DlssNr::MaxPassCount; ++pass) {
        void*& owned = pass ? g_nr.passFeature[pass] : g_nr.feature;
        if (&owned == &feature) {
            // Lists closed before this model existed never recorded it. Without
            // this, one game list that is never reset again held every later
            // model parked until the parked-model limit stopped NR for good.
            auto& closed = g_nr.passBirthClosed[pass];
            std::erase_if(r.uses, [&](const optishade::nr_lifetime::Use& use) {
                return std::any_of(closed.begin(), closed.end(), [&](const auto& c) { return c.lock() == use; });
            });
            closed.clear();
            r.parameters = g_nr.passParams[pass];
            g_nr.passParams[pass] = nullptr;
            if (pass == 0)
                g_nr.featureFirstEvaluationPending = false;
            else
                g_nr.passFirstEvaluationPending[pass] = false;
            break;
        }
    }
    feature = nullptr;
    g_nrRetired.push_back(r);
}

// Called just before a model is created: remembers the game lists that are
// already submitted, which therefore cannot record this model.
void NoteNrModelBirth(unsigned pass)
{
    using Wait = optishade::nr_lifetime::Lease::Wait;
    auto& closed = g_nr.passBirthClosed[pass];
    closed.clear();
    optishade::nr_lifetime::Active().Collect();
    for (const auto& use : optishade::nr_lifetime::Active().items)
    {
        const auto state = use->State();
        if (state == Wait::InFlight || state == Wait::FinishedNotReset)
            closed.push_back(use);
    }
}

void ParkNrResource(ID3D12Resource*& res)
{
    if (res == nullptr)
        return;

    NrRetired r;
    optishade::nr_lifetime::Active().Collect();
    r.uses=optishade::nr_lifetime::Active().items;
    r.resource = res;
    res = nullptr;
    g_nrRetired.push_back(r);
}

void TickNrRetired()
{
    // Route changes can leave an idle private command list with no future Reset.
    // Its sole owner may retire it after its exact completion fence, without
    // relaxing the replay rules for game-owned command lists.
    DlssNr::RetireCompletedPrivateRecordings();
    for (size_t i = 0; i < g_nrRetired.size();)
    {
        if (!std::all_of(g_nrRetired[i].uses.begin(),g_nrRetired[i].uses.end(),[](const auto& use){return use->Ready();}))
        {
            ++i;
            continue;
        }

        if (g_nrRetired[i].feature != nullptr && g_nr.release != nullptr)
        {
            LOG_INFO("DLSS-NR retiring feature {:X} after {} GPU-use lease(s) completed",
                     reinterpret_cast<uintptr_t>(g_nrRetired[i].feature),
                     g_nrRetired[i].uses.size());
            g_nr.release(g_nrRetired[i].feature);
        }

        if (g_nrRetired[i].parameters != nullptr)
            if (auto destroy=NVNGXProxy::D3D12_DestroyParameters()) destroy(g_nrRetired[i].parameters);

        if (g_nrRetired[i].resource != nullptr)
            g_nrRetired[i].resource->Release();

        g_nrRetired.erase(g_nrRetired.begin() + i);
    }
}

// The inject point decides which buffer is being measured -- the upscaler's linear output or the
// finished frame in swapchain format -- so a reading taken before a change describes a different
// picture to one taken after. Everything else that depends on the format is invalidated here.
void ForgetCalibration()
{
    g_nr.calibCount = 0;
    g_nr.calibSuggestion = 0.0f;
    g_nr.calibSteadiness = 0.0f;
    g_nr.calibUsable = false;
    g_nr.calibWhy = "measuring...";
}

void ParkModelsAndSurfaces();

void ReleaseSurfacesIfFormatChanged(DXGI_FORMAT needed)
{
    if (g_nr.output == nullptr || g_nr.output->GetDesc().Format == needed)
        return;

    LOG_INFO("DLSS-NR rebuilding surfaces: format {} -> {} (inject point changed)",
             (int) g_nr.output->GetDesc().Format, (int) needed);

    ParkModelsAndSurfaces();
}

// Hands this output's models and format-dependent surfaces to the exact GPU
// retirement path (TickNrRetired frees each one after every lease that could
// reference it has completed). The next dispatch rebuilds what it needs.
void ParkModelsAndSurfaces()
{
    ForgetCalibration();

    ParkNrFeature(g_nr.feature);
    g_nr.featurePendingSubmission = false;

    // The extras go with it: they were built for this raster and this tuning too.
    for (unsigned int i = 1; i < DlssNr::MaxPassCount; ++i)
    {
        ParkNrFeature(g_nr.passFeature[i]);
        g_nr.passNeedsReset[i] = false;
        g_nr.passCreateFailed[i] = false;
        g_nr.passPendingSubmission[i] = false;
    }

    for (ID3D12Resource** r :
         { &g_nr.output, &g_nr.passScratch, &g_nr.colorCopy, &g_nr.hdrCopy, &g_nr.colorSmall,
           &g_nr.outputNative, &g_nr.activeColor, &g_nr.residualEdited,
           &g_nr.residualHistory[0], &g_nr.residualHistory[1],
           &g_nr.residualComposed })
        ParkNrResource(*r);
    g_nr.residualStoreValid = false;
    g_nr.residualHistoryPrimed = false;
    g_nr.residualHistoryIndex = 0;

    g_nr.passScratchFailed = false;

    g_nr.reset = true;
}

// Switching NR off used to keep every model and working surface for the rest
// of the session: roughly 0.5 GB per model, and VR builds one per eye plus the
// desktop mirror. On a card already at its video-memory limit Windows then
// keeps paging and the game stays slow until it is restarted. Once NR has been
// off for a short grace (a quick off/on does not pay for a rebuild), hand all
// of it to the same exact-retirement path a resolution change uses. Switching
// NR on again rebuilds as normal. 20 s: testers compare on/off every few
// seconds, and a 3 s grace rebuilt NR on each switch (a visible gap).
constexpr ULONGLONG kNrOffReleaseGraceMs = 20000;
void ReleaseWhileSwitchedOff()
{
    bool holding = g_nr.feature != nullptr || g_nr.output != nullptr || g_nr.depthClone != nullptr ||
                   g_nr.motionClone != nullptr || g_nr.heldColor != nullptr;
    for (unsigned int i = 1; i < DlssNr::MaxPassCount; ++i)
        holding = holding || g_nr.passFeature[i] != nullptr;
    auto& offSince = optishade::route::OutputOwned<NrEngineState,1>().switchedOffAt;
    const ULONGLONG now = GetTickCount64();
    if (holding)
    {
        if (!offSince)
            offSince = now;
        else if (now - offSince >= kNrOffReleaseGraceMs)
        {
            LOG_INFO("DLSS-NR switched off: releasing its models and working surfaces once the GPU has finished with them");
            ParkModelsAndSurfaces();
            // Not format-dependent, so ParkModelsAndSurfaces keeps them for a rebuild; while off they go too.
            for (ID3D12Resource** r : { &g_nr.depthClone, &g_nr.motionClone, &g_nr.heldColor })
                ParkNrResource(*r);
            g_nr.heldActive = false;
            offSince = 0;
        }
    }
    else
        offSince = 0;
    TickNrRetired();
}

void Barrier(ID3D12GraphicsCommandList* cmdList, ID3D12Resource* res, D3D12_RESOURCE_STATES from,
             D3D12_RESOURCE_STATES to);

// The meter's grid is R32_FLOAT, which makes a row exactly 64 * 4 = 256 bytes -- the alignment a
// texture-to-buffer copy demands, met without padding, so the readback is a flat array of floats.
constexpr unsigned int kMeterRowBytes = kDlssNrMeterGrid * sizeof(float);
constexpr unsigned int kMeterBytes = kMeterRowBytes * kDlssNrMeterGrid;

// Records the copy of this frame's grid into whichever readback buffer is furthest from being read.
// Same shape as the meter's copy, against the calibration surface and its own ring.
void CopyCalibrationToReadback(ID3D12GraphicsCommandList* cmdList)
{
    const unsigned int slot = (unsigned int) (g_nr.calibFrames % 4);

    if (g_nr.calibReadback[slot] == nullptr || g_nr.calib == nullptr)
        return;

    D3D12_TEXTURE_COPY_LOCATION srcLoc {};
    srcLoc.pResource = g_nr.calib;
    srcLoc.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    srcLoc.SubresourceIndex = 0;

    D3D12_TEXTURE_COPY_LOCATION dst {};
    dst.pResource = g_nr.calibReadback[slot];
    dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint.Offset = 0;
    dst.PlacedFootprint.Footprint.Format = DXGI_FORMAT_R32_FLOAT;
    dst.PlacedFootprint.Footprint.Width = kDlssNrMeterGrid;
    dst.PlacedFootprint.Footprint.Height = kDlssNrMeterGrid;
    dst.PlacedFootprint.Footprint.Depth = 1;
    dst.PlacedFootprint.Footprint.RowPitch = kMeterRowBytes;

    Barrier(cmdList, g_nr.calib, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    cmdList->CopyTextureRegion(&dst, 0, 0, 0, &srcLoc, nullptr);
    Barrier(cmdList, g_nr.calib, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

    g_nr.calibFrames++;
}

void CopyMeterToReadback(ID3D12GraphicsCommandList* cmdList, ID3D12Device* device,
                         bool exposureBound)
{
    const unsigned int slot = (unsigned int) (g_nr.meterFrames % 4);

    if (g_nr.meterReadback[slot] == nullptr)
        return;

    // Travels with the grid: read back three frames from now, alongside the tiles it describes.
    g_nr.meterExposureValid[slot] = exposureBound;

    D3D12_TEXTURE_COPY_LOCATION src {};
    src.pResource = g_nr.meter;
    src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    src.SubresourceIndex = 0;

    D3D12_TEXTURE_COPY_LOCATION dst {};
    dst.pResource = g_nr.meterReadback[slot];
    dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint.Offset = 0;
    dst.PlacedFootprint.Footprint.Format = DXGI_FORMAT_R32_FLOAT;
    dst.PlacedFootprint.Footprint.Width = kDlssNrMeterGrid;
    dst.PlacedFootprint.Footprint.Height = kDlssNrMeterGrid;
    dst.PlacedFootprint.Footprint.Depth = 1;
    dst.PlacedFootprint.Footprint.RowPitch = kMeterRowBytes;

    Barrier(cmdList, g_nr.meter, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    cmdList->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    Barrier(cmdList, g_nr.meter, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

    g_nr.meterFrames++;
}

// Takes the game's exposure out of tile 0 of the grid recorded three frames ago.
//
// Only tile 0 is written now. The frame-statistics meter this served was removed: a divisor measured
// off a frame this pass writes is a feedback loop rather than a measurement. What is left is a
// courier -- the game's exposure is a 1x1 texture in a resource state this pass did not set and must
// not transition, so the shader reads it as an SRV and it rides home on a readback that exists.
// Reads the calibration grid written four frames ago and turns it into one number.
//
// A high percentile of tile peaks, not the maximum: the maximum is a sun or a specular hit and would
// normalise the whole picture into the dark. The 90th percentile is high enough to sit at the top of
// the real range and common enough that no single highlight decides it.
void ConsumeCalibrationReadback()
{
    if (g_nr.calibFrames < 4)
        return;

    const unsigned int slot = (unsigned int) (g_nr.calibFrames % 4);
    ID3D12Resource* buffer = g_nr.calibReadback[slot];

    if (buffer == nullptr)
        return;

    void* mapped = nullptr;
    D3D12_RANGE range { 0, kMeterBytes };

    if (FAILED(buffer->Map(0, &range, &mapped)) || mapped == nullptr)
        return;

    const float* src = (const float*) mapped;

    std::vector<float> tiles;
    tiles.reserve(kDlssNrMeterGrid * kDlssNrMeterGrid);

    for (unsigned int i = 0; i < kDlssNrMeterGrid * kDlssNrMeterGrid; ++i)
    {
        if (std::isfinite(src[i]) && src[i] > 1e-6f)
            tiles.push_back(src[i]);
    }

    D3D12_RANGE nothingWritten { 0, 0 };
    buffer->Unmap(0, &nothingWritten);

    if (tiles.size() < 16)
        return;

    const size_t nth = (size_t) ((float) (tiles.size() - 1) * 0.90f);
    std::nth_element(tiles.begin(), tiles.begin() + nth, tiles.end());

    // How much of the frame carries light, measured against its own brightest tile rather than an
    // absolute threshold -- the units here are the game's and there is no absolute scale.
    //
    // This is what separates "the buffer is scaled by 240" from "I am standing in a dark cave". A
    // percentile of tile peaks is a statement about scene content; it only describes the buffer when
    // enough of the picture is lit for the top of the range to actually appear in it.
    float brightest = 0.0f;

    for (float v : tiles)
        brightest = std::max(brightest, v);

    unsigned int lit = 0;

    for (float v : tiles)
    {
        if (v > brightest * 0.10f)
            ++lit;
    }

    const float litFraction = tiles.empty() ? 0.0f : (float) lit / (float) tiles.size();

    // A torn readback survives isfinite and would clamp to exactly the ceiling, which since the
    // ceiling became 2000 is a value the slider can hold -- so a garbage frame could be offered as a
    // real answer. Reject rather than clamp.
    if (!(tiles[nth] > 0.0f) || tiles[nth] >= 1999.0f)
        return;

    const float suggestion = std::clamp(tiles[nth], 0.25f, 1990.0f);

    g_nr.calibUsable = !g_nr.calibPassthrough && litFraction > 0.20f;
    g_nr.calibWhy = g_nr.calibPassthrough  ? "this game hands over a frame it already tone mapped, so there is nothing to normalise"
                    : litFraction <= 0.20f ? "too little of this scene is lit to say where the top of the range is"
                                           : "";

    g_nr.calibHistory[g_nr.calibCount % NrState::kCalibHistory] = suggestion;
    g_nr.calibCount++;
    g_nr.calibSuggestion = suggestion;

    // Confidence is the spread of recent answers, not their absolute size. A number that has held
    // still for a second is one worth taking; one that is swinging means the scene is changing under
    // the measurement, and no single value would serve anyway.
    const unsigned int have = std::min<unsigned int>(g_nr.calibCount, NrState::kCalibHistory);

    if (have >= 8)
    {
        float lo = g_nr.calibHistory[0];
        float hi = g_nr.calibHistory[0];

        for (unsigned int i = 0; i < have; ++i)
        {
            lo = std::min(lo, g_nr.calibHistory[i]);
            hi = std::max(hi, g_nr.calibHistory[i]);
        }

        // A spread of 1.0x is perfect agreement and 2x or worse is none.
        const float spread = hi / lo;
        g_nr.calibSteadiness = std::clamp(1.0f - (spread - 1.0f), 0.0f, 1.0f);
    }
}

void ConsumeMeterReadback()
{
    if (g_nr.meterFrames < 4)
        return;

    const unsigned int slot = (unsigned int) (g_nr.meterFrames % 4);
    ID3D12Resource* buffer = g_nr.meterReadback[slot];

    if (buffer == nullptr)
        return;

    void* mapped = nullptr;
    D3D12_RANGE range { 0, sizeof(float) };

    if (FAILED(buffer->Map(0, &range, &mapped)) || mapped == nullptr)
        return;

    const float* src = (const float*) mapped;

    // Only believed when the frame that wrote this grid actually had an exposure texture bound. With
    // nothing bound DispatchPass substitutes the source picture, and tile 0 is then a scene pixel
    // rather than an exposure -- believing it made the white point follow the top-left corner of the
    // screen, which in Cyberpunk moved by up to 272x between frames and flashed the whole picture.
    //
    // When it is not believed gameExposure keeps its last good value, or stays 0 and lets
    // ResolveWhitePoint fall back to the slider, which is what a game supplying none should get.
    if (g_nr.meterExposureValid[slot] && std::isfinite(src[0]) && src[0] > 0.0f)
        g_nr.gameExposure = src[0];

    D3D12_RANGE nothingWritten { 0, 0 };
    buffer->Unmap(0, &nothingWritten);
}

// Forget everything the meter knows, so nothing read before this moment can be believed after it.
//
// The exposure is written only inside the block that dispatches the meter, and that block does not
// run while the option is off. Nothing used to clear any of this when it stopped, so the reading
// simply froze: switching the option back on returned the value from whenever it was switched off,
// and ResolveWhitePoint took it as current because a held value is exactly what it expects to see.
// GTA V's exposure spans 0.127 to 0.511 in one session, so re-enabling in different light handed the
// encode a white point up to 4x wrong -- which trips the soft knee, scales the model's answer away
// and leaves its hue behind. That is the colour cast, and it looked random because it depends on the
// light at the moment of the PREVIOUS switch-off, which nothing on screen shows.
//
// The readback ring made it worse. `meterFrames` also only advances inside that block, so the four
// slots kept their contents and their valid flags across the gap, and the first frames after
// re-enabling consumed buffers written before it as though they had just arrived.
//
// Zero is not a fallback value here, it is the absence of one: ResolveWhitePoint's `> 1e-6f` guard
// fails and the manual slider is used, which is what a game supplying no exposure already gets.
void InvalidateExposureMeter()
{
    g_nr.gameExposure = 0.0f;

    for (bool& valid : g_nr.meterExposureValid)
        valid = false;

    // Re-arms the `< 4` guard in ConsumeMeterReadback, so nothing is read back until four frames
    // have genuinely been queued since this point.
    g_nr.meterFrames = 0;
}

// Turns what the meter saw into the divisor the encode uses, or falls back to the slider.
//
// `cut` says the exposure may jump rather than drift, and it is the difference between this working
// and not. GTA V's character switch pulls the camera up through the sky: a linear HDR buffer's sky is
// tens of times brighter than the ground, the proxy clips to flat white, and the frame blows out until
// the camera comes back down. Easing across that at two percent a frame takes three and a half
// seconds, which is longer than the transition -- so a meter that only eases would lag through the
// whole thing and fix nothing.
//
// So a cut snaps and a drift eases. Walking out of a cave is a drift; a camera cut is not, and
// pretending otherwise to avoid pumping just moves the failure somewhere more visible.
float ResolveWhitePoint(const Config& cfg, bool isHdrBuffer)
{
    const float slider = cfg.DlssNrWhitePointScale.value_or_default();

    // A frame the game already tone mapped is display-referred: white is at 1 by definition and there
    // is nothing to measure. The slider stays available as a manual exposure on that path.
    if (!isHdrBuffer)
        return slider;

    // The game's own exposure, where it supplies one.
    //
    // Exposure is the step that makes a cave and a field comparable: the renderer works in arbitrary
    // scene-referred units and multiplies by this before tone mapping, which is precisely why one
    // fixed paper white cannot serve both. FSR spells the relationship out -- frame / preExposure *
    // exposure -- so undoing it gives the divisor this pass wants, and paper white becomes a constant
    // on top rather than a value chasing the scene.
    //
    // Unlike anything measured off the frame this cannot be moved by what the pass writes, which is
    // what killed the statistical meter. It is the game's number, decided upstream.
    //
    // Held across the frames where the texture is absent -- GTA V dropped it three times in one
    // session -- because falling back to a default on those frames is a flicker, not a fallback.
    // The scan's anchor, where the game supplies no exposure of its own.
    //
    // Only ratios are used, so the units of the buffer never have to be known -- which is the whole
    // reason this is anchored rather than absolute. The anchor is the user's own white point at the
    // moment they pressed the button; everything after that is the scan moving it.
    //
    // Deliberately below the exposure texture in priority and mutually exclusive with it in the
    // menu. A game that hands over a real exposure has no business being driven by a buffer found by
    // its shape, and two sources fighting over one number is the class of bug worth making
    // unreachable rather than merely unlikely.
    if (cfg.DlssNrWhitePointSource.value_or_default() == 2)
    {
        // Multi-point: one or more calibration points the user placed, interpolated in log space by
        // the current scan value. One point is the original ratio law; more fit the buffer's actual
        // relationship so the white point holds across the whole range, not only near one anchor.
        const float w = DlssNr::ExposureScan::AnchoredWhitePoint(
            DlssNr::ExposureScan::BestValue(), cfg.DlssNrScanInverted.value_or_default(),
            cfg.DlssNrScanTrim.value_or_default());

        if (w > 0.0f)
            return w;
    }

    if (cfg.DlssNrWhitePointSource.value_or_default() == 1 && g_nr.gameExposure > 1e-6f)
    {
        // Its own setting, not the manual divisor. See Config: they are different quantities with
        // different units and different sensible ranges, and sharing one value meant adjusting the
        // trim destroyed the divisor somebody had found by hand.
        //
        // Still bounded at the point of use rather than only in the menu that draws it.
        //
        // Bounding it at the slider would have been cosmetic: someone who found 64 by hand on the
        // manual path and then switched the exposure source on keeps that 64 in their ini, and the
        // composition would go on reading it until they happened to touch the control. The picture
        // would be wrong for a reason the menu was no longer showing.
        //
        // Their value is left in the config untouched, so switching back to manual restores the
        // number they arrived at. It is only what this path consumes that is limited.
        const float trim = std::clamp(cfg.DlssNrWhitePointTrim.value_or_default(), 0.25f, 4.0f);

        return std::clamp(g_nr.gamePreExposure / g_nr.gameExposure * trim, 0.01f, 4096.0f);
    }

    // Otherwise the slider, and only the slider.
    //
    // Measuring white from the frame was tried and removed. It could not be made to work because the
    // pass writes the frame it measures: in Enshrouded one session walked the divisor from 0.010 to
    // 97.910, and toggling NR at a fixed spot read 41.31 off and 0.46 on. Two attempts to damp it --
    // a relative lit threshold, then a rate limit with a cut snap -- both treated a coupled system as
    // a noisy one and neither held. A constant cannot do that, which is the whole argument for it,
    // and is what RenoDX has always done.
    return slider;
}

ID3D12Resource* CreateScratch(ID3D12Device* device, DXGI_FORMAT format, unsigned int width,
                              unsigned int height)
{
    D3D12_HEAP_PROPERTIES heap {};
    heap.Type = D3D12_HEAP_TYPE_DEFAULT;

    D3D12_RESOURCE_DESC desc {};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = width;
    desc.Height = height;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.Format = format;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    // The model writes its result, so the destination has to be a UAV.
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;

    ID3D12Resource* res = nullptr;
    device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
                                    D3D12_RESOURCE_STATE_UNORDERED_ACCESS, nullptr, IID_PPV_ARGS(&res));
    return res;
}

void Barrier(ID3D12GraphicsCommandList* cmdList, ID3D12Resource* res, D3D12_RESOURCE_STATES from,
             D3D12_RESOURCE_STATES to)
{
    if (from == to)
        return;

    D3D12_RESOURCE_BARRIER b {};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = res;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = from;
    b.Transition.StateAfter = to;
    cmdList->ResourceBarrier(1, &b);
}

// A typeless resource cannot be viewed, and NGX builds its own views with nothing to tell it which
// format to use. Depth is very often declared typeless, so the typed member of the same family is
// substituted; CopyResource accepts that as a destination for the typeless original.
DXGI_FORMAT TypedGuideFormat(DXGI_FORMAT f)
{
    switch (f)
    {
    case DXGI_FORMAT_R32_TYPELESS:
        return DXGI_FORMAT_R32_FLOAT;
    case DXGI_FORMAT_R16_TYPELESS:
        return DXGI_FORMAT_R16_UNORM;
    case DXGI_FORMAT_R24G8_TYPELESS:
        return DXGI_FORMAT_R24_UNORM_X8_TYPELESS;
    case DXGI_FORMAT_R32G8X24_TYPELESS:
        return DXGI_FORMAT_R32_FLOAT_X8X24_TYPELESS;
    case DXGI_FORMAT_R32G32_TYPELESS:
        return DXGI_FORMAT_R32G32_FLOAT;
    case DXGI_FORMAT_R16G16_TYPELESS:
        return DXGI_FORMAT_R16G16_FLOAT;
    case DXGI_FORMAT_R8G8B8A8_TYPELESS:
        return DXGI_FORMAT_R8G8B8A8_UNORM;
    case DXGI_FORMAT_R16G16B16A16_TYPELESS:
        return DXGI_FORMAT_R16G16B16A16_FLOAT;
    default:
        return f;
    }
}

bool IsTypeless(DXGI_FORMAT f) { return TypedGuideFormat(f) != f; }

// Creates a typed twin of a guide buffer, matching everything but the format.
ID3D12Resource* CreateGuideClone(ID3D12Device* device, ID3D12Resource* source)
{
    D3D12_RESOURCE_DESC desc = source->GetDesc();
    desc.Format = TypedGuideFormat(desc.Format);
    desc.Flags = D3D12_RESOURCE_FLAG_NONE;

    D3D12_HEAP_PROPERTIES heap {};
    heap.Type = D3D12_HEAP_TYPE_DEFAULT;

    ID3D12Resource* res = nullptr;
    device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_COPY_DEST,
                                    nullptr, IID_PPV_ARGS(&res));
    return res;
}

// Hands back something the model can actually read: the guide itself when it is typed, or a typed copy
// of it when it is not. NGX requires its inputs in NON_PIXEL_SHADER_RESOURCE at evaluate time, which is
// a documented contract rather than a guess about any one game's frame graph, so that is the state
// transitioned away from and back to here.
// Freezing is a diagnostic, and it reuses this function because the clone it already keeps is
// exactly the thing a frozen guide is: a private copy the model reads instead of the live resource.
// Freezing is then not a new mechanism but the absence of one -- stop refreshing the copy.
//
// A frozen guide is valid data that is wrong for this frame, which is a far better probe than a
// constant would be. A constant is degenerate and a model may special-case it; stale depth is
// ordinary depth that simply disagrees with the picture, and anything reading it has to notice.
// Hands back something the model can actually read: the guide itself when it is typed, or a typed
// copy of it when it is not. NGX requires its inputs in NON_PIXEL_SHADER_RESOURCE at evaluate time,
// which is a documented contract rather than a guess about any one game's frame graph, so that is
// the state transitioned away from and back to here.
ID3D12Resource* ReadableGuide(ID3D12Device* device, ID3D12GraphicsCommandList* cmdList,
                              ID3D12Resource* source, ID3D12Resource** clone)
{
    if (source == nullptr || !IsTypeless(source->GetDesc().Format))
        return source;

    // A dynamic-resolution game reallocates its depth and motion vectors as the render size moves, so
    // the clone made for the old size no longer matches -- and CopyResource demands identical
    // dimensions. Copying a 1970x1108 source into a 984x554 clone is undefined and removes the device,
    // which is the DRS crash. Rebuild the clone whenever the source's shape has changed under it.
    if (*clone != nullptr)
    {
        const D3D12_RESOURCE_DESC have = (*clone)->GetDesc();
        const D3D12_RESOURCE_DESC want = source->GetDesc();

        if (have.Width != want.Width || have.Height != want.Height ||
            have.Format != TypedGuideFormat(want.Format))
        {
            // Retired, not released: the previous copy may still be in flight on the game's queue.
            ParkNrResource(*clone);
        }
    }

    if (*clone == nullptr)
    {
        *clone = CreateGuideClone(device, source);

        if (*clone == nullptr)
            return nullptr;

        LOG_DEBUG("DLSS-NR cloned a typeless guide as format {}",
                  (int) TypedGuideFormat(source->GetDesc().Format));
    }

    Barrier(cmdList, source, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
            D3D12_RESOURCE_STATE_COPY_SOURCE);
    cmdList->CopyResource(*clone, source);
    Barrier(cmdList, source, D3D12_RESOURCE_STATE_COPY_SOURCE,
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Barrier(cmdList, *clone, D3D12_RESOURCE_STATE_COPY_DEST,
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    return *clone;
}

// The upscaler's own names differ between super resolution and ray reconstruction, and only one set is
// present on any given block.
// Whether a surface can physically hold linear HDR.
//
// Only a float format can: linear light is open-ended and runs far past 1.0, which a normalised
// integer surface cannot represent. An 8-bit UNORM frame is finished, display-referred output, and
// so is a 10-bit one -- HDR10 is PQ-encoded, which is display-referred too.
//
// The game's IsHDR flag is a statement of intent that is not always true, and believing it over a
// format that cannot hold linear light means encoding an already-encoded frame a second time.
bool FormatCanHoldLinearHdr(DXGI_FORMAT format)
{
    switch (format)
    {
    case DXGI_FORMAT_R16G16B16A16_FLOAT:
    case DXGI_FORMAT_R16G16B16A16_TYPELESS:
    case DXGI_FORMAT_R32G32B32A32_FLOAT:
    case DXGI_FORMAT_R32G32B32A32_TYPELESS:
    case DXGI_FORMAT_R32G32B32_FLOAT:
    case DXGI_FORMAT_R11G11B10_FLOAT:
        return true;
    default:
        return false;
    }
}

ID3D12Resource* GetResource(NVSDK_NGX_Parameter* params, const char* a, const char* b)
{
    ID3D12Resource* res = nullptr;

    if (params->Get(a, &res) == NVSDK_NGX_Result_Success && res != nullptr)
        return res;

    res = nullptr;

    if (params->Get(b, &res) == NVSDK_NGX_Result_Success && res != nullptr)
        return res;

    // The same key again, as a plain pointer.
    //
    // NVSDK_NGX_Parameter has a typed setter per resource kind and an untyped one, and on a real NGX
    // parameter block those are separate slots: what goes in through Set(name, void*) does not come
    // back out of Get(name, ID3D12Resource**). A game running its own D3D12 upscaler sets these
    // typed, so the typed read above is enough and always was.
    //
    // Both of OptiScaler's bridges write them untyped. IFeature_Dx11wDx12 and IFeature_VkwDx12 turn
    // the game's D3D11 textures or Vulkan images into D3D12 resources and hand them over with
    // Set(name, (void*) resource) -- so the typed read came back null a few lines after the resource
    // had been written, and the pass quietly did nothing. That is the whole reason this never ran in
    // a DirectX 11 or Vulkan game.
    void* untyped = nullptr;

    if (params->Get(a, &untyped) == NVSDK_NGX_Result_Success && untyped != nullptr)
        return static_cast<ID3D12Resource*>(untyped);

    untyped = nullptr;

    if (params->Get(b, &untyped) == NVSDK_NGX_Result_Success && untyped != nullptr)
        return static_cast<ID3D12Resource*>(untyped);

    return nullptr;
}

// A change has to hold still before it is acted on: a slider being dragged reports a new value every
// frame, and each one would otherwise mean a new model.
constexpr unsigned long long kSettleFrames = 30;

// The extras the official integration sets: global tone (read at create) and the interface inputs.
// Written before every create and evaluate, nulls included, so nothing stale ever sits in the block.
void SetExtras(const Config& cfg, ID3D12Resource* ui, ID3D12Resource* backbuffer, unsigned int uiWidth,
               unsigned int uiHeight, unsigned int bbWidth, unsigned int bbHeight, NVSDK_NGX_Parameter* parameters = nullptr)
{
    if (!parameters) parameters = g_nr.capabilityParams;
    if (g_nr.setExtras == nullptr || parameters == nullptr)
        return;

    // Global tone is written at the model's own default: the control that exposed it changed nothing
    // that could be seen, and the block persists, so a value still has to be put there.
    g_nr.setExtras(parameters, 1.0f, ui, ui, backbuffer,
                   uiWidth, uiHeight, bbWidth, bbHeight);
}


// Do not reuse the capability/query table as mutable per-pass state. The model
// writes resource, tuning and history keys while evaluating; another feature
// must never overwrite those keys before the first feature is retired.
bool EnsurePassParameters(unsigned pass) {
    if (pass >= DlssNr::MaxPassCount) return false;
    if (g_nr.passParams[pass]) return true;
    const auto get=NVNGXProxy::D3D12_GetCapabilityParameters();
    if (!get || get(&g_nr.passParams[pass]) != NVSDK_NGX_Result_Success || !g_nr.passParams[pass]) {
        g_nr.failed=true;g_nr.reason="The NGX core could not allocate an independent model-pass parameter table";
        return false;
    }
    DiscoverFloatSlot(g_nr.passParams[pass]);
    return true;
}

bool TuningMatchesFeature(const Config& cfg, unsigned int requestedPasses)
{
    for (unsigned int pass = 0; pass < requestedPasses; ++pass)
    {
        // A profile cannot be stale until its feature exists. This lets a user prepare pass 2 or 3
        // while running fewer layers without needlessly rebuilding pass 1.
        if (pass > 0 && g_nr.passFeature[pass] == nullptr)
            continue;

        if (g_nr.builtPassTuning[pass] != PassTuning(cfg, pass) ||
            g_nr.builtPreset[pass] != PassPreset(cfg, pass) ||
            g_nr.builtStyle[pass] != PassStyle(cfg, pass))
            return false;
    }

    return true;
}

void RecordBuiltPrimaryTuning(const Config& cfg)
{
    g_nr.builtPassTuning[0] = PassTuning(cfg, 0);
    g_nr.builtPreset[0] = PassPreset(cfg, 0);
    g_nr.builtIntensity = cfg.DlssNrIntensity.value_or_default();
    g_nr.builtStyle[0] = PassStyle(cfg, 0);
    g_nr.builtLocalStructure = cfg.DlssNrLocalStructure.value_or_default();
    g_nr.builtLocalTone = cfg.DlssNrLocalTone.value_or_default();
    g_nr.builtSkinStructure = cfg.DlssNrSkinStructure.value_or_default();
    g_nr.builtAutoMask = cfg.DlssNrAutoMask.value_or_default();
}

// Render work is serialized; driver submission/reset callbacks enqueue without
// waiting for this state, avoiding the NR -> DXGI -> NR lock inversion.
optishade::nr::DeferredEvents<DlssNr::NrSubmissionEvent> g_nrEvents(DlssNr::ConsumeNrSubmissionEvent);
#define g_nrDeviceLost (optishade::route::OutputOwned<NrMemoryState,4>().deviceLost)
#define g_memoryPressureStopped (optishade::route::OutputOwned<NrMemoryState,4>().stopped)
#define g_memoryCheck (optishade::route::OutputOwned<NrMemoryState,4>().check)
static OptiShadeLog::ReasonLimits<3> g_memoryLogs;
#define g_memoryLow (optishade::route::Owned<NrMemoryWarningState,26>().low)

// Runs the pass inside the same state envelope every other OptiScaler compute pass runs in.
//
// The upscaler's own evaluate is wrapped like this by TryEvaluateOptiFeature: root-signature tracking
// off so the hooks do not record the pass's binds as the game's, heap capture skipped, and RestoreRoot
// afterwards to put the game's compute state back. Neural Rendering ran outside that envelope -- after
// the upscaler had already restored and re-armed -- so it left its own root signature and descriptor
// heaps bound and captured. On an ordinary engine the game rebinds and never notices. On a bindless
// engine (007 First Light, Monster Hunter Wilds, and the rest of the RestoreComputeSig* quirks) the
// game resumes off the pass's bindings and the device is removed.
//
// As RAII so every early return from the pass is covered. RestoreRoot is gated internally on the
// RestoreComputeSignature / RestoreGraphicSignature config, so this is a no-op on games that do not
// ask for it and only acts where it is needed.
struct ScopedNrStateEnvelope
{
    ID3D12GraphicsCommandList* cmd;
    ScopedSkipHeapCapture skipHeap;
    bool restore;

    explicit ScopedNrStateEnvelope(ID3D12GraphicsCommandList* c, bool independent=false) : cmd(c), restore(!independent)
    {
        D3D12Hooks::SetRootSignatureTracking(false);
    }

    ~ScopedNrStateEnvelope()
    {
        if (restore) D3D12Hooks::RestoreRoot(cmd);
        D3D12Hooks::SetRootSignatureTracking(true);
    }
};

// Missing inputs can be normal, so don't emit one line per rendered frame. Keep
// the first reason and periodically repeat it while the same condition persists:
// one line at onset, then one every five seconds, with recovery recorded too.
// This makes long NR gaps visible in a tester export without flooding the log.
struct NrSkipStall { std::string reason; uint64_t firstAt=0,lastReportAt=0,count=0; };
NrSkipStall& CurrentNrSkipStall() { static NrSkipStall stall; return stall; }
std::mutex& NrSkipStallMutex() { static std::mutex mutex; return mutex; }

void ReportSkipOnce(const char* reason)
{
    const uint64_t now=GetTickCount64();
    std::string text=reason?reason:"unspecified NR skip";
    uint64_t duration=0,count=0;
    bool report=false;
    {
        std::lock_guard lock(NrSkipStallMutex());
        auto& stall=CurrentNrSkipStall();
        if(stall.reason!=text){stall={text,now,0,0};}
        ++stall.count;
        duration=now-stall.firstAt;count=stall.count;
        if(!stall.lastReportAt||now-stall.lastReportAt>=5000){
            stall.lastReportAt=now;report=true;
        }
    }
    if(!report)return;
    const auto observation=optishade::nr_observation::State().Read(now);
    if(duration<5000){
        LOG_INFO("DLSS-NR pass skipped: reason='{}' (first occurrence; repeated reports are rate-limited)",text);
        return;
    }
    LOG_WARN("DLSS-NR stall/skip: reason='{}' repeats={} duration_ms={} requested={} failed_latched={} retired_items={} last_successful_dispatches={} last_completed_frame={} last_submitted_frame={} completion_age_ms={} fence_signal_failed={}",
        text,count,duration,observation.requested,g_nr.failed,g_nrRetired.size(),g_nr.successfulDispatches,
        observation.completedFrame,observation.submittedFrame,observation.age,observation.fenceSignalFailed);
    optishade::session::State().PutCritical({{"NRStallState","Blocked"},{"NRStallReason",text},
        {"NRStallRepeatCount",std::to_string(count)},{"NRStallDurationMs",std::to_string(duration)},
        {"NRStallFailedLatched",g_nr.failed?"true":"false"},
        {"NRStallRetiredItems",std::to_string(g_nrRetired.size())},
        {"NRStallSuccessfulDispatches",std::to_string(g_nr.successfulDispatches)},
        {"NRStallLastCompletedFrame",std::to_string(observation.completedFrame)},
        {"NRStallLastSubmittedFrame",std::to_string(observation.submittedFrame)},
        {"NRStallCompletionAgeMs",std::to_string(observation.age)},
        {"NRStallFenceSignalFailed",observation.fenceSignalFailed?"true":"false"}});
}

void ReportNrRecovered()
{
    std::string reason;uint64_t duration=0,count=0;
    {
        std::lock_guard lock(NrSkipStallMutex());
        auto& stall=CurrentNrSkipStall();
        if(stall.reason.empty())return;
        reason=stall.reason;duration=GetTickCount64()-stall.firstAt;count=stall.count;stall={};
    }
    if(duration<5000)return;
    LOG_INFO("DLSS-NR resumed after skip: reason='{}' repeats={} duration_ms={} successful_dispatches={}",
        reason,count,duration,g_nr.successfulDispatches);
    optishade::session::State().PutCritical({{"NRStallState","Recovered"},{"NRStallReason",reason},
        {"NRStallRepeatCount",std::to_string(count)},{"NRStallDurationMs",std::to_string(duration)},
        {"NRStallSuccessfulDispatches",std::to_string(g_nr.successfulDispatches)}});
}

} // namespace

// ---------------------------------------------------------------------------------------------
// The pass itself. Everything above is what it is made of; everything below is the shape the rest
// of OptiScaler sees.
// ---------------------------------------------------------------------------------------------

DlssNr_Dx12::DlssNr_Dx12(std::string InName, ID3D12Device* InDevice)
    : Shader_Dx12(InName, InDevice)
{
    if (InDevice == nullptr)
    {
        LOG_ERROR("InDevice is nullptr!");
        return;
    }

    LOG_DEBUG("{0} start!", _name);

    // Five inputs, two outputs, one constant buffer, and a clamped linear sampler.
    //
    // The sampler exists because the model may be run below full resolution, in which case its answer
    // has to be read back at a different size from the frame it is being transferred onto.
    D3D12_STATIC_SAMPLER_DESC sampler {};
    sampler.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    sampler.AddressU = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.AddressV = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;

    if (!SetupRootSignature(InDevice, kSrvCount, kUavCount, 1, 0, 0, 1, &sampler))
    {
        LOG_ERROR("[{0}] Failed to setup root signature", _name);
        return;
    }

    // Precompiled, with no source fallback. The shader used to be compiled at runtime from a string,
    // which would have meant no shader at all for anyone leaving UsePrecompiledShaders at its
    // default.
    if (!CreateComputePipeline(InDevice, &_pipelineState, DlssNr_cso, sizeof(DlssNr_cso), nullptr))
    {
        LOG_ERROR("[{0}] Failed to create the compute pipeline", _name);
        return;
    }

    // Second PSO for the ResidualAcrossRR v2 accumulator (its own blob, same root signature).
    // A failure here is not fatal to the class -- only that experimental mode goes unavailable.
    if (!CreateComputePipeline(InDevice, &_residualPipelineState, dlssnr_residual_cso,
                               sizeof(dlssnr_residual_cso), nullptr))
    {
        _residualPipelineState = nullptr;
        LOG_WARN("[{0}] ResidualAcrossRR compute pipeline unavailable", _name);
    }

    _init = GrowHeaps(DLSSNR_NUM_OF_HEAPS);
}

// Adds descriptor heaps and their constant buffers. Slots below _heapCount are
// never moved or freed while the shader lives, so leased slots stay valid.
bool DlssNr_Dx12::GrowHeaps(unsigned add)
{
    if(!_device||_heapCount>=DLSSNR_MAX_HEAPS)return false;
    const unsigned first=_heapCount,last=std::min<unsigned>(DLSSNR_MAX_HEAPS,_heapCount+add);
    D3D12_RESOURCE_DESC desc = CD3DX12_RESOURCE_DESC::Buffer(sizeof(DlssNrConstants));
    auto heapProps = CD3DX12_HEAP_PROPERTIES(D3D12_HEAP_TYPE_UPLOAD);
    for (unsigned i = first; i < last; ++i)
    {
        auto result = _device->CreateCommittedResource(&heapProps, D3D12_HEAP_FLAG_NONE, &desc,
                                                       D3D12_RESOURCE_STATE_GENERIC_READ, nullptr,
                                                       IID_PPV_ARGS(&_constantBuffers[i]));
        if (result != S_OK)
        {
            LOG_ERROR("[{0}] CreateCommittedResource error {1:x}", _name, (unsigned int) result);
            return false;
        }
        if (!InitHeaps(_device, &_frameHeaps[i], 1)) return false;
        _heapCount = i + 1;
    }
    return true;
}

void DlssNr_Dx12::CollectBindings()
{
    for(unsigned i=0;i<_heapCount;++i)
        if(_bindingLeases[i]&&_bindingLeases[i]->Ready()){
            _bindingObjects[i].clear();_bindingLeases[i].reset();
        }
}

bool DlssNr_Dx12::ReserveBatch(ID3D12GraphicsCommandList* cmd,unsigned count)
{
    if(_batchActive||!count||count>_reservedSlots.size())return false;
    optishade::nr_lifetime::Collect();
    unsigned found=0;
    for(unsigned i=0;i<_heapCount&&found<count;++i)
        if(!_bindingLeases[i]||_bindingLeases[i]->Ready())_reservedSlots[found++]=i;
    // Every slot is still leased to a list the game has not reset: add slots
    // instead of skipping this frame's NR.
    while(found<count&&_heapCount<DLSSNR_MAX_HEAPS){
        const unsigned before=_heapCount;
        if(!GrowHeaps(DLSSNR_HEAP_GROWTH)&&_heapCount==before)break;
        LOG_INFO("DLSS-NR binding pool grown to {} slots (max {}): the game keeps NR's command lists longer before resetting them",
                 _heapCount,DLSSNR_MAX_HEAPS);
        for(unsigned i=before;i<_heapCount&&found<count;++i)_reservedSlots[found++]=i;
    }
    if(found!=count)return false;
    auto lease=optishade::nr_lifetime::Capture(cmd);
    if(!lease||!optishade::nr_lifetime::Active().Add(lease))return false;
    for(unsigned n=0;n<count;++n){auto i=_reservedSlots[n];_bindingObjects[i].clear();_bindingLeases[i]=lease;}
    _reservedCount=count;_reservedUsed=0;_batchActive=true;return true;
}
void DlssNr_Dx12::EndBatch()
{
    // Unused reservations were never recorded and may be returned immediately.
    for(unsigned n=_reservedUsed;n<_reservedCount;++n)_bindingLeases[_reservedSlots[n]].reset();
    _reservedCount=_reservedUsed=0;_batchActive=false;
}
int DlssNr_Dx12::AcquireBinding(ID3D12GraphicsCommandList* cmd)
{
    if(_batchActive)return _reservedUsed<_reservedCount?int(_reservedSlots[_reservedUsed++]):-1;
    if(!ReserveBatch(cmd,1))return -1;
    int slot=int(_reservedSlots[_reservedUsed++]);EndBatch();return slot;
}
void DlssNr_Dx12::RetainBinding(unsigned slot,std::initializer_list<IUnknown*> objects)
{
    auto& held=_bindingObjects[slot];for(auto* object:objects)if(object)held.emplace_back(object);
}

bool DlssNr_Dx12::DispatchPass(ID3D12GraphicsCommandList* InCmdList, const DlssNrConstants& InConstants,
                                  ID3D12Resource* InSource, ID3D12Resource* InModel,
                                  ID3D12Resource* InOriginal, ID3D12Resource* InMotion,
                                  ID3D12Resource* InPrevEdit, ID3D12Resource* OutTarget,
                                  ID3D12Resource* OutKeep)
{
    if (!_init || InCmdList == nullptr || _device == nullptr || InSource == nullptr || OutTarget == nullptr)
        return false;

    const int acquired = AcquireBinding(InCmdList);
    if(acquired<0)return false;
    const uint32_t slot=static_cast<uint32_t>(acquired);
    RetainBinding(slot,{InSource,InModel,InOriginal,InMotion,OutTarget,
        _frameHeaps[slot].GetHeapCSU(),_constantBuffers[slot],_rootSignature});

    FrameDescriptorHeap& currentHeap = _frameHeaps[slot];

    // Every slot in the table gets a view, whether the mode reads it or not. An unbound descriptor is
    // not an empty read; it is a read from nothing, and the source stands in wherever a mode has
    // nothing of its own to put there.
    ID3D12Resource* const srvs[kSrvCount] = {
        InSource,
        InModel != nullptr ? InModel : InSource,
        InOriginal != nullptr ? InOriginal : InSource,
        InMotion != nullptr ? InMotion : InSource,
        InPrevEdit != nullptr ? InPrevEdit : InSource,
    };

    for (uint32_t i = 0; i < kSrvCount; ++i)
        CreateShaderResourceView(_device, srvs[i], currentHeap.GetSrvCPU(i));

    ID3D12Resource* const uavs[kUavCount] = {
        OutTarget,
        OutKeep != nullptr ? OutKeep : OutTarget,
    };

    for (uint32_t i = 0; i < kUavCount; ++i)
        CreateUnorderedAccessView(_device, uavs[i], currentHeap.GetUavCPU(i), 0);

    if (!CreateConstantsBuffer(_device, _constantBuffers[slot], InConstants, currentHeap.GetCbvCPU(0)))
    {
        LOG_ERROR("[{0}] Failed to create a constants buffer", _name);
        return false;
    }

    RetainBinding(slot,{InPrevEdit,OutKeep,_pipelineState});
    ID3D12DescriptorHeap* heaps[] = { currentHeap.GetHeapCSU() };
    InCmdList->SetDescriptorHeaps(_countof(heaps), heaps);
    InCmdList->SetComputeRootSignature(_rootSignature);
    InCmdList->SetPipelineState(_pipelineState);
    InCmdList->SetComputeRootDescriptorTable(0, currentHeap.GetTableGPUStart());

    // Sized from the constants rather than from a resource, because the pass that shrinks the proxy
    // writes fewer pixels than its source has.
    const UINT dispatchWidth = (InConstants.Width + _numThreadsX - 1) / _numThreadsX;
    const UINT dispatchHeight = (InConstants.Height + _numThreadsY - 1) / _numThreadsY;
    InCmdList->Dispatch(dispatchWidth, dispatchHeight, 1);

    return true;
}

DlssNr_Dx12::~DlssNr_Dx12()
{
    for(unsigned i=0;i<_heapCount;++i)
        optishade::nr_lifetime::Hold(std::move(_bindingLeases[i]),std::move(_bindingObjects[i]));
    if (_finishedColorPipelineState)
        _finishedColorPipelineState->Release();
    for (auto& buffer : _constantBuffers)
    {
        if (buffer != nullptr)
        {
            buffer->Release();
            buffer = nullptr;
        }
    }

    if (_residualPipelineState != nullptr)
    {
        _residualPipelineState->Release();
        _residualPipelineState = nullptr;
    }
}

bool DlssNr_Dx12::DispatchResidualPass(ID3D12GraphicsCommandList* InCmdList,
                                       const DlssNrConstants& InConstants, ID3D12Resource* InSource,
                                       ID3D12Resource* InModel, ID3D12Resource* InOriginal,
                                       ID3D12Resource* InMotion, ID3D12Resource* OutTarget, bool finishedColor)
{
    if (finishedColor && !_finishedColorPipelineState && _init)
        CreateComputePipeline(_device, &_finishedColorPipelineState, dlssnr_finished_color_cso,
                              sizeof(dlssnr_finished_color_cso), nullptr);
    auto* pipeline = finishedColor ? _finishedColorPipelineState : _residualPipelineState;
    if (!_init || pipeline == nullptr || InCmdList == nullptr || _device == nullptr ||
        InSource == nullptr || OutTarget == nullptr)
        return false;

    const int acquired = AcquireBinding(InCmdList);
    if(acquired<0)return false;
    const uint32_t slot=static_cast<uint32_t>(acquired);
    RetainBinding(slot,{InSource,InModel,InOriginal,InMotion,OutTarget,
        _frameHeaps[slot].GetHeapCSU(),_constantBuffers[slot],_rootSignature});

    FrameDescriptorHeap& currentHeap = _frameHeaps[slot];

    // Same table shape as DispatchPass: the residual shader reads t0..t3 + u0, and t4/u1 get the
    // source as a stand-in so no descriptor in the table is left unbound.
    ID3D12Resource* const srvs[kSrvCount] = {
        InSource,
        InModel != nullptr ? InModel : InSource,
        InOriginal != nullptr ? InOriginal : InSource,
        InMotion != nullptr ? InMotion : InSource,
        InSource,
    };

    for (uint32_t i = 0; i < kSrvCount; ++i)
        CreateShaderResourceView(_device, srvs[i], currentHeap.GetSrvCPU(i));

    ID3D12Resource* const uavs[kUavCount] = { OutTarget, OutTarget };

    for (uint32_t i = 0; i < kUavCount; ++i)
        CreateUnorderedAccessView(_device, uavs[i], currentHeap.GetUavCPU(i), 0);

    if (!CreateConstantsBuffer(_device, _constantBuffers[slot], InConstants, currentHeap.GetCbvCPU(0)))
    {
        LOG_ERROR("[{0}] Failed to create a constants buffer", _name);
        return false;
    }

    RetainBinding(slot,{pipeline});
    ID3D12DescriptorHeap* heaps[] = { currentHeap.GetHeapCSU() };
    InCmdList->SetDescriptorHeaps(_countof(heaps), heaps);
    InCmdList->SetComputeRootSignature(_rootSignature);
    InCmdList->SetPipelineState(pipeline);
    InCmdList->SetComputeRootDescriptorTable(0, currentHeap.GetTableGPUStart());

    const UINT dispatchWidth = (InConstants.Width + _numThreadsX - 1) / _numThreadsX;
    const UINT dispatchHeight = (InConstants.Height + _numThreadsY - 1) / _numThreadsY;
    InCmdList->Dispatch(dispatchWidth, dispatchHeight, 1);

    return true;
}



void DlssNr_Dx12::Dispatch(ID3D12GraphicsCommandList* cmdList, ID3D12Resource* colour,
                           ID3D12Resource* depth, ID3D12Resource* motion, ID3D12Resource* output,
                           const DlssNrFrameInfo& frame, ID3D12CommandQueue* timingQueue)
{
    auto nrLock = g_nrEvents.Lock();
    // Reclaim completed retirements even while memory pressure has suspended
    // processing; otherwise their budget charge can prevent Retry recovering.
    TickNrRetired();
    optishade::nr_lifetime::Active().Collect();
    optishade::nr_lifetime::Collect();
    CollectBindings(); // release retired bindings before rechecking memory pressure
    const Config& cfg = *Config::Instance();

    if(optishade::route::CurrentSimulator()!=optishade::route::Simulator::Unknown && !optishade::route::Current().module){
        g_nr.reason="Required simulator route DLL is missing or incompatible; repair this installation.";
        ReportSkipOnce(g_nr.reason);return;
    }
    DlssNrNative::SetPrecision(cfg.DlssNrPrecision.value_or_default());

    // Only the recoverable budget pause can auto-retry. Device/model failures
    // remain latched, and every new allocation still passes the normal guard.
    if (g_nr.failed && g_memoryPressureStopped && !g_nrDeviceLost &&
        cfg.DlssNrEnabled.value_or_default()) {
        auto& memoryState=optishade::route::OutputOwned<NrMemoryState,4>();
        const auto now=GetTickCount64();
        // The pause is opt-in: switching it off resumes NR straight away.
        if(!cfg.DlssNrPauseOnLowMemory.value_or_default()) {
            g_nr.failed=false;g_memoryPressureStopped=false;
            g_nr.reason="";g_nr.reset=true;memoryState.check.invalidate();
            LOG_INFO("DLSS-NR memory pause cleared: Pause NR when video memory is low is off");
        }else if(memoryState.recovery.Due(now)) {
            DXGI_QUERY_VIDEO_MEMORY_INFO memory{};
            const bool valid=memoryState.QueryMemory(_device,memory);
            if(memoryState.recovery.Observe(now,valid,memory.Budget,memory.CurrentUsage)) {
                g_nr.failed=false;g_memoryPressureStopped=false;
                g_nr.reason="";g_nr.reset=true;memoryState.check.invalidate();
                LOG_INFO("DLSS-NR memory budget recovered ({} MiB free for {} s); rechecking the current processing plan",memoryState.recovery.Required()/1048576,memoryState.recovery.WaitMs()/1000);
            }
        }
    }
    if (g_nr.failed || cmdList == nullptr || colour == nullptr || depth == nullptr ||
        motion == nullptr || output == nullptr)
    {
        ReportSkipOnce(g_nr.failed ? (g_memoryPressureStopped ? g_nr.reason : "it already failed this session") : "a resource was missing");
        return;
    }

    const optishade::D3D12FrameContext inputs {cmdList, colour, depth, motion, output,
        static_cast<ID3D12Resource*>(frame.ExposureTexture), timingQueue};
    if (const char* reason = inputs.ValidateDeviceIdentity(_device, frame.IndependentCommands && frame.FinishedPicture)) {
        ReportSkipOnce(reason);
        return; // No state changes or GPU commands have been recorded.
    }

    if (g_nr.capabilityDevice) {
        auto identity = optishade::ReShadeDeviceIdentity(_device);
        if (!identity ||
            identity.Get() != g_nr.capabilityDevice.Get()) {
            ReportSkipOnce("neural runtime belongs to another device; restart before changing devices");
            return;
        }
    }
    if(g_timingDomain.queue && timingQueue && g_timingDomain.queue!=timingQueue &&
       !optishade::nr_lifetime::Active().Ready()) {
        ReportSkipOnce("NR output changed queues while its earlier recordings remain in flight");return;
    }
    auto& outputState=optishade::route::OutputOwned<NrEngineState,1>();
    const auto generation=optishade::route::CurrentOutputKey().generation;
    if(outputState.outputGeneration!=generation){
        outputState.outputGeneration=generation;g_nr.reset=true;g_nr.residualHistoryPrimed=false;
        if(g_gpuTime)g_gpuTime->ClearLast();if(g_ngxTime)g_ngxTime->ClearLast();
    }
    const NrTimingDomain timingDomain{_device,timingQueue,frame.OutputWidth,frame.OutputHeight,frame.EstimatedTaaGuides,frame.FinishedPicture};
    if(frame.Reset || g_timingDomain.device!=timingDomain.device || g_timingDomain.queue!=timingDomain.queue ||
       g_timingDomain.width!=timingDomain.width || g_timingDomain.height!=timingDomain.height ||
       g_timingDomain.taa!=timingDomain.taa || g_timingDomain.finished!=timingDomain.finished){
        if(g_gpuTime)g_gpuTime->ClearLast();if(g_ngxTime)g_ngxTime->ClearLast();
        g_lastGpuTime.reset();g_lastNgxTime.reset();g_timingDomain=timingDomain;
        // Queue/extent/guide-domain changes invalidate temporal history as well
        // as timings. Preserve allocations and their exact GPU leases; the next
        // evaluation resets history instead of consuming the previous domain.
        g_nr.reset = true;
        g_nr.residualHistoryPrimed = false;
    }
    // The LUID comes from the actual rendering device, never adapter zero.
    static LUID reportedAdapter{};
    const auto renderingLuid=_device->GetAdapterLuid();
    if(renderingLuid.HighPart!=reportedAdapter.HighPart || renderingLuid.LowPart!=reportedAdapter.LowPart) {
        Microsoft::WRL::ComPtr<IDXGIFactory4> factory;
        Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;DXGI_ADAPTER_DESC1 description{};
        if(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))) &&
           SUCCEEDED(factory->EnumAdapterByLuid(renderingLuid,IID_PPV_ARGS(&adapter))) &&
           SUCCEEDED(adapter->GetDesc1(&description))) {
            reportedAdapter=renderingLuid;
            optishade::session::State().Put({{"NRProcessingAdapterLUID",std::format("{:08X}{:08X}",(unsigned)renderingLuid.HighPart,renderingLuid.LowPart)},
                {"NRProcessingVendorID",std::to_string(description.VendorId)},{"NRProcessingDeviceID",std::to_string(description.DeviceId)},{"NRProcessingAdapter",wstring_to_string(description.Description)}});
            LOG_INFO("NR rendering adapter: luid={:08X}{:08X}; vendor={:04X}; device={:04X}; software={}; name={}",
                (unsigned)renderingLuid.HighPart,renderingLuid.LowPart,description.VendorId,description.DeviceId,
                (description.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)!=0,wstring_to_string(description.Description));
        }
    }
    DlssNr::ObserveRequest(cfg);
    const auto observationRoute = frame.NativeFgProducer ? optishade::nr_observation::Route::PreFgTAA : frame.VulkanBridge ? optishade::nr_observation::Route::EstimatedVulkan : frame.EstimatedTaaGuides ? optishade::nr_observation::Route::EstimatedTAA : frame.FinishedPicture ? optishade::nr_observation::Route::FinishedPicture :
        frame.BeforeUpscale ? optishade::nr_observation::Route::BeforeSR : optishade::nr_observation::Route::NativeD3D12;
    const auto observation = optishade::nr_observation::State().Begin(
        {reinterpret_cast<uint64_t>(optishade::ReShadeDeviceIdentity(_device).Get()),reinterpret_cast<uintptr_t>(timingQueue),frame.ObservationOwner,
         frame.ObservationGeneration,frame.ObservationView,frame.OutputWidth,frame.OutputHeight,observationRoute},
        frame.SubmissionEpoch,GetTickCount64(),frame.Reset);
    if(frame.ObservationTicket)*frame.ObservationTicket=observation;
    ID3D12Resource* target = output;

    // Feature creation records GPU work too, and may return before the first evaluate.
    // Guard the entire dispatch, not just the colour passes at the bottom. Otherwise
    // creation/resize during an RE Engine loading screen captures NR's bindings as
    // the game's state, or returns with those bindings still active.
    const bool restoreRequired = cfg.RestoreComputeSignature.value_or_default() ||
                                 cfg.RestoreGraphicSignature.value_or_default();
    if (restoreRequired && !frame.IndependentCommands && !D3D12Hooks::CanRestoreRootSignature(cmdList))
    {
        ReportSkipOnce("the upscaler could not restore state this frame");
        return;
    }
    // Refuse new NR allocations before recording any transitions. The reserve is
    // a conservative headroom policy, not a prediction of the proprietary model's
    // allocation size. Existing game resources remain untouched on refusal.
    if (!_device || FAILED(_device->GetDeviceRemovedReason()))
    {
        g_nr.failed = true;
        g_nrDeviceLost = true;
        g_nr.reason = "the graphics device has failed; restart the simulator";
        // Keep the user request; this is an effective suspension, not a user disable.
        LOG_ERROR("DLSS-NR stopped: {}", g_nr.reason);
        return;
    }
    TickNrRetired();
    // Reserve the maximum meter/encode/resize/resolve/residual batch before
    // feature creation, texture barriers, copies or writes touch this frame.
    if(g_nrRetired.size()>=128) {
        g_nr.reason="NR is waiting for its previous GPU recordings to retire";
        ReportSkipOnce(g_nr.reason);return;
    }
    if(!ReserveBatch(cmdList,5)) {
        g_nr.reason="NR binding pool is full: the game has not reset NR's previous command lists";
        ReportSkipOnce(g_nr.reason);return;
    }
    struct BatchEnd { DlssNr_Dx12* self; ~BatchEnd(){self->EndBatch();} } batchEnd{this};
    g_nr.reason="";
    ScopedNrStateEnvelope stateEnvelope(cmdList, frame.IndependentCommands);

    // A completed upscaler output normally arrives as a UAV. The pre-SR colour input instead arrives
    // readable. Track every transition so both paths return the resource exactly as their caller gave
    // it to us; a pre-SR resource without UAV support is written through a scratch-and-copy fallback.
    const D3D12_RESOURCE_STATES outputArrival =
        frame.FinishedPicture ? (D3D12_RESOURCE_STATES) frame.OutputArrivalState : frame.BeforeUpscale
            ? (!frame.PrivateColorCopy && Config::Instance()->ColorResourceBarrier.has_value()
                   ? (D3D12_RESOURCE_STATES) Config::Instance()->ColorResourceBarrier.value()
                   : D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE)
            : Config::Instance()->OutputResourceBarrier.has_value()
            ? (D3D12_RESOURCE_STATES) Config::Instance()->OutputResourceBarrier.value()
            : D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
    D3D12_RESOURCE_STATES targetState = outputArrival;
    const auto TransitionTarget = [&](D3D12_RESOURCE_STATES to)
    {
        Barrier(cmdList, target, targetState, to);
        targetState = to;
    };

    ID3D12Device* device = nullptr;

    if (FAILED(target->GetDevice(IID_PPV_ARGS(&device))) || device == nullptr)
    {
        ReportSkipOnce("the output texture belongs to no D3D12 device");
        return;
    }

    const D3D12_RESOURCE_DESC desc = target->GetDesc();
    const auto active = frame.BeforeUpscale
        ? DlssNr::PreSrColorExtent(desc, frame.RenderSubrectWidth, frame.RenderSubrectHeight)
        : std::optional<DlssNr::ColorExtent> { DlssNr::ColorExtent { (unsigned int) desc.Width, desc.Height } };
    if (!active)
    {
        ReportSkipOnce("the pre-SR active colour size is invalid");
        device->Release();
        return;
    }
    const auto width = active->width;
    const auto height = active->height;
    const bool cropColor = frame.BeforeUpscale && (width != desc.Width || height != desc.Height);
    const bool targetSupportsUav =
        cropColor || (desc.Flags & D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS) != 0;

    // Resource/dispatch failures in this mode must preserve Color for RR.
    const bool residualAcrossRr = frame.ResidualAcrossRr && frame.BeforeUpscale;

    const auto guideDesc = depth->GetDesc();
    const auto motionDesc = motion->GetDesc();
    const auto guides = DlssNr::ResolveGuideRegions(
        { (unsigned int) guideDesc.Width, guideDesc.Height },
        { (unsigned int) motionDesc.Width, motionDesc.Height },
        { frame.RenderSubrectWidth, frame.RenderSubrectHeight },
        { frame.OutputWidth, frame.OutputHeight }, frame.MotionVectorsLowResolution,
        frame.DepthSubrectBaseX, frame.DepthSubrectBaseY,
        frame.MotionSubrectBaseX, frame.MotionSubrectBaseY);
    if (!guides.depth.valid() || !guides.motion.valid())
    {
        ReportSkipOnce("depth or motion-vector subrect is empty");
        device->Release();
        return;
    }
    const auto guideWidth = guides.depth.width, guideHeight = guides.depth.height;
    const auto motionWidth = guides.motion.width, motionHeight = guides.motion.height;
    const auto depthBaseX = guides.depth.x, depthBaseY = guides.depth.y;
    const auto motionBaseX = guides.motion.x, motionBaseY = guides.motion.y;

    g_nr.guideWidth = guideWidth;
    g_nr.guideHeight = guideHeight;
    g_nr.guideDepthInverted = frame.DepthInverted;

    // The game's own encoding, passed through. Every resource already carries a subrect saying how
    // big it is, so scaling by the resolution ratio on top of that counts it twice -- vectors come
    // out too long and the model warps its history past where the surface went.
    g_nr.guideMvScaleX = frame.MvScaleX;
    g_nr.guideMvScaleY = frame.MvScaleY;

    if (frame.Reset)
    {
        g_nr.reset = true;
        // Drop the accumulated enhancement layer: a cut invalidates the reprojection history.
        g_nr.residualHistoryPrimed = false;
        g_nr.residualStoreValid = false;

        static unsigned long long resets = 0;
        ++resets;

        if (resets <= 3 || resets % 100 == 0)
            LOG_INFO("DLSS-NR: temporal history reset requested by frame contract ({} so far; includes route discontinuities)", resets);
    }

    // Logged whenever it changes, not once per session.
    //
    // A guide size change does not rebuild the feature -- the guides are handed over as subrects and
    // the output size is what the model is built for -- so a once-only line goes stale the moment the
    // player moves the quality slider, and every later line in the log is then read against numbers
    // that stopped being true. In Nioh 3 the session opened at DLAA, moved to 66% and ended at 33%,
    // and the log claimed 1920x1080 guides throughout.
    struct GuideReport
    {
        bool valid;
        bool depthInverted;
        float mvScaleX;
        float mvScaleY;
        unsigned int guideW;
        unsigned int guideH;
        unsigned int frameW;
        unsigned int frameH;
    };

    auto& loggedGuides = optishade::route::OutputOwned<NrEngineState,1>().loggedGuides;

    const GuideReport guidesNow { true,       g_nr.guideDepthInverted, g_nr.guideMvScaleX,
                                  g_nr.guideMvScaleY, guideWidth,      guideHeight,
                                  width,      (unsigned int) height };

    if (!loggedGuides.valid || loggedGuides.depthInverted != guidesNow.depthInverted ||
        loggedGuides.mvScaleX != guidesNow.mvScaleX || loggedGuides.mvScaleY != guidesNow.mvScaleY ||
        loggedGuides.guideW != guidesNow.guideW || loggedGuides.guideH != guidesNow.guideH ||
        loggedGuides.frameW != guidesNow.frameW || loggedGuides.frameH != guidesNow.frameH)
    {
        loggedGuides = {guidesNow.valid, guidesNow.depthInverted, guidesNow.mvScaleX, guidesNow.mvScaleY,
                        guidesNow.guideW, guidesNow.guideH, guidesNow.frameW, guidesNow.frameH};
        LOG_INFO("DLSS-NR guides: depth {}, motion vector scale {} x {}, guides {}x{} for a {}x{} frame",
                 g_nr.guideDepthInverted ? "inverted" : "not inverted", g_nr.guideMvScaleX,
                 g_nr.guideMvScaleY, guideWidth, guideHeight, width, height);
    }

    if (cfg.DlssNrProxyProbe.value_or_default())
        ProbeProxyDispatch(cmdList);

    bool runtimeReady=false;
    try {
        const char* blocked = g_nr.capabilityParams ? nullptr :
            optishade::NvidiaNeuralPreflight(optishade::QueryD3D12Capabilities(device));
        if (blocked) g_nr.reason = blocked;
        else runtimeReady=EnsureForwarder()&&EnsureCapabilityParams(device);
    }
    catch(const std::exception& error){g_nr.reason="Optional Neural Rendering initialization threw a C++ exception. See Performance.log; restart before retrying.";LOG_ERROR("NR initialization exception: {}",error.what());}
    catch(...){g_nr.reason="Optional Neural Rendering initialization threw an exception. Restart before retrying.";LOG_ERROR("NR initialization exception (unknown type)");}
    if (!runtimeReady)
    {
        g_nr.failed = true;
        LOG_ERROR("DLSS-NR unavailable: {}", g_nr.reason);
        device->Release();
        return;
    }

    // What the model works at. The frame and its edit stay full resolution; only the model's input and
    // answer change size, and the resolve enlarges (or minifies) the answer while compositing. Below 1
    // the model runs reduced and cheaper; above 1 it SUPERSAMPLES -- the proxy is upscaled to a larger
    // working size so the model denoises a super-native input, which the resolve then samples back down.
    // Capped at 2x: cost grows with the area and NGX acceptance above native is what this probe tests.
    // In a headset session every remaining NR output is an eye (the desktop
    // mirror is skipped), and two eyes at full model resolution cost more than
    // a 90 Hz frame. Eyes use their own model resolution.
    const bool headsetEye = HeadsetPresenting();
    float workScale = headsetEye ? std::min(cfg.DlssNrVrWorkingScale.value_or_default(), 1.0f)
                                 : cfg.DlssNrWorkingScale.value_or_default();
    if (!std::isfinite(workScale))
        workScale = 1.0f;
    workScale = workScale < 0.25f ? 0.25f : (workScale > 2.0f ? 2.0f : workScale);
    // Foveated headset eyes: the model sees only a centred window of the eye (lenses blur the
    // outside, so NR there is mostly wasted). The window is cropped from the proxy by the
    // downsample and from the guides through their subrect bases; the resolve fades the result
    // into the untouched frame at the window's edge. Native DLSS eyes only.
    const bool foveated = headsetEye && !frame.EstimatedTaaGuides && !cfg.DlssNrUseProxy.value_or_default() &&
                          cfg.DlssNrVrFoveated.value_or_default() && cfg.DlssNrVrFoveaSize.value_or_default() < 0.995f;
    unsigned int fovX = 0, fovY = 0, fovW = width, fovH = height;
    if (foveated)
    {
        float size = cfg.DlssNrVrFoveaSize.value_or_default();
        size = std::isfinite(size) ? std::clamp(size, 0.3f, 1.0f) : 0.7f;
        fovW = std::max(64u, ((unsigned int) (width * size + 0.5f)) & ~1u);
        fovH = std::max(64u, ((unsigned int) (height * size + 0.5f)) & ~1u);
        fovW = std::min(fovW, width);
        fovH = std::min(fovH, height);
        fovX = (width - fovW) / 2;
        fovY = (height - fovH) / 2;
    }
    auto workWidth = (unsigned int) (fovW * workScale + 0.5f);
    auto workHeight = (unsigned int) (fovH * workScale + 0.5f);
    if (frame.EstimatedTaaGuides)
    {
        const auto taaWork = optishade::taa::TaaWorkingExtent(width, height);
        if (!frame.FinishedPicture || !frame.IndependentCommands || !taaWork.valid())
        {
            ReportSkipOnce("invalid bounded TAA working extent or command contract");
            device->Release();
            return;
        }
        workWidth = taaWork.width;
        workHeight = taaWork.height;
        workScale = static_cast<float>(workWidth) / width;
    }
    const bool reduced = workWidth != width || workHeight != height;
    {
        auto& loggedVrScale = optishade::route::OutputOwned<NrEngineState,1>().loggedVrScale;
        const int scaleNow = headsetEye && !frame.EstimatedTaaGuides ? (int)lroundf(workScale * 100.0f) * 1000 + (int)fovW % 1000 : 0;
        if (scaleNow != loggedVrScale)
        {
            loggedVrScale = scaleNow;
            if (scaleNow)
                LOG_INFO("DLSS-NR headset eye: model resolution {}%, {} ({}x{} window at {},{}; model {}x{} for a {}x{} eye)",
                         (int)lroundf(workScale * 100.0f), foveated ? "foveated" : "whole eye", fovW, fovH, fovX, fovY,
                         workWidth, workHeight, width, height);
        }
    }
    const unsigned int userRequestedPasses = std::clamp(
        cfg.DlssNrPasses.value_or_default(), 1u,
        cfg.DlssNrUnlockPasses.value_or_default() ? DlssNr::MaxPassCount
                                                  : DlssNr::DefaultMaxPassCount);
    const unsigned int configuredPasses = frame.EstimatedTaaGuides ? 1u : userRequestedPasses;
    const bool proxyBackend = cfg.DlssNrUseProxy.value_or_default();
    // Native FG uses independent output histories and per-feature parameter
    // tables. Admit the whole requested stack, never a varying ready prefix.
    const unsigned int requestedPasses = proxyBackend ? 1u : configuredPasses;
    // Estimated TAA temporarily evaluates one pass while native FG is off.
    // This is not a user request to delete the extra model. Keep the existing
    // histories/scratch bounded to the configured pass set, and reset unused
    // histories before native FG resumes. Never allocate extra passes here.
    const bool retainDormantPasses = frame.EstimatedTaaGuides && !proxyBackend &&
        cfg.DlssNrPasses.value_or_default() > 1;


    if (proxyBackend && configuredPasses > 1)
    {
        static bool warnedProxyPasses = false;
        if (!warnedProxyPasses)
        {
            warnedProxyPasses = true;
            LOG_WARN("DLSS-NR: the driver-proxy backend supports one pass; Passes={} is using 1",
                     configuredPasses);
        }
    }

    ReleaseSurfacesIfFormatChanged(desc.Format);

    const bool resolutionChanged = g_nr.width != width || g_nr.height != height ||
                                   g_nr.workWidth != workWidth || g_nr.workHeight != workHeight;
    const bool placementChanged = g_nr.feature != nullptr &&
        (g_nr.beforeUpscale != frame.BeforeUpscale ||
         g_nr.rayReconstruction != frame.RayReconstruction);

    // The model reads its tuning once, while the feature is built, so a changed setting only takes
    // effect when the feature is rebuilt. TuningMatchesFeature was written to notice that and then
    // never called, which is why every one of these controls appeared to do nothing until something
    // else -- a resolution change -- happened to force a rebuild by accident.
    // Sliders can change every frame. Wait for a settled value and for the
    // previous feature to retire before allocating another model generation.
    auto& tuningState=optishade::route::OutputOwned<NrEngineState,1>();
    auto& pendingTuning=tuningState.pendingTuning;auto& pendingPreset=tuningState.pendingPreset;auto& pendingStyle=tuningState.pendingStyle;
    auto& pendingPasses=tuningState.pendingPasses;auto& tuningChangedAt=tuningState.tuningChangedAt;
    bool pendingChanged = pendingPasses != requestedPasses;
    pendingPasses = requestedPasses;
    for (unsigned pass = 0; pass < requestedPasses; ++pass)
    {
        const auto tuning = PassTuning(cfg, pass);
        const auto preset = PassPreset(cfg, pass), style = PassStyle(cfg, pass);
        pendingChanged |= pendingTuning[pass] != tuning || pendingPreset[pass] != preset || pendingStyle[pass] != style;
        pendingTuning[pass] = tuning; pendingPreset[pass] = preset; pendingStyle[pass] = style;
    }
    const auto tuningTime = GetTickCount64();
    if (pendingChanged) { tuningChangedAt = tuningTime; ++tuningState.tuningGeneration; }
    const bool modelRetiring = std::any_of(g_nrRetired.begin(), g_nrRetired.end(), BlocksNrRebuild);
    const bool tuningChanged = !TuningMatchesFeature(cfg, requestedPasses) &&
                               tuningTime - tuningChangedAt >= 500 && !modelRetiring;
    if (tuningChanged)
        g_nr.residualHistoryPrimed = false;

    // MSFS occasionally hands DLSS one frame at another output size (3840x2160
    // between 2560x1440 frames: OSD-NB9Q, OSD-DDB5). Rebuilding for it parked
    // the working model and NR was gone for ~3 s while the old leases retired,
    // only to rebuild the same size again: "NR switches itself off". Skip such
    // a frame instead, and rebuild only once the new size holds. A swapchain
    // resize (resizeRebuildPending) still rebuilds at once.
    constexpr unsigned kExtentSettleFrames = 3;
    if (g_nr.feature != nullptr && resolutionChanged && !g_nr.resizeRebuildPending)
    {
        if (tuningState.settleWidth == width && tuningState.settleHeight == height &&
            tuningState.settleWorkWidth == workWidth && tuningState.settleWorkHeight == workHeight)
            ++tuningState.settleFrames;
        else
        {
            tuningState.settleWidth = width; tuningState.settleHeight = height;
            tuningState.settleWorkWidth = workWidth; tuningState.settleWorkHeight = workHeight;
            tuningState.settleFrames = 1;
        }
        if (tuningState.settleFrames < kExtentSettleFrames)
        {
            // Skip only this frame and keep the running model's history. A one-
            // or two-frame odd size never settles (115 times in OSD-5H4E, none
            // settled); resetting history on each made NR blink at MFG 4x. A
            // size that does settle rebuilds below, which starts history afresh.
            if (tuningState.settleFrames == 1)
            {
                static unsigned oddSizeLogs = 0;
                if (oddSizeLogs < 32 && ++oddSizeLogs)
                    LOG_INFO("DLSS-NR odd frame size {}x{} (model {}x{}) skipped; running model kept", width, height, workWidth, workHeight);
            }
            g_nr.reason = "Frame size changed; waiting for it to settle before rebuilding NR";
            ReportSkipOnce(g_nr.reason);
            device->Release();
            return;
        }
        LOG_INFO("DLSS-NR frame size settled at {}x{} (model {}x{}) after {} frames; rebuilding", width, height,
                 workWidth, workHeight, tuningState.settleFrames);
    }
    tuningState.settleFrames = 0;

    // Admit against the resolved active/model allocation plan, not the padded
    // game texture. Cache adapter identity and only force a new query when the
    // actual plan changes; repeated allocation attempts for the same extent are
    // rate limited independently of periodic budget telemetry.
    unsigned missingPasses=g_nr.feature?0u:1u;
    for(unsigned pass=1;pass<requestedPasses;++pass)if(!g_nr.passFeature[pass])++missingPasses;
    const bool resizeRebuildPending = g_nr.resizeRebuildPending;
    const bool allocationNeeded=missingPasses||resolutionChanged||placementChanged||tuningChanged||resizeRebuildPending;
    const auto memoryCheckTime=GetTickCount64();
    auto& memoryState=optishade::route::OutputOwned<NrMemoryState,4>();
    const auto adapterLuid=device->GetAdapterLuid();
    const uint64_t adapterKey=(uint64_t(static_cast<uint32_t>(adapterLuid.HighPart))<<32)|adapterLuid.LowPart;
    optishade::nr::AllocationPlan allocationPlan{};
    allocationPlan.adapter=adapterKey;allocationPlan.tuningGeneration=tuningState.tuningGeneration;
    allocationPlan.width=width;allocationPlan.height=height;allocationPlan.workWidth=workWidth;allocationPlan.workHeight=workHeight;
    allocationPlan.format=static_cast<uint32_t>(desc.Format);allocationPlan.precision=cfg.DlssNrPrecision.value_or_default();
    allocationPlan.passes=requestedPasses;allocationPlan.beforeUpscale=frame.BeforeUpscale;
    allocationPlan.rayReconstruction=frame.RayReconstruction;allocationPlan.proxy=proxyBackend;
    allocationPlan.estimatedTaa=frame.EstimatedTaaGuides;
    if(memoryState.check.due(memoryCheckTime,allocationPlan,allocationNeeded)){
        DXGI_QUERY_VIDEO_MEMORY_INFO memory{};
        if(memoryState.QueryMemory(device,memory)){
            namespace guard=optishade::nr::memory_guard;
            const UINT64 free=memory.Budget>memory.CurrentUsage?memory.Budget-memory.CurrentUsage:0;
            const auto passReserve=std::max(1u,missingPasses?missingPasses:requestedPasses);
            // A rebuild replaces the current models, whose memory is already in
            // the usage figure; only the growth needs new room.
            const bool rebuild=g_nr.feature!=nullptr&&(resolutionChanged||tuningChanged||placementChanged||resizeRebuildPending);
            unsigned currentPasses=g_nr.feature?1u:0u;
            for(unsigned pass=1;pass<DlssNr::MaxPassCount;++pass)if(g_nr.passFeature[pass])++currentPasses;
            const UINT64 reserve=allocationNeeded?guard::ModelReserve(workWidth,workHeight,passReserve):0;
            const UINT64 required=allocationNeeded?guard::RequiredFree(reserve,rebuild?guard::ModelReserve(g_nr.workWidth,g_nr.workHeight,currentPasses):0):0;
            if(allocationNeeded&&g_memoryLogs.record(0,memoryCheckTime))
                LOG_INFO("DLSS-NR memory plan: active={}x{} model={}x{} passes={} precision={} independent={} budget={} MiB usage={} MiB reserve={} MiB required={} MiB",
                    width,height,workWidth,workHeight,requestedPasses,allocationPlan.precision,frame.IndependentCommands,
                    memory.Budget/1048576,memory.CurrentUsage/1048576,reserve/1048576,required/1048576);
            // Running NR is never stopped for memory: over budget, Windows pages
            // memory out (stutter); stopping it here flickered NR on and off.
            if(!allocationNeeded&&memory.Budget&&free<guard::kMinimumHeadroom&&g_memoryLogs.record(2,memoryCheckTime))
                LOG_WARN("DLSS-NR: video memory is within {} MiB of the budget (usage={} MiB budget={} MiB); NR keeps running, the game may stutter",
                    free/1048576,memory.CurrentUsage/1048576,memory.Budget/1048576);
            const bool admitted=!allocationNeeded||guard::Admits(memory.Budget,memory.CurrentUsage,required);
            if(memory.Budget)g_memoryLow=allocationNeeded?!admitted:free<guard::kMinimumHeadroom;
            // Pausing is opt-in. By default NR is built anyway: over budget,
            // Windows pages memory out, so the cost is stutter, not a failure.
            if(!admitted&&!cfg.DlssNrPauseOnLowMemory.value_or_default()&&g_memoryLogs.record(2,memoryCheckTime))
                LOG_WARN("DLSS-NR: video memory is nearly full (needs {} MiB free, has {} MiB); NR starts anyway because Pause NR when video memory is low is off; the game may stutter",
                    required/1048576,free/1048576);
            if(!admitted&&cfg.DlssNrPauseOnLowMemory.value_or_default()){
                g_nr.failed=true;g_memoryPressureStopped=true;memoryState.recovery.Refused(required);
                g_nr.reason="Paused: video memory is almost full and Pause NR when video memory is low is on. NR retries once memory frees up.";
                LOG_WARN("DLSS-NR stopped: {} (needs {} MiB free, has {} MiB; next retry after {} s of headroom)",
                    g_nr.reason,required/1048576,free/1048576,memoryState.recovery.WaitMs()/1000);
                device->Release();return;
            }
            if(allocationNeeded)memoryState.recovery.Admitted();
        }else if(g_memoryLogs.record(1,memoryCheckTime))
            LOG_WARN("DLSS-NR: cached rendering-adapter memory query unavailable; allocation checks remain active (occurrences: {})",g_memoryLogs.count(1));
    }

    if ((g_nr.feature != nullptr && (resolutionChanged || tuningChanged || placementChanged)) ||
        resizeRebuildPending)
    {
        // Parked rather than released: with frame generation the GPU can still be several frames
        // deep in work that references all of it.
        ParkNrFeature(g_nr.feature);
        g_nr.featurePendingSubmission = false;

        for (unsigned int i = 1; i < DlssNr::MaxPassCount; ++i)
        {
            ParkNrFeature(g_nr.passFeature[i]);
            g_nr.passNeedsReset[i] = false;
            g_nr.passCreateFailed[i] = false;
            g_nr.passPendingSubmission[i] = false;
        }

        // Resolution and seam changes invalidate the scratch state. Tuning does not, and throwing
        // resources away for it would mean a reallocation every time a slider moves.
        if (resolutionChanged || placementChanged || resizeRebuildPending)
        {
            if (placementChanged)
                ForgetCalibration();

            ParkNrResource(g_nr.output);
            ParkNrResource(g_nr.passScratch);
            ParkNrResource(g_nr.colorCopy);
            ParkNrResource(g_nr.hdrCopy);
            ParkNrResource(g_nr.colorSmall);
            ParkNrResource(g_nr.outputNative);
            ParkNrResource(g_nr.activeColor);
            ParkNrResource(g_nr.residualEdited);
            ParkNrResource(g_nr.residualHistory[0]);
            ParkNrResource(g_nr.residualHistory[1]);
            ParkNrResource(g_nr.residualComposed);
            g_nr.residualStoreValid = false;
            g_nr.residualHistoryIndex = 0;
            g_nr.residualHistoryPrimed = false;
            g_nr.passScratchFailed = false;
        }

        g_nr.resizeRebuildPending = false;
    }

    // A resize or tuning rebuild can leave the prior NVIDIA feature alive while
    // its exact GPU-use leases are still in flight. Do not create another model
    // generation alongside it: some provider versions are not safe to overlap
    // across a resolution change. TickNrRetired() runs at the start of the next
    // dispatch; once the old feature is actually released, normal creation resumes.
    //
    // A game list that finished on the GPU but is never Reset again (it was
    // dropped, e.g. when the game rebuilt its render path), or one the game
    // recorded and then discarded without executing, would block forever.
    // After a bounded wait, keep the old generation parked (not freed, so a late
    // execute or replay stays valid) and let the new one be created. Only GPU
    // work still in flight keeps waiting. VRAM for parked models is covered by
    // the memory-pressure check above.
    if (std::any_of(g_nrRetired.begin(), g_nrRetired.end(), BlocksNrRebuild))
    {
        constexpr ULONGLONG IdleRebuildWaitMs = 3000;
        constexpr ULONGLONG UntrackedRebuildWaitMs = 10000;
        constexpr ULONGLONG WaitLogIntervalMs = 5000;
        constexpr size_t MaxDeferredModels = 6;
        const ULONGLONG now = GetTickCount64();
        if (g_nr.rebuildWaitStartMs == 0)
            g_nr.rebuildWaitStartMs = now;

        using Wait = optishade::nr_lifetime::Lease::Wait;
        size_t inFlight = 0, finishedNotReset = 0, unsubmitted = 0, unresolved = 0, unknown = 0;
        for (const auto& item : g_nrRetired)
        {
            if (!BlocksNrRebuild(item))
                continue;
            for (const auto& use : item.uses)
            {
                switch (use->State())
                {
                case Wait::Retired: break;
                case Wait::InFlight: ++inFlight; break;
                case Wait::FinishedNotReset: ++finishedNotReset; break;
                case Wait::Unsubmitted: ++unsubmitted; break;
                case Wait::Unresolved: ++unresolved; break;
                default: ++unknown; break;
                }
            }
        }
        const size_t deferredModels = std::count_if(g_nrRetired.begin(), g_nrRetired.end(),
            [](const NrRetired& item) { return item.feature != nullptr && item.deferred; });
        const ULONGLONG waited = now - g_nr.rebuildWaitStartMs;
        const size_t untracked = unsubmitted + unresolved + unknown;
        const size_t pending = finishedNotReset + untracked;
        const ULONGLONG required = untracked ? UntrackedRebuildWaitMs : IdleRebuildWaitMs;

        // The limit exists to bound video memory, not for correctness: parked
        // models are never freed early. MSFS can leave command lists finished but
        // unreset for half an hour, and with 2 passes each rebuild parks 2 models,
        // so 6 was reached after three rebuilds while 12 GB of the card sat free
        // (OSD-9TNR). Park more while there is clear headroom.
        constexpr size_t MaxDeferredModelsWithHeadroom = 24;
        size_t parkingLimit = MaxDeferredModels;
        UINT64 parkingHeadroom = 0;
        if (deferredModels >= MaxDeferredModels && deferredModels < MaxDeferredModelsWithHeadroom)
        {
            DXGI_QUERY_VIDEO_MEMORY_INFO info {};
            if (memoryState.QueryMemory(device, info) && info.Budget > info.CurrentUsage)
            {
                parkingHeadroom = info.Budget - info.CurrentUsage;
                const UINT64 needed = 2 * optishade::nr::memory_guard::ModelReserve(workWidth, workHeight, std::max(1u, requestedPasses)) +
                                      512ull * 1048576;
                if (parkingHeadroom >= needed)
                    parkingLimit = MaxDeferredModelsWithHeadroom;
            }
        }

        if (waited >= required && pending > 0 && inFlight == 0 && deferredModels < parkingLimit)
        {
            for (auto& item : g_nrRetired)
                if (BlocksNrRebuild(item))
                    item.deferred = true;
            LOG_WARN("DLSS-NR rebuild proceeding after {} ms: {} lease(s) whose game command list was never reset "
                     "(finishedNotReset={} unsubmitted={} unresolved={} unknown={}); previous model kept parked "
                     "until real retirement ({} deferred model(s) held, tick={})",
                     waited, pending, finishedNotReset, unsubmitted, unresolved, unknown, deferredModels + 1, now);
            if (deferredModels >= MaxDeferredModels)
                LOG_WARN("DLSS-NR parked beyond the usual {} models: {} MiB of video memory free", MaxDeferredModels,
                         parkingHeadroom / 1048576);
            g_nr.rebuildWaitStartMs = 0;
            g_nr.rebuildWaitLogMs = 0;
        }
        else
        {
            if (now - g_nr.rebuildWaitLogMs >= WaitLogIntervalMs)
            {
                LOG_WARN("DLSS-NR rebuild waiting {} ms on previous model leases: inFlight={} finishedNotReset={} "
                         "unsubmitted={} unresolved={} unknown={} deferredModels={}{}",
                         waited, inFlight, finishedNotReset, unsubmitted, unresolved, unknown, deferredModels,
                         deferredModels >= parkingLimit ? " (parked-model limit reached; waiting for real retirement)" : "");
                g_nr.rebuildWaitLogMs = now;
            }
            g_nr.reason = "Waiting for previous neural-rendering model work to finish before rebuilding";
            ReportSkipOnce(g_nr.reason);
            device->Release();
            return;
        }
    }
    else
    {
        g_nr.rebuildWaitStartMs = 0;
        g_nr.rebuildWaitLogMs = 0;
    }

    if (g_nr.output == nullptr)
    {
        g_nr.output = CreateScratch(device, desc.Format, workWidth, workHeight);
        g_nr.colorCopy = CreateScratch(device, desc.Format, width, height);
        g_nr.hdrCopy = CreateScratch(device, desc.Format, width, height);
        g_nr.workWidth = workWidth;
        g_nr.workHeight = workHeight;
    }

    if (cropColor && g_nr.activeColor == nullptr)
        g_nr.activeColor = CreateScratch(device, desc.Format, width, height);
    if (cropColor && g_nr.activeColor == nullptr)
    {
        g_nr.failed = true;
        g_nr.reason = "the pre-SR active colour staging texture could not be allocated";
        LOG_ERROR("DLSS-NR unavailable: {}", g_nr.reason);
        device->Release();
        return;
    }

    // All carriers rest in NPSR, including their first use. CreateScratch starts
    // in UAV, so transition only newly allocated resources here.
    if (residualAcrossRr)
    {
        auto ensureReadable = [&](ID3D12Resource*& resource, DXGI_FORMAT format, unsigned w, unsigned h)
        {
            if (resource == nullptr)
            {
                resource = CreateScratch(device, format, w, h);
                if (resource)
                    Barrier(cmdList, resource, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            }
            return resource != nullptr;
        };
        if (_residualPipelineState == nullptr ||
            !ensureReadable(g_nr.residualEdited, desc.Format, width, height) ||
            !ensureReadable(g_nr.residualHistory[0], DXGI_FORMAT_R16G16B16A16_FLOAT, width, height) ||
            !ensureReadable(g_nr.residualHistory[1], DXGI_FORMAT_R16G16B16A16_FLOAT, width, height) ||
            !ensureReadable(g_nr.residualComposed, g_nr.residualOutputFormat,
                            g_nr.residualOutputWidth, g_nr.residualOutputHeight))
        {
            ReportSkipOnce("RR residual resources unavailable; preserving the game's colour");
            g_nr.residualStoreValid = false;
            g_nr.residualHistoryPrimed = false;
            device->Release();
            return;
        }
    }

    if (requestedPasses == 1)
    {
        // Reclaim the extra raster and clear its failure latch. Raising the count later gets one fresh
        // allocation attempt; holding a failing allocation at two must not retry it every frame.
        if (!retainDormantPasses) {
            ParkNrResource(g_nr.passScratch);
            g_nr.passScratchFailed = false;
        }
    }
    else if (g_nr.passScratch == nullptr && !g_nr.passScratchFailed)
    {
        g_nr.passScratch = CreateScratch(device, desc.Format, workWidth, workHeight);
        g_nr.passScratchFailed = g_nr.passScratch == nullptr;

        if (g_nr.passScratchFailed)
            LOG_ERROR("DLSS-NR: could not allocate the model-output ping-pong; extra passes are disabled");
    }

    if (reduced && g_nr.colorSmall == nullptr)
        g_nr.colorSmall = CreateScratch(device, desc.Format, workWidth, workHeight);

    // The down-leg target is native (the answer is brought back to frame size before the resolve).
    if (workScale > 1.0f && g_nr.outputNative == nullptr)
        g_nr.outputNative = CreateScratch(device, desc.Format, width, height);

    if (g_nr.meter == nullptr)
    {
        g_nr.meter = CreateScratch(device, DXGI_FORMAT_R32_FLOAT, kDlssNrMeterGrid, kDlssNrMeterGrid);

        D3D12_HEAP_PROPERTIES readback {};
        readback.Type = D3D12_HEAP_TYPE_READBACK;

        D3D12_RESOURCE_DESC bufferDesc {};
        bufferDesc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        bufferDesc.Width = kMeterBytes;
        bufferDesc.Height = 1;
        bufferDesc.DepthOrArraySize = 1;
        bufferDesc.MipLevels = 1;
        bufferDesc.Format = DXGI_FORMAT_UNKNOWN;
        bufferDesc.SampleDesc.Count = 1;
        bufferDesc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;

        for (auto& rb : g_nr.meterReadback)
        {
            if (FAILED(device->CreateCommittedResource(&readback, D3D12_HEAP_FLAG_NONE, &bufferDesc,
                                                       D3D12_RESOURCE_STATE_COPY_DEST, nullptr,
                                                       IID_PPV_ARGS(&rb))))
            {
                rb = nullptr;
                LOG_WARN("DLSS-NR: the white point meter could not allocate its readback; falling back "
                         "to the paper white slider");
            }
        }

        if (g_nr.meter != nullptr)
            LOG_INFO("DLSS-NR: white point meter up, {}x{} tiles", kDlssNrMeterGrid, kDlssNrMeterGrid);
    }

    if (g_nr.feature == nullptr && g_nr.output != nullptr && g_nr.colorCopy != nullptr &&
        g_nr.hdrCopy != nullptr)
    {
        auto snippet = FindSelectedModel();

        if (!snippet.has_value())
        {
            g_nr.failed = true;
            g_nr.reason = "Model not found: nvngx_dlssnr.dll. Close the simulator, open Components > Neural rendering in OptiShade Manager, install or repair the model, then restart the simulator. The nvngx.dll_dlssnr.dll helper is a different file.";
            LOG_ERROR("DLSS-NR unavailable: {}", g_nr.reason);
            device->Release();
            return;
        }

        if (!EnsurePassParameters(0)) { device->Release(); return; }
        SetExtras(cfg, nullptr, nullptr, 0, 0, 0, 0, g_nr.passParams[0]);
        const auto tuning = PassTuning(cfg, 0);
        ResTrack_Dx12::HookLateNrQueue(device);
        if (!g_nr.featureCreation.Arm(cmdList)) {
            g_nr.failed=true;g_nr.reason="Model creation completion tracking could not be created";
            device->Release();return;
        }
        NoteNrModelBirth(0);
        g_nr.feature =
            g_nr.create(snippet->wstring().c_str(), State::Instance().NVNGX_ApplicationDataPath.c_str(),
                        device, cmdList, g_nr.passParams[0], workWidth, workHeight,
                        (int) PassPreset(cfg, 0),
                        tuning.intensity, (int) PassStyle(cfg, 0),
                        tuning.structure, tuning.tone, tuning.skin,
                        tuning.autoMask ? 1 : 0,
                        // UI correction at the model's own default: with no UI layer fed to it there
                        // is nothing for it to correct.
                        1);
        g_nr.featureFirstEvaluationPending = g_nr.feature != nullptr;

        if (g_nr.feature == nullptr)
        {
            g_nr.featurePendingSubmission = false;
            g_nr.failed = true;
            g_nr.reason = "the model would not initialise";
            if (g_nr.lastModelError && *g_nr.lastModelError())
            {
                g_nr.modelError = g_nr.lastModelError();
                g_nr.reason = g_nr.modelError.c_str();
            }
            const auto initResult = (unsigned int) (g_nr.lastInit != nullptr ? *g_nr.lastInit : 0);
            const auto createResult = (unsigned int) (g_nr.lastCreate != nullptr ? *g_nr.lastCreate : 0);

            if(initResult==0xBAD00001u||createResult==0xBAD00001u)g_nr.reason="Installed Neural Rendering model is not compatible with this GPU/driver";
            // Cast before formatting. These are ints, and "0x{:X}" on a negative int prints
            // 0x-452FFFFF, which no one can decode back to 0xBAD00001.
            LOG_ERROR("DLSS-NR create failed: init 0x{:X} ({}), create 0x{:X} ({})", initResult,
                      NgxResultName(initResult), createResult, NgxResultName(createResult));
            device->Release();
            return;
        }

        g_nr.width = width;
        g_nr.height = height;
        g_nr.beforeUpscale = frame.BeforeUpscale;
        g_nr.rayReconstruction = frame.RayReconstruction;
        g_nr.reset = true;
        g_nr.featurePendingSubmission = true;
        g_nr.featureCreateEpoch = frame.SubmissionEpoch;
        RecordBuiltPrimaryTuning(cfg);
        LOG_INFO("DLSS-NR model feature created from {}", snippet->string());
        LOG_INFO("DLSS-NR running {}: target {}x{}, model {}x{}, guides {}x{} "
                 "(preset {}, intensity {}, style {}, build epoch {})",
                 frame.RayReconstruction ? (frame.BeforeUpscale ? "before RR+SR" : "after RR+SR") :
                     (frame.BeforeUpscale ? "before SR" : "after SR"),
                 width, height, workWidth, workHeight,
                 guideWidth, guideHeight, g_nr.builtPreset[0], g_nr.builtIntensity, g_nr.builtStyle[0],
                 frame.SubmissionEpoch);

        // Creating and evaluating a feature in the same command list is the dice-roll that hung the
        // GPU (every crash died on a creation frame). The creation goes through the game's own submit
        // first; the first evaluate happens next frame. One frame without the model is invisible.
        device->Release();
        return;
    }

    if (g_nr.feature == nullptr)
    {
        device->Release();
        return;
    }

    // Only the actual creation recording's post-Execute fence can admit evaluation.
    // Later frame/Present counters also advance when Close fails or a list is discarded.
    if (g_nr.featurePendingSubmission)
    {
        if (g_nr.featureCreation.Failed()) {
            g_nr.failed=true;g_nr.reason="Model creation recording failed or was discarded before submission. Restart before retrying.";
            LOG_ERROR("DLSS-NR: refusing evaluation of an unsubmitted model creation recording");
            device->Release();return;
        }
        if (!g_nr.featureCreation.Ready())
        {
            device->Release();
            return;
        }

        g_nr.featurePendingSubmission = false;
        LOG_INFO("DLSS-NR: primary feature creation GPU fence completed (recording epoch {})", g_nr.featureCreateEpoch);
    }

    // Park no-longer-requested feature histories immediately (their actual release remains deferred),
    // and clear their failure latch so a later 1 -> N change is a deliberate retry.
    for (unsigned int pass = 1; pass < DlssNr::MaxPassCount; ++pass)
    {
        if (pass >= requestedPasses)
        {
            if (retainDormantPasses && pass < cfg.DlssNrPasses.value_or_default()) {
                if (g_nr.passFeature[pass]) g_nr.passNeedsReset[pass] = true;
                continue;
            }
            ParkNrFeature(g_nr.passFeature[pass]);
            g_nr.passNeedsReset[pass] = false;
            g_nr.passCreateFailed[pass] = false;
            g_nr.passPendingSubmission[pass] = false;
        }
    }

    // Do not create another feature, and do not evaluate any feature, while a requested layer still
    // belongs to the current submission epoch. This keeps multiple upscaler evaluations recorded on
    // one command list from recreating the historical create/evaluate GPU hang.
    for (unsigned int pass = 1; pass < requestedPasses; ++pass)
    {
        if (!g_nr.passPendingSubmission[pass])
            continue;

        if (g_nr.passCreation[pass].Failed()) {
            g_nr.failed=true;g_nr.reason="A model pass creation recording was discarded before submission. Restart before retrying.";
            device->Release();return;
        }
        if (!g_nr.passCreation[pass].Ready())
        {
            device->Release();
            return;
        }

        g_nr.passPendingSubmission[pass] = false;
        LOG_INFO("DLSS-NR: feature for pass {} creation GPU fence completed (recording epoch {})", pass + 1,
                 g_nr.passCreateEpoch[pass]);
    }

    // Build at most one missing extra feature on this invocation and evaluate nothing afterwards.
    // NGX feature creation records work on the supplied command list; evaluating that feature before
    // the list has been submitted is the creation-frame GPU hang that caused the old multi-pass path
    // to be removed. A new feature therefore gets an entire build-only frame and starts next time.
    if (g_nr.passScratch != nullptr)
    {
        for (unsigned int pass = 1; pass < requestedPasses; ++pass)
        {
            if (g_nr.passFeature[pass] != nullptr)
                continue;

            if (g_nr.passCreateFailed[pass])
                break;

            auto snippet = FindSelectedModel();

            if (!snippet.has_value())
            {
                g_nr.passCreateFailed[pass] = true;
                LOG_ERROR("DLSS-NR: pass {} feature not built because {} disappeared",
                          pass + 1, SelectedModelFile());
            }
            else
            {
                if (!EnsurePassParameters(pass)) { device->Release(); return; }
                SetExtras(cfg, nullptr, nullptr, 0, 0, 0, 0, g_nr.passParams[pass]);
                const auto tuning = PassTuning(cfg, pass);
                if (!g_nr.passCreation[pass].Arm(cmdList)) {
                    g_nr.passCreateFailed[pass]=true;device->Release();return;
                }
                NoteNrModelBirth(pass);
                g_nr.passFeature[pass] = g_nr.create(
                    snippet->wstring().c_str(), State::Instance().NVNGX_ApplicationDataPath.c_str(),
                    device, cmdList, g_nr.passParams[pass], workWidth, workHeight,
                    (int) PassPreset(cfg, pass), tuning.intensity,
                    (int) PassStyle(cfg, pass),
                    tuning.structure, tuning.tone, tuning.skin,
                    tuning.autoMask ? 1 : 0, 1);
                g_nr.passFirstEvaluationPending[pass] = g_nr.passFeature[pass] != nullptr;

                if (g_nr.passFeature[pass] != nullptr)
                {
                    g_nr.builtPreset[pass] = PassPreset(cfg, pass);
                    g_nr.builtPassTuning[pass] = tuning;
                    g_nr.builtStyle[pass] = PassStyle(cfg, pass);
                    g_nr.passNeedsReset[pass] = true;
                    g_nr.passPendingSubmission[pass] = true;
                    g_nr.passCreateEpoch[pass] = frame.SubmissionEpoch;
                    LOG_INFO("DLSS-NR: feature for pass {} built with preset {}, style {} at epoch {}; "
                             "waiting for submission",
                             pass + 1, g_nr.builtPreset[pass], g_nr.builtStyle[pass],
                             frame.SubmissionEpoch);
                }
                else
                {
                    g_nr.passPendingSubmission[pass] = false;
                    g_nr.passCreateFailed[pass] = true;
                    LOG_ERROR("DLSS-NR: feature for pass {} failed to build; {} earlier pass(es) retained, stack not activated",
                              pass + 1, pass);
                }
            }

            device->Release();
            return;
        }
    }

    if(requestedPasses>1) {
        bool complete=g_nr.passScratch!=nullptr;
        for(unsigned pass=1;pass<requestedPasses;++pass)
            complete &= g_nr.passFeature[pass] && g_nr.passParams[pass] && !g_nr.passPendingSubmission[pass] && !g_nr.passCreateFailed[pass];
        if(!complete){
            g_nr.failed=true;g_nr.reason="The requested NR stack could not be prepared in full; reduce passes and Retry";
            device->Release();return;
        }
    }

    // The upscaler has just written this, so it is a UAV. The model needs it readable.
    // Whether the buffer the upscaler just wrote is linear HDR or an already tone-mapped picture is not
    // something to assume: the game says so, in the flags it created its own DLSS feature with. Running
    // the colour transform over a frame that has already been through a tonemapper is pure damage, and
    // skipping it on one that has not leaves the model reading ordinary values as enormously bright.
    // EvaluateInternal has already combined the game's HDR flag with the authoritative output format.
    // That authority matters before SR: Color and Output may use different surface formats while still
    // representing the same frame colour space.
    const bool isHdrBuffer = frame.ColourIsLinearHdr;

    auto& reportedColour = optishade::route::OutputOwned<NrEngineState,1>().loggedColour;
    const int colourNow = (isHdrBuffer ? 2 : 0) | (frame.BeforeUpscale ? 1 : 0);

    if (reportedColour != colourNow)
    {
        reportedColour = colourNow;
        LOG_INFO("DLSS-NR {} SR: the game's DLSS colour space is {} so the colour transform is {}",
                 frame.BeforeUpscale ? "before" : "after",
                 isHdrBuffer ? "linear HDR" : "already tone-mapped",
                 isHdrBuffer ? "on" : "off");
    }

    const bool haveCodec = IsInit();

    if (!haveCodec)
    {
        g_nr.failed = true;
        g_nr.reason = "the colour codec would not compile";
        LOG_ERROR("DLSS-NR unavailable: {}", g_nr.reason);
        device->Release();
        return;
    }

    // What the upscaler produces is linear HDR with an open-ended range; the model was trained on
    // finished, sRGB-encoded frames. The white point is what maps one to the other, and it is a property
    // of the game's exposure rather than a number worth asking anyone to guess: measured means of 0.065,
    // 1.8 and 185 have all been seen in this one game.
    ++g_frames;
    TickNrRetired();
    CheckCaptureTrigger();

    if (g_capture.isActive())
    {
        const auto captureDir = Util::DllPath().remove_filename() / "dlssnr-capture";
        const auto written = g_capture.write(captureDir);

        if (!written.empty())
            LOG_INFO("DLSS-NR wrote matched before/after frames to {}", written);
    }

    // Paper white, and nothing else. The frame is divided by this and encoded, and the soft knee
    // above 0.75 takes whatever is left over.
    //
    // It used to be divided by a white point measured from the frame -- around 3 in Cyberpunk -- which
    // was right for the old composition, where the encode had to be inverted and highlights therefore
    // had to survive it. Under the composition this now uses it is actively wrong twice over: the
    // model is handed a picture three times darker than it should see, and the highlight branch is
    // defeated. That branch hands back `originalLuma - proxyLuma`, the headroom the proxy could not
    // represent -- it exists precisely because the proxy is meant to clip. Normalising the highlights
    // away first leaves it nothing to give back.

    ResTrack_Dx12::HookLateNrQueue(device);
    if (g_gpuTime == nullptr)
        g_gpuTime = std::make_unique<DlssNrGpuTime>(device, "total");

    if (g_ngxTime == nullptr)
        g_ngxTime = std::make_unique<DlssNrGpuTime>(device, "model");

    if (g_gpuTime != nullptr)
        g_gpuTime->Start(cmdList, observation);

    // Copy just the live image, not the stale right/bottom margins. Do this only after model
    // creation/pending-submission early returns, and inside the measured GPU interval. The compact
    // texture lets every existing codec/compare/hold/capture path use unmodified pixel coordinates.
    ID3D12Resource* const gameColor = target;
    if (cropColor)
    {
        TransitionTarget(D3D12_RESOURCE_STATE_COPY_SOURCE);
        Barrier(cmdList, g_nr.activeColor, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                D3D12_RESOURCE_STATE_COPY_DEST);
        DlssNr::CopyActiveColor(cmdList, g_nr.activeColor, gameColor, *active);
        TransitionTarget(outputArrival);
        Barrier(cmdList, g_nr.activeColor, D3D12_RESOURCE_STATE_COPY_DEST,
                D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        target = g_nr.activeColor;
        targetState = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    }

    const auto FinishColor = [&](bool copyBack)
    {
        if (cropColor)
        {
            if (copyBack)
            {
                TransitionTarget(D3D12_RESOURCE_STATE_COPY_SOURCE);
                Barrier(cmdList, gameColor, outputArrival, D3D12_RESOURCE_STATE_COPY_DEST);
                DlssNr::CopyActiveColor(cmdList, gameColor, target, *active);
                Barrier(cmdList, gameColor, D3D12_RESOURCE_STATE_COPY_DEST, outputArrival);
            }
            TransitionTarget(D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        }
        else
        {
            TransitionTarget(outputArrival);
        }
    };

    // Abort before model/output use when a prerequisite shader fails. Restore
    // only the scratch states actually reached; keep the caller's colour intact.
    const auto AbortPreparation = [&](const char* why, bool proxyReadable, bool smallReadable,
                                      bool depthReadable=false, bool motionReadable=false) {
        g_nr.failed=true; g_nr.reason=why;
        LOG_ERROR("DLSS-NR preparation aborted: {}",why);
        if(depthReadable&&g_nr.depthClone)Barrier(cmdList,g_nr.depthClone,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_DEST);
        if(motionReadable&&g_nr.motionClone)Barrier(cmdList,g_nr.motionClone,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_DEST);
        if(smallReadable&&g_nr.colorSmall)Barrier(cmdList,g_nr.colorSmall,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        if(proxyReadable){
            Barrier(cmdList,g_nr.colorCopy,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            Barrier(cmdList,g_nr.hdrCopy,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        }
        FinishColor(false);
        if(g_gpuTime)g_gpuTime->End(cmdList);
        device->Release();
    };

    // Fetch the game's exposure, where the game supplies one and the user asked for it.
    //
    // This used to measure the white point off the frame as well, over a 64x64 grid of tile
    // luminances. That is gone: the pass writes the frame it was measuring, so the divisor chased its
    // own output -- one Enshrouded session walked it from 0.010 to 97.910, and toggling NR at a fixed
    // spot read 41.31 off against 0.46 on. What remains dispatches a single thread to copy the game's
    // 1x1 exposure texture into tile 0. That is a courier, not a measurement, and cannot feed back.
    // Gated on the source the menu actually writes. This read the retired WhitePointFromExposure
    // flag while consumption keyed on WhitePointSource == 1, so choosing "the game's own exposure"
    // never dispatched the meter and the white point silently fell back to the slider.
    const bool exposureSettingOn = cfg.DlssNrWhitePointSource.value_or_default() == 1;

    // Nothing held from before the option was switched off may survive switching it back on. See
    // InvalidateExposureMeter for what froze and why it read as a colour cast.
    if (exposureSettingOn && !g_nr.exposureSettingWasOn)
    {
        InvalidateExposureMeter();
        LOG_INFO("DLSS-NR exposure: option switched on, held reading discarded");
    }

    g_nr.exposureSettingWasOn = exposureSettingOn;

    const bool wantExposure = exposureSettingOn && frame.ExposureTexture != nullptr;

    if (g_nr.meter != nullptr && wantExposure)
    {
        DlssNrConstants meterParams {};
        meterParams.Mode = DlssNrMode_Meter;

        // One pixel. Only tile (0,0) is read back, and the tile-mean branch below it in the shader is
        // dead code the dispatch simply never reaches.
        meterParams.Width = 1;
        meterParams.Height = 1;

        const D3D12_RESOURCE_STATES priorTargetState = targetState;
        TransitionTarget(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        if(!DispatchPass(cmdList, meterParams, target, nullptr, nullptr,
                     (ID3D12Resource*) frame.ExposureTexture, nullptr, g_nr.meter, nullptr)) {
            AbortPreparation("exposure preparation pass failed",false,false); return;
        }
        TransitionTarget(priorTargetState);

        CopyMeterToReadback(cmdList, device, true);
        ConsumeMeterReadback();
    }

    g_nr.gamePreExposure = frame.PreExposure;

    float whitePoint = frame.WhitePointOverride > 0.0f ? frame.WhitePointOverride : ResolveWhitePoint(cfg, isHdrBuffer);

    // Zero-latency exposure (D3D12, source 1): when the game hands us a live exposure texture, the
    // white point is recomputed in-shader every frame from it (ExposurePreMul / exposure) instead of
    // the 3-4 frame CPU meter readback. whitePoint above still rides along in gWhitePoint as the
    // fallback the shader uses if the live sample is missing or absurd. Bound at t4 (InPrevEdit) below.
    ID3D12Resource* exposureTex = nullptr;
    uint32_t useGameExposure = 0;
    float exposurePreMul = 0.0f;

    if (cfg.DlssNrWhitePointSource.value_or_default() == 1 && frame.ExposureTexture != nullptr)
    {
        exposureTex = (ID3D12Resource*) frame.ExposureTexture;
        useGameExposure = 1;
        const float trim = std::clamp(cfg.DlssNrWhitePointTrim.value_or_default(), 0.25f, 4.0f);
        exposurePreMul = g_nr.gamePreExposure * trim;
    }

    // Frame hold. Freeze the encode's input so a live setting change re-renders the same frame. This
    // is self-contained on purpose: it copies the output aside on hold-on and copies it BACK over the
    // live output before the encode reads it while held, so the encode's own path and barriers below
    // are untouched and the default (hold off) is byte-identical. See design/frame-hold.md.
    //
    // `target` is UAV here (normalised at entry, restored by the meter block above). The held copy is
    // left in COPY_SOURCE after capture and stays there for every restore.
    {
        const D3D12_RESOURCE_DESC holdDesc = target->GetDesc();
        // CreateScratch is one non-MSAA 2D subresource. CopyResource requires
        // compatible dimensions, mip/array counts and sample descriptions.
        const bool holdCompatible = holdDesc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE2D &&
                                    holdDesc.DepthOrArraySize == 1 && holdDesc.MipLevels == 1 &&
                                    holdDesc.SampleDesc.Count == 1 && holdDesc.SampleDesc.Quality == 0;
        const bool hold = cfg.DlssNrHoldFrame.value_or_default() && holdCompatible;
        if (cfg.DlssNrHoldFrame.value_or_default() && !holdCompatible)
        {
            LOG_WARN("Hold Frame disabled: unsupported texture shape (dimension={}, array={}, mips={}, samples={})",
                     (int) holdDesc.Dimension, holdDesc.DepthOrArraySize, holdDesc.MipLevels,
                     holdDesc.SampleDesc.Count);
            Config::Instance()->DlssNrHoldFrame = false;
        }

        if (hold)
        {
            const D3D12_RESOURCE_DESC td = target->GetDesc();
            const bool needCapture = !g_nr.heldActive || g_nr.heldColor == nullptr ||
                                     (unsigned int) td.Width != g_nr.heldWidth ||
                                     td.Height != g_nr.heldHeight || td.Format != g_nr.heldFormat;

            if (needCapture)
            {
                // Hold-on (or the output changed shape under a hold): capture THIS frame, do not
                // restore -- target already holds the frame to freeze, and the pass runs on it.
                if (g_nr.heldColor != nullptr)
                    ParkNrResource(g_nr.heldColor);

                g_nr.heldActive = false;
                g_nr.heldColor = CreateScratch(device, td.Format, (unsigned int) td.Width, td.Height);

                if (g_nr.heldColor != nullptr)
                {
                    const D3D12_RESOURCE_STATES priorTargetState = targetState;
                    TransitionTarget(D3D12_RESOURCE_STATE_COPY_SOURCE);
                    Barrier(cmdList, g_nr.heldColor, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                            D3D12_RESOURCE_STATE_COPY_DEST);
                    cmdList->CopyResource(g_nr.heldColor, target);
                    Barrier(cmdList, g_nr.heldColor, D3D12_RESOURCE_STATE_COPY_DEST,
                            D3D12_RESOURCE_STATE_COPY_SOURCE);
                    TransitionTarget(priorTargetState);

                    g_nr.heldActive = true;
                    g_nr.heldWidth = (unsigned int) td.Width;
                    g_nr.heldHeight = td.Height;
                    g_nr.heldFormat = td.Format;
                    g_nr.heldWhitePoint = whitePoint;
                }
                else
                {
                    Config::Instance()->DlssNrHoldFrame = false;
                    LOG_WARN("Hold Frame disabled: snapshot allocation failed ({}x{}, format={})",
                             td.Width, td.Height, (int) td.Format);
                }
            }
            else
            {
                // Held: restore the frozen frame onto the live output before the encode reads it.
                const D3D12_RESOURCE_STATES priorTargetState = targetState;
                TransitionTarget(D3D12_RESOURCE_STATE_COPY_DEST);
                cmdList->CopyResource(target, g_nr.heldColor);
                TransitionTarget(priorTargetState);
            }

            // Suspend white-point measurement while held: use the snapshot so it cannot drift and
            // confound the comparison. (No-op on the capture frame, where the snapshot IS whitePoint.)
            if (g_nr.heldActive)
                whitePoint = g_nr.heldWhitePoint;
        }
        else if (g_nr.heldActive)
        {
            // Released: let go of the frozen frame and resume live input next frame.
            if (g_nr.heldColor != nullptr)
                ParkNrResource(g_nr.heldColor);
            g_nr.heldActive = false;
        }
    }

    DlssNrConstants encodeParams {};
    encodeParams.Mode = DlssNrMode_Encode;
    // A frame that is already display-referred is handed over untouched: the encode becomes a copy and
    // the resolve adds the model's edit back at full scale.
    encodeParams.Passthrough = isHdrBuffer ? 0u : 1u;
    encodeParams.WhitePoint = whitePoint;
    encodeParams.UseGameExposure = useGameExposure;
    encodeParams.ExposurePreMul = exposurePreMul;
    encodeParams.ReversibleMode = cfg.DlssNrReversibleMode.value_or_default();
    // Match only takes effect once a fit exists; until then the table is empty and the shader would
    // read a curve of zeros, so it falls back to the plain proxy.
    encodeParams.Width = width;
    encodeParams.Height = height;

    TransitionTarget(D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    if(!DispatchPass(cmdList, encodeParams, target, nullptr, nullptr, nullptr, exposureTex,
                        g_nr.colorCopy, g_nr.hdrCopy)) {
        AbortPreparation("colour preparation pass failed",false,false); return;
    }

    if (targetSupportsUav)
        TransitionTarget(D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    // The transitions double as the wait for the encode's writes.
    Barrier(cmdList, g_nr.colorCopy, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    // Measure the buffer's scale from the copy the encode just kept -- untouched, so there is no path
    // (Calibration pass removed: it produced only a menu suggestion nothing consumed, at the cost
    // of a 4096-thread dispatch, a readback and an nth_element every frame.)

    Barrier(cmdList, g_nr.hdrCopy, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);

    // Below full resolution the model is shown a filtered shrink of the proxy; the edit it returns is
    // enlarged during the resolve while the frame underneath stays full size and untouched.
    ID3D12Resource* modelInput = g_nr.colorCopy;

    if (reduced && g_nr.colorSmall != nullptr)
    {
        bool built = false;

        if (workScale > 1.0f)
        {
            // Supersample: enlarge the proxy to the larger working size with a real upscaling filter
            // (the Output Scaling upsampler) so the model sees a clean super-native input, rather than
            // the box minifier which only makes sense going down. colorCopy is NON_PIXEL_SHADER_RESOURCE
            // from the encode (SRV-ready); colorSmall is UNORDERED_ACCESS from last frame's resolve.
            // (Re)build the supersample scalers when missing or when the NR downscaler changed (the
            // filter is baked at construction). Both use NR's own DlssNrScalingDownscaler, independent
            // of Output Scaling, so the two can run different filters at once. superDown is built here
            // and used after the model (the down-leg below).
            const Scaler nrScaler = cfg.DlssNrScalingDownscaler.value_or_default();
            if (g_nr.nrScaler != nrScaler)
            {
                if (g_nr.superUp != nullptr)   { delete g_nr.superUp;   g_nr.superUp = nullptr; }
                if (g_nr.superDown != nullptr) { delete g_nr.superDown; g_nr.superDown = nullptr; }
                g_nr.nrScaler = nrScaler;
            }
            if (g_nr.superUp == nullptr)
                g_nr.superUp = new OS_Dx12("DLSS-NR supersample up", device, true, nrScaler);
            if (g_nr.superDown == nullptr)
                g_nr.superDown = new OS_Dx12("DLSS-NR supersample down", device, false, nrScaler);

            if (g_nr.superUp != nullptr &&
                g_nr.superUp->Dispatch(cmdList, g_nr.colorCopy, g_nr.colorSmall))
            {
                Barrier(cmdList, g_nr.colorSmall, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                        D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
                built = true;
            }
        }

        if (!built)
        {
            if (workScale > 1.0f)
            {
                // Wanted to supersample but the upscaler was not available -- warn once; the box path
                // below can only enlarge blockily, so the user should know the clean path is off.
                static bool warnedSuper = false;
                if (!warnedSuper)
                {
                    warnedSuper = true;
                    LOG_WARN("DLSS-NR supersample: upscaler unavailable, falling back to a blocky enlarge.");
                }
            }

            // Sub-native (or the upsampler could not be built): box-resample the proxy to the work size.
            DlssNrConstants down {};
            down.Mode = DlssNrMode_Downsample;
            down.Width = workWidth;
            down.Height = workHeight;
            if (foveated)
            {
                down.Foveate = 1;
                down.FovMinX = (float) fovX / (float) width;
                down.FovMinY = (float) fovY / (float) height;
                down.FovMaxX = (float) (fovX + fovW) / (float) width;
                down.FovMaxY = (float) (fovY + fovH) / (float) height;
                down.FovFeather = std::clamp(std::isfinite(cfg.DlssNrVrFoveaFeather.value_or_default()) ? cfg.DlssNrVrFoveaFeather.value_or_default() : 0.25f, 0.02f, 1.0f);
            }
            if(!DispatchPass(cmdList, down, modelInput, nullptr, nullptr, nullptr, nullptr,
                                g_nr.colorSmall, nullptr)) {
                AbortPreparation("working-resolution preparation pass failed",true,false); return;
            }
            Barrier(cmdList, g_nr.colorSmall, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        }

        modelInput = g_nr.colorSmall;
    }

    // Read the exposure scan's candidates on the pass's own command list, once a frame.
    DlssNr::ExposureScan::Tick(device, cmdList);

    ID3D12Resource* depthIn = ReadableGuide(device, cmdList, depth, &g_nr.depthClone);
    ID3D12Resource* motionIn = ReadableGuide(device, cmdList, motion, &g_nr.motionClone);

    if (depthIn == nullptr || motionIn == nullptr)
    {
        g_nr.failed = true;
        g_nr.reason = "the game's depth or motion vectors could not be made readable";
        LOG_ERROR("DLSS-NR unavailable: {}", g_nr.reason);
        AbortPreparation(g_nr.reason,true,reduced,depthIn!=nullptr,motionIn!=nullptr);
        return;
    }

    // These are still the game's guide textures. Scaling them by the colour working
    // resolution changes the represented motion without resampling the guide.
    const auto motionReferenceWidth = frame.MotionVectorsLowResolution ? frame.RenderSubrectWidth : frame.OutputWidth;
    const auto motionReferenceHeight = frame.MotionVectorsLowResolution ? frame.RenderSubrectHeight : frame.OutputHeight;
    const float mvToWorkX = DlssNr::MotionScaleForGuide(motionWidth, motionReferenceWidth);
    const float mvToWorkY = DlssNr::MotionScaleForGuide(motionHeight, motionReferenceHeight);

    SetExtras(cfg, nullptr, nullptr, 0, 0, 0, 0);

    // Foveated: the model's guides cover the same window as its colour. Motion keeps the
    // full-frame scale above -- a pixel of motion is the same pixel inside the window.
    unsigned int evalGuideW = guideWidth, evalGuideH = guideHeight, evalMotionW = motionWidth, evalMotionH = motionHeight;
    unsigned int evalDepthX = depthBaseX, evalDepthY = depthBaseY, evalMotionX = motionBaseX, evalMotionY = motionBaseY;
    if (foveated)
    {
        const auto part = [](unsigned int value, unsigned int extent, unsigned int full) {
            return (unsigned int) ((uint64_t) value * extent / std::max(full, 1u));
        };
        evalDepthX = depthBaseX + part(fovX, guideWidth, width);
        evalDepthY = depthBaseY + part(fovY, guideHeight, height);
        evalGuideW = std::max(1u, part(fovW, guideWidth, width));
        evalGuideH = std::max(1u, part(fovH, guideHeight, height));
        evalMotionX = motionBaseX + part(fovX, motionWidth, width);
        evalMotionY = motionBaseY + part(fovY, motionHeight, height);
        evalMotionW = std::max(1u, part(fovW, motionWidth, width));
        evalMotionH = std::max(1u, part(fovH, motionHeight, height));
    }

    // The proxy path, when asked for. Same inputs, same model -- the difference is who calls it.
    //
    // Nothing falls back automatically. A silent fallback would mean never finding out the proxy
    // path was broken: the picture would look right either way, because the forwarder would be
    // quietly doing the work.
    if (cfg.DlssNrUseProxy.value_or_default())
    {
        const unsigned int proxyResult = DlssNr::Proxy::Run(
            cmdList, device, modelInput, depthIn, motionIn, g_nr.output, workWidth, workHeight,
            guideWidth, guideHeight, motionWidth, motionHeight, depthBaseX, depthBaseY,
            motionBaseX, motionBaseY, g_nr.guideDepthInverted, g_nr.reset,
            g_nr.guideMvScaleX * mvToWorkX, g_nr.guideMvScaleY * mvToWorkY);

        g_nr.reset = false;

        if (proxyResult != 1)
        {
            g_nr.failed = true;
            g_nr.reason = "the proxy path could not run the model";
            LOG_ERROR("DLSS-NR (proxy): evaluate returned 0x{:X} ({}), disabling for this session",
                      proxyResult, NgxResultName(proxyResult));
        }

        if (g_nr.depthClone) Barrier(cmdList,g_nr.depthClone,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_DEST);
        if (g_nr.motionClone) Barrier(cmdList,g_nr.motionClone,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_DEST);
        if (reduced && g_nr.colorSmall) Barrier(cmdList,g_nr.colorSmall,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        Barrier(cmdList,g_nr.colorCopy,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        Barrier(cmdList,g_nr.hdrCopy,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        FinishColor(false);
        if (g_gpuTime) g_gpuTime->End(cmdList);
        device->Release();
        return;
    }

    if (g_ngxTime != nullptr)
        g_ngxTime->Start(cmdList);

    // Readiness was admitted atomically before touching the game's image.
    const unsigned int effectivePasses = requestedPasses;

    {
        static unsigned int loggedRequested = 0;
        static unsigned int loggedConfigured = 0;
        static unsigned int loggedEffective = 0;
        if (loggedRequested != userRequestedPasses || loggedConfigured != configuredPasses ||
            loggedEffective != effectivePasses)
        {
            loggedRequested = userRequestedPasses;
            loggedConfigured = configuredPasses;
            loggedEffective = effectivePasses;
            LOG_INFO("DLSS-NR model passes: requested {}, session-configured {}, effective {}",
                     userRequestedPasses, configuredPasses, effectivePasses);
        }
    }

    // Encode happened once above. Keep that base proxy immutable and ping-pong only model answers:
    //   pass 0: base -> A, pass 1: A -> B, pass 2: B -> A.
    // The final answer is resolved once against the original base, so matched-residual transfer is the
    // cumulative final-minus-base edit and colour/transfer controls are not compounded.
    ID3D12Resource* passInput = modelInput;
    ID3D12Resource* passOutput = g_nr.output;
    ID3D12Resource* finalAnswer = nullptr;
    bool outputReadable = false;
    bool scratchReadable = false;

    const auto MakeModelReadable = [&](ID3D12Resource* resource)
    {
        bool& readable = resource == g_nr.output ? outputReadable : scratchReadable;
        if (!readable)
        {
            Barrier(cmdList, resource, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            readable = true;
        }
    };

    const auto MakeModelWritable = [&](ID3D12Resource* resource)
    {
        bool& readable = resource == g_nr.output ? outputReadable : scratchReadable;
        if (readable)
        {
            Barrier(cmdList, resource, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                    D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            readable = false;
        }
    };

    int result = NVSDK_NGX_Result_Success;
    bool compositionRecorded = false;

    for (unsigned int pass = 0; pass < effectivePasses && result == NVSDK_NGX_Result_Success;
         ++pass)
    {
        void* const passFeature = pass == 0 ? g_nr.feature : g_nr.passFeature[pass];
        bool& firstEvaluationPending = pass == 0 ? g_nr.featureFirstEvaluationPending
                                                  : g_nr.passFirstEvaluationPending[pass];
        const bool passReset = g_nr.reset || (pass > 0 && g_nr.passNeedsReset[pass]);
        // A slider edit is debounced before rebuilding the model. Evaluate every
        // layer with its creation-time tuning until that replacement is ready;
        // mixing old model history with new per-call tuning causes discontinuities.
        const auto tuning = g_nr.builtPassTuning[pass];

        MakeModelWritable(passOutput);
        SetExtras(cfg, nullptr, nullptr, 0, 0, 0, 0, g_nr.passParams[pass]);
        if (firstEvaluationPending)
        {
            LOG_INFO("DLSS-NR first feature evaluation entering provider: pass={} feature={:X} epoch={} "
                     "target={}x{} model={}x{} guides={}x{} motion={}x{} reset={}",
                     pass, reinterpret_cast<uintptr_t>(passFeature), frame.SubmissionEpoch,
                     width, height, workWidth, workHeight, guideWidth, guideHeight,
                     motionWidth, motionHeight, passReset);
        }
        result = g_nr.evaluate(
            cmdList, passFeature, g_nr.passParams[pass], passInput, depthIn, motionIn, passOutput,
            workWidth, workHeight, evalGuideW, evalGuideH, evalMotionW, evalMotionH,
            evalDepthX, evalDepthY, evalMotionX, evalMotionY, g_nr.guideDepthInverted ? 1 : 0,
            passReset ? 1 : 0, tuning.intensity,
            (int) g_nr.builtStyle[pass], tuning.structure,
            tuning.tone, tuning.skin,
            tuning.autoMask ? 1 : 0, g_nr.guideMvScaleX * mvToWorkX,
            g_nr.guideMvScaleY * mvToWorkY);

        if (firstEvaluationPending)
        {
            LOG_INFO("DLSS-NR first feature evaluation returned: pass={} feature={:X} epoch={} result=0x{:X}",
                     pass, reinterpret_cast<uintptr_t>(passFeature), frame.SubmissionEpoch,
                     static_cast<uint32_t>(result));
            firstEvaluationPending = false;
        }

        if (result != NVSDK_NGX_Result_Success)
            break;

        if (pass > 0)
            g_nr.passNeedsReset[pass] = false;

        finalAnswer = passOutput;
        MakeModelReadable(finalAnswer);

        if (pass + 1 < effectivePasses)
        {
            passInput = finalAnswer;
            passOutput = passOutput == g_nr.output ? g_nr.passScratch : g_nr.output;
        }
    }

    if (g_ngxTime != nullptr)
        g_ngxTime->End(cmdList);

    g_nr.reset = false;

    // Supersampling probe: report the model working ABOVE native so a test log tells us whether NGX even
    // accepts a super-native evaluate and what it returns. Once per working-size change, or on any error.
    if (workWidth > width || workHeight > height)
    {
        static unsigned int lastSuper = 0;
        if (lastSuper != workWidth || result != 1)
        {
            lastSuper = workWidth;
            LOG_INFO("DLSS-NR SUPERSAMPLE: model at {}x{} = {:.2f}x native {}x{}, evaluate result {} ({})",
                     workWidth, workHeight, (float) workWidth / (float) width, width, height, result,
                     NgxResultName((unsigned int) result));
        }
    }

    // Once, a few seconds in, so it lands after the values have been written at least once.
    static bool tuningReported = false;

    if (!tuningReported && g_frames > 240)
    {
        tuningReported = true;

        // This checks the parameter table, not whether the neural network uses a
        // setting. Multipass leaves the final pass's values in this shared table.
        auto report = [](const char* name, float wrote)
        {
            float value = 0.0f;
            const NVSDK_NGX_Result r = g_nr.passParams[0]->Get(name, &value);
            LOG_INFO("DLSS-NR readback {} -> {} (we wrote {}, result 0x{:X})", name, value, wrote,
                     (uint32_t) r);
        };

        const auto lastTuning = PassTuning(cfg, effectivePasses - 1);
        LOG_INFO("DLSS-NR parameter-table readback for pass {} (not proof of visual effect)", effectivePasses);
        report("DLSSNR.Intensity", lastTuning.intensity);
        report("DLSSNR.LocalStructureStrength", lastTuning.structure);
        report("DLSSNR.LocalToneStrength", lastTuning.tone);
        report("DLSSNR.SkinStructureStrength", lastTuning.skin);
        unsigned int autoMask = 0;
        const auto maskResult = g_nr.passParams[0]->Get("DLSSNR.UseAutoMask", &autoMask);
        LOG_INFO("DLSS-NR AutoMask readback: {} (wrote {}, result 0x{:X})", autoMask,
                 lastTuning.autoMask, (uint32_t) maskResult);

        unsigned int style = 0;
        const NVSDK_NGX_Result styleResult = g_nr.passParams[0]->Get("DLSSNR.Style", &style);
        LOG_DEBUG("DLSS-NR readback DLSSNR.Style -> {} (result 0x{:X})", style, (uint32_t) styleResult);

        // The preset is the last control whose arrival has never been checked, and three of them look
        // identical in play. Either it is not landing or the presets really are alike.
        unsigned int preset = 0;
        const NVSDK_NGX_Result presetResult =
            g_nr.passParams[0]->Get("DLSSNR.Hint.Render.Preset", &preset);
        LOG_DEBUG("DLSS-NR readback DLSSNR.Hint.Render.Preset -> {} (result 0x{:X}, we wrote {})", preset,
                 (uint32_t) presetResult, PassPreset(cfg, 0));

        LOG_DEBUG("DLSS-NR wrote intensity {}, local structure {}, local tone {}, skin {}, style {}",
                 cfg.DlssNrIntensity.value_or_default(), cfg.DlssNrLocalStructure.value_or_default(),
                 cfg.DlssNrLocalTone.value_or_default(), cfg.DlssNrSkinStructure.value_or_default(),
                 PassStyle(cfg, 0));
    }

    if (result == NVSDK_NGX_Result_Success)
    {
        // Resolve takes the difference between what the model returned and what it was shown, and adds
        // that back to the frame. At strength zero the result is what the upscaler produced, exactly, and
        // anything the model left alone is untouched rather than round-tripped through the curve.
        DlssNrConstants resolveParams {};
        resolveParams.Mode = DlssNrMode_Resolve;
        resolveParams.WhitePoint = whitePoint;
        resolveParams.UseGameExposure = useGameExposure;
        resolveParams.ExposurePreMul = exposurePreMul;
        resolveParams.Width = width;
        resolveParams.Height = height;
        resolveParams.TransferStrength = cfg.DlssNrTransferStrength.value_or_default();
        const auto strength = [](float v) { return std::isfinite(v) ? std::clamp(v, 0.0f, 1.0f) : 1.0f; };
        resolveParams.SkinProtection = cfg.DlssNrSkinProtection.value_or_default();
        resolveParams.ShowSkinMask = cfg.DlssNrShowSkinMask.value_or_default();
        resolveParams.SkinDetail = strength(cfg.DlssNrSkinDetail.value_or_default());
        resolveParams.SkinColour = cfg.DlssNrSkinToneEnabled.value_or_default() ? strength(cfg.DlssNrSkinColour.value_or_default()) : 0.0f;
        resolveParams.EnvironmentDetail = strength(cfg.DlssNrEnvironmentDetail.value_or_default());
        resolveParams.EnvironmentColour = strength(cfg.DlssNrEnvironmentColour.value_or_default());
        resolveParams.ColourStrength = cfg.DlssNrColourStrength.value_or_default();
        resolveParams.DebugView = cfg.DlssNrDebugView.value_or_default();
        resolveParams.MaxRatio = cfg.DlssNrMaxRatio.value_or_default();
        // Carry only the model's change back to the native ultrawide picture.
        // Classic transfer would interpret the input downsample's blur as an edit.
        resolveParams.Transfer = frame.EstimatedTaaGuides && reduced ? 1u : cfg.DlssNrTransfer.value_or_default();
        resolveParams.DebugScale = cfg.DlssNrWhitePointScale.value_or_default();
        resolveParams.Passthrough = isHdrBuffer ? 0u : 1u;
        resolveParams.ReversibleMode = cfg.DlssNrReversibleMode.value_or_default();
        resolveParams.ApplyModel = cfg.DlssNrApplyModel.value_or_default() ? 1u : 0u;
        resolveParams.CompareMode = cfg.DlssNrCompare.value_or_default();
        resolveParams.CompareSplit = cfg.DlssNrCompareSplit.value_or_default();
        resolveParams.CompareZoom = std::max(1.0f, cfg.DlssNrCompareZoom.value_or_default());
        resolveParams.CompareSwap = cfg.DlssNrCompareSwap.value_or_default() ? 1u : 0u;
        if (foveated)
        {
            resolveParams.Foveate = 1;
            resolveParams.FovMinX = (float) fovX / (float) width;
            resolveParams.FovMinY = (float) fovY / (float) height;
            resolveParams.FovMaxX = (float) (fovX + fovW) / (float) width;
            resolveParams.FovMaxY = (float) (fovY + fovH) / (float) height;
            resolveParams.FovFeather = std::clamp(std::isfinite(cfg.DlssNrVrFoveaFeather.value_or_default()) ? cfg.DlssNrVrFoveaFeather.value_or_default() : 0.25f, 0.02f, 1.0f);
        }

        // The numbers the composition actually ran with, logged when any of them changes.
        //
        // A colour report without these cannot be read. Paper white alone decides whether the model
        // was shown a sensible picture or a blown one, and it was absent from every log in the first
        // round of reports -- one tester's "much better at 16" had to be taken on trust because
        // nothing in the file said what the value was. Debug view and compare mode are here for the
        // same reason from the other direction: both change what is on screen, and a screenshot with
        // one left on is indistinguishable from a bug.
        struct ComposeReport
        {
            bool valid;
            float whitePoint;
            float transfer;
            float colour;
            float maxRatio;
            unsigned int passthrough;
            unsigned int debugView;
            unsigned int compareMode;
            unsigned int residual;
            unsigned int workW;
            unsigned int workH;
            unsigned int passes;
        };

        static ComposeReport loggedCompose {};
        static ULONGLONG lastComposeReport = 0;

        // Quantised to the precision it is printed at. Comparing raw floats logged 2376 lines in one
        // Enshrouded session, because a measured white point drifts continuously and every drift was a
        // change. A line per meaningful change is the point; a line per frame is a different problem.
        const ComposeReport composeNow { true,
                                         std::round(resolveParams.WhitePoint * 100.0f) / 100.0f,
                                         resolveParams.TransferStrength,
                                         resolveParams.ColourStrength,
                                         resolveParams.MaxRatio,
                                         resolveParams.Passthrough,
                                         resolveParams.DebugView,
                                         resolveParams.CompareMode,
                                         resolveParams.Transfer,
                                         g_nr.workWidth,
                                         g_nr.workHeight,
                                         effectivePasses };

        const bool composeChanged = !loggedCompose.valid || loggedCompose.whitePoint != composeNow.whitePoint ||
            loggedCompose.transfer != composeNow.transfer || loggedCompose.colour != composeNow.colour ||
            loggedCompose.maxRatio != composeNow.maxRatio ||
            loggedCompose.passthrough != composeNow.passthrough ||
            loggedCompose.debugView != composeNow.debugView ||
            loggedCompose.compareMode != composeNow.compareMode ||
            loggedCompose.residual != composeNow.residual || loggedCompose.workW != composeNow.workW ||
            loggedCompose.workH != composeNow.workH || loggedCompose.passes != composeNow.passes;
        // Dynamic exposure and interleaved views can change every frame. Retain
        // first effective state, then at most one composition summary per minute.
        const auto composeTime = GetTickCount64();
        if (composeChanged && (!loggedCompose.valid || composeTime - lastComposeReport >= 60000))
        {
            loggedCompose = composeNow;
            lastComposeReport = composeTime;
            LOG_INFO("DLSS-NR composition: paper white {:.2f}x, detail {:.2f}, colour {:.2f}, guard "
                     "{:.1f}x, colour transform {}, transfer {}, model {}x{}, passes {}, debug view {}, compare {}",
                     composeNow.whitePoint, composeNow.transfer, composeNow.colour, composeNow.maxRatio,
                     composeNow.passthrough != 0 ? "off (frame already tone mapped)" : "on (linear HDR)",
                     composeNow.residual == 1 ? "matched residual" : "classic", composeNow.workW,
                     composeNow.workH, composeNow.passes, composeNow.debugView, composeNow.compareMode);
        }

        // Supersampling down-leg. Average the Nx model answer back to native with the chosen filter, so
        // the resolve composites a native answer against the native proxy 1:1 -- a real area resample,
        // not the single bilinear tap the Nx answer would otherwise get in the resolve (which aliases
        // the model's detail into noise, the "noisier above 100%" the probe showed). On success the
        // resolve reads the native proxy (colorCopy) and native answer (outputNative); on failure it
        // falls back to the Nx pair. finalAnswer is NPSR here; outputNative is UAV from last frame.
        bool superDownOk = false;
        if (workScale > 1.0f && g_nr.superDown != nullptr && g_nr.outputNative != nullptr &&
            g_nr.superDown->Dispatch(cmdList, finalAnswer, g_nr.outputNative))
        {
            Barrier(cmdList, g_nr.outputNative, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            superDownOk = true;
        }

        ID3D12Resource* resolveProxy = superDownOk ? g_nr.colorCopy : modelInput;
        ID3D12Resource* resolveAnswer = superDownOk ? g_nr.outputNative : finalAnswer;

        // Pre-SR Color is not guaranteed to have UAV support. Write directly when legal; otherwise
        // resolve into hdrCopy while the original Color remains readable, then copy the result back.
        // ResidualAcrossRR overrides both: the resolve goes to an owned scratch and nothing is
        // written back to Color -- the edit is carried to the after-SR seam as a residual instead.
        ID3D12Resource* resolveOriginal =
            residualAcrossRr ? g_nr.hdrCopy : (targetSupportsUav ? g_nr.hdrCopy : target);
        ID3D12Resource* resolveTarget =
            residualAcrossRr ? g_nr.residualEdited : (targetSupportsUav ? target : g_nr.hdrCopy);

        if (residualAcrossRr)
        {
            Barrier(cmdList, g_nr.residualEdited, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                    D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        }
        else if (targetSupportsUav)
        {
            TransitionTarget(D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        }
        else
        {
            Barrier(cmdList, g_nr.hdrCopy, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                    D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        }

        // Apply the shared strength once, at the post-RR seam.
        if (residualAcrossRr)
            resolveParams.TransferStrength = 1.0f;
        const bool resolved = DispatchPass(cmdList, resolveParams, resolveProxy, resolveAnswer,
                                           resolveOriginal, motionIn, exposureTex, resolveTarget, nullptr);
        compositionRecorded = resolved;

        if (residualAcrossRr)
        {
            Barrier(cmdList, g_nr.residualEdited, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            const unsigned prev = g_nr.residualHistoryIndex & 1u;
            const unsigned cur = prev ^ 1u;
            Barrier(cmdList, g_nr.residualHistory[cur], D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                    D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            DlssNrConstants accum {};
            accum.Mode = DlssNrResidualMode_Accumulate;
            accum.Width = width;
            accum.Height = height;
            accum.ResidualBlend = std::clamp(cfg.DlssNrResidualAcrossRrBlend.value_or_default(), 0.01f, 1.0f);
            accum.ResidualHistoryValid = g_nr.residualHistoryPrimed ? 1u : 0u;
            accum.GuideWidth = motionWidth;
            accum.GuideHeight = motionHeight;
            accum.ResidualMotionBaseX = motionBaseX;
            accum.ResidualMotionBaseY = motionBaseY;
            accum.MvScaleX = frame.MvScaleX / (float) width;
            accum.MvScaleY = frame.MvScaleY / (float) height;
            const bool accumulated = resolved && DispatchResidualPass(cmdList, accum, g_nr.hdrCopy,
                g_nr.residualEdited, g_nr.residualHistory[prev], motionIn, g_nr.residualHistory[cur]);
            Barrier(cmdList, g_nr.residualHistory[cur], D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            compositionRecorded = accumulated;
            g_nr.residualHistoryPrimed = accumulated;
            g_nr.residualStoreValid = accumulated;
            if (accumulated)
                g_nr.residualHistoryIndex = cur;
        }
        else if (!targetSupportsUav)
        {
            Barrier(cmdList, g_nr.hdrCopy, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                    D3D12_RESOURCE_STATE_COPY_SOURCE);
            const D3D12_RESOURCE_STATES priorTargetState = targetState;
            TransitionTarget(D3D12_RESOURCE_STATE_COPY_DEST);
            if (resolved) cmdList->CopyResource(target, g_nr.hdrCopy);
            TransitionTarget(priorTargetState);
            Barrier(cmdList, g_nr.hdrCopy, D3D12_RESOURCE_STATE_COPY_SOURCE,
                    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        }

        MakeModelWritable(g_nr.output);
        if (g_nr.passScratch != nullptr)
            MakeModelWritable(g_nr.passScratch);

        if (superDownOk)
            Barrier(cmdList, g_nr.outputNative, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                    D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

        // On-demand capture retains an exact lease for each before/after pair.
        // Polling above maps only retired, completed recordings, with no frame-age heuristic.
        if (g_capture.isActive())
        {
            const auto owner=optishade::route::CurrentOutputKey();
            g_capture.record(cmdList, device, g_nr.colorCopy,
                             D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, target,
                             targetState,{owner.owner,owner.generation,owner.view,frame.SubmissionEpoch,observation});
        }
    }
    else
    {
        g_nr.failed = true;
        g_nr.reason = "the model refused to run";
        if (g_nr.lastModelError && *g_nr.lastModelError())
        {
            g_nr.modelError = g_nr.lastModelError();
            g_nr.reason = g_nr.modelError.c_str();
        }
        LOG_ERROR("DLSS-NR evaluate returned 0x{:X} ({}), disabling for this session", (uint32_t) result,
                  NgxResultName((unsigned int) result));
    }

    // On an evaluation failure, intermediate A/B inputs may still be readable. Restore both persistent
    // ping-pong surfaces to the UAV state the next frame starts from.
    MakeModelWritable(g_nr.output);
    if (g_nr.passScratch != nullptr)
        MakeModelWritable(g_nr.passScratch);

    Barrier(cmdList, g_nr.hdrCopy, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
            D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

    // Failed evaluations leave the game's original image intact. A successful copy-back writes
    // only the active rectangle and restores both resources before DLSS consumes the image.
    // ResidualAcrossRR never copies back -- Color must reach RR untouched.
    FinishColor(result == NVSDK_NGX_Result_Success && compositionRecorded && !residualAcrossRr);
    if (result == NVSDK_NGX_Result_Success && !compositionRecorded) {
        g_nr.failed = true;
        g_nr.reason = "NR composition pass failed; original image retained";
        LOG_ERROR("DLSS-NR: model evaluation succeeded but composition did not record");
    }
    if (result == NVSDK_NGX_Result_Success && compositionRecorded) {
        ++g_nr.successfulDispatches;
        ReportNrRecovered();
        optishade::nr_observation::State().Evaluated(observation,
            cfg.DlssNrApplyModel.value_or_default() && !residualAcrossRr && !frame.PrivateColorCopy);
    }

    if (g_gpuTime != nullptr)
    {
        g_gpuTime->End(cmdList);

        // This path records into the game's own list, so there is no queue of ours to read from.
        // A caller that knows which queue the list goes to says so; otherwise the one the upscaler was
        // invoked on serves. The bridges have to say, because they run on a queue of their own that
        // State never learns about -- a Vulkan game creates no D3D12 swapchain, so nothing ever sets
        // currentCommandQueue and the cost went unreported.
        auto* queue = timingQueue != nullptr ? timingQueue
                                             : (ID3D12CommandQueue*) State::Instance().currentCommandQueue;

        if (queue != nullptr)
        {
            if (auto ms = g_gpuTime->ReadGpuTime(queue); ms.has_value())
                g_lastGpuTime = ms;

            if (g_ngxTime != nullptr)
            {
                if (auto ngx = g_ngxTime->ReadGpuTime(queue); ngx.has_value())
                    g_lastNgxTime = ngx;
            }

            // The split, once every few hundred frames. What is worth reading is not the total but the
            // remainder: the model's cost is NVIDIA's to set, and everything else is ours.
            static unsigned long long lastSplitLog = 0;

            if (g_lastGpuTime.has_value() && g_lastNgxTime.has_value() && g_frames - lastSplitLog > 600)
            {
                lastSplitLog = g_frames;
                const double total = g_lastGpuTime.value();
                const double ngx = g_lastNgxTime.value();
                LOG_INFO("DLSS-NR elapsed: {:.2f} ms total, {:.2f} ms model, {:.2f} ms surrounding work ({:.0f}%; intervals may include other GPU work)",
                         total, ngx, total - ngx, total > 0.0 ? 100.0 * (total - ngx) / total : 0.0);
            }
        }
    }

    DlssNr::Observation();

    // Put any guide clones back where the next frame's copy expects to find them.
    // A clone left in NON_PIXEL_SHADER_RESOURCE by a frozen frame was never transitioned back to
    // COPY_DEST, because a frozen frame does not copy. Putting it back unconditionally would be a
    // barrier from a state it is not in, so the frozen case is skipped here and picked up by the
    // first live frame after the toggle goes off -- which is a copy, and copies transition it.
    if (g_nr.depthClone != nullptr)
        Barrier(cmdList, g_nr.depthClone, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                D3D12_RESOURCE_STATE_COPY_DEST);

    if (g_nr.motionClone != nullptr)
        Barrier(cmdList, g_nr.motionClone, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                D3D12_RESOURCE_STATE_COPY_DEST);

    if (reduced && g_nr.colorSmall != nullptr)
        Barrier(cmdList, g_nr.colorSmall, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

    // Leave the staging copy as the next frame expects to find it.
    Barrier(cmdList, g_nr.colorCopy, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
            D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

    device->Release();
}

namespace DlssNr
{
namespace Late { bool CaptureResidual(ID3D12GraphicsCommandList*, ID3D12Resource*, ID3D12Resource*, float, bool); }
#include "DlssNr_DeferredSr.inl"
std::string DeferredDlssStatus() { return SynchronousDeferredDlssStatus(); }

bool EvaluatePrivateVulkanBridge(ID3D12GraphicsCommandList* cmd,ID3D12CommandQueue* queue,ID3D12Resource* color,ID3D12Resource* depth,ID3D12Resource* motion,const osvtaa::Frame& f){
    auto guard = g_nrEvents.Lock();
    // The XP12 bridge calls this from a separate Vulkan submission route.
    // Check the session request at the final D3D12 dispatch boundary too, so
    // an already-entered bridge callback cannot record another NR output after
    // the in-game switch has been turned off.
    if(!Config::Instance()->DlssNrEnabled.value_or_default())return false;
    if(!cmd||!queue||!color||!depth||!motion)return false;
    Microsoft::WRL::ComPtr<ID3D12Device> device;if(FAILED(queue->GetDevice(IID_PPV_ARGS(&device))))return false;
    optishade::route::OutputScope outputScope(optishade::route::OutputKey{reinterpret_cast<uint64_t>(optishade::ReShadeDeviceIdentity(device.Get()).Get()),f.runtime,f.generation,0,3});
    if(!outputScope)return false;
    if(!g_compose)g_compose=std::make_unique<DlssNr_Dx12>("XP12 private D3D12 NR",device.Get());
    optishade::D3D12FrameContext context{cmd,color,depth,motion,color,nullptr,queue};
    if(context.ValidateDeviceIdentity(g_compose->Device(),true))return false;
    DlssNrFrameInfo info{};info.FinishedPicture=true;info.IndependentCommands=true;info.ColourIsLinearHdr=false;info.OutputArrivalState=D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    info.VulkanBridge=true;info.ObservationOwner=f.runtime;info.ObservationGeneration=f.generation;info.ObservationTicket=f.observationTicket;info.SubmissionEpoch=f.frame+1;
    info.OutputWidth=info.RenderSubrectWidth=f.width;info.OutputHeight=info.RenderSubrectHeight=f.height;info.MvScaleX=float(f.width);info.MvScaleY=float(f.height);
    info.Reset=f.frame==0;
    const auto before=g_nr.successfulDispatches;g_compose->Dispatch(cmd,color,depth,motion,color,info,queue);
    return g_nr.successfulDispatches>before&&Config::Instance()->DlssNrApplyModel.value_or_default();
}

void RetryAfterFailure()
{
    auto guard = g_nrEvents.Lock();
    if (g_nrDeviceLost) return;
    // Recovery clears the effective suspension only. The enabled flag is user
    // intent and must never be recreated by a retry or precision change.
    g_memoryPressureStopped = false;
    optishade::route::OutputOwned<NrMemoryState,4>().recovery.Manual();
    g_memoryCheck.invalidate();
    g_nr.failed = false;
    g_nr.reason = "";
    g_nr.reset = true;

}

void SetEnabled(bool enabled,const char* source)
{
    auto guard = g_nrEvents.Lock();
    const bool changed = Config::Instance()->DlssNrEnabled.value_or_default() != enabled;
    Config::Instance()->DlssNrEnabled = enabled;
    ObserveRequest(*Config::Instance(),true,source);
    if (!changed) return;
    LOG_INFO("Neural Rendering session request changed to {} through the runtime control path",enabled?"On":"Off");
    optishade::route::ForEachOutput([&]{
        if(enabled)RetryAfterFailure();
        optishade::route::OutputOwned<NrEngineState,1>().switchedOffAt=0;
        g_nr.reset=true;
        if(g_gpuTime)g_gpuTime->ClearLast();if(g_ngxTime)g_ngxTime->ClearLast();
        g_lastGpuTime.reset();g_lastNgxTime.reset();
    });
}

namespace {
optishade::nr_session::State ReadSessionStateOwned() {
    ObserveRequest(*Config::Instance());
    const auto observation=optishade::nr_observation::State().Read(GetTickCount64());
    return {observation.requested,observation.request,observation.explicitOffRevision};
}
}
bool TryReadSessionState(optishade::nr_session::State& state) {
    return g_nrEvents.TryWithState([&]{state=ReadSessionStateOwned();});
}
optishade::nr_session::Result TrySetSessionEnabled(bool enabled,uint64_t expectedRevision) {
    const auto result=optishade::nr_session::TrySet(g_nrEvents,enabled,expectedRevision,
        []{return ReadSessionStateOwned();},[](bool requested){SetEnabled(requested,"session-control");});
    if(result.code==optishade::nr_session::Code::Conflict)
        optishade::session::State().RecordNRActivation(enabled,"session-control","Rejected: session revision conflict");
    else if(result.code==optishade::nr_session::Code::Busy)
        optishade::session::State().RecordNRActivation(enabled,"session-control","Rejected: runtime state lock busy");
    return result;
}

// The legacy worker is an explicit NR consumer. Ordinary games still start off.
extern "C" __declspec(dllexport) unsigned OptiShadeLegacyNrControl(unsigned operation)
{
    wchar_t executable[MAX_PATH]{};
    if (!GetModuleFileNameW(nullptr, executable, MAX_PATH)) return 0;
    const auto name = std::filesystem::path(executable).filename().wstring();
    if (_wcsicmp(name.c_str(), L"dlss5-feed-host64.exe") != 0 || operation > 2) return 0;
    if (operation) SetEnabled(operation == 1,"legacy-worker-control");
    optishade::nr_observation::Snapshot observation;
    unsigned flags = 1; // version-1 endpoint available, not proof of NR
    if (optishade::nr_observation::State().TryRead(GetTickCount64(), observation)) {
        if (observation.requested) flags |= 2;
        if (observation.evaluated) flags |= 4;
        if (observation.composed) flags |= 8;
        if (observation.completed) flags |= 16;
    }
    return flags;
}

bool MemoryPressureStopped() { auto guard = g_nrEvents.Lock(); return g_memoryPressureStopped; }
bool VrHeadsetActive(){return HeadsetPresenting();}
bool MemoryLow() { auto guard = g_nrEvents.Lock(); return g_memoryLow; }

// Consume only the residual produced by this exact CPU evaluate. Dispatch failures
// leave the RR output untouched, and every exit restores the caller's bindings.
void ApplyResidualAcrossRr(ID3D12GraphicsCommandList* cmdList, NVSDK_NGX_Parameter* params)
{
    if(!Config::Instance()->DlssNrEnabled.value_or_default())
    {
        // A residual is output work, not just cached history. If the session
        // was switched off after its producer pass, consume and discard it.
        g_nr.residualPair.Cancel();
        g_nr.residualStoreValid = false;
        g_nr.residualHistoryPrimed = false;
        return;
    }
    auto* output = GetResource(params, NVSDK_NGX_Parameter_Output, "DLSSD.Output");
    const bool paired = g_nr.residualPair.Take(cmdList, params, output);
    const bool ready = g_nr.residualStoreValid;
    g_nr.residualStoreValid = false;
    if (!paired || !ready || !g_compose || !output || !g_nr.residualComposed)
    {
        g_nr.residualHistoryPrimed = false;
        return;
    }
    const auto& cfg = *Config::Instance();
    const float strength = cfg.DlssNrTransferStrength.value_or_default();
    if (!cfg.DlssNrApplyModel.value_or_default() || !std::isfinite(strength) || strength <= 0.0f)
    {
        g_nr.residualHistoryPrimed = false;
        return;
    }
    if ((cfg.RestoreComputeSignature.value_or_default() || cfg.RestoreGraphicSignature.value_or_default()) &&
        !D3D12Hooks::CanRestoreRootSignature(cmdList))
        return;
    ScopedNrStateEnvelope stateEnvelope(cmdList);
    const auto desc = output->GetDesc();
    const auto carrier = g_nr.residualComposed->GetDesc();
    if (desc.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D || desc.SampleDesc.Count != 1 ||
        desc.Width != carrier.Width || desc.Height != carrier.Height || desc.Format != carrier.Format ||
        desc.DepthOrArraySize != 1 || desc.MipLevels != 1)
        return;
    auto arrival = cfg.OutputResourceBarrier.has_value()
        ? (D3D12_RESOURCE_STATES) cfg.OutputResourceBarrier.value() : D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
    Barrier(cmdList, output, arrival, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    Barrier(cmdList, g_nr.residualComposed, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
            D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    DlssNrConstants apply {};
    apply.Mode = DlssNrResidualMode_Apply;
    apply.Width = (unsigned) desc.Width;
    apply.Height = desc.Height;
    apply.TransferStrength = std::clamp(strength, 0.0f, 1.0f);
    const bool composed = g_compose->DispatchResidualPass(cmdList, apply, output,
        g_nr.residualHistory[g_nr.residualHistoryIndex & 1u], nullptr, nullptr, g_nr.residualComposed);
    if (composed)
    {
        Barrier(cmdList, g_nr.residualComposed, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                D3D12_RESOURCE_STATE_COPY_SOURCE);
        Barrier(cmdList, output, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COPY_DEST);
        cmdList->CopyResource(output, g_nr.residualComposed);
        Barrier(cmdList, output, D3D12_RESOURCE_STATE_COPY_DEST, arrival);
        Barrier(cmdList, g_nr.residualComposed, D3D12_RESOURCE_STATE_COPY_SOURCE,
                D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    }
    else
    {
        Barrier(cmdList, output, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, arrival);
        Barrier(cmdList, g_nr.residualComposed, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        g_nr.residualHistoryPrimed = false;
    }
}

#include "DlssNr_Late.inl"

// Reads the game's parameter block and runs the pass on what it finds.
//
// This is the call site's job, not the pass's. A caller that has the resources in hand -- a
// reprojection stage, a frame generation path, anything that is not the upscaler seam -- calls
// RunPass directly and never touches an NGX parameter block.
void EvaluateInternal(ID3D12GraphicsCommandList* cmdList, NVSDK_NGX_Parameter* params,
                      bool beforeUpscale, ID3D12CommandQueue* timingQueue, bool rayReconstruction,
                      unsigned long long submissionEpoch, uint64_t outputOwner)
{
    auto nrLock = g_nrEvents.Lock();
    if(!cmdList || !params)return;
    Microsoft::WRL::ComPtr<ID3D12Device> outputDevice;
    if(FAILED(cmdList->GetDevice(IID_PPV_ARGS(&outputDevice))))return;
    const optishade::route::OutputKey outputKey{reinterpret_cast<uint64_t>(optishade::ReShadeDeviceIdentity(outputDevice.Get()).Get()),outputOwner?outputOwner:reinterpret_cast<uint64_t>(params),0,0,4};
    optishade::route::OutputScope outputScope(outputKey);
    if(!outputScope)return;
    const Config& cfg = *Config::Instance();
    auto& nativeHistory = optishade::route::OutputOwned<NrEngineState,1>().lastNativeEvaluationAt;
    const auto nativeNow = GetTickCount64();
    // The game may resume the same DLSS feature after spending time in TAA.
    // Do not reuse NR's old temporal/residual history just because that handle
    // and output dimensions survived the settings change.
    if (!nativeHistory || nativeNow < nativeHistory || nativeNow - nativeHistory > 500) {
        g_nr.reset = true;
        g_nr.residualHistoryPrimed = false;
    }
    nativeHistory = nativeNow;
    // Invalid/secondary-device NGX calls cannot indefinitely suppress a valid
    // main TAA provider. Scope preference to validated device/output evidence.
    if(cfg.DlssNrEnabled.value_or_default() && cmdList && params) {
        auto* output=GetResource(params,NVSDK_NGX_Parameter_Output,"DLSSD.Output");
        auto* depth=GetResource(params,NVSDK_NGX_Parameter_Depth,"DLSSD.Depth");
        auto* motion=GetResource(params,NVSDK_NGX_Parameter_MotionVectors,"DLSSD.MotionVectors");
        Microsoft::WRL::ComPtr<ID3D12Device> owner;
        if(output && depth && motion && SUCCEEDED(output->GetDevice(IID_PPV_ARGS(&owner)))) {
            const auto desc=output->GetDesc();
            if(desc.Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE2D && desc.DepthOrArraySize==1 && desc.Width<=UINT32_MAX)
                g_nativeNrInputs.observe(reinterpret_cast<uint64_t>(optishade::ReShadeDeviceIdentity(owner.Get()).Get()),static_cast<unsigned>(desc.Width),desc.Height,GetTickCount64());
        }
    }

    auto& lastPrecision=optishade::route::OutputOwned<NrEngineState,1>().lastPrecision;
    const unsigned precision=cfg.DlssNrPrecision.value_or_default();
    if(lastPrecision!=precision)
    {
        RetryAfterFailure();
        DeferredSr::Instance().Cancel();
        lastPrecision = precision;
    }
    DlssNrNative::SetPrecision(precision);
    const unsigned finishedMode = !cfg.DlssNrFinishedPicture.value_or_default() ? 0u :
        (cfg.DlssNrRunBeforeSr.value_or_default() || cfg.DlssNrDeferredDlss.value_or_default()) ? 2u : 1u;
    auto& lastFinishedMode=optishade::route::OutputOwned<NrEngineState,1>().lastFinishedMode;
    if (lastFinishedMode != finishedMode)
    {
        g_nr.reset = true;
        if (g_gpuTime) g_gpuTime->ClearLast();
        if (g_ngxTime) g_ngxTime->ClearLast();
        g_lastGpuTime.reset();
        g_lastNgxTime.reset();
        Late::Instance().Cancel();
        DeferredSr::Instance().Cancel();
        lastFinishedMode = finishedMode;
    }
    if (finishedMode)
    {
        g_nr.residualPair.Cancel();
        g_nr.residualStoreValid = false;
        g_nr.residualHistoryPrimed = false;
        if (!cfg.DlssNrEnabled.value_or_default())
        { DeferredSr::Instance().Cancel(); Late::Instance().Cancel(); return; }
        if (timingQueue || State::Instance().swapchainInteropApi != SwapchainInteropApi::None)
        { DeferredSr::Instance().Cancel(); Late::Instance().Cancel(); Late::Instance().Say("This option needs a native DirectX 12 game."); return; }
        if (finishedMode == 2)
        {
            if (rayReconstruction)
            { DeferredSr::Instance().Cancel(); Late::Instance().Cancel(); Late::Instance().Say("Running the model before SR with this option does not support Ray Reconstruction."); return; }
            if (cmdList && params)
            {
                const auto submitted = State::Instance().frameCount;
                const auto epoch = g_nrSeamClock.AtSeam(beforeUpscale, false, submitted);
                if (beforeUpscale) DeferredSr::Instance().Before(cmdList, params, epoch, submitted, nullptr);
                else DeferredSr::Instance().After(cmdList, params, epoch);
            }
        }
        else
        {
            DeferredSr::Instance().Cancel();
            if (beforeUpscale) Late::Instance().Capture(cmdList, params, rayReconstruction);
        }
        return;
    }
    Late::Instance().Cancel();
    if (beforeUpscale)
    {
        // Even a disabled/skipped pre pass must invalidate the previous result.
        if (g_nr.residualStoreValid)
            g_nr.residualHistoryPrimed = false;
        g_nr.residualPair.Cancel();
        g_nr.residualStoreValid = false;
    }
    const bool residualMode = cfg.DlssNrEnabled.value_or_default() &&
        cfg.DlssNrRunBeforeSr.value_or_default() && cfg.DlssNrResidualAcrossRr.value_or_default() && rayReconstruction;
    if (residualMode != g_nr.residualModeActive)
    {
        g_nr.residualPair.Cancel();
        g_nr.residualHistoryPrimed = false;
        g_nr.residualStoreValid = false;
        g_nr.residualModeActive = residualMode;
    }
    if (!cfg.DlssNrEnabled.value_or_default() || !cfg.DlssNrDeferredDlss.value_or_default() || rayReconstruction)
    {
        DeferredSr::Instance().Cancel();
        if (rayReconstruction && cfg.DlssNrEnabled.value_or_default() && cfg.DlssNrDeferredDlss.value_or_default())
            DeferredSr::Instance().Say("inactive: Ray Reconstruction; using ordinary before/after NR placement");
    }
    else
    {
        if (cmdList != nullptr && params != nullptr)
        {
            const auto submitted = timingQueue != nullptr ? submissionEpoch : State::Instance().frameCount;
            const auto epoch = g_nrSeamClock.AtSeam(beforeUpscale, timingQueue != nullptr, submitted);
            if (beforeUpscale)
                DeferredSr::Instance().Before(cmdList, params, epoch, submitted, timingQueue);
            else
                DeferredSr::Instance().After(cmdList, params, epoch);
        }
        return;
    }

    if (!cfg.DlssNrEnabled.value_or_default())
    {
        ReportSkipOnce("it is switched off");
        ReleaseWhileSwitchedOff();
        return;
    }
    if (NrOffInHeadset())
    {
        ReportSkipOnce("Use NR in the VR headset is off");
        ReleaseWhileSwitchedOff();
        return;
    }

    if (cmdList == nullptr || params == nullptr)
    {
        ReportSkipOnce("no command list or no parameter block");
        return;
    }

    // Both SR and RR+SR use the same placement control. Unsupported colour subrects
    // retain the common post-upscale fallback; RR identity only separates history
    // and prevents using the SR-only deferred-residual experiment on an RR feature.
    bool preSrCompatible = true;
    if (cfg.DlssNrRunBeforeSr.value_or_default())
    {
        ID3D12Resource* preColor = GetResource(params, NVSDK_NGX_Parameter_Color, "DLSSD.Color");
        unsigned int renderWidth = 0, renderHeight = 0, colorBaseX = 0, colorBaseY = 0;
        params->Get(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width, &renderWidth);
        params->Get(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, &renderHeight);
        params->Get(NVSDK_NGX_Parameter_DLSS_Input_Color_Subrect_Base_X, &colorBaseX);
        params->Get(NVSDK_NGX_Parameter_DLSS_Input_Color_Subrect_Base_Y, &colorBaseY);

        if (preColor == nullptr)
        {
            preSrCompatible = false;
        }
        else
        {
            const D3D12_RESOURCE_DESC colorDesc = preColor->GetDesc();
            const unsigned int allocationWidth = (unsigned int) colorDesc.Width;
            const unsigned int allocationHeight = colorDesc.Height;
            const auto active = PreSrColorExtent(colorDesc, renderWidth, renderHeight, colorBaseX, colorBaseY);
            preSrCompatible = active.has_value();

            if (active && (active->width != allocationWidth || active->height != allocationHeight))
            {
                static bool reportedPadding = false;
                if (!reportedPadding)
                {
                    reportedPadding = true;
                    LOG_INFO("DLSS-NR before SR: staging active {}x{} from padded Color allocation {}x{}; "
                             "only the active rectangle is copied back. Model size follows active size and WorkingScale.",
                             active->width, active->height, allocationWidth, allocationHeight);
                }
            }

            if (!preSrCompatible)
            {
                static bool warnedSubrect = false;
                if (!warnedSubrect)
                {
                    warnedSubrect = true;
                    LOG_WARN("DLSS-NR before SR requires a valid origin-zero active rectangle inside a "
                             "single-sample 2D Color texture; got allocation {}x{}, active {}x{} at {},{}. "
                             "Falling back after SR.",
                             allocationWidth, allocationHeight, renderWidth, renderHeight, colorBaseX,
                             colorBaseY);
                }
            }
        }
    }

    const bool configuredBefore = cfg.DlssNrRunBeforeSr.value_or_default() &&
                                  preSrCompatible;

    // ResidualAcrossRR: with RunBeforeSR + the game's Ray Reconstruction both on, run
    // the model before SR but leave Color untouched, then add its captured residual back after RR+SR.
    // Unlike every other placement this needs BOTH seams of one evaluate -- the before-upscale seam
    // falls through to the normal pre-SR body (which captures the residual and skips the copy-back),
    // and the after-upscale seam is handled here. If it is requested but the pre-SR path is not
    // compatible, configuredBefore is false and the normal gate runs plain post-SR NR instead.
    const bool residualAcrossRr =
        cfg.DlssNrResidualAcrossRr.value_or_default() && configuredBefore && rayReconstruction;

    if (residualAcrossRr && beforeUpscale &&
        (cfg.DlssNrHoldFrame.value_or_default() || cfg.DlssNrDebugView.value_or_default() != 0 ||
         cfg.DlssNrCompare.value_or_default() != 0 || cfg.DlssNrShowSkinMask.value_or_default()))
    {
        g_nr.residualHistoryPrimed = false;
        ReportSkipOnce("disable Hold frame, Compare and Debug view for residual-across-RR");
        return;
    }

    if (residualAcrossRr && !beforeUpscale)
    {
        ApplyResidualAcrossRr(cmdList, params);

        static bool announcedResidualAcrossRr = false;
        if (!announcedResidualAcrossRr)
        {
            announcedResidualAcrossRr = true;
            LOG_INFO("DLSS-NR: residual-across-RR active -- MV-reprojected accumulator, blend {:.2f}",
                     std::clamp(cfg.DlssNrResidualAcrossRrBlend.value_or_default(), 0.01f, 1.0f));
        }
        return;
    }

    if (configuredBefore != beforeUpscale)
        return;

    // Which of the game's APIs this evaluate arrived through.
    //
    // Says out loud what was previously only reasoned about: an FSR or XeSS title reaches this pass
    // transitively, because those shims call OptiScaler's own NVSDK_NGX_D3D12_EvaluateFeature and
    // this pass hangs off that. Nothing needed adding to the shims -- a call there would run the
    // model twice -- but "nothing needed adding" is a claim, and this is the line that checks it.
    {
        static ApiUpscalerInput saidApi = (ApiUpscalerInput) -1;
        const ApiUpscalerInput api = State::Instance().currentInputApiName;

        if (saidApi != api)
        {
            saidApi = api;
            LOG_INFO("DLSS-NR reached through the game's {} input", ApiUpscalerInputName(api));
        }
    }

    ID3D12Resource* output = GetResource(params, NVSDK_NGX_Parameter_Output, "DLSSD.Output");
    ID3D12Resource* target = beforeUpscale
                                 ? GetResource(params, NVSDK_NGX_Parameter_Color, "DLSSD.Color")
                                 : output;
    ID3D12Resource* depth = GetResource(params, NVSDK_NGX_Parameter_Depth, "DLSSD.Depth");
    ID3D12Resource* motion = GetResource(params, NVSDK_NGX_Parameter_MotionVectors, "DLSSD.MotionVectors");

    // Without all three there is nothing to run on. This is not a failure -- some evaluates legitimately
    // carry none of it -- so it stays quiet and tries again next frame.
    if (target == nullptr || depth == nullptr || motion == nullptr)
    {
        ReportSkipOnce(target == nullptr    ? (beforeUpscale ? "the parameters carried no color texture"
                                                              : "the parameters carried no output texture")
                       : depth == nullptr   ? "the parameters carried no depth"
                                            : "the parameters carried no motion vectors");
        return;
    }

    unsigned int createFlags = 0;
    params->Get(NVSDK_NGX_Parameter_DLSS_Feature_Create_Flags, &createFlags);

    DlssNrFrameInfo frame {};
    frame.DepthInverted = (createFlags & NVSDK_NGX_DLSS_Feature_Flags_DepthInverted) != 0;
    frame.MotionVectorsLowResolution = (createFlags & NVSDK_NGX_DLSS_Feature_Flags_MVLowRes) != 0;
    if (output != nullptr)
    {
        frame.OutputWidth = (unsigned int) output->GetDesc().Width;
        frame.OutputHeight = output->GetDesc().Height;
    }
    unsigned int outputWidth = 0, outputHeight = 0;
    params->Get(NVSDK_NGX_Parameter_OutWidth, &outputWidth);
    params->Get(NVSDK_NGX_Parameter_OutHeight, &outputHeight);
    if (outputWidth && outputHeight)
    {
        frame.OutputWidth = outputWidth;
        frame.OutputHeight = outputHeight;
    }
    frame.ObservationOwner=outputKey.owner;frame.ObservationGeneration=outputKey.generation;frame.ObservationView=outputKey.view;
    frame.BeforeUpscale = beforeUpscale;
    frame.RayReconstruction = rayReconstruction;
    frame.ResidualAcrossRr = residualAcrossRr; // only reaches here on the before-upscale seam
    if (residualAcrossRr)
    {
        if (!output)
            return;
        const auto outDesc = output->GetDesc();
        if (outDesc.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D || outDesc.SampleDesc.Count != 1 ||
            outDesc.DepthOrArraySize != 1 || outDesc.MipLevels != 1)
            return;
        if (g_nr.residualOutputWidth != outDesc.Width || g_nr.residualOutputHeight != outDesc.Height ||
            g_nr.residualOutputFormat != outDesc.Format)
        {
            ParkNrResource(g_nr.residualComposed);
            g_nr.residualHistoryPrimed = false;
            g_nr.residualOutputWidth = (unsigned) outDesc.Width;
            g_nr.residualOutputHeight = outDesc.Height;
            g_nr.residualOutputFormat = outDesc.Format;
        }
    }
    frame.SubmissionEpoch = timingQueue != nullptr ? submissionEpoch : State::Instance().frameCount;

    // Color and Output may use different formats even though DLSS treats them as the same frame colour
    // space. Output is the stable authority across injection points; target is only a fallback for a
    // malformed parameter block.
    ID3D12Resource* colourAuthority = output != nullptr ? output : target;
    frame.ColourIsLinearHdr =
        (createFlags & NVSDK_NGX_DLSS_Feature_Flags_IsHDR) != 0 &&
        colourAuthority != nullptr && FormatCanHoldLinearHdr(colourAuthority->GetDesc().Format);

    // The game telling the upscaler to forget everything it has accumulated: a cut, a teleport, a
    // load. Every upscaler in this tree reads it and this pass did not, so the model's history was
    // only ever reset by things that happened to us -- a resize, a rebuild, a recovery from failure
    // -- and never by anything that happened in the game. Across a cut the model was reprojecting
    // the previous scene onto the new one and being asked to reconcile them.
    //
    // Read the same way FFXFeature_Dx12 reads it, including leaving it alone when the parameter is
    // absent: a game that never sets it is not asking for a reset every frame.
    {
        unsigned int gameReset = 0;

        if (params->Get(NVSDK_NGX_Parameter_Reset, &gameReset) == NVSDK_NGX_Result_Success)
            frame.Reset = gameReset != 0;
    }

    // How much of the guides is real. See DlssNrFrameInfo -- zero means the game did not say.
    params->Get(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width, &frame.RenderSubrectWidth);
    params->Get(NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, &frame.RenderSubrectHeight);
    params->Get(NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_X, &frame.DepthSubrectBaseX);
    params->Get(NVSDK_NGX_Parameter_DLSS_Input_Depth_Subrect_Base_Y, &frame.DepthSubrectBaseY);
    params->Get(NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_X, &frame.MotionSubrectBaseX);
    params->Get(NVSDK_NGX_Parameter_DLSS_Input_MV_SubrectBase_Y, &frame.MotionSubrectBaseY);

    if (params->Get(NVSDK_NGX_Parameter_MV_Scale_X, &frame.MvScaleX) != NVSDK_NGX_Result_Success)
        frame.MvScaleX = 1.0f;

    if (params->Get(NVSDK_NGX_Parameter_MV_Scale_Y, &frame.MvScaleY) != NVSDK_NGX_Result_Success)
        frame.MvScaleY = 1.0f;

    // What the game says about its own exposure. Logged, used for nothing yet.
    //
    // The white point measured from the frame turned out to be a control loop rather than a
    // measurement: the pass writes into the buffer it reads, most games adapt their exposure to the
    // finished frame, and the two chase each other -- 0.01 to 97.9 in one Enshrouded session. Any
    // statistic taken from a frame we modify has that problem.
    //
    // These do not. DLSS.Pre.Exposure is the scale the game applied before handing the buffer over,
    // and ExposureTexture is a 1x1 the game fills with the exposure it is using; both are the game's
    // own numbers, decided upstream of anything here. Whether either is close to the divisor the model
    // actually wants is unknown, which is why this only prints them.
    //
    // The auto-exposure flag decides whether the texture means anything: with it set the game is
    // telling DLSS to work exposure out for itself and may supply nothing. OptiScaler forces that flag
    // on for eighteen games, so it is logged too -- reading a value whose flag has been overridden is
    // how the debug views lied earlier tonight.
    {
        float preExposure = 0.0f;
        const bool havePre =
            params->Get(NVSDK_NGX_Parameter_DLSS_Pre_Exposure, &preExposure) == NVSDK_NGX_Result_Success;

        void* exposureTex = nullptr;
        params->Get(NVSDK_NGX_Parameter_ExposureTexture, &exposureTex);

        frame.ExposureTexture = exposureTex;
        frame.PreExposure = havePre && preExposure > 1e-6f ? preExposure : 1.0f;

        g_nr.exposureOfferedNow = exposureTex != nullptr;
        g_nr.exposureEverOffered = g_nr.exposureEverOffered || g_nr.exposureOfferedNow;
        g_nr.exposureFrames++;

        const bool autoExposureFlag = (createFlags & NVSDK_NGX_DLSS_Feature_Flags_AutoExposure) != 0;

        struct ExposureReport
        {
            bool valid;
            float pre;
            bool havePre;
            bool haveTexture;
            bool autoFlag;
        };

        static ExposureReport logged {};
        const ExposureReport now { true, havePre ? preExposure : 0.0f, havePre, exposureTex != nullptr,
                                   autoExposureFlag };

        if (!logged.valid || logged.havePre != now.havePre || logged.haveTexture != now.haveTexture ||
            logged.autoFlag != now.autoFlag ||
            std::abs(logged.pre - now.pre) > std::max(0.01f * std::abs(now.pre), 1e-4f))
        {
            logged = now;
            LOG_INFO("DLSS-NR exposure from the game: DLSS.Pre.Exposure {}, ExposureTexture {}, "
                     "auto-exposure flag {}",
                     now.havePre ? std::to_string(now.pre) : std::string("not supplied"),
                     now.haveTexture ? "supplied" : "not supplied", now.autoFlag ? "set" : "clear");
        }

        // The value itself, once it has come back off the GPU. Separate from the line above because
        // that one says what the game offers and this one says what it actually reads -- and because
        // the reading arrives three frames after the offer.
        static float loggedExposure = -1.0f;

        if (g_nr.gameExposure > 1e-6f &&
            std::abs(loggedExposure - g_nr.gameExposure) > std::max(0.02f * g_nr.gameExposure, 1e-5f))
        {
            loggedExposure = g_nr.gameExposure;
            LOG_INFO("DLSS-NR game exposure {:.5f} (pre-exposure {:.3f}) -> white point would be {:.2f}",
                     g_nr.gameExposure, g_nr.gamePreExposure, g_nr.gamePreExposure / g_nr.gameExposure);
        }

        // The scan's number, on the same cadence, so one log carries both.
        //
        // This is the whole validation. In a game that hands over an exposure texture there is a
        // known-correct value; if the scan's candidate tracks it, the scan found the right buffer
        // rather than merely a moving one, and can be trusted where a game hands over nothing.
        // Comparing two numbers after the fact needs both written down, and until now the scan's
        // value existed only in a menu nobody can read while playing.
        {
            int which = 0;
            float low = 0.0f, high = 0.0f;
            const float scanned = DlssNr::ExposureScan::BestValue(&which, &low, &high);

            static float loggedScan = -1.0f;

            if (scanned > 0.0f && std::abs(loggedScan - scanned) > std::max(0.02f * scanned, 1e-6f))
            {
                loggedScan = scanned;

                if (g_nr.gameExposure > 1e-6f)
                    LOG_INFO("DLSS-NR exposure scan: candidate {} = {:.5f} ({:.5f}..{:.5f})  |  the "
                             "game's own exposure is {:.5f}  |  ratio {:.4f}",
                             which, scanned, low, high, g_nr.gameExposure, scanned / g_nr.gameExposure);
                else
                    LOG_INFO("DLSS-NR exposure scan: candidate {} = {:.5f} ({:.5f}..{:.5f})  |  this "
                             "game supplies no exposure to compare against",
                             which, scanned, low, high);
            }
        }
    }

    // The upscaler's inputs are at render resolution while colour and output are at display
    // resolution; the model takes that as a subrect per resource, which the pass reads from the
    // resources themselves.
    ID3D12Device* device = nullptr;

    if (FAILED(target->GetDevice(IID_PPV_ARGS(&device))) || device == nullptr)
    {
        ReportSkipOnce("the output texture belongs to no D3D12 device");
        return;
    }

    // The pass is the object, so the caller holds it. Built once, on the device the frame is on.
    if (g_compose == nullptr)
        g_compose = std::make_unique<DlssNr_Dx12>("Neural Rendering", device);

    device->Release();

    if (g_compose == nullptr)
    {
        ReportSkipOnce("the pass could not be created");
        return;
    }

    g_compose->Dispatch(cmdList, target, depth, motion, target, frame, timingQueue);
    if (residualAcrossRr && g_nr.residualStoreValid)
        g_nr.residualPair.Arm(cmdList, params, output);
}

void EvaluateAfterUpscale(ID3D12GraphicsCommandList* cmdList, NVSDK_NGX_Parameter* params,
                          ID3D12CommandQueue* timingQueue, bool rayReconstruction,
                          unsigned long long submissionEpoch, uint64_t outputOwner)
{
    EvaluateInternal(cmdList, params, false, timingQueue, rayReconstruction, submissionEpoch, outputOwner);
}

void EvaluateBeforeUpscale(ID3D12GraphicsCommandList* cmdList, NVSDK_NGX_Parameter* params,
                           ID3D12CommandQueue* timingQueue, unsigned long long submissionEpoch,
                           bool rayReconstruction, uint64_t outputOwner)
{
    EvaluateInternal(cmdList, params, true, timingQueue, rayReconstruction, submissionEpoch, outputOwner);
}

// The pass. Resources in, nothing read from anywhere the caller cannot see.

void ProbeD3D11(void* d3d11Device)
{
    static bool done = false;

    if (done || d3d11Device == nullptr)
        return;

    // Every other entry point in this file takes the lock before touching g_nr; this one was reaching
    // EnsureForwarder without it.
    auto nrLock = g_nrEvents.Lock();

    // Opt in only. See the note on DlssNrProbeD3D11: this is the one call in the pass that reaches
    // into a subsystem on the game's own device rather than reading something we already hold.
    if (!Config::Instance()->DlssNrProbeD3D11.value_or_default())
        return;

    done = true;

    if (!EnsureForwarder())
        return;

    auto probe = (int (*)(const wchar_t*)) GetProcAddress(g_nr.forwarder, "dlssnr_d3d11_probe");
    auto init = (int (*)(const wchar_t*, const wchar_t*, void*, int, int*, int*)) GetProcAddress(
        g_nr.forwarder, "dlssnr_d3d11_init");

    if (probe == nullptr || init == nullptr)
    {
        LOG_INFO("DLSS-NR D3D11: this forwarder has no D3D11 probe");
        return;
    }

    auto snippet = FindSelectedModel();

    if (!snippet.has_value())
        return;

    // Four bits, one per entry point: init 1, create 2, evaluate 4, release 8.
    const int bits = probe(snippet->wstring().c_str());

    // And the question NGX has an API for. Asked first because it creates nothing: if the feature
    // declines D3D11 here, that is the feature's own answer rather than our reading of a failed init.
    auto requirements = (int (*)(const wchar_t*, void*, unsigned int*, unsigned int*, unsigned int*))
        GetProcAddress(g_nr.forwarder, "dlssnr_d3d11_requirements");

    if (requirements != nullptr)
    {
        // The adapter the game is actually running on. Without it the query answers
        // AdapterUnsupported, which looks like a verdict on the hardware and is really a verdict on
        // the question -- that is what the first attempt got, on a 5080.
        IDXGIAdapter* adapter = nullptr;
        IDXGIDevice* gameDevice = nullptr;

        if (SUCCEEDED(static_cast<IUnknown*>(d3d11Device)->QueryInterface(IID_PPV_ARGS(&gameDevice))))
            gameDevice->GetAdapter(&adapter);

        unsigned int supported = 0xFFFFFFFFu;
        unsigned int minArch = 0;
        unsigned int minOs = 0;
        const int rc = requirements(snippet->wstring().c_str(), adapter, &supported, &minArch, &minOs);

        const char* meaning = supported == 0        ? "SUPPORTED"
                              : (supported & 16)    ? "NotImplemented -- the feature has no D3D11 path"
                              : (supported & 4)     ? "AdapterUnsupported"
                              : (supported & 2)     ? "DriverVersionUnsupported"
                              : (supported & 8)     ? "OSVersionBelowMinimum"
                              : (supported & 1)     ? "CheckNotPresent"
                                                    : "unknown";

        LOG_WARN("DLSS-NR D3D11: GetFeatureRequirements {} ({}), FeatureSupported 0x{:X} -- {}. "
                 "minimum architecture 0x{:X}, minimum OS 0x{:X}",
                 rc, NgxResultName((unsigned int) rc), supported, meaning, minArch, minOs);

        if (adapter != nullptr)
            adapter->Release();

        if (gameDevice != nullptr)
            gameDevice->Release();
    }

    LOG_INFO("DLSS-NR D3D11: entry points resolved {}/15 (init {}, create {}, evaluate {}, release {})",
             bits, (bits & 1) ? "yes" : "no", (bits & 2) ? "yes" : "no", (bits & 4) ? "yes" : "no",
             (bits & 8) ? "yes" : "no");

    if (bits != 15)
    {
        LOG_INFO("DLSS-NR D3D11: incomplete surface, the bridge stays the only route");
        return;
    }

    // Four ways of asking, since the feature has already said it supports this platform.
    int attempt = 0;
    int results[4] = { -9, -9, -9, -9 };

    const int result = init(snippet->wstring().c_str(), State::Instance().NVNGX_ApplicationDataPath.c_str(),
                            d3d11Device, 0x0000015, &attempt, results);

    static const char* kNames[4] = { "Init_Ext on our own copy", "Init on our own copy",
                                     "Init_Ext on the shared module", "Init on the shared module" };

    for (int i = 0; i < 4; ++i)
    {
        LOG_INFO("DLSS-NR D3D11:   {} -> {} ({})", kNames[i], results[i],
                 results[i] == -2   ? "module not loaded"
                 : results[i] == -3 ? "export missing"
                 : results[i] == -9 ? "not reached"
                                    : NgxResultName((unsigned int) results[i]));
    }

    if (result == 1)
        LOG_WARN("DLSS-NR D3D11: initialised, via {}. The feature already said this platform is "
                 "supported; now the call works too. Next is a feature create on a device context.",
                 attempt > 0 ? kNames[attempt - 1] : "?");
    else
        // Deliberately not "so the bridge is required". GetFeatureRequirements answers 0x0 SUPPORTED
        // with a minimum architecture this card meets, so the platform is not the obstacle and saying
        // otherwise here would be printing a conclusion the evidence does not carry.
        LOG_WARN("DLSS-NR D3D11: every init variant refused, last {} ({}) -- though the feature itself "
                 "reports this platform as supported, so the obstacle is in how it is being called",
                 result, NgxResultName((unsigned int) result));
}

CalibrationReading Calibration()
{
    CalibrationReading r {};
    r.suggestion = g_nr.calibSuggestion;
    r.steadiness = g_nr.calibSteadiness;
    r.samples = g_nr.calibCount;
    r.usable = g_nr.calibUsable;
    r.why = g_nr.calibWhy;
    return r;
}

optishade::nr_observation::Snapshot Observation() {
    auto guard = g_nrEvents.Lock();
    ObserveRequest(*Config::Instance());
    if(g_gpuTime) g_gpuTime->HasRecentCompletion();
    const auto now=GetTickCount64();
    auto value=optishade::nr_observation::State().Read(now);
    static ULONGLONG lastLog=0;
    if(now-lastLog>=5000) {
        lastLog=now;
        LOG_INFO("NR observation: pid={} tick={} request={} effective={} route={} owner={:X} generation={} view={} device={:X} queue={:X} frame={} completedFrame={} enabled={} visible={} evaluated={} completed={} composed={} recent={} ageMs={} gpuMs={} frequency={} submitted={} submittedFrame={} submissionQueue={} fenceSignalFailed={} outputTicket={} outputStages={} outputFailures={} presentedNotInferred=true",
            GetCurrentProcessId(),now,value.request,value.effective,optishade::nr_observation::Name(value.owner.route),value.owner.runtime,value.owner.generation,value.owner.view,value.owner.device,value.queue,
            value.frame,value.completedFrame,value.requested,value.visible,value.evaluated,value.completed,value.composed,value.recent,value.age,value.gpuMilliseconds.value_or(-1),value.frequency,value.submitted,value.submittedFrame,value.submissionQueue,value.fenceSignalFailed,value.output.ticket,value.output.observed,value.output.failed);
    }
    optishade::session::State().Put({{"Device",std::to_string(value.owner.device)},{"Generation",std::to_string(value.owner.generation)},
        {"NRRoute",std::to_string(unsigned(value.owner.route))},{"NRStage",value.recent&&value.completed&&value.composed?"Active":"Waiting"},
        {"SubmissionStage",value.submitted?"Submitted":"Not observed"},{"GPUCompletion",value.completed?"Completed":"Not observed"},
        {"LastSuccessfulTicket",std::to_string(value.completedTicket)}});
    return value;
}
bool IsRunning() {
    // The current owner may be Vulkan. D3D12 feature presence is not its status.
    const auto observed=Observation();
    return observed.requested && observed.evaluated && observed.completed && observed.composed && observed.recent;
}

const char* FailureReason() { return g_nr.failed ? g_nr.reason : ""; }
std::vector<optishade::selfhelp::Advice> FlickerSuspects() {
    using optishade::nr_observation::Route;
    auto* config=Config::Instance();
    optishade::selfhelp::FlickerFacts facts;
    facts.nrOn=config->DlssNrEnabled.value_or_default()&&config->DlssNrApplyModel.value_or_default();
    const auto observed=Observation();
    const auto route=observed.owner.route;
    facts.estimatedMotion=observed.recent&&(route==Route::EstimatedTAA||route==Route::EstimatedVulkan);
    facts.beforeFrameGeneration=observed.recent&&route==Route::PreFgTAA;
    facts.nrStopping=facts.nrOn&&observed.completedFrame>0&&!(observed.recent&&observed.completed);
    facts.deferredDlss=config->DlssNrDeferredDlss.value_or_default();
    const auto hdr=config->DlssNrReversibleMode.value_or_default();
    facts.hdrReplace=hdr==2||hdr==4;
    facts.residualExperimental=config->DlssNrResidualAcrossRr.value_or_default()||config->DlssNrResidualFg.value_or_default();
    facts.memoryLow=MemoryLow();
    return optishade::selfhelp::FlickerSuspects(facts);
}

// What the game offers by way of exposure, and what has been read from it. For the menu, so a user
// can see whether this game supplies one at all without having to read a log.
ExposureStatus GameExposureStatus()
{
    ExposureStatus s {};
    s.seenFrames = g_nr.exposureFrames;
    s.offeredNow = g_nr.exposureOfferedNow;
    s.everOffered = g_nr.exposureEverOffered;
    s.exposure = g_nr.gameExposure;
    s.preExposure = g_nr.gamePreExposure;
    return s;
}

std::optional<double> LastGpuTime() { const auto observed=Observation();return observed.recent ? observed.gpuMilliseconds : std::nullopt; }



void RequestCapture(unsigned int frames)
{
    ClearCaptureDirectory();
    g_capture.request(frames);
}

bool CaptureInProgress() { return g_capture.isActive(); }

bool ShutdownOutput()
{
    auto nrLock = g_nrEvents.Lock();
    TickNrRetired();
    if(!optishade::nr_lifetime::Active().Ready() || !g_nrRetired.empty() || !g_capture.readyToRelease()) {
        g_nr.reason="NR shutdown is waiting for exact GPU recording retirement";
        LOG_WARN("{}; resources retained",g_nr.reason);return false;
    }
    DeferredSr::Instance().Shutdown();

    for (auto& r : g_nrRetired)
    {
        if (r.feature != nullptr && g_nr.release != nullptr)
            g_nr.release(r.feature);

        if (r.resource != nullptr)
            r.resource->Release();
    }

    g_nrRetired.clear();

    if (g_nr.feature != nullptr && g_nr.release != nullptr)
        g_nr.release(g_nr.feature);

    g_nr.feature = nullptr;
    g_nr.featurePendingSubmission = false;

    for (unsigned int pass = 1; pass < DlssNr::MaxPassCount; ++pass)
    {
        void*& f = g_nr.passFeature[pass];
        if (f != nullptr && g_nr.release != nullptr)
            g_nr.release(f);

        f = nullptr;
        g_nr.passNeedsReset[pass] = false;
        g_nr.passCreateFailed[pass] = false;
        g_nr.passPendingSubmission[pass] = false;
    }

    if (g_nr.output != nullptr)
    {
        g_nr.output->Release();
        g_nr.output = nullptr;
    }

    if (g_nr.passScratch != nullptr)
    {
        g_nr.passScratch->Release();
        g_nr.passScratch = nullptr;
    }
    g_nr.passScratchFailed = false;

    if (g_nr.colorCopy != nullptr)
    {
        g_nr.colorCopy->Release();
        g_nr.colorCopy = nullptr;
    }

    if (g_nr.hdrCopy != nullptr)
    {
        g_nr.hdrCopy->Release();
        g_nr.hdrCopy = nullptr;
    }

    if (g_nr.activeColor != nullptr)
    {
        g_nr.activeColor->Release();
        g_nr.activeColor = nullptr;
    }

    if (g_nr.colorSmall != nullptr)
    {
        g_nr.colorSmall->Release();
        g_nr.colorSmall = nullptr;
    }

    if (g_nr.superUp != nullptr)
    {
        delete g_nr.superUp;
        g_nr.superUp = nullptr;
    }

    if (g_nr.superDown != nullptr)
    {
        delete g_nr.superDown;
        g_nr.superDown = nullptr;
    }

    for (ID3D12Resource** r : { &g_nr.residualEdited, &g_nr.residualHistory[0],
                               &g_nr.residualHistory[1], &g_nr.residualComposed })
        if (*r != nullptr)
        {
            (*r)->Release();
            *r = nullptr;
        }
    g_nr.residualPair.Cancel();
    g_nr.residualStoreValid = false;
    g_nr.residualHistoryPrimed = false;
    g_nr.residualHistoryIndex = 0;

    if (g_nr.outputNative != nullptr)
    {
        g_nr.outputNative->Release();
        g_nr.outputNative = nullptr;
    }

    if (g_nr.heldColor != nullptr)
    {
        g_nr.heldColor->Release();
        g_nr.heldColor = nullptr;
    }
    g_nr.heldActive = false;

    if (g_nr.meter != nullptr)
    {
        g_nr.meter->Release();
        g_nr.meter = nullptr;
    }

    if (g_nr.calib != nullptr)
    {
        g_nr.calib->Release();
        g_nr.calib = nullptr;
    }

    for (auto& r : g_nr.calibReadback)
    {
        if (r != nullptr)
        {
            r->Release();
            r = nullptr;
        }
    }

    g_nr.calibFrames = 0;
    g_nr.calibCount = 0;
    g_nr.calibSuggestion = 0.0f;
    g_nr.calibSteadiness = 0.0f;
    g_nr.calibUsable = false;
    g_nr.calibWhy = "measuring...";

    for (auto& rb : g_nr.meterReadback)
    {
        if (rb != nullptr)
        {
            rb->Release();
            rb = nullptr;
        }
    }

    // The slots these flags describe have just been released, so nothing may vouch for what the next
    // buffers happen to contain. gameExposure is deliberately NOT cleared here: a recreate is a
    // transition within the same scene, and dropping to the slider for a few frames would be the
    // flicker the held value exists to prevent. The user switching the option off is the case where
    // the held value has to go, and that is handled at the edge in Dispatch.
    for (bool& valid : g_nr.meterExposureValid)
        valid = false;

    g_nr.meterFrames = 0;


    if (g_nr.depthClone != nullptr)
    {
        g_nr.depthClone->Release();
        g_nr.depthClone = nullptr;
    }



    if (g_nr.motionClone != nullptr)
    {
        g_nr.motionClone->Release();
        g_nr.motionClone = nullptr;
    }

    g_capture.release();
    g_gpuTime.reset();
    g_ngxTime.reset();
    g_lastNgxTime.reset();
    g_lastGpuTime.reset();

    g_compose.reset();
    for (auto& parameters : g_nr.passParams) {
        if (parameters) if (auto destroy=NVNGXProxy::D3D12_DestroyParameters()) destroy(parameters);
        parameters=nullptr;
    }
    if (g_nr.capabilityParams) {
        if (auto destroy = NVNGXProxy::D3D12_DestroyParameters()) destroy(g_nr.capabilityParams);
        g_nr.capabilityParams = nullptr;
    }
    g_nr.capabilityDevice.Reset();
    g_nr.failed = false; g_nr.reason = ""; g_nr.reset = true;
    g_nrDeviceLost = false; g_memoryCheck.invalidate();
    return true;
}
RetirementResult Shutdown(uint32_t waitTimeoutMs){
    const auto started=GetTickCount64();
    for(;;){
      {
        auto guard=g_nrEvents.Lock();
        RetireCompletedTaaRecordings();
        optishade::route::ForEachOutput([]{auto& late=Late::Instance();for(auto& slot:late.slots)
            if(slot.commands&&!slot.recording&&!slot.pending&&late.Finished(slot))optishade::nr_lifetime::RetirePrivate(slot.commands.Get());});
        bool ready=TaaFgReadyToRetire();
        optishade::route::ForEachOutput([&]{TickNrRetired();ready &= optishade::nr_lifetime::Active().Ready() && g_nrRetired.empty();});
        if(ready){
    struct DeviceOwner{Microsoft::WRL::ComPtr<ID3D12Device> device;HMODULE forwarder;};
    std::vector<DeviceOwner> devices;
    optishade::route::ForEachOutput([&]{
        Microsoft::WRL::ComPtr<ID3D12Device> device;
        if(g_nr.capabilityDevice && SUCCEEDED(g_nr.capabilityDevice.As(&device)) &&
           std::none_of(devices.begin(),devices.end(),[&](const auto& old){return old.device==device;}))
            devices.push_back({device,g_nr.forwarder});
        ShutdownOutput();
    });
    // Model features from every eye/output have been released before device shutdown.
    for(const auto& owner:devices){
        const auto retire=owner.forwarder?reinterpret_cast<bool(*)(ID3D12Device*)>(GetProcAddress(owner.forwarder,"dlssnr_call_retire_device")):nullptr;
        if(retire)retire(owner.device.Get());
        if(optishade::route::CurrentSimulator()==optishade::route::Simulator::XPlane12)
            if(auto shutdown=NVNGXProxy::D3D12_Shutdown1())shutdown(owner.device.Get());
    }
          if(optishade::route::CurrentSimulator()==optishade::route::Simulator::XPlane12)NVNGXProxy::SetDx12Inited(false);
          return RetirementResult::Retired;
        }
      }
      if(!waitTimeoutMs||GetTickCount64()-started>=waitTimeoutMs){
        size_t pendingUses=0,pendingLateSlots=0,pendingBindingGroups=0,pendingBindingObjects=0,pendingBindingGroupsNotReady=0;
        {
            auto guard=g_nrEvents.Lock();
            const size_t pendingRetired=g_nrRetired.size();
            optishade::route::ForEachOutput([&]{
                auto& uses=optishade::nr_lifetime::Active();uses.Collect();pendingUses+=uses.items.size();
                const auto held=optishade::nr_lifetime::SnapshotHeld();
                pendingBindingGroups+=held.groups;pendingBindingObjects+=held.objects;pendingBindingGroupsNotReady+=held.pending;
                auto& late=Late::Instance();
                for(const auto& slot:late.slots)if(slot.commands)++pendingLateSlots;
            });
            LOG_WARN("NR shutdown retained output leases: waitedMs={} nativeFgFrames={} activeCommandUses={} retiredDomains={} lateSlots={} bindingGroups={} bindingObjects={} bindingGroupsNotReady={}",
                GetTickCount64()-started,TaaFgPendingCount(),pendingUses,pendingRetired,pendingLateSlots,
                pendingBindingGroups,pendingBindingObjects,pendingBindingGroupsNotReady);
        }
        return RetirementResult::PendingGpu;
      }
      // Drop the event lock between polls so presentation and provider callbacks
      // can publish the exact retirement observations needed by this reset.
      Sleep(1);
    }
}

RetirementResult PrepareForSwapchainResize()
{
    const auto retirement = Shutdown(0);
    if (retirement == RetirementResult::Retired)
        return retirement;

    // Do not make a game retry a one-shot settings resize because an older NR
    // command list has not yet reset. Shutdown retained all live objects; mark
    // the next NR dispatch to park the old feature and surfaces under the same
    // exact-generation leases before creating replacements.
    auto guard = g_nrEvents.Lock();
    optishade::route::ForEachOutput([] {
        g_nr.resizeRebuildPending = true;
        g_nr.reset = true;
        g_nr.residualHistoryPrimed = false;
    });
    LOG_WARN("Swapchain resize proceeding with NR output leases retained; surfaces will rebuild after exact retirement.");
    return retirement;
}
bool TaaPreFgObserver()
{
    static const auto exe = Util::ExePath().filename().wstring();
    static const bool beta = optishade::taa::NativeMsfsObserver(exe, OPTISHADE_VERSION_TEXT);
    return optishade::taa::PreFgObserver(beta, optishade::taa::MsfsExecutable(exe),
                                         optishade::route::ExternalFgObserver());
}
// OptiMFG keeps slDLSSGSetOptions native, so no accepted SetOptions signature
// is ever published there. Publish its backend's status instead (throttled
// file read), so the pre-FG TAA route and the late route agree on whether
// frames are being generated.
// TAA NR before frame generation stays out of the game's per-frame Streamline
// and present calls until the TAA route has run in this session. From R327 every
// DLSS NR + OptiMFG session had each tag, constants, token and present callback
// take the NR event lock on the game's threads (MSFS froze on R330 and not on
// R324: OSD-3NCN, OSD-6NCE, OSD-RF5J). Output binding and release stay live.
std::atomic<bool> g_taaRouteUsed{false};
bool TaaPreFgUsed(){return g_taaRouteUsed.load(std::memory_order_relaxed);}
// For the lock watchdog (D3D12_Hooks.cpp): TryWithState never waits for the lock.
bool NrEventLockFree(){return !TaaPreFgUsed()||g_nrEvents.TryWithState([]{});}
void RefreshUnobservedFgSignature()
{
    auto& state = State::Instance();
    if (!state.optiMfgExternalController)
        return;
    uint32_t applied = 0;
    const bool generating = optishade::external_fg_status::Session().Generating(&applied);
    state.dlssgTemporalSignature.store(optishade::taa::StatusSignature(generating, applied), std::memory_order_relaxed);
    // One line per held pause, so a report shows whether NR stayed on one route.
    static bool loggedHold = false;
    const bool holding = optishade::external_fg_status::Session().Holding();
    if (holding != loggedHold)
    {
        loggedHold = holding;
        if (holding)
            LOG_INFO("TAA NR: frame generation presented single frames with FG still on (dynamic mode or a dropout); keeping the current NR route for up to {} ms", optishade::external_fg_status::kPauseHoldMs);
        else
            LOG_INFO("TAA NR: frame generation pause hold ended");
    }
}
#include "DlssNr_Taa.inl"
#include "DlssNr_TaaNativeFg.inl"

void RetireCompletedPrivateRecordings()
{
    RetireCompletedTaaRecordings(false);
    optishade::route::ForEachOutput([] {
        auto& late = Late::Instance();
        for (auto& slot : late.slots)
            if (slot.commands && !slot.recording && !slot.pending && late.Finished(slot))
                optishade::nr_lifetime::RetirePrivate(slot.commands.Get());
    });
}


// Called under the NR event lock. Only ReShade's synchronous TAA route (1)
// participates; native FG/provider outputs have their own owner and are untouched.
void CollectRetiredTaaOutputs()
{
    static bool collecting=false; // protected by recursive NR state ownership
    if(collecting)return;
    collecting=true;
    struct Reset {bool& value;~Reset(){value=false;}} reset{collecting};
    const auto entries=optishade::route::Outputs().Snapshot();
    for(unsigned index=1;index<optishade::route::OutputDirectory::Capacity;++index){
        const auto& entry=entries[index];
        if(!entry.used||!entry.retiring||entry.key.route!=1)continue;
        optishade::route::OutputScope scope(index);
        auto& taa=Taa::Instance();taa.Reclaim();
        // Failure/unknown completion quarantines the owner. Never substitute
        // elapsed time or runtime destruction for the actual GPU proof.
        if(!optishade::taa::PrivateSubmitRetired(taa.poisoned,
            taa.Borrowing(),taa.fence!=nullptr,
            taa.fence?taa.fence->GetCompletedValue():0,taa.fenceValue))continue;
        taa.ForEachRecording([](ID3D12GraphicsCommandList* list){optishade::nr_lifetime::RetirePrivate(list);});
        bool ready=true;
        auto& late=Late::Instance();
        for(auto& slot:late.slots)if(slot.commands){
            if(slot.pending||!late.Finished(slot)){ready=false;break;}
            optishade::nr_lifetime::RetirePrivate(slot.commands.Get());
        }
        auto& native=NativeTaaFg::Instance();native.Collect();
        for(const auto& frame:native.frames)if(frame)ready=false;
        auto& deferred=DeferredSr::Instance();deferred.Collect();
        if(deferred.pending.cmd||(deferred.current&&!deferred.current->Idle())||!deferred.retired.empty())ready=false;
        TickNrRetired();optishade::nr_lifetime::Collect();
        if(!ready||!optishade::nr_lifetime::Active().Ready()||!g_nrRetired.empty()||!optishade::nr_lifetime::HeldObjects().empty())continue;
        if(!ShutdownOutput())continue;
        // All storage associated with this D3D12/TAA owner must go before its
        // directory slot can identify a different runtime or projection eye.
        using namespace optishade::route;
        ReleaseOutputOwned<Taa::Context,6>(index);
        ReleaseOutputOwned<Late::Context,5>(index);
        ReleaseOutputOwned<NativeTaaFg::Context,7>(index);
        ReleaseOutputOwned<DeferredSr::Context,10>(index);
        ReleaseOutputOwned<NrState,0>(index);
        ReleaseOutputOwned<NrEngineState,1>(index);
        ReleaseOutputOwned<std::vector<NrRetired>,3>(index);
        ReleaseOutputOwned<NrMemoryState,4>(index);
        ReleaseOutputOwned<optishade::nr_lifetime::Uses,17>(index);
        ReleaseOutputOwned<std::vector<optishade::nr_lifetime::Held>,24>(index);
        if(Outputs().CompleteRetirement(index,entry.key,true))
            LOG_INFO("NR TAA output retired: owner={:X} generation={} view={} slot={}; GPU-complete resources released",entry.key.owner,entry.key.generation,entry.key.view,index);
    }
}
} // namespace DlssNr

extern "C" __declspec(dllexport) void OptiShadeTaaRetireRuntime(uint32_t version,uint64_t runtime)
{
    if(version!=ostaa::RetirementVersion||!runtime)return;
    // Destruction can arrive while DXGI/queue locks are held. Publish only;
    // the next regular NR entry collects under its normal state lock.
    const auto count=optishade::route::Outputs().RetireOwner(runtime,1);
    if(count)LOG_INFO("NR TAA runtime ended: owner={:X} outputs={}; requesting exact GPU retirement",runtime,count);
}

extern "C" __declspec(dllexport) bool OptiShadeTaaRequested()
{
    auto guard = g_nrEvents.Lock();
    DlssNr::CollectRetiredTaaOutputs();
    // The TAA route never reaches EvaluateInternal while NR is off, so its
    // outputs (the VR desktop mirror among them) release their memory here.
    const bool offHere=NrOffInHeadset();
    if(!Config::Instance()->DlssNrEnabled.value_or_default()||offHere)
        optishade::route::ForEachOutput([]{ReleaseWhileSwitchedOff();});
    if(offHere)return false;
    const auto& route=optishade::route::Current();
    // Admission depends on the loaded contract and subsequently validated resources,
    // not a game filename. A missing adapter must not silently run a second owner.
    return route.module && route.descriptor.api==optishade::route::Api::Dx12 && Config::Instance()->DlssNrEnabled.value_or_default() && optishade::nr_source::AllowsTemporal(Config::Instance()->SourcePolicy());
}
extern "C" __declspec(dllexport) void OptiShadeTaaSubmit(const ostaa::Frame* frame)
{
    if (!OptiShadeTaaRequested()) return;
    auto guard = g_nrEvents.Lock();
    if(!frame||frame->version!=ostaa::Version||frame->size!=sizeof(*frame)||!frame->queue||
       !frame->runtime||!frame->generation||frame->projection>1||frame->viewCount<1||frame->viewCount>16||frame->view>=frame->viewCount)return;
    DlssNr::CollectRetiredTaaOutputs();
    // Refused/incomplete guide frames do not allocate per-output NR histories.
    // Use the reserved status slot without changing a live provider's context.
    if(!frame->providerReady||!frame->color||!frame->depth||!frame->motion){
        optishade::route::OutputScope status(0u);
        DlssNr::Taa::Instance().Say(frame->reason?frame->reason:"Waiting for built-in guides, valid scene depth and an SDR D3D12 frame.");return;
    }
    Microsoft::WRL::ComPtr<ID3D12Device> device;
    if(FAILED(static_cast<ID3D12CommandQueue*>(frame->queue)->GetDevice(IID_PPV_ARGS(&device))))return;
    optishade::route::OutputScope scope(optishade::route::OutputKey{reinterpret_cast<uint64_t>(optishade::ReShadeDeviceIdentity(device.Get()).Get()),frame->runtime,frame->generation,frame->view,1});
    if(!scope){
        static OptiShadeLog::ReasonLimits<1> limits;
        if(limits.record(0,GetTickCount64(),5000))LOG_WARN("NR TAA output unavailable: owner={:X} generation={} view={}; existing GPU owners retained",frame->runtime,frame->generation,frame->view);
        return;
    }
    // In VR the desktop window only mirrors the headset: NR there costs a whole
    // model and its GPU time for an image nobody wears. Skip it and let its
    // model and surfaces go after the usual grace.
    if(!frame->projection&&HeadsetPresenting()){
        DlssNr::Taa::Instance().Say("Not applied to the desktop mirror while a VR headset session is running; NR runs in the headset.");
        ReleaseWhileSwitchedOff();
        return;
    }
    // Flat D3D12 output stays on the presenting queue, so it is pipelined; VR eyes
    // go to the compositor and still wait for their GPU work.
    const auto result=DlssNr::Taa::Instance().Submit(frame,frame->projection!=0);
    if(!frame->projection)optishade::actual_gpu::NrOutput(static_cast<ID3D12Resource*>(frame->color),result.ticket,
        optishade::nr_observation::State().Read(GetTickCount64()).request,
        result.evaluated&&result.composed&&(result.gpuCompleted||result.submitted),result.modelFailed||result.gpuUnsafe);
}

extern "C" __declspec(dllexport) void OptiShadeXrFrame(uint32_t version)
{
    // Version 1: called by ReShade's OpenXR layer once per xrEndFrame.
    if (version != 1) return;
    const ULONGLONG previous = g_headsetFrameAt.exchange(GetTickCount64(), std::memory_order_relaxed);
    if (!previous || GetTickCount64() - previous >= 1500)
        LOG_INFO("VR headset session frames observed: NR {} in the headset; the desktop mirror is skipped",
                 Config::Instance()->DlssNrInVrHeadset.value_or_default() ? "runs" : "is off (Use NR in the VR headset)");
}

extern "C" __declspec(dllexport) bool OptiShadeTaaNeedsGuides(void* device, uint32_t width, uint32_t height)
{
    if (HeadsetPresenting()) return false;  // flat runtime = desktop mirror in VR
    if (!OptiShadeTaaRequested() || !optishade::nr_source::AllowsEstimated(Config::Instance()->SourcePolicy()) || !device || !width || !height) return false;
    auto guard = g_nrEvents.Lock();
    const auto identity = optishade::ReShadeDeviceIdentity(static_cast<ID3D12Device*>(device));
    return identity && !g_nativeNrInputs.recent(reinterpret_cast<uint64_t>(identity.Get()), width, height, GetTickCount64());
}

extern "C" __declspec(dllexport) bool OptiShadeD3D11TaaNeedsGuides(void* nativeDevice, uint32_t width, uint32_t height)
{
    if (HeadsetPresenting()) return false;
    if (!OptiShadeTaaRequested() || !optishade::nr_source::AllowsEstimated(Config::Instance()->SourcePolicy()) ||
        !nativeDevice || width < 64 || height < 64 || width > 16384 || height > 16384) return false;
    auto guard = g_nrEvents.Lock();
    Microsoft::WRL::ComPtr<IDXGIDevice> dxgi;
    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    DXGI_ADAPTER_DESC desc{};
    if (FAILED(static_cast<ID3D11Device*>(nativeDevice)->QueryInterface(IID_PPV_ARGS(&dxgi))) ||
        FAILED(dxgi->GetAdapter(&adapter)) || FAILED(adapter->GetDesc(&desc))) return false;
    // Generic D3D11 frames use estimated motion. The bridge still validates the
    // physical NVIDIA device and exact resources before any model work is queued.
    return desc.VendorId == 0x10de;
}

extern "C" __declspec(dllexport) void OptiShadeD3D11TaaSubmit(const ostaa::Frame* input){
    if(!OptiShadeTaaRequested()||!input||input->version!=ostaa::Version||input->size!=sizeof(*input)||
       !input->runtime||!input->generation||!input->queue||input->projection||input->viewCount!=1||input->view)return;
    auto guard=g_nrEvents.Lock();
    auto* context=static_cast<ID3D11DeviceContext*>(input->queue);
    Microsoft::WRL::ComPtr<ID3D11Device> device;context->GetDevice(&device);if(!device)return;
    optishade::route::OutputScope scope({reinterpret_cast<uint64_t>(optishade::ReShadeObjectIdentity(device.Get()).Get()),input->runtime,input->generation,0,6});
    if(!scope)return;
    struct Transport {std::unique_ptr<optishade::d11nr::Bridge> bridge;uint64_t lastFailure=0;};
    auto& transport=optishade::route::OutputOwned<Transport,27>();
    auto& state=DlssNr::Taa::Instance();
    if(!input->providerReady||!input->color||!input->depth||!input->motion){state.Say(input->reason?input->reason:"Waiting for D3D11 depth and estimated motion");return;}
    ID3D11Texture2D* textures[]={static_cast<ID3D11Texture2D*>(input->color),static_cast<ID3D11Texture2D*>(input->depth),static_cast<ID3D11Texture2D*>(input->motion)};
    if(transport.bridge&&transport.bridge->Poisoned()){state.Say(transport.bridge->Reason());return;}
    if(!transport.bridge||!transport.bridge->Matches(device.Get(),textures)){
        if(transport.bridge&&!transport.bridge->ReadyToRetire()){state.Say("Waiting for the previous D3D11 NR transaction");return;}
        const auto now=GetTickCount64();if(transport.lastFailure&&now-transport.lastFailure<5000)return;
        auto candidate=std::make_unique<optishade::d11nr::Bridge>();
        if(!candidate->Init(device.Get(),textures,transport.bridge?transport.bridge->Device():nullptr,transport.bridge?transport.bridge->Queue():nullptr)){
            state.Say(candidate->Reason());transport.lastFailure=now;return;
        }
        state.ForEachRecording([](ID3D12GraphicsCommandList* list){optishade::nr_lifetime::RetirePrivate(list);});
        transport.bridge=std::move(candidate);state.lastRun=0;
    }
    const auto transaction=optishade::nr_submission::RunTransport(*transport.bridge,textures,[&](auto* queue,auto* colour,auto* depth,auto* motion){
        ostaa::Frame frame=*input;frame.queue=queue;frame.color=colour;frame.depth=depth;frame.motion=motion;
        return state.Submit(&frame);
    });
    if(!transaction.completed)state.Say(transport.bridge->Reason());
    // Associate the exact inference ticket with the original D3D11 output only
    // after the real same-adapter transport returns its copy-back result.
    optishade::actual_gpu::NrOutput(textures[0],transaction.inference.ticket,
        optishade::nr_observation::State().Read(GetTickCount64()).request,transaction.ComposedImageCopied(),
        !transaction.completed||transaction.inference.modelFailed||transaction.inference.gpuUnsafe);
    static ULONGLONG lastD3D11CopybackLog=0;
    const auto now=GetTickCount64();
    if(transaction.completed&&(!lastD3D11CopybackLog||now-lastD3D11CopybackLog>=5000)){
        lastD3D11CopybackLog=now;
        D3D11_TEXTURE2D_DESC colourDesc{};textures[0]->GetDesc(&colourDesc);
        LOG_INFO("TAA D3D11 transport: {}; inference={}; composedImageCopied={}; ticket={}; runtime={:X} generation={} extent={}x{} format={}; presentation not observed here",
            transaction.TransportStatus(),transaction.inference.InferenceStatus(),transaction.ComposedImageCopied(),transaction.inference.ticket,
            input->runtime,input->generation,colourDesc.Width,colourDesc.Height,(unsigned)colourDesc.Format);
    }
    optishade::session::State().Put({{"API","D3D11"},{"NRTransport","Same-adapter D3D11/D3D12 shared textures and fences"},
        {"NRTransportResult",transaction.TransportStatus()},{"NRInferenceResult",transaction.inference.InferenceStatus()},
        {"NRTransportCopiedComposition",transaction.ComposedImageCopied()?"Yes; current ticket":"Not verified"},
        {"NRTransportTicket",std::to_string(transaction.inference.ticket)},{"NRTransportFrame",std::to_string(transaction.inference.frame)},
        {"NRRuntime",std::to_string(input->runtime)},{"NRGeneration",std::to_string(input->generation)},
        {"InputProvenance","Captured colour/depth; image-estimated motion"}});
}

// Read-only diagnostics for the OptiShade hardware test.
extern "C" __declspec(dllexport) unsigned long long OptiShadeNrCompletedFrames(){auto guard = g_nrEvents.Lock();return optishade::nr_observation::State().CompletedRecords();}

extern "C" __declspec(dllexport) void OptiShadeNrCompositionCompleted(uint64_t ticket,uint64_t queue){
    optishade::nr_observation::State().Completed(ticket,queue,0,std::nullopt);
    DlssNr::Observation();
}

extern "C" __declspec(dllexport) uint64_t OptiShadeTaaHistoryKey(){return State::Instance().dlssgTemporalSignature.load(std::memory_order_relaxed);}



extern "C" __declspec(dllexport) bool OptiShadeTaaOwnsWindow(uint64_t hwnd){
    auto guard = g_nrEvents.Lock();
    auto* swap=State::Instance().currentRealSwapchain;DXGI_SWAP_CHAIN_DESC desc{};
    return hwnd&&swap&&SUCCEEDED(swap->GetDesc(&desc))&&reinterpret_cast<uint64_t>(desc.OutputWindow)==hwnd&&MenuOverlayDx::IsPrimarySwapchain(desc.OutputWindow,swap);
}
