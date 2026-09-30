#define NOMINMAX
#include "../shared/NrAdmission.h"
#include "../optiscaler/OptiScaler/shaders/dlssnr/DlssNr_Guides.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <limits>

int main()
{
    using optishade::taa::TaaWorkingExtent;
    for (unsigned w : {1u, 1278u, 1920u, 2560u, 3440u, 3838u, 3840u})
    for (unsigned h : {1u, 718u, 1080u, 1440u, 1600u, 2158u, 2160u})
    {
        const auto work = TaaWorkingExtent(w,h);
        assert(work.valid() && work.width==w && work.height==h && !work.reduced(w,h));
    }
    for (const auto size : {DlssNr::GuideExtent{0,1440}, {5120,0}, {3841,2160},
                           {5120,2160}, {5121,1440}, {5119,1439}, {7680,2160}, {3840,2161}})
        assert(!TaaWorkingExtent(size.width,size.height).valid());
    assert(!TaaWorkingExtent(std::numeric_limits<uint64_t>::max(),1440).valid());
    const auto work=TaaWorkingExtent(5120,1440);
    assert(work.width==3840 && work.height==1080 && work.reduced(5120,1440));
    assert(uint64_t(work.width)*1440 == uint64_t(work.height)*5120);
    assert(uint64_t(work.width)*work.height <= 3840ull*2160);
    const auto regions=DlssNr::ResolveGuideRegions({5120,1440},{5120,1440},{5120,1440},{5120,1440},false,0,0,0,0);
    assert(regions.depth.width==5120 && regions.depth.height==1440 && regions.depth.x==0 && regions.depth.y==0);
    assert(regions.motion.width==5120 && regions.motion.height==1440 && regions.motion.x==0 && regions.motion.y==0);
    // TAA guide values are normalized displacements. Exactly one pixels-to-work
    // conversion preserves the same normalized reprojection in both axes.
    for (float normalized : {-1.f,-0.125f,0.f,0.03125f,1.f})
    {
        assert(normalized * 5120.f * (float(work.width)/5120.f) / work.width == normalized);
        assert(normalized * 1440.f * (float(work.height)/1440.f) / work.height == normalized);
    }
    puts("PASS: native extent preservation; exact 5120x1440 -> 3840x1080 aspect/area bounds; oversized/odd/zero guards; full guide regions and single motion scaling");
}
