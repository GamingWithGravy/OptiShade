#pragma once
#include <string_view>
#include <optional>
namespace optishade::taa {
inline bool NativeMsfsObserver(std::wstring_view name,std::string_view version) {
    if(version.find("-beta")==std::string_view::npos)return false;
    const auto equal=[&](std::wstring_view expected) {
        if(name.size()!=expected.size())return false;
        for(size_t i=0;i<name.size();++i){auto c=name[i];if(c>=L'A'&&c<=L'Z')c+=L'a'-L'A';if(c!=expected[i])return false;}
        return true;
    };
    return equal(L"flightsimulator.exe")||equal(L"flightsimulator2024.exe");
}
// A route-authorized external FG observer also needs the producer's restorable
// state. This does not permit initialization/capability overrides or FG takeover.
inline bool NativeStateCapture(bool eligible,bool externalProvider,bool externalObserver) {
    return eligible && (!externalProvider || externalObserver);
}
// Capture restorable game state when the selected route exposes the native
// observer. Explicit user overrides remain authoritative; unrelated games
// retain their existing default policy.
inline bool NativeTrackingPolicy(std::optional<bool> configured,bool nativeObserver) {
    return configured.value_or(nativeObserver);
}
// Independent native-FG/TAA observation is not an OptiScaler FG takeover.
// Preserve external-provider bypass; adding that observer needs a separate path
// which does not install initialization/capability overrides.
inline bool AttachTaaTags(bool managedTagInput,bool nativeMsfsObserver,bool externalProvider) {
    return !externalProvider&&(managedTagInput||nativeMsfsObserver);
}
}
