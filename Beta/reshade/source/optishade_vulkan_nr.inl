#include "../../shared/SimulatorRouteHost.h"
// Experimental XP12 provider: one primary history; borrowed guides expire on return.
#include "../../shared/VulkanNeuralBridge.h"
#include "../../shared/VulkanNrLifecycle.h"
#include "../../shared/GuideExtent.h"
#include "../../shared/VulkanOwnerBridge.h"
#include <array>
#include <mutex>
#include <string>
extern "C" void OptiShadeFlushExternalVulkanCommands(void* queue);
namespace osvnr_impl {
using optishade::vknr::Reason;
struct Context {
    reshade::api::effect_runtime* runtime=nullptr;
    optishade::vknr::Lifecycle life{};
    uint64_t effects=0,surface=0;
    unsigned reloadAttempts=0;
    bool reloadRequested=false;
    std::string preset;
};
static std::array<Context,8> contexts{};
static std::recursive_mutex mutex;
static reshade::api::effect_runtime* owner=nullptr;
static bool submissionFailed=false;
static HMODULE Consumer();
static Context* Find(reshade::api::effect_runtime* runtime,bool create=true){
    for(auto& state:contexts)if(state.runtime==runtime)return &state;
    if(create)for(auto& state:contexts)if(!state.runtime){state={};state.runtime=runtime;return &state;}
    return nullptr; // Never evict another live view's history or bookkeeping.
}
static void Note(Context& state,Reason reason,const char* text){
    const bool firstReport=state.life.report(reason,GetTickCount64());
    if(reason!=Reason::Disabled&&reason!=Reason::GuideReload&&reason!=Reason::Warmup&&reason!=Reason::Composed){
        auto module=Consumer();
        using Report=void(*)(unsigned,uint64_t,uint64_t,uint64_t,uint64_t);
        auto report=module?reinterpret_cast<Report>(GetProcAddress(module,"OptiShadeVulkanNrReportBlock")):nullptr;
        if(report&&state.runtime){
            const auto device=state.runtime->get_device();const auto queue=state.runtime->get_command_queue();
            uint64_t ownerHandle=0,presentationGeneration=0;
            const auto& adapter=optishade::route::Current();
            if(adapter.vulkan){optishade::route::VulkanRequest request;request.event=optishade::route::VulkanEvent::Lookup;
                optishade::route::VulkanResult result;if(adapter.vulkan(&request,sizeof(request),&result,sizeof(result))){ownerHandle=result.owner.chain;presentationGeneration=result.owner.generation;}}
            report(unsigned(reason),device?device->get_native():0,ownerHandle,presentationGeneration,queue?queue->get_native():0);
        }
    }
    if(firstReport)
        reshade::log::message(reshade::log::level::info,"XP12 Vulkan NR: reason=%u %s; generation=%llu occurrences=%llu calls=%llu completed=%llu",
            unsigned(reason),text,state.life.generation,state.life.reasons[unsigned(reason)].total,state.life.calls,state.life.completed);
}
static void Changed(reshade::api::effect_runtime* runtime,bool surface=false){
    std::lock_guard guard(mutex);if(auto* state=Find(runtime,false)){if(surface)state->life.change(state->surface);else state->life.change(state->effects);}
}
static void Loading(reshade::api::effect_runtime* runtime){std::lock_guard guard(mutex);if(auto* state=Find(runtime,false)){state->life.missing();if(state->life.active)Note(*state,Reason::Loading,"effect compilation pending; transient history invalidated");}}
static void GuideUnavailable(reshade::api::effect_runtime* runtime){std::lock_guard guard(mutex);if(auto* state=Find(runtime,false)){state->life.missing();Note(*state,Reason::MissingGuides,"guide compilation failed; fix the shader error and recompile, no game restart required");}}
static void Retire(reshade::api::effect_runtime* runtime){
    std::lock_guard guard(mutex);if(owner==runtime)owner=nullptr;if(auto* state=Find(runtime,false))*state={};
    // Device/submission failure is intentionally not cleared by effect teardown.
}
static HMODULE Consumer(){return OptiShadeVulkanConsumer();}
static bool Candidate(reshade::api::effect_runtime* runtime){
    if(runtime->get_device()->get_api()!=reshade::api::device_api::vulkan)return false;
    auto module=Consumer();
    using Owns=bool(*)(uint64_t); Owns owns=module?reinterpret_cast<Owns>(GetProcAddress(module,"OptiShadeVulkanOwnsWindow")):nullptr;
    using Request=bool(*)(); Request requested=module?reinterpret_cast<Request>(GetProcAddress(module,"OptiShadeVulkanNrRequested")):nullptr;
    const bool owned=owns&&owns(reinterpret_cast<uint64_t>(runtime->get_hwnd()));
    static ULONGLONG last=0;const auto now=GetTickCount64();
    if(!last||now-last>=5000){last=now;reshade::log::message(reshade::log::level::info,"OptiShade Vulkan candidate: simulator=%u consumer=%p requestedExport=%u requested=%u ownsExport=%u owned=%u window=%p",unsigned(optishade::route::CurrentSimulator()),module,requested!=nullptr,requested&&requested(),owns!=nullptr,owned,runtime->get_hwnd());}
    return owned;
}

using Reset=void(*)();
static bool RequiresGuides(reshade::api::effect_runtime* runtime){
    if(!Candidate(runtime))return false;
    std::lock_guard guard(mutex);auto* state=Find(runtime);if(!state){static uint64_t last=0;const auto now=GetTickCount64();if(!last||now-last>=5000){last=now;reshade::log::message(reshade::log::level::warning,"XP12 Vulkan NR: runtime tracking capacity reached; extra view bypassed without sharing history");}return false;}
    auto module=Consumer();const auto requested=reinterpret_cast<bool(*)()>(GetProcAddress(module,"OptiShadeVulkanNrRequested"));
    const auto reset=reinterpret_cast<Reset>(GetProcAddress(module,"OptiShadeVulkanNrReset"));
    if(!requested){Note(*state,Reason::ProviderMissing,"consumer export unavailable; retrying when available");return false;}
    if(!requested()){
        if(owner==runtime&&state->life.active&&reset)reset();
        if(state->life.active)Note(*state,Reason::Disabled,"disabled by user");
        state->life.active=false;state->life.invalidate();state->reloadAttempts=0;state->reloadRequested=false;
        return false;
    }
    if(owner&&owner!=runtime){if(reset)reset();state->life.invalidate();}
    owner=runtime;
    if(submissionFailed){Note(*state,Reason::RestartRequired,"submission/device failure is latched; restart required");return false;}
    if(!state->life.active){state->life.active=true;state->life.invalidate();if(reset)reset();}
    return true;
}
static void Run(reshade::api::effect_runtime* runtime,reshade::api::command_list* cmd,
                reshade::api::resource_view rtv,reshade::api::color_space space,const osguide::Frame& guides){
    using namespace reshade;
    if(!RequiresGuides(runtime))return;
    std::lock_guard guard(mutex);auto* state=Find(runtime,false);if(!state)return;
    auto* device=runtime->get_device();auto* queue=runtime->get_command_queue();
    if(space!=api::color_space::srgb_nonlinear){Note(*state,Reason::UnsupportedSpace,"requires SDR sRGB output");return;}
    if(cmd!=queue->get_immediate_command_list()){Note(*state,Reason::UnsupportedCommands,"requires the runtime immediate command list");return;}
    const auto module=Consumer();const auto reset=reinterpret_cast<Reset>(GetProcAddress(module,"OptiShadeVulkanNrReset"));
    const auto submit=reinterpret_cast<osvtaa::Submit>(GetProcAddress(module,"OptiShadeVulkanNrSubmit"));
    if(!submit||!reset){Note(*state,Reason::ProviderMissing,"submit/reset exports unavailable");return;}
    if(!guides.ready){state->life.missing();Note(*state,Reason::MissingGuides,guides.reason);return;}
    api::resource_view views[3]{{},guides.depthView,guides.motionView};
    api::resource resources[3]{guides.sourceDepth,guides.depth,guides.motion};
    const auto color=device->get_resource_from_view(rtv);if(!color.handle){Note(*state,Reason::InvalidColour,"missing output resource");return;}
    const auto desc=device->get_resource_desc(color);
    if(desc.type!=api::resource_type::texture_2d||desc.texture.depth_or_layers!=1||desc.texture.levels!=1||desc.texture.samples!=1||desc.texture.width<64||desc.texture.height<64||desc.texture.width>3840||desc.texture.height>2160||
       (desc.texture.format!=api::format::b8g8r8a8_unorm&&desc.texture.format!=api::format::b8g8r8a8_unorm_srgb&&desc.texture.format!=api::format::b8g8r8a8_typeless)){
        Note(*state,Reason::InvalidColour,"unsupported output extent/format/sample/array/mip contract");return;
    }
    const auto sourceDepthDesc=device->get_resource_desc(resources[0]);
    if(sourceDepthDesc.type!=api::resource_type::texture_2d||sourceDepthDesc.texture.samples!=1||
       sourceDepthDesc.texture.depth_or_layers!=1||sourceDepthDesc.texture.levels!=1||
       !optishade::guides::CompatibleDepthExtent(desc.texture.width,desc.texture.height,
                                                   sourceDepthDesc.texture.width,sourceDepthDesc.texture.height)){
        state->life.missing();Note(*state,Reason::InvalidGuides,"scene-depth scale/aspect does not match current output");return;
    }
    for(unsigned i=1;i!=3;++i){const auto d=device->get_resource_desc(resources[i]);
        if(d.type!=api::resource_type::texture_2d||d.texture.width!=desc.texture.width||d.texture.height!=desc.texture.height||d.texture.samples!=1||d.texture.depth_or_layers!=1){state->life.missing();Note(*state,Reason::InvalidGuides,"derived guide extent/sample/array does not match current output");return;}}
    if(device->get_resource_desc(resources[1]).texture.format!=api::format::r32_float||device->get_resource_desc(resources[2]).texture.format!=api::format::r16g16_float){Note(*state,Reason::InvalidGuides,"requires R32F depth and RG16F estimated motion");return;}
    optishade::vknr::HistoryIdentity identity{};identity.width=desc.texture.width;identity.height=desc.texture.height;identity.effects=state->effects;identity.surface=state->surface;identity.guides[0]=guides.generation;
    // The scene depth semantic may legitimately rotate between game buffers each
    // frame. Track the persistent derived depth/motion resources, not that input.
    for(unsigned i=1;i!=3;++i){identity.guides[i*2]=resources[i].handle;identity.guides[i*2+1]=views[i].handle;}
    if(state->life.observe(identity)){reset();Note(*state,Reason::GuideReload,"current guide/resource/preset generation rebound; history reset");}
    optishade::route::FrameContext routeFrame;
    routeFrame.simulator=optishade::route::CurrentSimulator();routeFrame.api=optishade::route::Api::Vulkan;
    routeFrame.device=device->get_native();routeFrame.queue=queue->get_native();routeFrame.colour=color.handle;routeFrame.depth=resources[1].handle;routeFrame.motion=resources[2].handle;
    routeFrame.presentationOwner=0;routeFrame.presentationGeneration=0;
    routeFrame.frameId=state->life.calls;routeFrame.width=desc.texture.width;routeFrame.height=desc.texture.height;
    const auto& adapter=optishade::route::Current();
    optishade::route::VulkanRequest ownerRequest;ownerRequest.event=optishade::route::VulkanEvent::Lookup;
    optishade::route::VulkanResult ownerResult;
    if(adapter.vulkan&&adapter.vulkan(&ownerRequest,sizeof(ownerRequest),&ownerResult,sizeof(ownerResult))){routeFrame.presentationOwner=ownerResult.owner.chain;routeFrame.presentationGeneration=ownerResult.owner.generation;}

    const auto simulator=optishade::route::CurrentSimulator();
    const bool genericOwnedVulkan=simulator==optishade::route::Simulator::Unknown&&OptiShadeIsOwnedVulkanWindow(runtime->get_hwnd());
    if(!genericOwnedVulkan&&(!adapter.validate||!adapter.validate(&routeFrame,sizeof(routeFrame)))){Note(*state,Reason::ProviderMissing,"simulator/API route missing or rejected the Vulkan frame contract");return;}
    if(genericOwnedVulkan){
        // Generic games do not have a Vulkan route DLL yet. Candidate() proved
        // this ReShade runtime owns the window; OptiScaler's Vulkan submit then
        // validates the active swapchain device and graphics queue per frame.
    }
    // The bridge owns copy-in, submission, copy-back and barriers. This callback
    // performs no work with its old command-list pointer after scheduling.
    osvtaa::Frame f{};f.device=device->get_native();f.commands=cmd->get_native();f.color=color.handle;f.colorView=rtv.handle;
    f.colorLayout=2; // VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
    f.depth=resources[1].handle;f.depthView=views[1].handle;f.motion=resources[2].handle;f.motionView=views[2].handle;f.width=desc.texture.width;f.height=desc.texture.height;
    uint64_t observationTicket=0;
    f.runtime=reinterpret_cast<uintptr_t>(runtime);f.generation=state->life.generation;
    f.queue=queue->get_native();f.frame=state->life.calls;f.observationTicket=&observationTicket;
    f.commandContext=queue;
    f.flush=[](void* context){OptiShadeFlushExternalVulkanCommands(context);};
    f.currentCommands=[](void* context)->uint64_t{return static_cast<api::command_queue*>(context)->get_immediate_command_list()->get_native();};
    const int result=submit(&f);
    state->life.result(false); // Only the bridge's completion fence proves completion.
    if(result==-1){submissionFailed=true;Note(*state,Reason::ConsumerFailed,"Restart required after device/submission loss");}
    else if(result==1)Note(*state,Reason::Composed,"NR copy-back submitted; GPU completion tracked by the bridge");
    else if(result==-2)Note(*state,Reason::BridgeUnavailable,"transport initialization or frame admission failed; exact Vulkan/D3D12 bridge reason is saved to LastSession and the OptiScaler log");
    else Note(*state,Reason::Warmup,"Neural model warming up or GPU frame pending");
}
}
