#include "PreparedOverlay.h"

#include <cassert>

int main()
{
    using optishade::overlay::ShouldSubmitPreparedOverlay;

    assert(!ShouldSubmitPreparedOverlay(false, false));
    assert(!ShouldSubmitPreparedOverlay(false, true));
    assert(!ShouldSubmitPreparedOverlay(true, false));
    assert(ShouldSubmitPreparedOverlay(true, true));
}
