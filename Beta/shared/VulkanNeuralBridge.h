#pragma once
#include <cstdint>
// Local, synchronous Vulkan experiment. Borrowed handles expire on return.
// Colour is a storage-capable BGRA8 UNORM copy in GENERAL; guides are sampled
// R32F depth and RG16F estimated motion in SHADER_READ_ONLY_OPTIMAL.
namespace osvtaa {
struct Frame {
    uint32_t version = 4, size = sizeof(Frame);
    uint64_t device = 0, commands = 0;
    uint64_t runtime = 0, generation = 0, queue = 0, frame = 0;
    uint64_t* observationTicket = nullptr; // borrowed only during Submit
    uint64_t color = 0, colorView = 0, depth = 0, depthView = 0, motion = 0, motionView = 0;
    uint32_t width = 0, height = 0;
    uint32_t colorLayout = 1; // VkImageLayout; GENERAL by default, attachment for the runtime output.
    // The owner alone flushes/reacquires its immediate recording. A bridge must
    // never end, reset or submit a borrowed Vulkan command buffer itself.
    void* commandContext=nullptr;
    void (*flush)(void*)=nullptr;
    uint64_t (*currentCommands)(void*)=nullptr;
};
using Submit = int (*)(const Frame*); // -2 unsupported/not requested, -1 fatal model/submission failure, 0 warm-up, 1 composed
}
