#pragma once
#include <array>
#include <cmath>
#include <cstdint>

namespace optishade::vknr {
enum class Reason : unsigned { Disabled, Secondary, ProviderMissing, UnsupportedSpace, UnsupportedCommands,
    MissingGuides, GuideReload, Loading, InvalidColour, InvalidGuides, UnsupportedStorage, WaitBeforeFailed,
    AllocationFailed, ViewFailed, ConsumerFailed, WaitAfterFailed, Warmup, Composed, RestartRequired, Count };
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
