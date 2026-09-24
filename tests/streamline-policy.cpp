#include <cassert>
#include <sl.h>
#include "../shared/OptiShadeStreamlinePolicy.h"
int main() {
    using namespace OptiShadeStreamlinePolicy;
    assert(UseGamePlugins(L"FlightSimulator.exe"));
    assert(UseGamePlugins(L"FLIGHTSIMULATOR.EXE"));
    assert(!UseGamePlugins(L"FlightSimulator2024.exe"));
    assert(!UseGamePlugins(L"FlightSimulator.exe.other"));
    assert(!UseGamePlugins(L"OtherGame.exe"));
    sl::Preferences pref;
    const wchar_t* paths[] = {L"game-plugins"};
    sl::Feature features[] = {sl::kFeatureDLSS_G};
    pref.pathsToPlugins=paths; pref.numPathsToPlugins=1;
    pref.featuresToLoad=features; pref.numFeaturesToLoad=1;
    auto original = pref.flags;
    assert(!ApplyNativePolicy(L"FlightSimulator2024.exe",2,2,pref));
    assert(!ApplyNativePolicy(L"FlightSimulator.exe",2,14,pref));
    assert(pref.flags==original);
    assert(ApplyNativePolicy(L"FlightSimulator.exe",2,2,pref));
    assert((uint64_t(pref.flags) & ((1 << 3) | (1 << 6))) == 0);
    assert((uint64_t(pref.flags) | ((1 << 3) | (1 << 6))) == uint64_t(original));
    assert(pref.pathsToPlugins==paths && pref.numPathsToPlugins==1);
    assert(pref.featuresToLoad==features && pref.numFeaturesToLoad==1);
}
