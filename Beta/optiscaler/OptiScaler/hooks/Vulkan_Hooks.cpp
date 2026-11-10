#include "pch.h"
#include "../../../shared/LastSession.h"
#include "../../../shared/NrObservation.h"
#include "../../../shared/RuntimeRenderContext.h"

#include "Vulkan_Hooks.h"
#include "../../../shared/XPlaneWindowIdentity.h"

#include <Util.h>
#include <Config.h>
#include <SysUtils.h>

#include <menu/menu_overlay_vk.h>
#include <proxies/KernelBase_Proxy.h>
#include <upscaler_time/UpscalerTime_Vk.h>

#include <misc/FrameLimit.h>
#include "Reflex_Hooks.h"

#include <spoofing/Vulkan_Spoofing.h>

#include <vulkan/vulkan.hpp>
#include "../../../shared/VulkanOverlayBridge.h"
#include "../../../shared/VulkanOwner.h"
#include "../../../shared/SimulatorRouteHost.h"
#include "../../../shared/XPlaneVulkanProcess.h"
#include "../../../shared/XPlaneBridgeRuntime.h"
#include "../../../shared/VulkanPresentObservation.h"
#include "../../../shared/VulkanAcquireObservation.h"
#include "../../../shared/VulkanSubmitObservation.h"
#include "../../../shared/VulkanSyncObservation.h"
#include "../../../shared/UnlockedProviderCall.h"
#include "../../../shared/OverlaySubmissionLock.h"
#include <dlssnr/DlssNrFeature_Dx12.h>
#include <dlssnr/DlssNrFeature_Vk.h>

#include <dlssnr/DlssNr_VkExtensions.h>
#include <dlssnr/DlssNrFeature_Vk.h>

#include <hooks/ProcessDetourTransaction.h>
#include <detours/detours.h>
#include <misc/IdentifyGpu.h>
#include <atomic>
#include <algorithm>
#include <string>

#include "Hook_Utils.h"

struct VulkanDeviceDispatch
{
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    PFN_vkQueuePresentKHR queuePresent = nullptr;
    PFN_vkCreateSwapchainKHR createSwapchain = nullptr;
    bool nrCapabilityKnown = false;
    bool nrExtensionsReady = false;
    optishade::runtime_render::Device renderingDevice;
};
// The route owns Vulkan presentation identity and device dispatch lifetime.
struct VulkanHookOwner {
 VkDevice device=VK_NULL_HANDLE;VkInstance instance=VK_NULL_HANDLE;VkPhysicalDevice physical=VK_NULL_HANDLE;
 optishade::route::VulkanRegistry owners;std::recursive_mutex mutex;
 VkSwapchainCreateInfoKHR createInfo{};
 uint64_t prepared=0,candidate=0,candidateSince=0;uint32_t presents=0;
 std::unordered_map<VkDevice,VkPhysicalDevice> physicalDevices;
 std::unordered_map<VkDevice,VulkanDeviceDispatch> dispatch;
};
#define _device (optishade::route::Owned<VulkanHookOwner,23>().device)
#define _instance (optishade::route::Owned<VulkanHookOwner,23>().instance)
#define _PD (optishade::route::Owned<VulkanHookOwner,23>().physical)
#define _owners (optishade::route::Owned<VulkanHookOwner,23>().owners)
#define _ownerMutex (optishade::route::Owned<VulkanHookOwner,23>().mutex)
#define _ownerCreateInfo (optishade::route::Owned<VulkanHookOwner,23>().createInfo)
#define _preparedGeneration (optishade::route::Owned<VulkanHookOwner,23>().prepared)
#define _candidateGeneration (optishade::route::Owned<VulkanHookOwner,23>().candidate)
#define _candidateSince (optishade::route::Owned<VulkanHookOwner,23>().candidateSince)
#define _candidatePresents (optishade::route::Owned<VulkanHookOwner,23>().presents)
#define _physicalDevices (optishade::route::Owned<VulkanHookOwner,23>().physicalDevices)
#define _deviceDispatch (optishade::route::Owned<VulkanHookOwner,23>().dispatch)

static bool GameplayWindow(HWND hwnd);

// Publishes only the already-selected route's scalar WSI identity. This does
// not create a Vulkan/D3D12 device, request inputs or install a provider.
static void PublishVulkanAutoContext(VkQueue queue)
{
    if(optishade::route::CurrentSimulator()!=optishade::route::Simulator::XPlane12||
       !optishade::xplane_layer::UsesNativeEffects(optishade::xplane_layer::CurrentRoute()))return;
    const auto found=_deviceDispatch.find((VkDevice)_owners.owner.device);
    const auto selected=_owners.findQueue((uint64_t)queue);
    if(found==_deviceDispatch.end()||!found->second.renderingDevice.Known()||
       selected.device!=_owners.owner.device||!selected.graphics)return;
    optishade::vulkan_fg::Owner sample;
    sample.xplaneNative=true;sample.graphicsQueue=true;sample.presentObserved=true;
    sample.sampledAt=GetTickCount64();sample.providerAvailable=optishade::Evidence::No;
    static const auto process=[] {
        struct Process {uint32_t pid;uint64_t birth;};
        FILETIME born{},exit{},kernel{},user{};
        const bool known=GetProcessTimes(GetCurrentProcess(),&born,&exit,&kernel,&user)!=FALSE;
        return Process{GetCurrentProcessId(),known?(uint64_t(born.dwHighDateTime)<<32)|born.dwLowDateTime:0};
    }();
    auto& binding=sample.binding;binding.pid=process.pid;binding.birth=process.birth;
    binding.device=_owners.owner.device;binding.luid=found->second.renderingDevice.luid;
    binding.output=_owners.owner.chain;binding.generation=_owners.owner.generation;
    binding.queue=(uint64_t)queue;binding.queueFamily=selected.family;
    binding.format=static_cast<uint32_t>(_ownerCreateInfo.imageFormat);
    binding.colourSpace=static_cast<uint32_t>(_ownerCreateInfo.imageColorSpace);
    binding.width=_ownerCreateInfo.imageExtent.width;binding.height=_ownerCreateInfo.imageExtent.height;
    binding.layers=_ownerCreateInfo.imageArrayLayers;
    // A WSI image/layer is not an engine eye or temporal input frame. Keep
    // those identities unknown until an actual source supplies them.
    binding.view=UINT32_MAX;binding.viewKnown=false;
    const optishade::format_view::SurfaceView surface{{binding.width,binding.height},
        {0,0,binding.width,binding.height},binding.layers,0,1,1,0,binding.layers,1};
    sample.surfaceMetadataValid=optishade::format_view::ValidateSurface(surface);
    // The WSI description proves its allocation shape, not a provider's
    // support for the colour transfer/format or an engine eye. Those remain
    // unknown while the native Vulkan FG delegate is absent.
    sample.surface=optishade::Evidence::Unknown;
    optishade::runtime_render::State().Publish(found->second.renderingDevice,binding.output,binding.generation,
        "vulkan",binding.view,sample.sampledAt,{},&sample);
}

static void ResetOverlayCandidate() noexcept
{
    _candidateGeneration = 0;
    _candidateSince = 0;
    _candidatePresents = 0;
}

static bool OverlayOwnerReady()
{
    if (_wcsicmp(Util::ExePath().filename().c_str(), L"X-Plane.exe") != 0)
        return true;

    const auto generation = _owners.owner.generation;
    const auto window = reinterpret_cast<HWND>(_owners.owner.window);
    const auto now = GetTickCount64();
    RECT client{};
    if (!generation || !GameplayWindow(window) || !GetClientRect(window, &client) ||
        client.right <= client.left || client.bottom <= client.top)
    {
        ResetOverlayCandidate();
        return false;
    }

    if (_candidateGeneration != generation)
    {
        _candidateGeneration = generation;
        _candidateSince = now;
        _candidatePresents = 0;
        LOG_INFO("X-Plane 12: deferring menu/input attachment until the Vulkan presentation owner is stable");
        return false;
    }

    // Effects and Vulkan NR are already live before this point. Delay only
    // Win32 menu/input attachment. _candidatePresents counts successful Vulkan
    // presents only (updated after the real present call), not attempts.
    return _candidatePresents >= 8 && now >= _candidateSince && now - _candidateSince >= 1500;
}

static void ObserveOverlayOwnerPresent(VkResult result)
{
    if (_wcsicmp(Util::ExePath().filename().c_str(), L"X-Plane.exe") != 0 ||
        _preparedGeneration == _owners.owner.generation)
        return;

    if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR)
    {
        ResetOverlayCandidate();
        return;
    }

    const auto generation = _owners.owner.generation;
    if (!generation || _candidateGeneration != generation)
        return;
    if (_candidatePresents < UINT32_MAX)
        ++_candidatePresents;
}

static bool GameplayWindow(HWND hwnd)
{
    DWORD pid=0; GetWindowThreadProcessId(hwnd,&pid);
    if (!IsWindow(hwnd) || pid!=GetCurrentProcessId() || GetAncestor(hwnd,GA_ROOT)!=hwnd ||
        GetWindow(hwnd,GW_OWNER) || (GetWindowLongPtrW(hwnd,GWL_EXSTYLE)&WS_EX_TOOLWINDOW)) return false;
    if (_wcsicmp(Util::ExePath().filename().c_str(),L"X-Plane.exe")!=0)
        return hwnd==Util::GetProcessWindow();
    return optishade::window::IsXPlaneMainWindow(hwnd);
}

extern "C" __declspec(dllexport) bool OptiShadeVulkanOwnsWindow(uint64_t window)
{
    std::lock_guard lock(_ownerMutex);
    return _owners.owner.window==window && _owners.owner.chain && IsWindow((HWND)window);
}

std::string DlssNr::VulkanBridgeStatus(){auto* b=optishade::vknr::XPlaneBridge();if(!b)return "Waiting for primary Vulkan swapchain";std::lock_guard lock(b->mutex);return b->poisoned?"Restart required after graphics submission/device loss":b->reason;}

extern "C" __declspec(dllexport) bool OptiShadeVulkanNrRequested()
{
    return optishade::route::Current().module &&
           (optishade::route::CurrentSimulator()==optishade::route::Simulator::XPlane12||optishade::route::CurrentSimulator()==optishade::route::Simulator::Unknown) &&
           Config::Instance()->DlssNrEnabled.value_or_default() && optishade::nr_source::AllowsEstimated(Config::Instance()->SourcePolicy());
}

extern "C" __declspec(dllexport) void OptiShadeVulkanNrReset()
{
    DlssNr::ResetTaaHistoryVk();
}

extern "C" __declspec(dllexport) void OptiShadeVulkanNrReportBlock(unsigned reasonCode,
    uint64_t device,uint64_t owner,uint64_t generation,uint64_t queue)
{
    std::string reason=reasonCode<static_cast<unsigned>(optishade::vknr::Reason::Count)
        ?optishade::vknr::Name(static_cast<optishade::vknr::Reason>(reasonCode))
        :"Unknown XP12 Vulkan NR blocker code";
    if(reasonCode==static_cast<unsigned>(optishade::vknr::Reason::BridgeUnavailable)){
        const auto detail=DlssNr::VulkanBridgeStatus();
        if(!detail.empty())reason+="; "+detail;
    }
    optishade::session::State().RecordXP12BridgeBlock(reason,"Vulkan",device,owner,generation,queue);
}

