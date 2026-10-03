#pragma once
#include <cstdint>
// Private, versioned ABI between the bundled image-effects and performance DLLs.
// Resources are borrowed until Submit returns. Only SDR, native D3D12 is accepted.
namespace ostaa {
constexpr uint32_t Version = 2;
struct Frame {
    uint32_t version = Version;
    uint32_t size = sizeof(Frame);
    uint64_t runtime = 0, generation = 0;
    const char* reason = nullptr; // Borrowed only during Submit.
    void* queue = nullptr;
    void* color = nullptr;
    void* depth = nullptr;
    void* motion = nullptr;
    uint32_t reversedDepth = 0;
    uint32_t providerReady = 0;
};
using Requested = bool (*)();
using NeedsGuides = bool (*)(void* device, uint32_t width, uint32_t height);
using Submit = void (*)(const Frame*);
}
