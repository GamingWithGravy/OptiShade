#pragma once
#include <cstdint>
// Include after the consumer's Vulkan declarations (SDK or generated GLAD).

// Private opt-in Vulkan presentation ABI. V1 is per-call; V2 registers preparation
// and submission callbacks for either hook order, cleared on unhook. Preparation
// runs after effects flush, outside queue locks; submission runs under queue locks.
// Only handles cross
// the DLL boundary; each renderer retains its own ImGui context and resources.
namespace osvk {
constexpr uint32_t Version = 1;
using DrawOverlay = bool (*)(VkQueue, VkPresentInfoKHR*, PFN_vkQueueSubmit) noexcept;
constexpr uint32_t CallbackVersion = 2;
using PrepareOverlay = bool (*)(VkQueue,const VkPresentInfoKHR*) noexcept;
using SetCallbacks = bool (*)(uint32_t,VkQueue,PrepareOverlay,DrawOverlay);
using SetOverlay = bool (*)(uint32_t, VkQueue, DrawOverlay);
}