extern "C" void OptiShadeNrCompositionCompleted(uint64_t,uint64_t);
extern "C" __declspec(dllexport) int OptiShadeVulkanNrSubmit(const osvtaa::Frame* frame)
{
    const auto reportBlock=[&](const char* reason,uint64_t device=0,uint64_t owner=0,uint64_t generation=0,uint64_t queue=0){
        optishade::session::State().RecordXP12BridgeBlock(reason,"Vulkan",device,owner,generation,queue);
    };
    if (!OptiShadeVulkanNrRequested()) {
        const auto simulator=optishade::route::CurrentSimulator();const auto* config=Config::Instance();
        if(simulator==optishade::route::Simulator::XPlane12&&config->DlssNrEnabled.value_or_default()){
            const char* reason=!optishade::route::Current().module?"XP12 Vulkan route module is not active":
                !optishade::nr_source::AllowsEstimated(config->SourcePolicy())?"Selected NR source policy does not admit the XP12 Vulkan estimated-input route":
                "XP12 Vulkan NR request was rejected by route admission";
            reportBlock(reason,frame?frame->device:0,0,frame?frame->generation:0,frame?frame->queue:0);
        }
        return -2;
    }
    if (!frame || frame->version != 4 || frame->size != sizeof(*frame) || !frame->commands ||
        !frame->color || !frame->colorView || !frame->depth || !frame->depthView ||
        !frame->motion || !frame->motionView || frame->width < 64 || frame->height < 64 ||
        frame->width > 3840 || frame->height > 2160) {
        reportBlock("XP12 Vulkan NR frame contract rejected: missing handle, invalid version, or unsupported extent",frame?frame->device:0,0,frame?frame->generation:0,frame?frame->queue:0);
        static ULONGLONG lastReport=0;const auto now=GetTickCount64();
        if(!lastReport||now-lastReport>=5000){lastReport=now;LOG_WARN("XP12 Vulkan NR request rejected: frame version/handle/extent contract; normal picture preserved");}
        return -2;
    }

    uint32_t bridgeFamily=UINT32_MAX;uint64_t bridgeOwner=0,bridgeGeneration=0;
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    std::string admissionBlock;
    uint64_t observedOwner=0,observedGeneration=0;
    {
        std::lock_guard lock(_ownerMutex);
        device = reinterpret_cast<VkDevice>(frame->device);
        const auto dispatch = _deviceDispatch.find(device);
        if (dispatch == _deviceDispatch.end() || device != _device || !_instance || !_PD)
        {
            admissionBlock="XP12 Vulkan frame device is not the active presentation owner";
        }
        observedOwner=_owners.owner.chain;observedGeneration=_owners.owner.generation;
        if(admissionBlock.empty()){
            const auto producerQueue=_owners.findQueue(frame->queue);
            if(producerQueue.device!=frame->device||!producerQueue.graphics||_owners.owner.device!=frame->device)
                admissionBlock="XP12 Vulkan submission queue is not a registered graphics queue for the active presentation owner";
            else{bridgeFamily=producerQueue.family;bridgeOwner=_owners.owner.chain;bridgeGeneration=_owners.owner.generation;instance=_instance;physical=_PD;}
        }
    }
    if(!admissionBlock.empty()){
        reportBlock(admissionBlock.c_str(),frame->device,observedOwner,observedGeneration,frame->queue);
        static ULONGLONG lastDeviceReport=0;const auto now=GetTickCount64();
        if(!lastDeviceReport||now-lastDeviceReport>=5000){lastDeviceReport=now;LOG_WARN("XP12 Vulkan NR request rejected: {}; normal picture preserved",admissionBlock);}
        return -2;
    }

    auto* cfg = Config::Instance();
    // Snapshot the route's controls once. Never temporarily overwrite shared
    // configuration while another renderer/menu may read it.
    const optishade::vknr::GuideOptions options{cfg->DlssNrWorkingScale.value_or_default(),
        cfg->DlssNrPasses.value_or_default(),cfg->DlssNrApplyModel.value_or_default()};
    auto* bridge=optishade::vknr::XPlaneBridge();if(!bridge||!frame->flush||!frame->currentCommands){
        reportBlock(!bridge?"XP12 Vulkan NR bridge runtime is unavailable":"XP12 Vulkan command flush/current-command callbacks are missing",frame->device,bridgeOwner,bridgeGeneration,frame->queue);return -2;}
    std::lock_guard bridgeLock(bridge->mutex);
    if(bridge->poisoned){reportBlock("XP12 Vulkan NR bridge is poisoned after a prior device/submission failure",frame->device,bridgeOwner,bridgeGeneration,frame->queue);return -1;}
    if(bridge->transport&&(!bridge->transport->Matches(device,(VkQueue)frame->queue,frame->width,frame->height)||bridge->owner!=bridgeOwner||bridge->generation!=bridgeGeneration||bridge->runtime!=frame->runtime)){
        static ULONGLONG lastMismatchReport=0;const auto now=GetTickCount64();
        if(!lastMismatchReport||now-lastMismatchReport>=5000){lastMismatchReport=now;LOG_WARN("XP12 private bridge identity changed: transportMismatch=0x{:X} owner={} -> {} generation={} -> {} runtime={} -> {}",bridge->transport->Mismatch(device,(VkQueue)frame->queue,frame->width,frame->height),bridge->owner,bridgeOwner,bridge->generation,bridgeGeneration,bridge->runtime,frame->runtime);}
        if(!bridge->transport->ReadyToRetire()){bridge->reason="Waiting for the previous XP12 bridge generation";reportBlock(bridge->reason.c_str(),frame->device,bridgeOwner,bridgeGeneration,frame->queue);return 0;}
        if(!bridge->transport->RetireCompletedRecordings()){bridge->reason="Waiting for completed XP12 bridge command lists before NR shutdown";reportBlock(bridge->reason.c_str(),frame->device,bridgeOwner,bridgeGeneration,frame->queue);return 0;}
        if(DlssNr::Shutdown()!=DlssNr::RetirementResult::Retired)return 0;bridge->transport.reset();
    }
    if(!bridge->transport){
        const optishade::vknr::BridgeAttemptKey attempt{frame->device,frame->queue,bridgeOwner,bridgeGeneration,frame->runtime,frame->width,frame->height};
        if(!bridge->initializationRetry.Begin(attempt,GetTickCount64()))return -2;
        auto candidate=std::make_unique<optishade::vknr::PrivateVulkanNrRing>();
        if(!candidate->Init(physical,device,(VkQueue)frame->queue,bridgeFamily,frame->width,frame->height)){
            bridge->reason=candidate->Reason();reportBlock(bridge->reason.c_str(),frame->device,bridgeOwner,bridgeGeneration,frame->queue);static std::string last;
            if(last!=bridge->reason){last=bridge->reason;LOG_WARN("XP12 private NR bridge unavailable: {}",last);}return -2;
        }
        bridge->transport=std::move(candidate);bridge->owner=bridgeOwner;bridge->generation=bridgeGeneration;bridge->runtime=frame->runtime;bridge->guideGeneration=frame->generation;
        LOG_INFO("XP12 private NR bridge: owner={} generation={} VkDevice={} VkQueue={} family={} matchedD3D12Device={} privateQueue={} extent={}x{}; frame generation is not used",bridgeOwner,bridgeGeneration,frame->device,frame->queue,bridgeFamily,reinterpret_cast<uint64_t>(bridge->transport->Device()),reinterpret_cast<uint64_t>(bridge->transport->Queue()),frame->width,frame->height);
    }
    if(bridge->guideGeneration!=frame->generation){
        LOG_INFO("XP12 private NR temporal generation changed {} -> {}; keeping the API transport and resetting model history in the output scope",bridge->guideGeneration,frame->generation);
        bridge->guideGeneration=frame->generation;
    }
    bridge->transport->Collect(OptiShadeNrCompositionCompleted);
    auto evaluate=[](void*,ID3D12GraphicsCommandList* cmd,ID3D12CommandQueue* queue,ID3D12Resource* color,ID3D12Resource* depth,ID3D12Resource* motion,const osvtaa::Frame& f){return DlssNr::EvaluatePrivateVulkanBridge(cmd,queue,color,depth,motion,f);};
    const auto result=bridge->transport->Run(*frame,evaluate,nullptr);bridge->reason=bridge->transport->Reason();
    if(result<0)reportBlock(bridge->reason.c_str(),frame->device,bridgeOwner,bridgeGeneration,frame->queue);
    static std::string lastStageReport;static ULONGLONG lastStageReportAt=0;const auto stageNow=GetTickCount64();
    if((result!=1&&(lastStageReport!=bridge->reason||stageNow-lastStageReportAt>=5000))||result==-1){lastStageReport=bridge->reason;lastStageReportAt=stageNow;LOG_INFO("XP12 private NR frame result={} submitted={} stage={} generation={} extent={}x{}",result,bridge->transport->Submitted(),bridge->reason,frame->generation,frame->width,frame->height);}
    if(result==-1){
        LOG_ERROR("Vulkan private NR submission failed: {}; submitted={}; owner={} generation={} extent={}x{}",
            bridge->reason,bridge->transport->Submitted(),bridgeOwner,bridgeGeneration,frame->width,frame->height);
    }
    if(bridge->transport->Submitted()){ID3D12CommandList* lists[]={bridge->transport->Commands()};DlssNr::FinishedPictureSubmitted(bridge->transport->Queue(),1,lists);}
    if(result==1&&frame->observationTicket)bridge->pendingPresentTicket=*frame->observationTicket;
    if(result==0){const auto* failure=DlssNr::FailureReason();if(failure&&*failure)bridge->reason=failure;}
    optishade::session::State().Put({{"API","Vulkan -> private D3D12"},{"FGMode","Not used by XP12 NR"},{"XP12BridgeStage",bridge->reason},{"Generation",std::to_string(bridgeGeneration)},{"Device",std::to_string(frame->device)}});
    if(result==-1)bridge->poisoned=true;
    return result;
}
static std::mutex _vkPresentMutex;

static PFN_vkQueueSubmit o_QueueSubmit=nullptr;
static PFN_vkQueueSubmit2 o_QueueSubmit2=nullptr;
static PFN_vkGetDeviceProcAddr o_vkGetDeviceProcAddr = nullptr;
static std::mutex _vkAcquireObservationMutex;
static optishade::vulkan_acquire_observation::Snapshot _vkLatestAcquireObservation{};
static uint64_t _vkAcquireObservationSequence=0;
static uint64_t _vkAcquireObservationWrittenSequence=0;
static std::mutex _vkSubmitObservationMutex;
static optishade::vulkan_submit_observation::Snapshot _vkLatestSubmitObservation{};
static uint64_t _vkSubmitObservationSequence=0;
static uint64_t _vkSubmitObservationWrittenSequence=0;
static uint64_t _vkSubmitObservationsSinceWrite=0;
struct VulkanSyncEventRecord {uint64_t sequence=0;optishade::vulkan_sync_observation::Event event{};};
static constexpr size_t VulkanSyncEventCapacity=4;
static std::mutex _vkSyncObservationMutex;
static std::array<VulkanSyncEventRecord,VulkanSyncEventCapacity> _vkSyncEvents{};
static size_t _vkSyncEventCount=0;
static size_t _vkSyncEventNext=0;
static uint64_t _vkSyncEventSequence=0;
static uint64_t _vkSyncEventDropped=0;
static uint64_t _vkSemaphoreCreates=0,_vkSemaphoreDestroys=0,_vkFenceCreates=0,_vkFenceDestroys=0;

