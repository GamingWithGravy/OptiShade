#include "../../Beta/optiscaler/OptiScaler/inputs/FG/FgDisplayExtent.h"

#include <cassert>
#include <iostream>

using optishade::fg::DisplayExtent;
using optishade::fg::SelectDisplayExtent;

int main()
{
    const DisplayExtent output { 3840, 2160 };
    const DisplayExtent fallback { 2560, 1440 };

    const auto selectedOutput = SelectDisplayExtent(output, fallback);
    assert(selectedOutput.width == 3840 && selectedOutput.height == 2160);

    // Never mix a partially reported output with another surface's dimensions.
    const auto selectedFallback = SelectDisplayExtent({ 0, 2160 }, fallback);
    assert(selectedFallback.width == 2560 && selectedFallback.height == 1440);

    const auto missing = SelectDisplayExtent({}, { 2560, 0 });
    assert(!missing.IsValid());

    std::cout << "Streamline FG display extent: output preference, complete-pair fallback, and fail-closed checks passed.\n";
}
