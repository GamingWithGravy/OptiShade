// Experimental XP12 provider: one primary history; borrowed guides expire on return.
#include "../../shared/VulkanNeuralBridge.h"
#include "../../shared/VulkanNrLifecycle.h"
#include <array>
#include <mutex>
#include <string>
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
static Context* Find(reshade::api::effect_runtime* runtime,bool create=true){
    for(auto& state:contexts)if(state.runtime==runtime)return &state;
    if(create)for(auto& state:contexts)if(!state.runtime){state={};state.runtime=runtime;return &state;}
    return nullptr; // Never evict another live view's history or bookkeeping.
}
static void Note(Context& state,Reason reason,const char* text){
    if(state.life.report(reason,GetTickCount64()))
        reshade::log::message(reshade::log::level::info,"XP12 Vulkan NR: reason=%u %s; generation=%llu occurrences=%llu calls=%llu completed=%llu",
            unsigned(reason),text,state.life.generation,state.life.reasons[unsigned(reason)].total,state.life.calls,state.life.completed);
}
static void Changed(reshade::api::effect_runtime* runtime,bool surface=false){
    std::lock_guard guard(mutex);if(auto* state=Find(runtime,false)){if(surface)++state->surface;else ++state->effects;state->life.invalidate();}
}
static void Loading(reshade::api::effect_runtime* runtime){std::lock_guard guard(mutex);if(auto* state=Find(runtime,false)){state->life.missing();if(state->life.active)Note(*state,Reason::Loading,"effect compilation pending; transient history invalidated");}}
static void GuideUnavailable(reshade::api::effect_runtime* runtime){std::lock_guard guard(mutex);if(auto* state=Find(runtime,false)){state->life.missing();Note(*state,Reason::MissingGuides,"guide compilation failed; fix the shader error and recompile, no game restart required");}}
static void Retire(reshade::api::effect_runtime* runtime){
    std::lock_guard guard(mutex);if(owner==runtime)owner=nullptr;if(auto* state=Find(runtime,false))*state={};
    // Device/submission failure is intentionally not cleared by effect teardown.
}
static bool Candidate(reshade::api::effect_runtime* runtime){
    static const bool xp12=[] {wchar_t exe[MAX_PATH]{};GetModuleFileNameW(nullptr,exe,MAX_PATH);const auto* name=wcsrchr(exe,L'\\');return name&&_wcsicmp(name+1,L"X-Plane.exe")==0;}();
    if(!xp12||runtime->get_device()->get_api()!=reshade::api::device_api::vulkan)return false;
    wchar_t title[256]{};GetWindowTextW(static_cast<HWND>(runtime->get_hwnd()),title,256);
    return wcsncmp(title,L"X-System",8)==0||wcsncmp(title,L"X-Plane",7)==0;
}
static HMODULE Consumer(){
    wchar_t path[MAX_PATH]{};if(!GetModuleFileNameW(nullptr,path,MAX_PATH))return nullptr;
    auto* slash=wcsrchr(path,L'\\');if(!slash)return nullptr;
    wcscpy_s(slash+1,MAX_PATH-(slash+1-path),L"dxgi.dll");return GetModuleHandleW(path);
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
    if(owner&&owner!=runtime){Note(*state,Reason::Secondary,"secondary runtime bypassed; primary temporal history kept separate");return false;}
    owner=runtime;
    if(submissionFailed){Note(*state,Reason::RestartRequired,"submission/device failure is latched; restart required");return false;}
    if(!state->life.active){state->life.active=true;state->life.invalidate();if(reset)reset();}
    char preset[1024]{};size_t size=sizeof(preset);runtime->get_current_preset_path(preset,&size);
    if(state->preset!=preset){state->preset=preset;++state->effects;state->life.invalidate();state->reloadRequested=false;}
    const auto guide=runtime->find_technique("OptiShade_TAA_Guides.fx","OptiShade_TAA_Guides");
    if(!guide.handle){
        state->life.missing();Note(*state,Reason::MissingGuides,"guide technique unavailable; source preset and ordinary effects kept");
        if(!state->reloadRequested&&state->reloadAttempts<3){state->reloadRequested=true;++state->reloadAttempts;runtime->reload_effect_next_frame("OptiShade_TAA_Guides.fx");Note(*state,Reason::GuideReload,"requested only the missing guide effect; check compile errors if unavailable");}
        return false;
    }
    state->reloadRequested=false;
    return true;
}
static void Run(reshade::api::effect_runtime* runtime,reshade::api::command_list* cmd,
                reshade::api::resource_view rtv,reshade::api::color_space space){
    using namespace reshade;
    if(!RequiresGuides(runtime))return;
    std::lock_guard guard(mutex);auto* state=Find(runtime,false);if(!state)return;
    auto* device=runtime->get_device();auto* queue=runtime->get_command_queue();
    if(space!=api::color_space::srgb_nonlinear){Note(*state,Reason::UnsupportedSpace,"requires SDR sRGB output");return;}
    if(cmd!=queue->get_immediate_command_list()){Note(*state,Reason::UnsupportedCommands,"requires the runtime immediate command list");return;}
    const auto module=Consumer();const auto reset=reinterpret_cast<Reset>(GetProcAddress(module,"OptiShadeVulkanNrReset"));
    const auto submit=reinterpret_cast<osvtaa::Submit>(GetProcAddress(module,"OptiShadeVulkanNrSubmit"));
    using Wait=int(*)(uint64_t);
    const auto wait=reinterpret_cast<Wait>(GetProcAddress(GetModuleHandleW(L"vulkan-1.dll"),"vkQueueWaitIdle"));
    if(!submit||!wait||!reset){Note(*state,Reason::ProviderMissing,"submit/reset/queue-wait exports unavailable");return;}
    api::resource_view views[3]{};api::resource resources[3]{};
    const char* names[]={"DepthTex","OptiShadeTaaDepth","MotVectTexVort"};
    for(unsigned i=0;i!=3;++i){
        const auto var=runtime->find_texture_variable("OptiShade_TAA_Guides.fx",names[i]);
        if(var.handle)runtime->get_texture_binding(var,&views[i],nullptr);
        if(!views[i].handle){state->life.missing();Note(*state,Reason::MissingGuides,names[i]);return;}
        resources[i]=device->get_resource_from_view(views[i]);
        if(!resources[i].handle){state->life.missing();Note(*state,Reason::MissingGuides,names[i]);return;}
    }
    const auto color=device->get_resource_from_view(rtv);if(!color.handle){Note(*state,Reason::InvalidColour,"missing output resource");return;}
    const auto desc=device->get_resource_desc(color);
    if(desc.type!=api::resource_type::texture_2d||desc.texture.depth_or_layers!=1||desc.texture.levels!=1||desc.texture.samples!=1||desc.texture.width<64||desc.texture.height<64||desc.texture.width>3840||desc.texture.height>2160||
       (desc.texture.format!=api::format::b8g8r8a8_unorm&&desc.texture.format!=api::format::b8g8r8a8_unorm_srgb&&desc.texture.format!=api::format::b8g8r8a8_typeless)){
        Note(*state,Reason::InvalidColour,"unsupported output extent/format/sample/array/mip contract");return;
    }
    for(const auto r:resources){const auto d=device->get_resource_desc(r);
        if(d.type!=api::resource_type::texture_2d||d.texture.width!=desc.texture.width||d.texture.height!=desc.texture.height||d.texture.samples!=1||d.texture.depth_or_layers!=1){state->life.missing();Note(*state,Reason::InvalidGuides,"guide extent/sample/array does not match current output");return;}}
    if(device->get_resource_desc(resources[1]).texture.format!=api::format::r32_float||device->get_resource_desc(resources[2]).texture.format!=api::format::r16g16_float){Note(*state,Reason::InvalidGuides,"requires R32F depth and RG16F estimated motion");return;}
    optishade::vknr::HistoryIdentity identity{};identity.width=desc.texture.width;identity.height=desc.texture.height;identity.effects=state->effects;identity.surface=state->surface;
    // The scene depth semantic may legitimately rotate between game buffers each
    // frame. Track the persistent derived depth/motion resources, not that input.
    for(unsigned i=1;i!=3;++i){identity.guides[i*2]=resources[i].handle;identity.guides[i*2+1]=views[i].handle;}
    if(state->life.observe(identity)){reset();Note(*state,Reason::GuideReload,"current guide/resource/preset generation rebound; history reset");}
    if(!device->check_format_support(api::format::b8g8r8a8_unorm,api::resource_usage::unordered_access|api::resource_usage::shader_resource)){Note(*state,Reason::UnsupportedStorage,"BGRA storage unsupported; normal picture preserved");return;}
    queue->flush_immediate_command_list();
    if(wait(queue->get_native())!=0){submissionFailed=true;Note(*state,Reason::WaitBeforeFailed,"pre-submission queue wait failed; restart required");return;}
    api::resource work{};api::resource_view view{};
    const api::resource_desc workDesc(desc.texture.width,desc.texture.height,1,1,api::format::b8g8r8a8_unorm,1,api::memory_heap::default_,api::resource_usage::unordered_access|api::resource_usage::shader_resource|api::resource_usage::copy_source|api::resource_usage::copy_dest);
    if(!device->create_resource(workDesc,nullptr,api::resource_usage::copy_dest,&work)){submissionFailed=true;Note(*state,Reason::AllocationFailed,"work allocation failed; restart required");return;}
    if(!device->create_resource_view(work,api::resource_usage::unordered_access|api::resource_usage::shader_resource,api::resource_view_desc(api::format::b8g8r8a8_unorm),&view)){
        device->destroy_resource(work);submissionFailed=true;Note(*state,Reason::ViewFailed,"work view failed; restart required");return;
    }
    cmd->barrier(color,api::resource_usage::render_target,api::resource_usage::copy_source);cmd->copy_resource(color,work);cmd->barrier(work,api::resource_usage::copy_dest,api::resource_usage::unordered_access);
    osvtaa::Frame f{};f.device=device->get_native();f.commands=cmd->get_native();f.color=work.handle;f.colorView=view.handle;f.depth=resources[1].handle;f.depthView=views[1].handle;f.motion=resources[2].handle;f.motionView=views[2].handle;f.width=desc.texture.width;f.height=desc.texture.height;
    const int result=submit(&f);
    if(result==1){cmd->barrier(work,api::resource_usage::unordered_access,api::resource_usage::copy_source);cmd->barrier(color,api::resource_usage::copy_source,api::resource_usage::copy_dest);cmd->copy_resource(work,color);cmd->barrier(color,api::resource_usage::copy_dest,api::resource_usage::render_target);}
    else cmd->barrier(color,api::resource_usage::copy_source,api::resource_usage::render_target);
    queue->flush_immediate_command_list();const int done=wait(queue->get_native());
    state->life.result(done==0&&result==1);
    if(done==0){device->destroy_resource_view(view);device->destroy_resource(work);}
    if(done!=0){submissionFailed=true;Note(*state,Reason::WaitAfterFailed,"post-submission queue wait failed; resources retained, restart required");}
    else if(result==-1){submissionFailed=true;Note(*state,Reason::ConsumerFailed,"consumer/model failure latched; restart required");}
    else if(result==1)Note(*state,Reason::Composed,"GPU completion confirmed; estimated guides, inspect visual output separately");
    else Note(*state,Reason::Warmup,result==-2?"request currently unsupported; check consumer options/contract reason":"model warm-up or transient not-ready; clean picture retained");
}
}