static void RecordAcquireObservation(const optishade::vulkan_acquire_observation::Snapshot& snapshot){
 {std::lock_guard lock(_vkAcquireObservationMutex);_vkLatestAcquireObservation=snapshot;++_vkAcquireObservationSequence;}
 if(snapshot.result<0)optishade::session::State().PutCritical({
  {"XP12VulkanAcquireApi",std::to_string(snapshot.api)},
  {"XP12VulkanAcquireResult",std::to_string(snapshot.result)},
  {"XP12VulkanAcquireSwapchain",std::to_string(snapshot.swapchain)},
  {"XP12VulkanAcquireImageIndexValid",snapshot.imageIndexValid?"true":"false"}});
}

static std::map<std::string,std::string> AcquireObservationFields(
 const optishade::vulkan_acquire_observation::Snapshot& snapshot){
 return {{"XP12VulkanAcquireApi",std::to_string(snapshot.api)},
  {"XP12VulkanAcquireResult",std::to_string(snapshot.result)},
  {"XP12VulkanAcquireDevice",std::to_string(snapshot.device)},
  {"XP12VulkanAcquireSwapchain",std::to_string(snapshot.swapchain)},
   {"XP12VulkanAcquireSwapchainGeneration",std::to_string(snapshot.swapchainGeneration)},
  {"XP12VulkanAcquireTimeout",std::to_string(snapshot.timeout)},
  {"XP12VulkanAcquireSemaphore",std::to_string(snapshot.semaphore)},
  {"XP12VulkanAcquireFence",std::to_string(snapshot.fence)},
  {"XP12VulkanAcquireDeviceMask",std::to_string(snapshot.deviceMask)},
  {"XP12VulkanAcquireHasPNext",snapshot.hasPNext?"true":"false"},
  {"XP12VulkanAcquireImageIndexValid",snapshot.imageIndexValid?"true":"false"},
  {"XP12VulkanAcquireImageIndex",std::to_string(snapshot.imageIndex)}};
}

static std::map<std::string,std::string> SubmitObservationFields(
 const optishade::vulkan_submit_observation::Snapshot& snapshot,uint64_t observedSinceWrite){
 using namespace optishade::vulkan_submit_observation;
 const auto joinHandles=[](const uint64_t* handles,uint32_t count){
  std::string text;for(uint32_t i=0;i<count;++i){if(i)text.push_back(',');text+=std::to_string(handles[i]);}return text;
 };
 const auto joinSemaphores=[](const SemaphoreEntry* entries,uint32_t count){
  std::string text;for(uint32_t i=0;i<count;++i){if(i)text.push_back(';');const auto& item=entries[i];
   text+=std::to_string(item.handle)+":"+std::to_string(item.value)+":"+std::to_string(item.stageMask)+":"+
    std::to_string(item.deviceIndex)+":"+(item.hasPNext?"1":"0");}return text;
 };
 const auto joinSemaphoreHandles=[](const SemaphoreEntry* entries,uint32_t count){
  std::string text;for(uint32_t i=0;i<count;++i){if(i)text.push_back(',');text+=std::to_string(entries[i].handle);}return text;
 };
 std::string batches;
 for(uint32_t i=0;i<snapshot.batchCount;++i){if(i)batches.push_back(';');const auto& batch=snapshot.batches[i];
  batches+=std::to_string(batch.waitCount)+","+std::to_string(batch.signalCount)+","+std::to_string(batch.commandCount)+"@"+
   std::to_string(batch.waitStart)+","+std::to_string(batch.signalStart)+","+std::to_string(batch.commandStart)+","+
   std::to_string(batch.capturedWaitCount)+","+std::to_string(batch.capturedSignalCount)+","+std::to_string(batch.capturedCommandCount)+","+
   (batch.hasPNext?"1":"0");}
 const uint32_t waitDetails=std::min<uint32_t>(snapshot.capturedWaitCount,4);
 const uint32_t signalDetails=std::min<uint32_t>(snapshot.capturedSignalCount,4);
 return {{"XP12VulkanSubmitApi",std::to_string(snapshot.api)},
  {"XP12VulkanSubmitSource",std::to_string(snapshot.source)},
  {"XP12VulkanSubmitQueue",std::to_string(snapshot.queue)},
  {"XP12VulkanSubmitFence",std::to_string(snapshot.fence)},
  {"XP12VulkanSubmitResult",std::to_string(snapshot.result)},
  {"XP12VulkanSubmitBatchCount",std::to_string(snapshot.submitCount)},
  {"XP12VulkanSubmitBatchesCaptured",std::to_string(snapshot.batchCount)},
  {"XP12VulkanSubmitBatchSummary",batches},
  {"XP12VulkanSubmitWaitCount",std::to_string(snapshot.waitCount)},
  {"XP12VulkanSubmitWaitHandles",joinSemaphoreHandles(snapshot.waits.data(),snapshot.capturedWaitCount)},
  {"XP12VulkanSubmitWaitCaptured",std::to_string(snapshot.capturedWaitCount)},
  {"XP12VulkanSubmitWaitDetails",joinSemaphores(snapshot.waits.data(),waitDetails)},
  {"XP12VulkanSubmitWaitDetailsTruncated",waitDetails<snapshot.capturedWaitCount?"true":"false"},
  {"XP12VulkanSubmitSignalCount",std::to_string(snapshot.signalCount)},
  {"XP12VulkanSubmitSignalHandles",joinSemaphoreHandles(snapshot.signals.data(),snapshot.capturedSignalCount)},
  {"XP12VulkanSubmitSignalCaptured",std::to_string(snapshot.capturedSignalCount)},
  {"XP12VulkanSubmitSignalDetails",joinSemaphores(snapshot.signals.data(),signalDetails)},
  {"XP12VulkanSubmitSignalDetailsTruncated",signalDetails<snapshot.capturedSignalCount?"true":"false"},
  {"XP12VulkanSubmitCommandCount",std::to_string(snapshot.commandCount)},
  {"XP12VulkanSubmitCommandHandles",joinHandles(snapshot.commands.data(),snapshot.capturedCommandCount)},
  {"XP12VulkanSubmitCommandsCaptured",std::to_string(snapshot.capturedCommandCount)},
  {"XP12VulkanSubmitHasPNext",snapshot.hasPNext?"true":"false"},
  {"XP12VulkanSubmitTruncated",snapshot.truncated?"true":"false"},
  {"XP12VulkanSubmitSnapshotValid",snapshot.valid?"true":"false"},
  {"XP12VulkanSubmitObservedSinceWrite",std::to_string(observedSinceWrite)},
  {"XP12VulkanSubmitOmittedSinceWrite",std::to_string(observedSinceWrite?observedSinceWrite-1:0)}};
}

static std::map<std::string,std::string> VulkanSyncObservationFields(){
 using namespace optishade::vulkan_sync_observation;
 std::array<VulkanSyncEventRecord,VulkanSyncEventCapacity> events{};size_t count=0;
 uint64_t sequence=0,dropped=0,semaphoreCreates=0,semaphoreDestroys=0,fenceCreates=0,fenceDestroys=0;
 {std::lock_guard lock(_vkSyncObservationMutex);count=_vkSyncEventCount;sequence=_vkSyncEventSequence;dropped=_vkSyncEventDropped;
  semaphoreCreates=_vkSemaphoreCreates;semaphoreDestroys=_vkSemaphoreDestroys;fenceCreates=_vkFenceCreates;fenceDestroys=_vkFenceDestroys;
  for(size_t i=0;i<count;++i)events[i]=_vkSyncEvents[(_vkSyncEventNext+VulkanSyncEventCapacity-count+i)%VulkanSyncEventCapacity];}
 std::string history;
 for(size_t i=0;i<count;++i){const auto& record=events[i];const auto& event=record.event;
  char item[160]{};
  sprintf_s(item,"%s%llx,%u,%u,%llx,%llx,%d,%x,%u,%llx,%x,%u",i?";":"",
   static_cast<unsigned long long>(record.sequence),event.objectType,event.action,
   static_cast<unsigned long long>(event.device),static_cast<unsigned long long>(event.object),event.result,
   event.flags,event.timeline,static_cast<unsigned long long>(event.initialValue),event.exportHandleTypes,event.hasPNext);
  if(history.size()+strlen(item)>480)break;history+=item;}
 return {{"XP12VulkanSyncEventSequence",std::to_string(sequence)},
  {"XP12VulkanSyncEventsDropped",std::to_string(dropped)},
  {"XP12VulkanSyncSemaphoreCreates",std::to_string(semaphoreCreates)},
  {"XP12VulkanSyncSemaphoreDestroys",std::to_string(semaphoreDestroys)},
  {"XP12VulkanSyncFenceCreates",std::to_string(fenceCreates)},
  {"XP12VulkanSyncFenceDestroys",std::to_string(fenceDestroys)},
  {"XP12VulkanSyncRecentEvents",history}};
}

extern "C" __declspec(dllexport) void OptiShadeVulkanNrSyncObjectObserved(
 const optishade::vulkan_sync_observation::Event* event){
 using namespace optishade::vulkan_sync_observation;
 if(!event||event->size!=sizeof(Event)||event->abi!=Abi||!event->valid||
    optishade::route::CurrentSimulator()!=optishade::route::Simulator::XPlane12)return;
 {std::lock_guard lock(_vkSyncObservationMutex);
  if(_vkSyncEventSequence!=UINT64_MAX)++_vkSyncEventSequence;
  if(_vkSyncEventCount==VulkanSyncEventCapacity){if(_vkSyncEventDropped!=UINT64_MAX)++_vkSyncEventDropped;}
  else ++_vkSyncEventCount;
  auto& record=_vkSyncEvents[_vkSyncEventNext];record.sequence=_vkSyncEventSequence;record.event=*event;
  _vkSyncEventNext=(_vkSyncEventNext+1)%VulkanSyncEventCapacity;
  if(event->objectType==static_cast<uint32_t>(Object::Semaphore)){
   auto& counter=event->action==static_cast<uint32_t>(Action::Create)?_vkSemaphoreCreates:_vkSemaphoreDestroys;
   if(counter!=UINT64_MAX)++counter;
  }else if(event->objectType==static_cast<uint32_t>(Object::Fence)){
   auto& counter=event->action==static_cast<uint32_t>(Action::Create)?_vkFenceCreates:_vkFenceDestroys;
   if(counter!=UINT64_MAX)++counter;
  }else return;
 }
 if(event->action==static_cast<uint32_t>(Action::Create)&&event->result<0)
  optishade::session::State().PutCritical(VulkanSyncObservationFields());
}

