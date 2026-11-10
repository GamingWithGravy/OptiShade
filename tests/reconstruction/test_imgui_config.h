// Headless test configuration only. Preserve all layout-affecting options from
// the pinned ImGui configuration, using its embedded STB font builder on Linux.
#pragma once
#include <imgui/imconfig.h>
#undef IMGUI_ENABLE_FREETYPE
#define IMGUI_ENABLE_STB_TRUETYPE
#define IMGUI_DISABLE_DEFAULT_SHELL_FUNCTIONS
