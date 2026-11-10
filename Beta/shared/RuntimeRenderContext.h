// OptiShade additions, GPL-3.0-or-later. Scalar metadata only; owns no GPU object.
#pragma once
#include "AutoCompatibility.h"
#include "NativeMfgControl.h"
#include "VulkanFgAdmission.h"
#include <mutex>

namespace optishade::runtime_render {
struct Device {
    uint64_t identity=0,luid=0;
    uint32_t vendor=0,id=0,architecture=0;
    bool software=false;
    std::string name;
    bool Known()const{return identity&&luid&&vendor&&!software;}
};
struct NativeSample {
    uint64_t device=0,luid=0,provider=0,generation=0,sampledAt=0;
    uint32_t view=0,intervalFrames=0;
    bool passive=false;
};
struct UpscalingSample {
    uint64_t device=0,luid=0,feature=0,sampledAt=0;
    bool succeeded=false,missingInput=false;
    std::string backend;
};
struct NrOutputSample {
    uint64_t ticket=0,revision=0,sampledAt=0;
    bool compositionReachedOutput=false,failed=false;
};
struct Snapshot {
    automatic::Context context;
    Device device;
    uint64_t output=0,sampledAt=0;
    NativeSample native;
    UpscalingSample upscaling;
    std::array<uint64_t,16> backBuffers{};
    NrOutputSample nr;
    vulkan_fg::Owner vulkanFg;
    // Last reason the game-facing DLSS-G state query was skipped. This is
    // diagnostic text only; it never grants provider control.
    std::string nativeUnavailableReason;
    unsigned computeMajor=0,computeMinor=0,computeFamily=0;
    bool computeKnown=false;
    bool streamlineMatches=false;
    bool Fresh(uint64_t now)const{return context.Valid()&&sampledAt&&now>=sampledAt&&now-sampledAt<=3000;}
};
// Shared metadata admission for Auto and the native menu. The accepted game
// provider/view must belong to the current primary device/output; a capability
// sample from a helper or a retired output is not a writable control context.
inline bool NativeCapabilityBound(const Snapshot& live,const native_mfg::Snapshot& state,uint64_t now){
    const auto& sample=live.native;
    return live.Fresh(now)&&sample.device==live.device.identity&&sample.luid==live.device.luid&&
        sample.provider&&sample.provider==state.provider&&sample.generation==state.generation&&
        sample.view==state.view&&sample.view==live.context.view&&sample.sampledAt&&
        now>=sample.sampledAt&&now-sample.sampledAt<=3000&&native_mfg::Control::Fresh(state);
}
// Optional SM75/86 loading is a D3D12 preparation step. Keep admission
// at the loader as well as its worker so stale startup callers cannot bypass it.
inline bool CompatibilityMfgSetupContextReady(const Snapshot& live,uint64_t now){
    // GPU-family admission stays in the existing loader, with its existing
    // unsupported-hardware reason. This is only the shared runtime/API gate.
    return live.Fresh(now)&&live.context.api=="d3d12"&&!live.vulkanFg.xplaneNative&&live.computeKnown;
}
enum class Apply {Done,Busy,Changed};

// This is the single primary output's published metadata, not an inventory of
// all NR lanes or another owner of resources, fences, or output generations.
// Generation is supplied by the existing PresentationOwner; zero stays zero.
class Context {
    std::mutex mutex_;
    Snapshot value_;
    Device streamline_;
    uint64_t serial_=0,deviceSerial_=0,outputSerial_=0;
public:
    void Publish(const Device& device,uint64_t output,uint64_t generation,const char* api,
                 uint32_t view,uint64_t now,const std::array<uint64_t,16>& backBuffers={},
                 const vulkan_fg::Owner* vulkan=nullptr){
        std::lock_guard lock(mutex_);
        // A native XP12 Vulkan owner cannot be replaced by an interop/helper
        // DXGI swapchain. Its route choice lasts for this process, including
        // the scalar retirement interval between Vulkan swapchains.
        if(value_.vulkanFg.xplaneNative&&!vulkan)return;
        if(vulkan&&(!api||std::string_view(api)!="vulkan"||!vulkan->xplaneNative||vulkan->binding.device!=device.identity||
           vulkan->binding.luid!=device.luid||vulkan->binding.output!=output||
           vulkan->binding.generation!=generation||vulkan->binding.view!=view))return;
        if(!device.Known()||!output||!generation){value_={};return;}
        const bool changedDevice=value_.device.identity!=device.identity||value_.device.luid!=device.luid;
        const bool changedOutput=changedDevice||value_.output!=output||
            (vulkan&&!(value_.vulkanFg.binding==vulkan->binding));
        if(changedDevice){deviceSerial_=++serial_;value_.computeKnown=false;value_.computeMajor=value_.computeMinor=value_.computeFamily=0;}
        if(changedOutput)outputSerial_=++serial_;
        if(changedDevice||changedOutput||value_.context.outputGeneration!=generation){value_.native={};value_.nativeUnavailableReason.clear();value_.upscaling={};value_.nr={};}
        if(value_.backBuffers!=backBuffers)value_.nr={};
        value_.backBuffers=backBuffers;
        value_.vulkanFg=vulkan?*vulkan:vulkan_fg::Owner{};
        value_.device=device;value_.output=output;value_.sampledAt=now;
        value_.streamlineMatches=streamline_.Known()&&streamline_.identity==device.identity&&streamline_.luid==device.luid;
        auto& context=value_.context;context.luid=device.luid;
        context.deviceGeneration=context.outputGeneration=generation;
        context.deviceIdentity="device-"+std::to_string(deviceSerial_);
        context.outputId="output-"+std::to_string(outputSerial_);
        context.deviceGenerationSource="primary_output_binding";
        context.view=view;context.api=api;
        context.architecture=sizeof(void*)==8?"x64":"x86";
    }
    void Invalidate(uint64_t output){
        std::lock_guard lock(mutex_);
        if(value_.vulkanFg.xplaneNative)return; // Its Vulkan owner retires it explicitly.
        if(!output||value_.output==output){value_={};}
    }
    // Called by the same Vulkan destruction/present owner before retiring its
    // handle. Only a scalar tombstone survives; no GPU object or callback does.
    void RetireVulkan(uint64_t output,bool cancelled=false){
        std::lock_guard lock(mutex_);
        if(!value_.vulkanFg.xplaneNative||value_.output!=output)return;
        value_.vulkanFg.retiring=!cancelled;value_.vulkanFg.cancelled=cancelled;
        value_.context={};value_.sampledAt=0;value_.native={};value_.upscaling={};value_.nr={};
    }
    Snapshot Read(){std::lock_guard lock(mutex_);return value_;}
    // Accepted Streamline device metadata is independent of arbitrary device
    // creation. An auxiliary adapter never becomes the native FG owner here.
    void StreamlineDevice(const Device& device){
        std::lock_guard lock(mutex_);
        if(streamline_.identity!=device.identity||streamline_.luid!=device.luid)value_.native={};
        streamline_=device;
        value_.streamlineMatches=device.Known()&&device.identity==value_.device.identity&&device.luid==value_.device.luid;
    }
    void NativeUnavailable(const char* reason=nullptr){
        std::lock_guard lock(mutex_);value_.native={};
        if(reason)value_.nativeUnavailableReason=reason;
    }
    void NativeState(uint64_t provider,uint64_t generation,uint32_t view,
                     uint32_t intervalFrames,uint64_t now,bool passive=false){
        std::lock_guard lock(mutex_);
        if(value_.vulkanFg.xplaneNative||!streamline_.Known()||!value_.Fresh(now)||
           value_.device.identity!=streamline_.identity||value_.device.luid!=streamline_.luid){value_.native={};return;}
        value_.native={streamline_.identity,streamline_.luid,provider,generation,now,view,intervalFrames,passive};
        value_.nativeUnavailableReason.clear();
    }
    void Upscaling(const Device& device,uint64_t feature,const std::string& backend,
                   bool succeeded,bool missingInput,uint64_t now){
        std::lock_guard lock(mutex_);
        if(value_.vulkanFg.xplaneNative||!feature||!value_.Fresh(now)||device.identity!=value_.device.identity||device.luid!=value_.device.luid)return;
        value_.upscaling={device.identity,device.luid,feature,now,succeeded,missingInput,backend};
    }
    // Associates one existing NR ticket with an actual resource of this output.
    // This stores scalar evidence only; the tracker/renderer retains all GPU
    // ownership. A bridge must report successful copy-back separately.
    bool NrOutput(uint64_t color,uint64_t ticket,uint64_t revision,bool compositionReachedOutput,uint64_t now,bool failed=false){
        std::lock_guard lock(mutex_);
        if(!color||!value_.Fresh(now)||std::find(value_.backBuffers.begin(),value_.backBuffers.end(),color)==value_.backBuffers.end())return false;
        // A deliberate no-work return must not erase a native owner's result.
        // Failure without a ticket is still bound to the current request.
        if(!ticket&&!failed)return false;
        value_.nr={ticket,revision,now,compositionReachedOutput,failed};return true;
    }
    void Compute(uint64_t device,uint64_t luid,bool known,unsigned major,unsigned minor,unsigned family){
        std::lock_guard lock(mutex_);
        if(value_.device.identity!=device||value_.device.luid!=luid)return;
        value_.computeKnown=known;value_.computeMajor=major;value_.computeMinor=minor;value_.computeFamily=family;
    }
    template<class Function> Apply WithCurrent(const Snapshot& expected,uint64_t now,Function function){
        std::unique_lock lock(mutex_,std::try_to_lock);
        if(!lock.owns_lock())return Apply::Busy;
        // No provider or model disk identity is invented by this publisher.
        // Their own existing controls still compare their separate revisions.
        if(!value_.Fresh(now)||value_.device.identity!=expected.device.identity||
           !(value_.context==expected.context))return Apply::Changed;
        function();return Apply::Done;
    }
};
inline Context& State(){static Context context;return context;}
}