extern "C" __declspec(dllexport) void OptiShadeVulkanNrSubmissionObserved(uint64_t queue,uint64_t command,bool success){
 optishade::vknr::Submissions().Observe(queue,command,success);
}
extern "C" __declspec(dllexport) void OptiShadeVulkanNrQueueSubmitObserved(
 const optishade::vulkan_submit_observation::Snapshot* snapshot){
 using namespace optishade::vulkan_submit_observation;
 if(!snapshot||snapshot->size!=sizeof(Snapshot)||snapshot->abi!=Abi||
    optishade::route::CurrentSimulator()!=optishade::route::Simulator::XPlane12)return;
 uint64_t observedSinceWrite=0;
 {std::lock_guard lock(_vkSubmitObservationMutex);_vkLatestSubmitObservation=*snapshot;
  ++_vkSubmitObservationSequence;if(_vkSubmitObservationsSinceWrite!=UINT64_MAX)++_vkSubmitObservationsSinceWrite;
  observedSinceWrite=_vkSubmitObservationsSinceWrite;}
 if(snapshot->result<0&&snapshot->source==static_cast<uint32_t>(Source::Application))
  optishade::session::State().PutCritical(SubmitObservationFields(*snapshot,observedSinceWrite));
}
extern "C" __declspec(dllexport) void OptiShadeVulkanNrPresentObserved(
 const optishade::vulkan_present_observation::Snapshot* snapshot){
 using namespace optishade::vulkan_present_observation;
 if(!snapshot||snapshot->size!=sizeof(Snapshot)||snapshot->abi!=Abi||
    optishade::route::CurrentSimulator()!=optishade::route::Simulator::XPlane12)return;
  Snapshot correlated=*snapshot;
  {
   std::lock_guard lock(_ownerMutex);
   correlated.device=_owners.findQueue(correlated.queue).device;
   for(uint32_t i=0;i<correlated.capturedSwapchainCount;++i)
    correlated.chains[i].generation=_owners.swapchainGeneration(correlated.device,correlated.chains[i].swapchain);
  }
 static std::atomic<uint64_t> lastCapture{0};
 const uint64_t now=GetTickCount64();uint64_t prior=lastCapture.load(std::memory_order_relaxed);
 if(prior&&now-prior<1000)return;
 if(!lastCapture.compare_exchange_strong(prior,now,std::memory_order_relaxed))return;
 const uint32_t waitDetailsCount=std::min<uint32_t>(snapshot->capturedWaitCount,20);
 const auto joinHandles=[](const uint64_t* values,uint32_t count){
  std::string joined;for(uint32_t i=0;i<count;++i){if(i)joined.push_back(',');joined+=std::to_string(values[i]);}return joined;
 };
 std::string images,results;
  std::string generations;
  for(uint32_t i=0;i<correlated.capturedSwapchainCount;++i){
  if(i){images.push_back(',');results.push_back(',');}
   if(i)generations.push_back(',');
   images+=std::to_string(correlated.chains[i].swapchain)+":"+std::to_string(correlated.chains[i].imageIndex);
   generations+=std::to_string(correlated.chains[i].generation);
   results+=std::to_string(correlated.chains[i].result);
 }
 bool haveAcquire=false;optishade::vulkan_acquire_observation::Snapshot acquire{};uint64_t acquireSequence=0;
 {std::lock_guard lock(_vkAcquireObservationMutex);acquireSequence=_vkAcquireObservationSequence;
  if(acquireSequence!=_vkAcquireObservationWrittenSequence){acquire=_vkLatestAcquireObservation;haveAcquire=true;_vkAcquireObservationWrittenSequence=acquireSequence;}}
 bool haveSubmit=false;optishade::vulkan_submit_observation::Snapshot submit{};uint64_t observedSubmits=0;
 {std::lock_guard lock(_vkSubmitObservationMutex);
  if(_vkSubmitObservationSequence!=_vkSubmitObservationWrittenSequence){submit=_vkLatestSubmitObservation;haveSubmit=true;
   observedSubmits=_vkSubmitObservationsSinceWrite;_vkSubmitObservationsSinceWrite=0;_vkSubmitObservationWrittenSequence=_vkSubmitObservationSequence;}}
 std::map<std::string,std::string> values{
   {"XP12VulkanPresentQueue",std::to_string(correlated.queue)},
   {"XP12VulkanPresentDevice",std::to_string(correlated.device)},
  {"XP12VulkanPresentWaitCount",std::to_string(snapshot->waitCount)},
  {"XP12VulkanPresentWaitHandles",joinHandles(snapshot->waits.data(),waitDetailsCount)},
  {"XP12VulkanPresentWaitHandlesCaptured",std::to_string(waitDetailsCount)},
  {"XP12VulkanPresentWaitHandlesTruncated",waitDetailsCount<snapshot->capturedWaitCount?"true":"false"},
   {"XP12VulkanPresentSwapchainCount",std::to_string(correlated.swapchainCount)},
  {"XP12VulkanPresentImages",images},
   {"XP12VulkanPresentGenerations",generations},
  {"XP12VulkanPresentResults",results},
  {"XP12VulkanPresentGlobalResult",std::to_string(snapshot->globalResult)},
  {"XP12VulkanPresentPerResultsKnown",snapshot->perSwapchainResultsKnown?"true":"false"},
  {"XP12VulkanPresentHasPNext",snapshot->hasPNext?"true":"false"},
  {"XP12VulkanPresentTruncated",snapshot->truncated?"true":"false"},
  {"XP12VulkanPresentSnapshotValid",snapshot->valid?"true":"false"}};
 if(haveAcquire){auto fields=AcquireObservationFields(acquire);values.insert(fields.begin(),fields.end());}
 if(haveSubmit){auto fields=SubmitObservationFields(submit,observedSubmits);values.insert(fields.begin(),fields.end());}
 {auto fields=VulkanSyncObservationFields();values.insert(fields.begin(),fields.end());}
 optishade::session::State().Put(values);
}

static VkResult VKAPI_CALL ObserveAcquireNextImageKHR(VkDevice device,VkSwapchainKHR swapchain,uint64_t timeout,
 VkSemaphore semaphore,VkFence fence,uint32_t* imageIndex){
 auto original=o_vkGetDeviceProcAddr?reinterpret_cast<PFN_vkAcquireNextImageKHR>(o_vkGetDeviceProcAddr(device,"vkAcquireNextImageKHR")):nullptr;
 const VkResult result=original?original(device,swapchain,timeout,semaphore,fence,imageIndex):VK_ERROR_INITIALIZATION_FAILED;
 optishade::vulkan_acquire_observation::Snapshot snapshot{};
 optishade::vulkan_acquire_observation::CaptureLegacy(device,swapchain,timeout,semaphore,fence,imageIndex,static_cast<int32_t>(result),snapshot);
 {std::lock_guard lock(_ownerMutex);snapshot.swapchainGeneration=_owners.swapchainGeneration(snapshot.device,snapshot.swapchain);}
 RecordAcquireObservation(snapshot);return result;
}

static VkResult VKAPI_CALL ObserveAcquireNextImage2KHR(VkDevice device,const VkAcquireNextImageInfoKHR* info,uint32_t* imageIndex){
 auto original=o_vkGetDeviceProcAddr?reinterpret_cast<PFN_vkAcquireNextImage2KHR>(o_vkGetDeviceProcAddr(device,"vkAcquireNextImage2KHR")):nullptr;
 const VkResult result=original?original(device,info,imageIndex):VK_ERROR_INITIALIZATION_FAILED;
 optishade::vulkan_acquire_observation::Snapshot snapshot{};
 optishade::vulkan_acquire_observation::CaptureDeviceGroup(device,info,imageIndex,static_cast<int32_t>(result),snapshot);
 {std::lock_guard lock(_ownerMutex);snapshot.swapchainGeneration=_owners.swapchainGeneration(snapshot.device,snapshot.swapchain);}
 RecordAcquireObservation(snapshot);return result;
}
static VkResult VKAPI_CALL ObserveQueueSubmit(VkQueue q,uint32_t count,const VkSubmitInfo* submits,VkFence fence){
 auto result=o_QueueSubmit?o_QueueSubmit(q,count,submits,fence):VK_ERROR_INITIALIZATION_FAILED;
 if(submits)for(uint32_t i=0;i<count;++i)for(uint32_t j=0;j<submits[i].commandBufferCount;++j)
  optishade::vknr::Submissions().Observe(reinterpret_cast<uint64_t>(q),reinterpret_cast<uint64_t>(submits[i].pCommandBuffers[j]),result==VK_SUCCESS);
 return result;
}
static VkResult VKAPI_CALL ObserveQueueSubmit2(VkQueue q,uint32_t count,const VkSubmitInfo2* submits,VkFence fence){
 auto result=o_QueueSubmit2?o_QueueSubmit2(q,count,submits,fence):VK_ERROR_INITIALIZATION_FAILED;
 if(submits)for(uint32_t i=0;i<count;++i)for(uint32_t j=0;j<submits[i].commandBufferInfoCount;++j)
  optishade::vknr::Submissions().Observe(reinterpret_cast<uint64_t>(q),reinterpret_cast<uint64_t>(submits[i].pCommandBufferInfos[j].commandBuffer),result==VK_SUCCESS);
 return result;
}
PFN_vkCreateDevice o_vkCreateDevice = nullptr;
PFN_vkCreateInstance o_vkCreateInstance = nullptr;
PFN_vkCreateWin32SurfaceKHR o_vkCreateWin32SurfaceKHR = nullptr;
PFN_vkQueuePresentKHR o_QueuePresentKHR = nullptr;
PFN_vkCreateSwapchainKHR o_CreateSwapchainKHR = nullptr;
static PFN_vkGetInstanceProcAddr o_vkGetInstanceProcAddr = nullptr;

// Those aren't hooked, just grabbed for use
static PFN_vkGetPhysicalDeviceFeatures2 o_vkGetPhysicalDeviceFeatures2 = nullptr;
PFN_vkCreateSemaphore VulkanHooks::o_vkCreateSemaphore = nullptr;
PFN_vkSignalSemaphore VulkanHooks::o_vkSignalSemaphore = nullptr;
PFN_vkAntiLagUpdateAMD VulkanHooks::o_vkAntiLagUpdateAMD = nullptr;


