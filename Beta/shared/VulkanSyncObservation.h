#pragma once

#include <cstdint>
#include <cstddef>
#include <type_traits>

namespace optishade::vulkan_sync_observation {

constexpr uint32_t Abi = 1;
enum class Object : uint32_t { Semaphore = 1, Fence = 2 };
enum class Action : uint32_t { Create = 1, Destroy = 2 };

// One bounded lifecycle event from ReShade's Vulkan device-proc boundary.
// This is diagnostic evidence only; it does not establish GPU completion.
struct Event {
	uint32_t size = sizeof(Event);
	uint32_t abi = Abi;
	uint32_t objectType = 0;
	uint32_t action = 0;
	uint64_t device = 0;
	uint64_t object = 0;
	int32_t result = 0;
	uint32_t flags = 0;
	uint32_t hasPNext = 0;
	uint32_t timeline = 0;
	uint64_t initialValue = 0;
	uint32_t exportHandleTypes = 0;
	uint32_t valid = 0;
};

template <typename Handle>
inline uint64_t HandleValue(Handle handle) noexcept {
	if constexpr (std::is_pointer_v<Handle>)
		return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(handle));
	else
		return static_cast<uint64_t>(handle);
}
inline uint64_t HandleValue(std::nullptr_t) noexcept { return 0; }

using Observer = void (*)(const Event*);

} // namespace optishade::vulkan_sync_observation
