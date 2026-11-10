#include "../../Beta/reshade/source/input_press_latch.hpp"
#include <cassert>
#include <cstdio>

int main()
{
    using namespace reshade::input_press_latch;
    auto state = update(0, true);
    state = update(state, false);
    assert(pressed(state)); // A complete click between frames must survive.
    assert((state & 0x80) == 0); // Do not invent a held button.
    state = next_frame(state);
    assert(!pressed(state)); // One delivery only.
    state = update(state, true);
    assert(pressed(state));
    state = next_frame(state);
    state = update(state, true);
    assert(!pressed(state)); // OS auto-repeat is not another toggle.
    state = update(state, false);
    state = update(state, true);
    assert(pressed(state)); // A genuine second press still works.
    assert((next_frame(state) & 0x80) != 0);
    puts("PASS: short taps, release state, repeated holds and subsequent presses");
}