static PFN_vkDestroySurfaceKHR o_DestroySurface=nullptr;
static PFN_vkDestroySwapchainKHR o_DestroySwapchain=nullptr;
static PFN_vkDestroyDevice o_DestroyDevice=nullptr;
static PFN_vkDestroyInstance o_DestroyInstance=nullptr;
static void VKAPI_CALL hkvkDestroySwapchainKHR(VkDevice d,VkSwapchainKHR c,const VkAllocationCallbacks* a) {
    std::lock_guard lock(_ownerMutex);
    if(_owners.owner.chain==(uint64_t)c) {optishade::runtime_render::State().RetireVulkan(_owners.owner.chain);MenuOverlayVk::DestroyVulkanObjects(true);_preparedGeneration=0;ResetOverlayCandidate();}
    _owners.eraseChain((uint64_t)c);o_DestroySwapchain(d,c,a);
}
static void VKAPI_CALL hkvkDestroySurfaceKHR(VkInstance i,VkSurfaceKHR s,const VkAllocationCallbacks* a) {
    std::lock_guard lock(_ownerMutex);
    if(_owners.owner.surface==(uint64_t)s) {optishade::runtime_render::State().RetireVulkan(_owners.owner.chain);MenuOverlayVk::DestroyVulkanObjects(true);_preparedGeneration=0;ResetOverlayCandidate();}
    _owners.eraseSurface((uint64_t)s);o_DestroySurface(i,s,a);
}
static void VKAPI_CALL hkvkDestroyDevice(VkDevice d,const VkAllocationCallbacks* a) {
    std::lock_guard lock(_ownerMutex);
    if(_owners.owner.device==(uint64_t)d) {optishade::runtime_render::State().RetireVulkan(_owners.owner.chain);MenuOverlayVk::DestroyVulkanObjects(true);_preparedGeneration=0;ResetOverlayCandidate();}
    if(auto* bridge=optishade::vknr::XPlaneBridge()){
        std::lock_guard bridgeLock(bridge->mutex);
        if(bridge->transport&&bridge->transport->OwnsDevice(d)){
            if(bridge->transport->ReadyToRetire()&&bridge->transport->RetireCompletedRecordings()&&DlssNr::Shutdown()==DlssNr::RetirementResult::Retired){bridge->transport.reset();}
            else {
                // A device destroyed with pending work has violated the Vulkan
                // destruction contract. Quarantine references, never destroy
                // imported handles later through the now-dead VkDevice.
                bridge->reason="XP12 destroyed its device with unfinished interop work; restart required";
                bridge->poisoned=true;bridge->transport.release();
            }
            bridge->owner=bridge->generation=bridge->pendingPresentTicket=0;
        }
    }
    _owners.eraseDevice((uint64_t)d);_physicalDevices.erase(d);_deviceDispatch.erase(d);
    if(_device==d){_device=VK_NULL_HANDLE;_PD=VK_NULL_HANDLE;}
    DlssNr::ShutdownVkDevice(d);
    o_DestroyDevice(d,a);
}
static void VKAPI_CALL hkvkDestroyInstance(VkInstance i,const VkAllocationCallbacks* a) {
    std::lock_guard lock(_ownerMutex);
    if(_owners.lookup(_owners.owner.surface).instance==(uint64_t)i) {optishade::runtime_render::State().RetireVulkan(_owners.owner.chain);MenuOverlayVk::DestroyVulkanObjects(true);_preparedGeneration=0;ResetOverlayCandidate();}
    _owners.eraseInstance((uint64_t)i);if(_instance==i)_instance=VK_NULL_HANDLE;
    o_DestroyInstance(i,a);
}

// Forward declaration
static VkResult hkvkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR* pPresentInfo);
static VkResult hkvkCreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR* pCreateInfo,
                                       const VkAllocationCallbacks* pAllocator, VkSwapchainKHR* pSwapchain);

static void TrackDeviceDispatch(VkDevice device, VkPhysicalDevice physical, bool nrCapabilityKnown,
                                bool nrExtensionsReady)
{
    if (!device || !o_vkGetDeviceProcAddr)
        return;

    VulkanDeviceDispatch dispatch{};
    dispatch.physical = physical;
    dispatch.queuePresent = reinterpret_cast<PFN_vkQueuePresentKHR>(o_vkGetDeviceProcAddr(device, "vkQueuePresentKHR"));
    dispatch.createSwapchain = reinterpret_cast<PFN_vkCreateSwapchainKHR>(o_vkGetDeviceProcAddr(device, "vkCreateSwapchainKHR"));
    dispatch.nrCapabilityKnown = nrCapabilityKnown;
    dispatch.nrExtensionsReady = nrExtensionsReady;
    _deviceDispatch[device] = dispatch;

    // Device-proc pointers are recorded for ownership/capability diagnostics only.
    // Calls are forwarded through vulkan-1.dll's exported loader trampolines below,
    // which dispatch from the actual VkDevice/VkQueue and therefore remain valid
    // when X-Plane recreates a logical device.
    LOG_DEBUG("Tracked Vulkan device dispatch: device={0:X}, present={1:X}, createSwapchain={2:X}, NR={3}",
              (UINT64)device, (UINT64)dispatch.queuePresent, (UINT64)dispatch.createSwapchain,
              nrCapabilityKnown ? (nrExtensionsReady ? "ready" : "unavailable") : "not checked");
}

VALIDATE_HOOK(hkvkCreateWin32SurfaceKHR, PFN_vkCreateWin32SurfaceKHR)
static VkResult hkvkCreateWin32SurfaceKHR(VkInstance instance, const VkWin32SurfaceCreateInfoKHR* pCreateInfo,
                                          const VkAllocationCallbacks* pAllocator, VkSurfaceKHR* pSurface)
{
    LOG_FUNC();

    auto result = o_vkCreateWin32SurfaceKHR(instance, pCreateInfo, pAllocator, pSurface);

    auto procHwnd = Util::GetProcessWindow();
    LOG_DEBUG("procHwnd: {0:X}, swapchain hwnd: {1:X}", (UINT64) procHwnd, (UINT64) pCreateInfo->hwnd);

    if (result == VK_SUCCESS && !State::Instance().vulkanSkipHooks)
    {
        std::lock_guard lock(_ownerMutex);
        _owners.surface((uint64_t)instance,(uint64_t)*pSurface,(uint64_t)pCreateInfo->hwnd);
    }

    LOG_FUNC_RESULT(result);

    return result;
}

VALIDATE_HOOK(hkvkCreateInstance, PFN_vkCreateInstance)
static VkResult hkvkCreateInstance(const VkInstanceCreateInfo* pCreateInfo, const VkAllocationCallbacks* pAllocator,
                                   VkInstance* pInstance)
{
    LOG_FUNC();

    if (optishade::route::CurrentSimulator() == optishade::route::Simulator::XPlane12 || optishade::route::CurrentSimulator() == optishade::route::Simulator::Unknown)
        LOG_INFO("Game-local Vulkan instance layer: {}", optishade::xplane_layer::Configure(Util::ExePath()));

    VkInstanceCreateInfo localCreateInfo {};
    memcpy(&localCreateInfo, pCreateInfo, sizeof(VkInstanceCreateInfo));

    VulkanSpoofing::hkvkCreateInstance(&localCreateInfo, pAllocator, pInstance);

    VkResult result;
    {
        ScopedSkipSpoofingGlobal skipSpoofingGlobal {};
        result = o_vkCreateInstance(&localCreateInfo, pAllocator, pInstance);
    }

    if (result == VK_SUCCESS)
    {
        State::Instance().VulkanInstance = *pInstance;
        LOG_DEBUG("State::Instance().VulkanInstance captured: {0:X}", (UINT64) State::Instance().VulkanInstance);

#ifdef VULKAN_DEBUG_LAYER
        auto address = vkGetInstanceProcAddr(State::Instance().VulkanInstance, "vkCreateDebugUtilsMessengerEXT");
        auto vkCreateDebugUtilsMessengerEXT = (PFN_vkCreateDebugUtilsMessengerEXT) address;
        VkDebugUtilsMessengerEXT debugMessenger;
        vkCreateDebugUtilsMessengerEXT(State::Instance().VulkanInstance, &VulkanSpoofing::debugCreateInfo, nullptr,
                                       &debugMessenger);
#endif
    }

    // Disabled to prevent unnecessary object release
    // if (result == VK_SUCCESS && !State::Instance().vulkanSkipHooks)
    //{
    //     MenuOverlayVk::DestroyVulkanObjects(false);
    // }

    LOG_FUNC_RESULT(result);

    return result;
}

