#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <locale>
#include <optional>
#include <sstream>
#include <string>

namespace optishade::menu_geometry
{
struct Rect { float x = 0, y = 0, width = 0, height = 0; };
struct View { float width = 0, height = 0; };
struct Geometry { Rect rect; View view; float scale = 1; };

inline bool ValidView(View v)
{
    return std::isfinite(v.width) && std::isfinite(v.height) &&
        v.width >= 1 && v.height >= 1 && v.width <= 65536 && v.height <= 65536;
}
inline bool Valid(const Geometry& g)
{
    return ValidView(g.view) && std::isfinite(g.scale) && g.scale >= .5f && g.scale <= 2.f &&
        std::isfinite(g.rect.x) && std::isfinite(g.rect.y) &&
        std::abs(g.rect.x) <= 1000000 && std::abs(g.rect.y) <= 1000000 &&
        std::isfinite(g.rect.width) && std::isfinite(g.rect.height) &&
        g.rect.width >= 1 && g.rect.height >= 1 && g.rect.width <= 65536 && g.rect.height <= 65536;
}
inline bool Same(Rect a, Rect b)
{
    return std::abs(a.x-b.x) < .75f && std::abs(a.y-b.y) < .75f &&
        std::abs(a.width-b.width) < .75f && std::abs(a.height-b.height) < .75f;
}
inline std::optional<Geometry> Parse(const std::string& text)
{
    if (text.size() > 256) return {};
    std::istringstream input(text);
    input.imbue(std::locale::classic());
    Geometry g;
    if (!(input >> g.rect.x >> g.rect.y >> g.rect.width >> g.rect.height >>
        g.view.width >> g.view.height >> g.scale)) return {};
    input >> std::ws;
    return input.eof() && Valid(g) ? std::optional<Geometry>(g) : std::nullopt;
}
inline std::string Serialize(const Geometry& g)
{
    if (!Valid(g)) return {};
    std::ostringstream output;
    output.imbue(std::locale::classic());
    output << std::setprecision(9) << g.rect.x << ' ' << g.rect.y << ' ' << g.rect.width << ' ' <<
        g.rect.height << ' ' << g.view.width << ' ' << g.view.height << ' ' << g.scale;
    return output.str();
}
inline bool ValidContext(const std::string& key)
{
    return !key.empty() && key.size() <= 64 && std::all_of(key.begin(), key.end(), [](unsigned char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-';
    });
}

class Contexts
{
    struct Slot { uintptr_t handle = 0; std::string base; unsigned ordinal = 0; };
    std::array<Slot, 16> slots {};
public:
    template<class IsLive> std::string Select(const std::string& base, uintptr_t handle, IsLive isLive)
    {
        if (!handle || !ValidContext(base)) return {};
        for (const auto& slot : slots)
            if (slot.handle == handle && slot.base == base) return base + "." + std::to_string(slot.ordinal);
        for (unsigned ordinal = 0; ordinal < slots.size(); ++ordinal) {
            bool used = false;
            for (const auto& slot : slots)
                used |= slot.base == base && slot.ordinal == ordinal && isLive(slot.handle);
            if (used) continue;
            for (auto& slot : slots) {
                if (slot.handle && isLive(slot.handle)) continue;
                slot = {handle, base, ordinal};
                return base + "." + std::to_string(ordinal);
            }
            break;
        }
        return {};
    }
};
inline Rect Available(View v) { return {std::min(15.f, v.width/4), std::min(15.f, v.height/4),
    std::max(1.f, v.width-2*std::min(15.f, v.width/4)), std::max(1.f, v.height-2*std::min(15.f, v.height/4))}; }
inline Rect Fit(const std::optional<Geometry>& preferred, View view, float scale)
{
    const auto area = Available(view);
    Rect r {area.x, area.y, 980.f*scale, 740.f*scale};
    if (preferred && Valid(*preferred)) {
        const float ratio = scale/preferred->scale;
        r = {preferred->rect.x*ratio, preferred->rect.y*ratio,
            preferred->rect.width*ratio, preferred->rect.height*ratio};
    }
    r.width = std::clamp(r.width, std::min(680.f*scale, area.width), std::min(1600.f*scale, area.width));
    r.height = std::clamp(r.height, std::min(420.f*scale, area.height), area.height);
    r.x = std::clamp(r.x, area.x, area.x+area.width-r.width);
    r.y = std::clamp(r.y, area.y, area.y+area.height-r.height);
    return r;
}

// The preferred rectangle is changed ONLY by a deliberate edit. A small mirror,
// fullscreen transition or DPI clamp is temporary and cannot erase the large view.
class State
{
    std::optional<Geometry> preferred;
    View lastView {};
    float lastScale = 0;
    Rect shown {};
    bool initialized = false, dirty = false;
    uint64_t changedAt = 0, attemptedAt = 0;
public:
    void Load(std::optional<Geometry> value) { *this = {}; preferred = value && Valid(*value) ? value : std::nullopt; }
    const std::optional<Geometry>& Preferred() const { return preferred; }
    bool Prepare(View view, float scale, Rect& output)
    {
        if (!ValidView(view) || !std::isfinite(scale) || scale < .5f || scale > 2) return false;
        if (initialized && view.width == lastView.width && view.height == lastView.height && scale == lastScale) return false;
        shown = output = Fit(preferred, view, scale);
        initialized = true; lastView = view; lastScale = scale;
        return true;
    }
    void Observe(Rect actual, bool editing, uint64_t now)
    {
        Geometry value {actual, lastView, lastScale};
        if (!initialized || !editing || !Valid(value) || Same(actual, shown)) return;
        preferred = value; shown = actual; dirty = true; changedAt = now;
    }
    bool Due(uint64_t now, bool editing, bool boundary = false) const
    {
        // Failed writes retry at most once per five seconds; never one IO attempt/frame.
        return dirty && preferred && (!attemptedAt || now-attemptedAt >= 5000) &&
            (boundary || (!editing && now-changedAt >= 750));
    }
    void Saved(uint64_t now, bool success) { attemptedAt = success ? 0 : now; if (success) dirty = false; }
};
}
