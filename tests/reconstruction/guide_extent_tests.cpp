#include "GuideExtent.h"
#include <stdexcept>

#define CHECK(x) do { if (!(x)) throw std::runtime_error(#x); } while (0)

int main() {
    using optishade::guides::CompatibleDepthExtent;

    CHECK(CompatibleDepthExtent(1920, 1080, 1920, 1080));
    CHECK(CompatibleDepthExtent(1920, 1080, 5760, 3240));
    CHECK(CompatibleDepthExtent(2560, 1440, 7680, 4321)); // one-pixel raster rounding
    CHECK(CompatibleDepthExtent(3840, 2160, 1920, 1080));
    CHECK(CompatibleDepthExtent(2560, 1440, 640, 360));

    CHECK(!CompatibleDepthExtent(1920, 1080, 5760, 2160)); // non-uniform scale / aspect mismatch
    CHECK(!CompatibleDepthExtent(1920, 1080, 9600, 5400)); // outside bounded 4x range
    CHECK(!CompatibleDepthExtent(1920, 1080, 32768, 18432));
    CHECK(!CompatibleDepthExtent(63, 1080, 189, 3240));
    CHECK(!CompatibleDepthExtent(1920, 1080, 0, 0));
}