VALIDATE_HOOK(hkvkCreateDevice, PFN_vkCreateDevice)
static VkResult hkvkCreateDevice(VkPhysicalDevice physicalDevice, const VkDeviceCreateInfo* pCreateInfo,
                                 const VkAllocationCallbacks* pAllocator, VkDevice* pDevice)
{
    LOG_FUNC();

    VkDeviceCreateInfo localCreteInfo {};
    memcpy(&localCreteInfo, pCreateInfo, sizeof(VkDeviceCreateInfo));

    // Check support for AntiLag before spoof
    VkPhysicalDeviceFeatures2 features2 = {};
    features2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;

    VkPhysicalDeviceAntiLagFeaturesAMD antiLagFeatures = {};
    antiLagFeatures.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ANTI_LAG_FEATURES_AMD;

    features2.pNext = &antiLagFeatures;

    if (o_vkGetPhysicalDeviceFeatures2)
    {
        o_vkGetPhysicalDeviceFeatures2(physicalDevice, &features2);
        State::Instance().vkAntiLagSupported = antiLagFeatures.antiLag != 0;
    }

    VulkanSpoofing::hkvkCreateDevice(physicalDevice, &localCreteInfo, pAllocator, pDevice);

    // Neural Rendering on Vulkan without a D3D12 bridge, or the reason it cannot be.
    //
    // The model needs two NVIDIA vendor extensions to load its kernels, a game never asks for them,
    // and a device's extension list cannot be changed after creation. This is the only moment it can
    // be arranged. Reported either way: if the answer is no, the log says so here rather than leaving
    // a create failure three layers down to be explained.
    //
    // Only appended when the feature is switched on, and only what the physical device already
    // offers -- asking for an extension a driver does not have makes vkCreateDevice fail and the game
    // not start.
    DlssNr::VkExt::Merged nrExtensions;
    bool nrExtensionsReady = true;
    const bool nrStartupProbe = optishade::route::Current().module && (optishade::route::CurrentSimulator()==optishade::route::Simulator::XPlane12||optishade::route::CurrentSimulator()==optishade::route::Simulator::Unknown);
    const bool nrCapabilityKnown = Config::Instance()->DlssNrEnabled.value_or_default() || nrStartupProbe;

    if (nrCapabilityKnown)
    {
        const auto supported = DlssNr::VkExt::SupportedDeviceExtensions(
            o_vkGetInstanceProcAddr, State::Instance().VulkanInstance, physicalDevice);

        if (localCreteInfo.enabledExtensionCount != 0 && localCreteInfo.ppEnabledExtensionNames != nullptr)
            nrExtensions.names.assign(localCreteInfo.ppEnabledExtensionNames,
                                      localCreteInfo.ppEnabledExtensionNames + localCreteInfo.enabledExtensionCount);

        std::string present, added, missing;

        for (const char* want : DlssNr::VkExt::kDevice)
        {
            const bool already = DlssNr::VkExt::ListHas(localCreteInfo.ppEnabledExtensionNames,
                                                        localCreteInfo.enabledExtensionCount, want);

            if (already)
                present += std::string(present.empty() ? "" : ", ") + want;
            else if (!DlssNr::VkExt::Contains(supported, want))
                missing += std::string(missing.empty() ? "" : ", ") + want;
            else
            {
                nrExtensions.names.push_back(want);
                added += std::string(added.empty() ? "" : ", ") + want;
            }
        }

        LOG_INFO("DLSS-NR Vulkan: device offers {} extensions. game already enabled: [{}]. added here: "
                 "[{}]. NOT AVAILABLE: [{}]",
                 supported.size(), present.empty() ? "none" : present, added.empty() ? "none" : added,
                 missing.empty() ? "none" : missing);

        // XP12's private D3D12 transport needs only standard Win32 interop,
        // independent of the optional native NVIDIA Vulkan kernel extensions.
        if(nrStartupProbe)for(const char* want:{VK_KHR_EXTERNAL_MEMORY_WIN32_EXTENSION_NAME,VK_KHR_EXTERNAL_SEMAPHORE_WIN32_EXTENSION_NAME}){
            if(!DlssNr::VkExt::ListHas(localCreteInfo.ppEnabledExtensionNames,localCreteInfo.enabledExtensionCount,want)&&DlssNr::VkExt::Contains(supported,want)){
                nrExtensions.names.push_back(want);added+=std::string(added.empty()?"":", ")+want;
            }
        }
        nrExtensionsReady = missing.empty();
        if (!missing.empty())
            LOG_WARN("DLSS-NR Vulkan: the native path is not possible on this device -- the model's kernels "
                     "cannot be loaded without the extensions listed as NOT AVAILABLE");

        if (!added.empty())
        {
            localCreteInfo.ppEnabledExtensionNames = nrExtensions.names.data();
            localCreteInfo.enabledExtensionCount = (uint32_t) nrExtensions.names.size();
        }
    }

    auto result = o_vkCreateDevice(physicalDevice, &localCreteInfo, pAllocator, pDevice);

    if (nrCapabilityKnown)
        LOG_INFO("DLSS-NR Vulkan: vkCreateDevice returned {} with {} extensions requested", (int) result,
                 localCreteInfo.enabledExtensionCount);


    const bool needPresentationTracking =
        Config::Instance()->OverlayMenu.value_or_default() || nrCapabilityKnown;
    if (result == VK_SUCCESS && needPresentationTracking)
    {
        std::lock_guard lock(_ownerMutex);
        _physicalDevices[*pDevice]=physicalDevice;
        TrackDeviceDispatch(*pDevice, physicalDevice, nrCapabilityKnown, nrExtensionsReady);
        uint32_t familyCount=0;
        vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice,&familyCount,nullptr);
        std::vector<VkQueueFamilyProperties> families(familyCount);
        vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice,&familyCount,families.data());
        for(uint32_t i=0;i<pCreateInfo->queueCreateInfoCount;++i) {
            const auto& requested=pCreateInfo->pQueueCreateInfos[i];
            if(requested.flags || requested.queueFamilyIndex>=familyCount)continue;
            for(uint32_t n=0;n<requested.queueCount;++n) {
                VkQueue q{};vkGetDeviceQueue(*pDevice,requested.queueFamilyIndex,n,&q);
                _owners.queue((uint64_t)*pDevice,(uint64_t)q,requested.queueFamilyIndex,
                    (families[requested.queueFamilyIndex].queueFlags&VK_QUEUE_GRAPHICS_BIT)!=0);
            }
        }
        if (!State::Instance().vulkanSkipHooks)
        {
            // Device-level WSI calls are intercepted through the loader exports
            // and vkGetDeviceProcAddr. No per-device code pointer is detoured here.
        }

        ScopedSkipSpoofingGlobal skipSpoofingGlobal {};

        VkPhysicalDeviceIDProperties idProps {};
        idProps.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES;

        VkPhysicalDeviceProperties2 props2 {};
        props2.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
        props2.pNext = &idProps;

        vkGetPhysicalDeviceProperties2(physicalDevice, &props2);

        // These are the physical device's unspoofed properties for this exact
        // logical device, not the desktop/inventory adapter.
        auto& actual=_deviceDispatch[*pDevice].renderingDevice;
        actual.identity=(uint64_t)*pDevice;actual.vendor=props2.properties.vendorID;
        actual.id=props2.properties.deviceID;actual.name=props2.properties.deviceName;
        actual.software=props2.properties.deviceType==VK_PHYSICAL_DEVICE_TYPE_CPU;
        if(idProps.deviceLUIDValid==VK_TRUE)std::memcpy(&actual.luid,idProps.deviceLUID,sizeof(actual.luid));

        if (idProps.deviceLUIDValid == VK_TRUE)
        {
            auto primaryGpu = IdentifyGpu::getPrimaryGpu();
            auto luid = (PLUID) idProps.deviceLUID;
            if (!IsEqualLUID(*luid, primaryGpu.luid))
                LOG_WARN("VkDevice created with non-primary GPU");
        }
    }

    if (State::Instance().vkAntiLagSupported)
    {
        if (result == VK_SUCCESS && o_vkGetDeviceProcAddr)
        {
            VulkanHooks::o_vkAntiLagUpdateAMD =
                (PFN_vkAntiLagUpdateAMD) o_vkGetDeviceProcAddr(*pDevice, "vkAntiLagUpdateAMD");
        }
        else
        {
            State::Instance().vkAntiLagSupported = false;
            LOG_WARN("Vulkan AntiLag can't be enabled");
        }
    }

#ifdef USE_QUEUE_SUBMIT_2_KHR
    if (result == VK_SUCCESS)
        hkvkGetDeviceProcAddr(*pDevice, "vkQueueSubmit2KHR");
#endif

    LOG_FUNC_RESULT(result);

    return result;
}

static bool PrepareMenuOutsideQueueLocks(VkQueue queue,const VkPresentInfoKHR* info) noexcept
{
    try {
        std::unique_lock lock(_ownerMutex);
        if(Config::Instance()->OverlayMenu.value_or_default())MenuOverlayVk::PreparePresent(queue,info);
        return true;
    } catch (...) { return false; }
}

// Preparation and recreation already use the owner mutex. Submission must
// retain that same lifetime protection until the driver has accepted its work.
// The effects layer owns its queue lock here, so contention must skip, not wait.
static bool SubmitMenuWithOwner(VkQueue queue,VkPresentInfoKHR* info,PFN_vkQueueSubmit submit) noexcept
{
    try {
        return optishade::overlay::TrySubmitWithOwner(_ownerMutex,
            [&] { return MenuOverlayVk::QueuePresent(queue,info,submit); });
    } catch (...) { return false; }
}

VALIDATE_HOOK(hkvkQueuePresentKHR, PFN_vkQueuePresentKHR)
static VkResult hkvkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR* pPresentInfo)
{
    LOG_FUNC();
    std::unique_lock lock(_ownerMutex);
    if(!pPresentInfo || !_owners.present((uint64_t)queue,pPresentInfo->swapchainCount,
        reinterpret_cast<const uint64_t*>(pPresentInfo->pSwapchains),pPresentInfo->pImageIndices,UINT32_MAX))
        return optishade::InvokeWithoutOwnerLock(lock,[&]{return o_QueuePresentKHR(queue,pPresentInfo);});
    const auto ownerIndex=optishade::vkowner::PresentIndex((VkSwapchainKHR)_owners.owner.chain,
        pPresentInfo->swapchainCount,pPresentInfo->pSwapchains,pPresentInfo->pImageIndices,UINT32_MAX);
    const auto ownerImage=pPresentInfo->pImageIndices[ownerIndex];
    PublishVulkanAutoContext(queue);
    // Log once per owner/batch layout, not per frame. Older reports lacked this
    // distinction between a single window and a shared multi-window present.
    static uint64_t reportedGeneration=0;
    static uint32_t reportedCount=0,reportedIndex=UINT32_MAX,layoutReports=0;
    if(reportedGeneration!=_owners.owner.generation)layoutReports=0;
    if(layoutReports<8 && (reportedGeneration!=_owners.owner.generation || reportedCount!=pPresentInfo->swapchainCount || reportedIndex!=ownerIndex)){
        ++layoutReports;
        reportedGeneration=_owners.owner.generation;reportedCount=pPresentInfo->swapchainCount;reportedIndex=ownerIndex;
        LOG_INFO("Vulkan presentation owner: generation={} batchCount={} ownerIndex={}",reportedGeneration,reportedCount,reportedIndex);
    }
    const bool overlayEnabled = Config::Instance()->OverlayMenu.value_or_default();
    if(overlayEnabled && _preparedGeneration!=_owners.owner.generation) {
        const auto q=_owners.findQueue((uint64_t)queue);
        VkBool32 present=VK_FALSE;
        if(vkGetPhysicalDeviceSurfaceSupportKHR(_PD,q.family,(VkSurfaceKHR)_owners.owner.surface,&present)!=VK_SUCCESS || !present)
            return optishade::InvokeWithoutOwnerLock(lock,[&]{return o_QueuePresentKHR(queue,pPresentInfo);});
        if (OverlayOwnerReady())
        {
            auto chain=(VkSwapchainKHR)_owners.owner.chain;
            MenuOverlayVk::CreateSwapchain(_device,_PD,_instance,(HWND)_owners.owner.window,
                &_ownerCreateInfo,nullptr,&chain,queue,q.family);
            _preparedGeneration=_owners.owner.generation;
            if (_wcsicmp(Util::ExePath().filename().c_str(), L"X-Plane.exe") == 0)
                LOG_INFO("X-Plane 12: stable Vulkan presentation owner confirmed; menu/input attachment enabled");
        }
    }

    // get upscaler time
    UpscalerTimeVk::ReadUpscalingTime(_device);

    // A hybrid system's preferred desktop adapter may differ from the adapter
    // behind this present queue. Classify the live VkDevice instead.
    if (const auto dispatch = _deviceDispatch.find(_device); dispatch != _deviceDispatch.end())
    {
        const auto renderingGpu = IdentifyGpu::getGpuForVulkanPhysicalDevice(dispatch->second.physical);
        if (renderingGpu.vendorId != VendorId::Invalid && !renderingGpu.usesDxvk)
            State::Instance().swapchainApi = Vulkan;
    }

    // Tick feature to let it know if it's frozen
    if (auto currentFeature = State::Instance().currentFeature; currentFeature != nullptr)
        currentFeature->TickFrozenCheck();

    VkPresentInfoKHR localPresentInfo {};
    memcpy(&localPresentInfo, pPresentInfo, sizeof(VkPresentInfoKHR));

    // A matching native effects layer can draw the menu after its effects pass.
    // Old DLLs and other presentation paths retain their existing behavior.
    // Compatibility/diagnostic routes own the same Vulkan menu, but must not
    // register it with a native effects layer excluded by the selected route.
    auto effectsModule = optishade::xplane_layer::UsesNativeEffects(optishade::xplane_layer::CurrentRoute())?
        GetModuleHandleW(L"ReShade64.dll"):nullptr;
    auto setCallbacks=effectsModule?reinterpret_cast<osvk::SetCallbacks>(GetProcAddress(effectsModule,"OptiShadeVulkanSetCallbacks")):nullptr;
    const bool managedOverlay=overlayEnabled&&setCallbacks&&MenuOverlayVk::CanDrawAfterEffects(queue,pPresentInfo)&&
        setCallbacks(osvk::CallbackVersion,queue,&PrepareMenuOutsideQueueLocks,&SubmitMenuWithOwner);
    if(managedOverlay){static bool reported=false;if(!reported){reported=true;LOG_INFO("Vulkan menu callback bridge v2 active: prepare after effects flush outside queue locks, then submit; either hook order supported");}}
    if(overlayEnabled&&!managedOverlay)MenuOverlayVk::PreparePresent(queue,pPresentInfo);
    auto setOverlay = effectsModule ? reinterpret_cast<osvk::SetOverlay>(
        GetProcAddress(effectsModule, "OptiShadeVulkanSetOverlay")) : nullptr;
    const bool deferredOverlay = overlayEnabled && !managedOverlay && setOverlay &&
        MenuOverlayVk::CanDrawAfterEffects(queue, pPresentInfo) &&
        setOverlay(osvk::Version, queue, &SubmitMenuWithOwner);
    if(optishade::xplane_layer::ProcessRoute().xplane){
        static uint64_t routeGeneration=0;static int previousMode=-1;static uint32_t routeReports=0;
        const int mode=managedOverlay?2:deferredOverlay?1:0;
        if(routeGeneration!=_owners.owner.generation){routeGeneration=_owners.owner.generation;routeReports=0;previousMode=-1;}
        if(routeReports<8&&previousMode!=mode){++routeReports;previousMode=mode;
            LOG_INFO("XP12 menu route={} submission={} owner={} generation={} HWND={:X} queue={:X} swapchain={:X} batch={} image={}",
                optishade::xplane_layer::GraphicsRouteName(optishade::xplane_layer::CurrentRoute()),
                managedOverlay?"effects-callback-v2":deferredOverlay?"effects-callback-v1":"standalone-vulkan",
                MenuOverlayVk::DrawOwner(),_owners.owner.generation,_owners.owner.window,(uint64_t)queue,_owners.owner.chain,pPresentInfo->swapchainCount,ownerImage);
        }
    }
    if (overlayEnabled && !managedOverlay && !deferredOverlay && !MenuOverlayVk::QueuePresent(queue, &localPresentInfo))
    {
        LOG_ERROR("QueuePresent: false!");
        // Failed overlay submission has not consumed the incoming waits.
        // Preserve the game's result instead of inventing OUT_OF_DATE.
    }

    ReflexHooks::update(false, true);

    // External presentation can synchronously wait for callbacks on another
    // thread. Those callbacks inspect this owner. Never hold the owner lock
    // across the provider; retire/observe only the generation we presented.
    const auto presentedChain=_owners.owner.chain;
    const auto presentedGeneration=_owners.owner.generation;
    const auto menuDrawOwner=overlayEnabled?MenuOverlayVk::DrawOwner():0;
    auto result = optishade::InvokeWithoutOwnerLock(lock,[&]{
        ScopedVulkanCreatingSC scopedVulkanCreatingSC {};
        return o_QueuePresentKHR(queue, &localPresentInfo);
    });
    const bool sameOwner=_owners.owner.chain==presentedChain && _owners.owner.generation==presentedGeneration;
    // WSI per-chain results distinguish an auxiliary-window resize from a
    // failed main-window present. Fatal/global failures must never be hidden.
    const bool hasPerChainResult=result==VK_SUCCESS || result==VK_SUBOPTIMAL_KHR ||
        result==VK_ERROR_OUT_OF_DATE_KHR || result==VK_ERROR_SURFACE_LOST_KHR ||
        result==VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT;
    const auto ownerResult=optishade::vkowner::PresentResult(result,hasPerChainResult,
        pPresentInfo->pResults,ownerIndex,pPresentInfo->swapchainCount);
    if(sameOwner&&ownerResult!=VK_SUCCESS&&ownerResult!=VK_SUBOPTIMAL_KHR)
        optishade::runtime_render::State().RetireVulkan(presentedChain);
    if(sameOwner)ObserveOverlayOwnerPresent(ownerResult);
    if(sameOwner&&menuDrawOwner)
        MenuOverlayVk::PresentProgress(menuDrawOwner,ownerResult,ownerImage);
    if(auto* bridge=optishade::vknr::XPlaneBridge()){
        std::lock_guard bridgeLock(bridge->mutex);
        if(sameOwner&&bridge->pendingPresentTicket&&bridge->owner==presentedChain&&bridge->generation==presentedGeneration){
            optishade::nr_observation::State().PresentSubmitted(bridge->pendingPresentTicket,ownerResult,ownerResult==VK_SUCCESS||ownerResult==VK_SUBOPTIMAL_KHR);
            if(bridge->pendingPresentTicket%300==0||ownerResult<0)LOG_INFO("XP12 output ticket={}: owner vkQueuePresentKHR result={}; scanout is not inferred",bridge->pendingPresentTicket,int(ownerResult));
            bridge->pendingPresentTicket=0;
        }
    }
    lock.unlock();
    if (deferredOverlay)
        setOverlay(osvk::Version, queue, nullptr);

    // Unsure about Vulkan Reflex fps limit and if that could be causing an issue here
    if (!State::Instance().reflexLimitsFps)
        FrameLimit::sleep(false);

    LOG_FUNC_RESULT(result);
    return result;
}

