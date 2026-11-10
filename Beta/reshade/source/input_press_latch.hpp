#pragma once

#include <cstdint>

namespace reshade::input_press_latch
{
// Retain a press until the render frame consumes it, even if release arrived
// in the same message batch. The remaining bits keep ReShade's state layout.
constexpr uint8_t update(uint8_t previous, bool down)
{
	return static_cast<uint8_t>((down ? 0x88 : 0x08) | (previous & 0x10) |
		(down && (previous & 0x80) == 0 ? 0x10 : 0));
}
constexpr bool pressed(uint8_t state) { return (state & 0x10) != 0; }
constexpr uint8_t next_frame(uint8_t state) { return state & ~0x18; }
}
