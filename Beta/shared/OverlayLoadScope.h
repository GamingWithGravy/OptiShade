#pragma once
#include <string_view>
namespace optishade::loader {
struct Scope {
    bool& active;
    explicit Scope(bool& value) : active(value) { active=true; }
    ~Scope() { active=false; }
    Scope(const Scope&)=delete;
    Scope& operator=(const Scope&)=delete;
};
inline bool WarmDxgi(std::wstring_view executable) {
    constexpr std::wstring_view xp=L"x-plane.exe";
    if(executable.size()!=xp.size()) return true;
    for(size_t i=0;i<xp.size();++i) {
        auto c=executable[i]; if(c>=L'A'&&c<=L'Z')c+=L'a'-L'A';
        if(c!=xp[i])return true;
    }
    // Native Vulkan presentation does not need synthetic DXGI factory calls
    // from the overlay loader. Actual game/overlay DXGI calls remain intact.
    return false;
}
}
