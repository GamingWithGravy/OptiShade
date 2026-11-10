// Production admission/publisher tests. No Vulkan calls, provider, inference,
// driver compilation or physical output is claimed by these CPU fixtures.
#include "VulkanFgAdmission.h"
#include "RuntimeRenderContext.h"
#include "SimulatorRoute.h"
#include "XPlaneGraphicsRoute.h"
#include <functional>
#include <iostream>
#include <stdexcept>
#include <unordered_map>
#include <vector>
static unsigned checks=0;
#define CHECK(value) do{++checks;if(!(value))throw std::runtime_error(#value);}while(false)

// OS/device records are supplied at the already-existing route boundary. The
// actual publisher and actual Vulkan registry execute unchanged below.
using VkDevice=uint64_t;
using VkQueue=uint64_t;
struct FILETIME {uint32_t dwLowDateTime=0,dwHighDateTime=0;};
constexpr int FALSE=0;
static uint64_t now=100000;
static uint64_t GetTickCount64(){return now;}
static uint32_t GetCurrentProcessId(){return 42;}
static int GetCurrentProcess(){return 1;}
static int GetProcessTimes(int,FILETIME* birth,FILETIME*,FILETIME*,FILETIME*){birth->dwLowDateTime=12345;return 1;}
namespace optishade::route {
static Simulator simulator=Simulator::XPlane12;
static Simulator CurrentSimulator(){return simulator;}
}
namespace optishade::xplane_layer {
static GraphicsRoute selected=GraphicsRoute::NativeVulkan;
static GraphicsRoute CurrentRoute(){return selected;}
}
static optishade::vkowner::Registry _owners;
struct Dispatch {optishade::runtime_render::Device renderingDevice;};
static std::unordered_map<VkDevice,Dispatch> _deviceDispatch;
struct SwapchainInfo {uint32_t imageFormat=44,imageColorSpace=0;
    optishade::format_view::Extent imageExtent{1920,1080};uint32_t imageArrayLayers=1;};
static SwapchainInfo _ownerCreateInfo;
#include "vulkan_publisher.inc"

using namespace optishade;
using namespace optishade::vulkan_fg;
static Owner CompleteOwner(){
    Owner owner;auto& b=owner.binding;
    b.pid=42;b.birth=12345;b.device=101;b.luid=202;b.output=303;b.generation=5;b.queue=404;b.queueFamily=2;
    b.format=44;b.colourSpace=0;b.width=1920;b.height=1080;b.layers=1;b.view=0;b.viewCount=1;b.viewKnown=true;
    b.sourceGeneration=8;b.executableIdentity="exe-sha256:fixture";b.providerIdentity="provider-sha256:fixture";b.sourceIdentity="engine-temporal:fixture";
    owner.sampledAt=now;owner.requestRevision=7;owner.sourceFrame=99;owner.xplaneNative=true;
    owner.graphicsQueue=owner.presentObserved=owner.surfaceMetadataValid=true;
    owner.surface=owner.providerAvailable=Evidence::Yes;
    return owner;
}
static Inputs CompleteInputs(const Owner& owner){
    Inputs input;input.binding=owner.binding;input.sampledAt=now;input.requestRevision=owner.requestRevision;
    input.frame=owner.sourceFrame;input.source=Source::EngineTemporal;
    input.providerBound=input.colour=input.depth=input.motion=input.timing=true;
    input.inputLease=input.submissionDependency=input.presentationContract=true;return input;
}
static Qualification Check(const Owner& owner,const Inputs& input){return Assess(owner,input,now,42,12345);}

