#pragma once
#include <cstdint>
// Include after the consumer's Vulkan declarations (SDK or generated GLAD).

// Private opt-in ABI for a single native Vulkan present. Only Vulkan handles cross
// the DLL boundary; each renderer retains its own ImGui context and resources.
namespace osvk {
constexpr uint32_t Version = 1;
using DrawOverlay = bool (*)(VkQueue, VkPresentInfoKHR*, PFN_vkQueueSubmit);
using SetOverlay = bool (*)(uint32_t, VkQueue, DrawOverlay);
}
