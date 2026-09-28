#pragma once
#include <array>

// Shared by the overlay title and release comparison; not the upstream engine version.
#define OPTISHADE_VERSION_MAJOR 0
#define OPTISHADE_VERSION_MINOR 21
#define OPTISHADE_VERSION_PATCH 3
#define OPTISHADE_VERSION_REVISION 1
#define OPTISHADE_STRINGIFY_IMPL(x) #x
#define OPTISHADE_STRINGIFY(x) OPTISHADE_STRINGIFY_IMPL(x)
#define OPTISHADE_VERSION_TEXT "0.21.3-beta.1"
namespace OptiShadeVersion {
inline constexpr std::array<int, 4> Current{OPTISHADE_VERSION_MAJOR, OPTISHADE_VERSION_MINOR, OPTISHADE_VERSION_PATCH, OPTISHADE_VERSION_REVISION};
}
