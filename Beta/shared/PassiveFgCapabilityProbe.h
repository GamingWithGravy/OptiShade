#pragma once

// A passive probe for games where OptiShade intentionally keeps native DLSS-G
// controls disabled. It looks up the game's real GetState entry point, but does
// not call it or return it to the game. The caller can therefore report that a
// provider function exists without changing the game's existing fallback path.
namespace optishade::passive_fg {
template<class Result, class Resolve, class Observe>
bool ProbeStateFunction(Result success, Resolve&& resolve, Observe&& observe) {
    void* function = nullptr;
    const Result result = resolve(&function);
    const bool available = result == success && function != nullptr;
    observe(result, available);
    return available;
}
}
