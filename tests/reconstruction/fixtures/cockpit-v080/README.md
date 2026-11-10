# Official cockpit panel test fixture

`status_panel.cpp`, `status.hpp` and `version.h` are unchanged from IFreemz/msfs2024-glass-cockpit-dlss-fix tag v0.8.0. MIT licence is included. `fixture.cpp` supplies synthetic state/setters, not the GPU correction. `host.cpp` tests the actual OptiShade ABI adapter against that official UI callback in an isolated executable. It does not load a game, install anything or invoke simulator GPU hooks.

From a Visual Studio developer shell at the repository root: `python tests/reconstruction/test_cockpit_controls.py`. Outputs remain under `test-results/cockpit-official-fixture/`.
