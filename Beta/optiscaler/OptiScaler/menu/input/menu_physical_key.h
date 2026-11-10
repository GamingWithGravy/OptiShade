#pragma once

#include <cstdint>

namespace OptiInput
{
// Opt-in dedicated navigation cluster. All other bindings retain logical VK
// semantics. No physical identity can be inferred from GetAsyncKeyState.
inline unsigned NavigationMakeCode(int vk)
{
    switch (vk)
    {
    case 0x2d: return 0x52; // Insert
    case 0x24: return 0x47; // Home
    case 0x23: return 0x4f; // End
    case 0x2e: return 0x53; // Delete
    case 0x21: return 0x49; // Page Up
    case 0x22: return 0x51; // Page Down
    default: return 0;
    }
}

enum class PhysicalKeySource { None, Window, Raw, DirectInput };

struct MenuPhysicalKey
{
    int Binding = 0;
    PhysicalKeySource Source = PhysicalKeySource::None;
    bool Down = false;
    bool Pressed = false;
    bool Released = false;

    void Configure(int binding)
    {
        if (Binding != binding)
        {
            *this = {};
            Binding = binding;
        }
    }

    bool Matches(int vk, unsigned scan, bool e0, bool e1) const
    {
        return Binding != 0 && vk == Binding && scan == NavigationMakeCode(Binding) && e0 && !e1;
    }

    void Observe(int vk, unsigned scan, bool e0, bool e1, bool released, PhysicalKeySource source)
    {
        if (!Matches(vk, scan, e0, e1)) return;
        // One scan-aware source owns this binding for the focus session. This
        // avoids delayed duplicate WM/raw/DI edges, including a short tap that
        // completely finishes on one source before its duplicate is delivered.
        if (Source == PhysicalKeySource::None)
        {
            if (released) return;
            Source = source;
        }
        if (source != Source) return;
        if (released)
        {
            if (Down) Released = true;
            Down = false;
        }
        else
        {
            if (!Down) Pressed = true;
            Down = true;
        }
    }

    void EndFrame() { Pressed = false; Released = false; }
};
}
