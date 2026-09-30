#include <windows.h>
#include "../shared/DeferredSrQuality.h"
#include <cassert>
#include <cstdio>

int main()
{
    using namespace optishade::deferred_quality;
    for (const auto size : {1920u, 2560u, 3840u})
    {
        assert(Resolve(optishade::deferred_quality::Unknown,size,1080,size,1080) == NVSDK_NGX_PerfQuality_Value_DLAA);
        assert(Resolve(NVSDK_NGX_PerfQuality_Value_DLAA,size,1080,size,1080) == NVSDK_NGX_PerfQuality_Value_DLAA);
        // A deliberate known mode remains authoritative even with dynamic 1:1 input.
        assert(Resolve(NVSDK_NGX_PerfQuality_Value_MaxQuality,size,1080,size,1080) == NVSDK_NGX_PerfQuality_Value_MaxQuality);
        assert(Resolve(optishade::deferred_quality::Unknown,size,1080,size,1080,NVSDK_NGX_PerfQuality_Value_MaxQuality) == NVSDK_NGX_PerfQuality_Value_MaxQuality);
        assert(Resolve(NVSDK_NGX_PerfQuality_Value_DLAA,size,1080,size,1080,NVSDK_NGX_PerfQuality_Value_MaxQuality) == NVSDK_NGX_PerfQuality_Value_DLAA);
    }
    for (unsigned quality=0;quality<=NVSDK_NGX_PerfQuality_Value_DLAA;++quality)
        assert(Resolve(quality,1280,720,1920,1080) == static_cast<NVSDK_NGX_PerfQuality_Value>(quality));
    assert(Resolve(optishade::deferred_quality::Unknown,1280,720,1920,1080) == NVSDK_NGX_PerfQuality_Value_MaxPerf);
    assert(Resolve(optishade::deferred_quality::Unknown,1280,720,1920,1080,NVSDK_NGX_PerfQuality_Value_MaxQuality) == NVSDK_NGX_PerfQuality_Value_MaxQuality);
    assert(!Resolve(optishade::deferred_quality::Unknown,1920,1080,1920,1080,static_cast<NVSDK_NGX_PerfQuality_Value>(77)));
    assert(!Resolve(77,1920,1080,1920,1080));
    assert(!Resolve(optishade::deferred_quality::Unknown,0,1080,1920,1080));
    assert(!Resolve(optishade::deferred_quality::Unknown,2560,1440,1920,1080));
    puts("PASS: private 1:1 native-AA inference, same-contract authoritative omission, explicit changes, scaled fallback and invalid contracts");
}