VALIDATE_HOOK(hkvkCreateSwapchainKHR, PFN_vkCreateSwapchainKHR)
static VkResult hkvkCreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR* pCreateInfo,
                                       const VkAllocationCallbacks* pAllocator, VkSwapchainKHR* pSwapchain)
{
    LOG_FUNC();

    ScopedVulkanCreatingSC scopedVulkanCreatingSC {};
    VkResult result = VK_SUCCESS;
    {
        ScopedSkipSpoofingGlobal skipSpoofingGlobal {};
        result = o_CreateSwapchainKHR(device, pCreateInfo, pAllocator, pSwapchain);
    }

    if (result == VK_SUCCESS && device != VK_NULL_HANDLE && pCreateInfo != nullptr && *pSwapchain != VK_NULL_HANDLE &&
        !State::Instance().vulkanSkipHooks)
    {
        std::lock_guard lock(_ownerMutex);
        const auto surface=_owners.lookup((uint64_t)pCreateInfo->surface);
        const bool selected=_owners.swapchain((uint64_t)device,(uint64_t)pCreateInfo->surface,
            (uint64_t)*pSwapchain,GameplayWindow((HWND)surface.window),IsWindow((HWND)_owners.owner.window)!=FALSE);
        if(!selected)return result;
        MenuOverlayVk::DestroyVulkanObjects(false);
        _instance=(VkInstance)surface.instance;
        _PD=_physicalDevices[device];
        _ownerCreateInfo=*pCreateInfo;
        _ownerCreateInfo.pNext=nullptr;
        _ownerCreateInfo.pQueueFamilyIndices=nullptr;
        _preparedGeneration=0;
        ResetOverlayCandidate();
        State::Instance().VulkanInstance=_instance;
        State::Instance().screenWidth = static_cast<float>(pCreateInfo->imageExtent.width);
        State::Instance().screenHeight = static_cast<float>(pCreateInfo->imageExtent.height);

        // The same question the DXGI side asks: what does one unit of this buffer mean?
        //
        // EXTENDED_SRGB_LINEAR is scRGB, 1.0 = 80 nits. HDR10_ST2084 is PQ, 1.0 = 10000 nits. Both
        // are absolute, so in either the white point is arithmetic rather than a reading -- which
        // matters most for the games that supply no exposure texture, since nothing else answers for
        // them. Logged, not yet used.
        {
            static VkColorSpaceKHR lastSpace = (VkColorSpaceKHR) -1;

            if (pCreateInfo->imageColorSpace != lastSpace)
            {
                lastSpace = pCreateInfo->imageColorSpace;

                const char* name = "other";
                const char* meaning = "relative -- no scale to be had";

                switch (pCreateInfo->imageColorSpace)
                {
                case VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT:
                    name = "scRGB (extended sRGB, linear)";
                    meaning = "absolute: 1.0 = 80 nits, so 203-nit paper white = 2.5375";
                    break;
                case VK_COLOR_SPACE_HDR10_ST2084_EXT:
                    name = "PQ / ST.2084 (HDR10)";
                    meaning = "absolute: 1.0 = 10000 nits, so 203-nit paper white = 0.0203";
                    break;
                case VK_COLOR_SPACE_SRGB_NONLINEAR_KHR:
                    name = "sRGB (SDR)";
                    break;
                case VK_COLOR_SPACE_HDR10_HLG_EXT:
                    name = "HLG";
                    break;
                default:
                    break;
                }

                LOG_INFO("DLSS-NR: swapchain colour space {} -- {} ({}), format {}",
                         (int) pCreateInfo->imageColorSpace, name, meaning, (int) pCreateInfo->imageFormat);
            }
        }

        LOG_DEBUG("if (result == VK_SUCCESS && device != VK_NULL_HANDLE && pCreateInfo != nullptr && pSwapchain != "
                  "VK_NULL_HANDLE)");

        _device = device;
        LOG_DEBUG("_device captured: {0:X}", (UINT64) _device);

        // Initialize on the first owned presentation, using its actual queue.
    }

    LOG_FUNC_RESULT(result);
    return result;
}

VALIDATE_HOOK(hkvkGetInstanceProcAddr, PFN_vkGetInstanceProcAddr)
PFN_vkVoidFunction hkvkGetInstanceProcAddr(VkInstance instance, const char* pName)
{
    auto orgFunc = o_vkGetInstanceProcAddr(instance, pName);
    if(orgFunc&&pName&&optishade::route::CurrentSimulator()==optishade::route::Simulator::XPlane12){
        if(!strcmp(pName,"vkAcquireNextImageKHR"))return reinterpret_cast<PFN_vkVoidFunction>(ObserveAcquireNextImageKHR);
        if(!strcmp(pName,"vkAcquireNextImage2KHR"))return reinterpret_cast<PFN_vkVoidFunction>(ObserveAcquireNextImage2KHR);
    }
    // Preserve the Vulkan layer/device dispatch returned by this lookup on XP12.
    // The loader export detour observes loader calls; the effects layer reports
    // its own submissions explicitly, so direct pointers need no substitution.
    if(orgFunc && pName && optishade::route::CurrentSimulator()==optishade::route::Simulator::XPlane12 &&
       (!strcmp(pName,"vkQueueSubmit") || !strcmp(pName,"vkQueueSubmit2") || !strcmp(pName,"vkQueueSubmit2KHR")))
        return orgFunc;
    if(orgFunc&&pName){if(!strcmp(pName,"vkQueueSubmit")&&o_QueueSubmit)return reinterpret_cast<PFN_vkVoidFunction>(ObserveQueueSubmit);
        if((!strcmp(pName,"vkQueueSubmit2")||!strcmp(pName,"vkQueueSubmit2KHR"))&&o_QueueSubmit2)return reinterpret_cast<PFN_vkVoidFunction>(ObserveQueueSubmit2);}


    if (orgFunc == VK_NULL_HANDLE)
        return VK_NULL_HANDLE;

    auto procName = std::string(pName);
    if(procName=="vkDestroySurfaceKHR" && o_DestroySurface)return (PFN_vkVoidFunction)hkvkDestroySurfaceKHR;
    if(procName=="vkDestroySwapchainKHR" && o_DestroySwapchain)return (PFN_vkVoidFunction)hkvkDestroySwapchainKHR;
    if(procName=="vkDestroyDevice" && o_DestroyDevice)return (PFN_vkVoidFunction)hkvkDestroyDevice;
    if(procName=="vkDestroyInstance" && o_DestroyInstance)return (PFN_vkVoidFunction)hkvkDestroyInstance;
    if(procName=="vkCreateWin32SurfaceKHR" && o_vkCreateWin32SurfaceKHR)return (PFN_vkVoidFunction)hkvkCreateWin32SurfaceKHR;
    if(procName=="vkCreateSwapchainKHR" && o_CreateSwapchainKHR)return (PFN_vkVoidFunction)hkvkCreateSwapchainKHR;
    if(procName=="vkQueuePresentKHR" && o_QueuePresentKHR)return (PFN_vkVoidFunction)hkvkQueuePresentKHR;


    if (procName == std::string("vkCreateInstance"))
    {
        if (o_vkCreateInstance == nullptr)
            o_vkCreateInstance = (PFN_vkCreateInstance) orgFunc;

        LOG_DEBUG("vkCreateInstance");
        return (PFN_vkVoidFunction) hkvkCreateInstance;
    }
    else if (procName == std::string("vkCreateDevice"))
    {
        if (o_vkCreateDevice == nullptr)
            o_vkCreateDevice = (PFN_vkCreateDevice) orgFunc;

        LOG_DEBUG("vkCreateDevice");
        return (PFN_vkVoidFunction) hkvkCreateDevice;
    }

    auto result = VulkanSpoofing::hkvkGetInstanceProcAddr(orgFunc, pName);
    if (result != VK_NULL_HANDLE)
        return result;

    return orgFunc;
}

