#pragma once

#include <array>



// Shared by the overlay title and release comparison; not the upstream engine version.

#define OPTISHADE_VERSION_MAJOR 1

#define OPTISHADE_VERSION_MINOR 0

#define OPTISHADE_VERSION_PATCH 77

#define OPTISHADE_VERSION_REVISION 0

#define OPTISHADE_STRINGIFY_IMPL(x) #x

#define OPTISHADE_STRINGIFY(x) OPTISHADE_STRINGIFY_IMPL(x)

#define OPTISHADE_VERSION_TEXT "1.0.77"

#define OPTISHADE_BUILD_CHANNEL "stable"

#define OPTISHADE_VERSION_DISPLAY "1.0.77 stable"

namespace OptiShadeVersion {

inline constexpr std::array<int, 4> Current{OPTISHADE_VERSION_MAJOR, OPTISHADE_VERSION_MINOR, OPTISHADE_VERSION_PATCH, OPTISHADE_VERSION_REVISION};

}

