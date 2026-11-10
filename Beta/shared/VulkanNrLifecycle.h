#pragma once
#include <array>
#include <cmath>
#include <cstdint>

namespace optishade::vknr {
enum class Reason : unsigned { Disabled, Secondary, ProviderMissing, UnsupportedSpace, UnsupportedCommands,
    MissingGuides, GuideReload, Loading, InvalidColour, InvalidGuides, UnsupportedStorage, WaitBeforeFailed,
    AllocationFailed, ViewFailed, ConsumerFailed, WaitAfterFailed, Warmup, Composed, RestartRequired, BridgeUnavailable, Count };
inline const char* Name(Reason reason){switch(reason){
case Reason::Disabled:return "NR disabled by user";case Reason::Secondary:return "This Vulkan runtime is not the selected NR presentation owner";
case Reason::ProviderMissing:return "XP12 Vulkan NR provider or route is unavailable";case Reason::UnsupportedSpace:return "XP12 Vulkan NR requires SDR sRGB output";
case Reason::UnsupportedCommands:return "XP12 Vulkan NR requires the runtime immediate command list";case Reason::MissingGuides:return "XP12 temporal guide producer is unavailable";
case Reason::GuideReload:return "XP12 guide or resource generation changed";case Reason::Loading:return "XP12 guide effects are still compiling";
case Reason::InvalidColour:return "XP12 output image is missing or unsupported";case Reason::InvalidGuides:return "XP12 depth or motion guide contract is unsupported";
case Reason::UnsupportedStorage:return "XP12 Vulkan device lacks required external storage support";case Reason::WaitBeforeFailed:return "XP12 Vulkan interop wait before NR failed";
case Reason::AllocationFailed:return "XP12 Vulkan NR bridge allocation failed";case Reason::ViewFailed:return "XP12 Vulkan NR bridge image view creation failed";
case Reason::ConsumerFailed:return "XP12 Vulkan NR consumer submission failed";case Reason::WaitAfterFailed:return "XP12 Vulkan interop wait after NR failed";
case Reason::Warmup:return "XP12 NR model is warming up or GPU work is pending";case Reason::Composed:return "XP12 NR copy-back was submitted; GPU completion is pending";
case Reason::RestartRequired:return "XP12 Vulkan submission or device loss requires restart";case Reason::BridgeUnavailable:return "XP12 Vulkan NR bridge is unavailable";default:return "Unknown XP12 Vulkan NR blocker";}}
struct Counter { uint64_t total=0,lastReport=0; bool used=false; };
struct HistoryIdentity {
    std::array<uint64_t,6> guides{};
    uint64_t effects=0,surface=0;
    uint32_t width=0,height=0;
    bool operator==(const HistoryIdentity& b) const { return guides==b.guides&&effects==b.effects&&surface==b.surface&&width==b.width&&height==b.height; }
};
struct Lifecycle {
    std::array<Counter,static_cast<unsigned>(Reason::Count)> reasons{};
    HistoryIdentity identity{};
    uint64_t generation=0,calls=0,completed=0;
    bool observed=false,resetPending=true,active=false;
    bool report(Reason why,uint64_t now){auto& c=reasons[static_cast<unsigned>(why)];++c.total;if(!c.used||now-c.lastReport>=5000){c.used=true;c.lastReport=now;return true;}return false;}
    void invalidate(){resetPending=true;observed=false;}
    void change(uint64_t& revision){++revision;invalidate();}
    bool observe(const HistoryIdentity& current){if(!observed||!(identity==current)){identity=current;observed=true;resetPending=true;++generation;}const bool reset=resetPending;resetPending=false;return reset;}
    void missing(){invalidate();} // A missing guide is transient, regardless of duration.
    void result(bool composed){++calls;if(composed)++completed;} // Warm-up never invents a device failure.
};
struct GuideOptions { float workingScale=1.f; unsigned passes=1; bool applyModel=true; };
struct WorkingExtent { uint32_t width=0,height=0; bool supported=false; };
inline WorkingExtent working_extent(uint32_t width,uint32_t height,const GuideOptions& options){
    if(width<64||height<64||width>3840||height>2160||!std::isfinite(options.workingScale)||options.workingScale<.25f||options.workingScale>2.f||options.passes<1||options.passes>3)return {};
    const auto w=static_cast<uint32_t>(width*options.workingScale+.5f),h=static_cast<uint32_t>(height*options.workingScale+.5f);
    // Keep the known native ceiling on the model working grid as well. A larger
    // request is explicitly unavailable, rather than silently forcing scale 1.
    return {w,h,w>=64&&h>=64&&w<=3840&&h<=2160};
}
}