VALIDATE_HOOK(hkvkGetDeviceProcAddr, PFN_vkGetDeviceProcAddr)
PFN_vkVoidFunction hkvkGetDeviceProcAddr(VkDevice device, const char* pName)
{
    auto orgFunc = o_vkGetDeviceProcAddr(device, pName);
    if(orgFunc&&pName&&optishade::route::CurrentSimulator()==optishade::route::Simulator::XPlane12){
        if(!strcmp(pName,"vkAcquireNextImageKHR"))return reinterpret_cast<PFN_vkVoidFunction>(ObserveAcquireNextImageKHR);
        if(!strcmp(pName,"vkAcquireNextImage2KHR"))return reinterpret_cast<PFN_vkVoidFunction>(ObserveAcquireNextImage2KHR);
    }
    // Preserve the Vulkan layer/device dispatch returned by this lookup on XP12.
    // The loader export detour observes loader calls; the effects layer reports
    // its own submissions explicitly, so direct pointers need no substitution.
    if(orgFunc && pName && optishade::route::CurrentSimulator()==optishade::route::Simulator::XPlane12 &&
       (!strcmp(pName,"vkQueueSubmit") || !strcmp(pName,"vkQueueSubmit2") || !strcmp(pName,"vkQueueSubmit2KHR")))
        return orgFunc;
    if(orgFunc&&pName){if(!strcmp(pName,"vkQueueSubmit")&&o_QueueSubmit)return reinterpret_cast<PFN_vkVoidFunction>(ObserveQueueSubmit);
        if((!strcmp(pName,"vkQueueSubmit2")||!strcmp(pName,"vkQueueSubmit2KHR"))&&o_QueueSubmit2)return reinterpret_cast<PFN_vkVoidFunction>(ObserveQueueSubmit2);}


    if (orgFunc == VK_NULL_HANDLE)
        return VK_NULL_HANDLE;

    auto procName = std::string(pName);
    if(procName=="vkDestroySurfaceKHR" && o_DestroySurface)return (PFN_vkVoidFunction)hkvkDestroySurfaceKHR;
    if(procName=="vkDestroySwapchainKHR" && o_DestroySwapchain)return (PFN_vkVoidFunction)hkvkDestroySwapchainKHR;
    if(procName=="vkDestroyDevice" && o_DestroyDevice)return (PFN_vkVoidFunction)hkvkDestroyDevice;
    if(procName=="vkDestroyInstance" && o_DestroyInstance)return (PFN_vkVoidFunction)hkvkDestroyInstance;
    if(procName=="vkCreateWin32SurfaceKHR" && o_vkCreateWin32SurfaceKHR)return (PFN_vkVoidFunction)hkvkCreateWin32SurfaceKHR;
    if(procName=="vkCreateSwapchainKHR" && o_CreateSwapchainKHR)return (PFN_vkVoidFunction)hkvkCreateSwapchainKHR;
    if(procName=="vkQueuePresentKHR" && o_QueuePresentKHR)return (PFN_vkVoidFunction)hkvkQueuePresentKHR;


    if (procName == std::string("vkCreateInstance"))
    {
        if (o_vkCreateInstance == nullptr)
            o_vkCreateInstance = (PFN_vkCreateInstance) orgFunc;

        LOG_DEBUG("vkCreateInstance");
        return (PFN_vkVoidFunction) hkvkCreateInstance;
    }
    else if (procName == std::string("vkCreateDevice"))
    {
        if (o_vkCreateDevice == nullptr)
            o_vkCreateDevice = (PFN_vkCreateDevice) orgFunc;

        LOG_DEBUG("vkCreateDevice");
        return (PFN_vkVoidFunction) hkvkCreateDevice;
    }

    auto result = VulkanSpoofing::hkvkGetDeviceProcAddr(orgFunc, pName);
    if (result != VK_NULL_HANDLE)
        return result;

    return orgFunc;
}

void VulkanHooks::Hook(HMODULE vulkan1)
{
    if (vulkanModule == nullptr)
        vulkanModule = vulkan1;

    VulkanSpoofing::HookForVulkanSpoofing(vulkan1);
    VulkanSpoofing::HookForVulkanExtensionSpoofing(vulkan1);
    VulkanSpoofing::HookForVulkanVRAMSpoofing(vulkan1);

    if (o_vkCreateDevice != nullptr)
        return;

    FARPROC address = nullptr;

    o_vkCreateDevice = (PFN_vkCreateDevice) KernelBaseProxy::GetProcAddress_()(vulkan1, "vkCreateDevice");
    o_vkCreateInstance = (PFN_vkCreateInstance) KernelBaseProxy::GetProcAddress_()(vulkan1, "vkCreateInstance");

    address = KernelBaseProxy::GetProcAddress_()(vulkan1, "vkGetInstanceProcAddr");
    o_vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr) address;

    address = KernelBaseProxy::GetProcAddress_()(vulkan1, "vkGetDeviceProcAddr");
    o_vkGetDeviceProcAddr = (PFN_vkGetDeviceProcAddr) address;

    // Use the loader's exported WSI trampolines as the universal forwarding path.
    // Unlike a pointer returned by vkGetDeviceProcAddr for one logical device,
    // these dispatch from the VkDevice/VkQueue passed by the caller.
    o_QueuePresentKHR = (PFN_vkQueuePresentKHR) KernelBaseProxy::GetProcAddress_()(vulkan1, "vkQueuePresentKHR");
    o_CreateSwapchainKHR = (PFN_vkCreateSwapchainKHR) KernelBaseProxy::GetProcAddress_()(vulkan1, "vkCreateSwapchainKHR");

    address = KernelBaseProxy::GetProcAddress_()(vulkan1, "vkCreateWin32SurfaceKHR");
    o_vkCreateWin32SurfaceKHR = (PFN_vkCreateWin32SurfaceKHR) address;

    // address = KernelBaseProxy::GetProcAddress_()(vulkan1, "vkCmdPipelineBarrier");
    // o_vkCmdPipelineBarrier = (PFN_vkCmdPipelineBarrier) address;

    address = KernelBaseProxy::GetProcAddress_()(vulkan1, "vkGetPhysicalDeviceFeatures2");
    o_vkGetPhysicalDeviceFeatures2 = (PFN_vkGetPhysicalDeviceFeatures2) address;

    address = KernelBaseProxy::GetProcAddress_()(vulkan1, "vkCreateSemaphore");
    o_vkCreateSemaphore = (PFN_vkCreateSemaphore) address;

    address = KernelBaseProxy::GetProcAddress_()(vulkan1, "vkSignalSemaphore");
    o_vkSignalSemaphore = (PFN_vkSignalSemaphore) address;

    o_DestroySurface=(PFN_vkDestroySurfaceKHR)KernelBaseProxy::GetProcAddress_()(vulkan1,"vkDestroySurfaceKHR");
    o_DestroySwapchain=(PFN_vkDestroySwapchainKHR)KernelBaseProxy::GetProcAddress_()(vulkan1,"vkDestroySwapchainKHR");
    o_DestroyDevice=(PFN_vkDestroyDevice)KernelBaseProxy::GetProcAddress_()(vulkan1,"vkDestroyDevice");
    o_DestroyInstance=(PFN_vkDestroyInstance)KernelBaseProxy::GetProcAddress_()(vulkan1,"vkDestroyInstance");
    o_QueueSubmit=(PFN_vkQueueSubmit)KernelBaseProxy::GetProcAddress_()(vulkan1,"vkQueueSubmit");
    o_QueueSubmit2=(PFN_vkQueueSubmit2)KernelBaseProxy::GetProcAddress_()(vulkan1,"vkQueueSubmit2");
    const auto detourResult = OptiShade::Detours::WithProcessDetourTransaction([&]() -> LONG {
        LONG attachResult = NO_ERROR;
        if(o_QueueSubmit)attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&)o_QueueSubmit,ObserveQueueSubmit);
        if(o_QueueSubmit2)attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&)o_QueueSubmit2,ObserveQueueSubmit2);

        if (o_vkCreateDevice != nullptr)
            attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&) o_vkCreateDevice, hkvkCreateDevice);

        if (o_QueuePresentKHR != nullptr)
            attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&) o_QueuePresentKHR, hkvkQueuePresentKHR);

        if (o_CreateSwapchainKHR != nullptr)
            attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&) o_CreateSwapchainKHR, hkvkCreateSwapchainKHR);

        if (o_vkGetInstanceProcAddr != nullptr)
            attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&) o_vkGetInstanceProcAddr, hkvkGetInstanceProcAddr);

        if (o_vkGetDeviceProcAddr != nullptr)
            attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&) o_vkGetDeviceProcAddr, hkvkGetDeviceProcAddr);

        if (o_vkCreateInstance != nullptr)
            attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&) o_vkCreateInstance, hkvkCreateInstance);

        if (o_vkCreateWin32SurfaceKHR != nullptr)
            attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&) o_vkCreateWin32SurfaceKHR, hkvkCreateWin32SurfaceKHR);

        if(o_DestroySurface)attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&)o_DestroySurface,hkvkDestroySurfaceKHR);
        if(o_DestroySwapchain)attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&)o_DestroySwapchain,hkvkDestroySwapchainKHR);
        if(o_DestroyDevice)attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&)o_DestroyDevice,hkvkDestroyDevice);
        if(o_DestroyInstance)attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&)o_DestroyInstance,hkvkDestroyInstance);
        // if (o_vkCmdPipelineBarrier != nullptr)
        //     attachResult = OptiShade::Detours::QueueProcessDetour(attachResult, &(PVOID&) o_vkCmdPipelineBarrier, hkvkCmdPipelineBarrier);

            return attachResult;
    });
    if (detourResult != NO_ERROR)
    {
        LOG_ERROR("Failed to hook Vulkan, error code: {:X}", detourResult);
        o_vkCreateDevice = nullptr;
        o_vkCreateInstance = nullptr;
        o_vkGetInstanceProcAddr = nullptr;
        o_vkGetDeviceProcAddr = nullptr;
        o_vkCreateWin32SurfaceKHR = nullptr;
        o_QueuePresentKHR = nullptr;
        o_CreateSwapchainKHR = nullptr;
        // o_vkCmdPipelineBarrier = nullptr;
    }
}
