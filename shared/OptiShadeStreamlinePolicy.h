#pragma once
#include <string_view>
#include <sl.h>
namespace OptiShadeStreamlinePolicy {
// Native MSFS 2020 only. Do not change MSFS 2024 or our separate FG runtime.
inline bool UseGamePlugins(std::wstring_view name) {
    constexpr std::wstring_view expected = L"flightsimulator.exe";
    if (name.size() != expected.size()) return false;
    for (size_t i = 0; i < name.size(); ++i) {
        auto c = name[i];
        if (c >= L'A' && c <= L'Z') c += L'a' - L'A';
        if (c != expected[i]) return false;
    }
    return true;
}
inline bool ApplyNativePolicy(std::wstring_view name, unsigned major, unsigned minor, sl::Preferences& pref) {
    // Apply only to the legacy interposer family seen in the crash reports.
    if (!UseGamePlugins(name) || major != 2 || minor > 2) return false;
    pref.flags &= ~(sl::PreferenceFlags::eAllowOTA | sl::PreferenceFlags::eLoadDownloadedPlugins);
    return true;
}
}