int main(){try{
    auto owner=CompleteOwner();auto input=CompleteInputs(owner);
    const std::string providerUnavailable=Name(Reason::ProviderUnavailable);
    CHECK(providerUnavailable.find("before Vulkan device creation")!=std::string::npos);
    CHECK(providerUnavailable.find("engine colour/depth/motion/timing source")!=std::string::npos);
    CHECK(Check(owner,input).phase==Phase::Qualified);
    CHECK(!Check(owner,input).canActivate); // Qualification never installs/calls a provider.
    auto changed=owner;changed.providerAvailable=Evidence::No;
    CHECK(Check(changed,{}).phase==Phase::Unsupported&&Check(changed,{}).reason==Reason::ProviderUnavailable);
    changed=owner;changed.providerAvailable=Evidence::Unknown;CHECK(Check(changed,input).phase==Phase::Waiting);
    changed=owner;changed.cancelled=true;CHECK(Check(changed,input).phase==Phase::Cancelled);
    changed=owner;changed.retiring=true;CHECK(Check(changed,input).phase==Phase::Retiring);
    changed=owner;changed.sampledAt=now-3001;CHECK(Check(changed,input).reason==Reason::StaleOwner);
    changed=owner;changed.sampledAt=now+1;CHECK(Check(changed,input).reason==Reason::StaleOwner);
    changed=owner;++changed.binding.pid;CHECK(Check(changed,input).reason==Reason::WrongProcess);
    CHECK(Assess(owner,input,now,42,12346).reason==Reason::WrongProcess);
    changed=owner;changed.surfaceMetadataValid=false;CHECK(Check(changed,input).reason==Reason::UnsupportedSurface);
    changed=owner;changed.surface=Evidence::No;CHECK(Check(changed,input).phase==Phase::Unsupported);
    changed=owner;changed.surface=Evidence::Unknown;CHECK(Check(changed,input).phase==Phase::Waiting);
    changed=owner;changed.graphicsQueue=false;CHECK(Check(changed,input).reason==Reason::WaitingForOwner);
    changed=owner;changed.presentObserved=false;CHECK(Check(changed,input).reason==Reason::WaitingForOwner);
    changed=owner;changed.binding.viewKnown=false;auto matching=CompleteInputs(changed);
    CHECK(Check(changed,matching).reason==Reason::MissingView);
    changed=owner;changed.binding.viewCount=2;matching=CompleteInputs(changed);
    CHECK(Check(changed,matching).reason==Reason::MissingView); // Stereo requires projection identity.
    changed.binding.projection=true;matching=CompleteInputs(changed);CHECK(Check(changed,matching).phase==Phase::Qualified);
    changed.binding.view=2;matching=CompleteInputs(changed);CHECK(Check(changed,matching).reason==Reason::MissingView);

    // Each independent identity dimension invalidates a complete older report.
    const std::vector<std::function<void(Binding&)>> mutations{
        [](auto& b){++b.pid;},[](auto& b){++b.birth;},[](auto& b){++b.device;},[](auto& b){++b.luid;},
        [](auto& b){++b.output;},[](auto& b){++b.generation;},[](auto& b){++b.queue;},[](auto& b){++b.queueFamily;},
        [](auto& b){++b.format;},[](auto& b){++b.colourSpace;},[](auto& b){++b.width;},[](auto& b){++b.height;},
        [](auto& b){++b.layers;},[](auto& b){++b.view;},[](auto& b){++b.viewCount;},[](auto& b){b.projection=true;},
        [](auto& b){++b.sourceGeneration;},[](auto& b){b.sourceIdentity+="changed";},
        [](auto& b){b.executableIdentity+="changed";}
    };
    for(const auto& mutation:mutations){auto wrong=input;mutation(wrong.binding);
        CHECK(Check(owner,wrong).reason==Reason::WrongBinding&&!Check(owner,wrong).canActivate);}
    auto wrong=input;wrong.binding.providerIdentity+="changed";
    CHECK(Check(owner,wrong).reason==Reason::WrongProvider);
    wrong=input;++wrong.requestRevision;CHECK(Check(owner,wrong).phase==Phase::Cancelled);
    wrong=input;++wrong.frame;CHECK(Check(owner,wrong).reason==Reason::WrongBinding);
    wrong=input;wrong.source=Source::CoreEstimated;CHECK(Check(owner,wrong).phase==Phase::Unsupported);
    wrong=input;wrong.source=Source::Unknown;CHECK(Check(owner,wrong).phase==Phase::Waiting);
    for(auto member:{&Inputs::colour,&Inputs::depth,&Inputs::motion,&Inputs::timing}){
        wrong=input;wrong.*member=false;CHECK(Check(owner,wrong).reason==Reason::MissingInputs);
    }
    wrong=input;wrong.inputLease=false;CHECK(Check(owner,wrong).reason==Reason::MissingSubmission);
    wrong=input;wrong.submissionDependency=false;CHECK(Check(owner,wrong).reason==Reason::MissingSubmission);
    wrong=input;wrong.presentationContract=false;CHECK(Check(owner,wrong).reason==Reason::MissingPresentation);
    wrong=input;wrong.sampledAt=now-3001;CHECK(Check(owner,wrong).reason==Reason::WaitingForProvider);

    // The production context protects the route against a DXGI interop/helper
    // output, including its retirement interval and handle-value collisions.
    runtime_render::Context context;runtime_render::Device device{101,202,0x10de,0x2684,0,false,"actual"};
    context.Publish(device,303,5,"vulkan",0,now,{},&owner);auto baseline=context.Read();
    CHECK(baseline.Fresh(now)&&baseline.vulkanFg.binding==owner.binding);
    auto helper=device;helper.identity=909;
    context.Publish(helper,999,1,"d3d12",0,now);CHECK(context.Read().context==baseline.context);
    context.Invalidate(303);CHECK(context.Read().Fresh(now));
    context.StreamlineDevice(device);context.NativeState(55,1,0,6,now);CHECK(!context.Read().native.provider);
    context.Upscaling(device,9,"DLSS",true,false,now);CHECK(!context.Read().upscaling.feature);
    auto rejected=owner;++rejected.binding.device;
    context.Publish(device,303,5,"vulkan",0,now,{},&rejected);CHECK(context.Read().context==baseline.context);
    context.Publish(device,303,5,"d3d12",0,now,{},&owner);CHECK(context.Read().context==baseline.context);
    auto newFormat=owner;++newFormat.binding.format;
    context.Publish(device,303,5,"vulkan",0,now,{},&newFormat);CHECK(context.Read().context.outputId!=baseline.context.outputId);
    unsigned applies=0;CHECK(context.WithCurrent(baseline,now,[&]{++applies;})==runtime_render::Apply::Changed&&!applies);
    baseline=context.Read();context.RetireVulkan(999);CHECK(context.Read().Fresh(now));
    context.RetireVulkan(303);CHECK(!context.Read().Fresh(now)&&Check(context.Read().vulkanFg,{}).phase==Phase::Retiring);
    context.Publish(helper,999,1,"d3d12",0,now);CHECK(context.Read().vulkanFg.retiring&&!context.Read().Fresh(now));
    CHECK(context.WithCurrent(baseline,now,[&]{++applies;})==runtime_render::Apply::Changed&&!applies);
    ++owner.binding.generation;context.Publish(device,303,6,"vulkan",0,now,{},&owner);
    CHECK(context.Read().Fresh(now)&&!context.Read().vulkanFg.retiring);
    context.RetireVulkan(303,true);CHECK(Check(context.Read().vulkanFg,{}).phase==Phase::Cancelled);

    // Exact native publisher reads the already-selected route registry. No
    // inventory/primary adapter or available DLSS DLL can supply this identity.
    _owners.surface(1,2,3);CHECK(_owners.swapchain(101,2,303,true,false));
    _owners.queue(101,404,2,true);_owners.queue(999,405,7,true);
    _deviceDispatch[101]={device};_deviceDispatch[999]={helper};
    PublishVulkanAutoContext(405);CHECK(!runtime_render::State().Read().Fresh(now));
    PublishVulkanAutoContext(404);auto published=runtime_render::State().Read();
    CHECK(published.Fresh(now)&&published.device.identity==101&&published.device.luid==202);
    CHECK(published.vulkanFg.binding.pid==42&&published.vulkanFg.binding.birth==12345);
    CHECK(published.vulkanFg.binding.output==303&&published.vulkanFg.binding.queue==404&&published.vulkanFg.binding.queueFamily==2);
    CHECK(published.vulkanFg.binding.format==44&&published.vulkanFg.binding.width==1920);
    CHECK(!published.vulkanFg.binding.viewKnown&&published.context.view==UINT32_MAX);
    CHECK(published.vulkanFg.surfaceMetadataValid&&published.vulkanFg.surface==Evidence::Unknown);
    CHECK(Check(published.vulkanFg,{}).reason==Reason::ProviderUnavailable);
    CHECK(published.vulkanFg.binding.sourceIdentity.empty()&&published.vulkanFg.binding.providerIdentity.empty());
    const auto previous=published.context;PublishVulkanAutoContext(405);CHECK(runtime_render::State().Read().context==previous);
    xplane_layer::selected=xplane_layer::GraphicsRoute::MenuOnly;
    _ownerCreateInfo.imageFormat=97;PublishVulkanAutoContext(404);CHECK(runtime_render::State().Read().context==previous);
    xplane_layer::selected=xplane_layer::GraphicsRoute::NativeVulkan;
    PublishVulkanAutoContext(404);CHECK(runtime_render::State().Read().context.outputId!=previous.outputId);
    CHECK(runtime_render::State().Read().vulkanFg.binding.format==97);
    std::cout<<checks<<" production Vulkan FG admission/context/publisher checks passed. Inactive CPU contract; no provider activation or physical graphics qualification.\n";
    return 0;
}catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}}
