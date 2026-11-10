#pragma once
#include <array>
namespace optishade::taa {
// The fourth internal resource is our composition destination, not an input
// tag to invent for Streamline. Its swapchain owns backbuffer discovery and
// the game's optional subrect tag must remain untouched. Internal order:
// HUD-less, composition destination, depth, motion.
template<class Tag> std::array<Tag,3> ReplacementInputTags(const Tag* contract) {
    return {contract[0],contract[2],contract[3]};
}
}
