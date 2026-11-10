#pragma once
#include <optional>
#include <tuple>
#include <string>
#include <sstream>
#include <iomanip>
#include <locale>
#include <type_traits>

namespace optishade::menu_settings {
// Only menu preferences belong to this preview. Discard never touches a
// renderer/provider/effects draft, and Save never serializes those settings.
template<class T> auto Optional(const T& value) {
    using Value=typename T::value_type;
    return value.has_value()?std::optional<Value>(value.value()):std::optional<Value>{};
}
template<class C> auto Fields(C& c) {
    return std::tie(c.ShortcutKey,c.BackupShortcutKey,c.FpsShortcutKey,c.FpsCycleShortcutKey,
        c.FGShortcutKey,c.DlssNrToggleKey,c.PresetHotSwapKey,c.SnapshotKey,c.MenuPhysicalNavigationKey,
        c.MenuScale,c.MenuAccentColorR,c.MenuAccentColorG,c.MenuAccentColorB,c.MenuBGColorA);
}
template<class C> auto Capture(C& c) {
    return std::apply([](const auto&... field){return std::make_tuple(Optional(field)...);},Fields(c));
}
template<class Ini,class T> void WriteValue(Ini& ini,const char* section,const char* key,const T& field) {
    auto value=Optional(field);
    if(!value){ini.SetValue(section,key,"auto");return;}
    std::ostringstream text;text.imbue(std::locale::classic());text<<std::setprecision(9)<<std::boolalpha<<*value;
    ini.SetValue(section,key,text.str().c_str());
}
template<class Ini,class C> void Write(Ini& ini,C& c) {
    WriteValue(ini,"Menu","ShortcutKey",c.ShortcutKey);
    WriteValue(ini,"Menu","BackupShortcutKey",c.BackupShortcutKey);
    WriteValue(ini,"Menu","FpsShortcutKey",c.FpsShortcutKey);
    WriteValue(ini,"Menu","FpsCycleShortcutKey",c.FpsCycleShortcutKey);
    WriteValue(ini,"Menu","FGShortcutKey",c.FGShortcutKey);
    WriteValue(ini,"DlssNr","ToggleKey",c.DlssNrToggleKey);
    WriteValue(ini,"Menu","PresetHotSwapKey",c.PresetHotSwapKey);
    WriteValue(ini,"Menu","SnapshotKey",c.SnapshotKey);
    WriteValue(ini,"Menu","PhysicalNavigationKey",c.MenuPhysicalNavigationKey);
    WriteValue(ini,"Menu","Scale",c.MenuScale);
    WriteValue(ini,"Menu","AccentColorR",c.MenuAccentColorR);
    WriteValue(ini,"Menu","AccentColorG",c.MenuAccentColorG);
    WriteValue(ini,"Menu","AccentColorB",c.MenuAccentColorB);
    WriteValue(ini,"Menu","BGColorA",c.MenuBGColorA);
}
template<class C> class Draft {
    using Snapshot=decltype(Capture(std::declval<C&>()));
    std::optional<Snapshot> baseline;
    std::optional<Snapshot> lastObserved;
public:
    std::string feedback;
    void Begin(C& c){auto current=Capture(c);if(!baseline)baseline=current;if(lastObserved&&*lastObserved!=current)feedback.clear();lastObserved=current;}
    bool Dirty(C& c)const{return baseline&&*baseline!=Capture(c);}
    void Discard(C& c){if(baseline)Fields(c)=*baseline;lastObserved=Capture(c);feedback="Menu preferences and shortcuts restored.";}
    template<class Save> bool Commit(C& c,Save save){
        if(!save()){feedback="Could not save menu settings. Your changes are still pending; retry Save.";return false;}
        baseline=Capture(c);lastObserved=baseline;feedback="Menu preferences and shortcuts saved.";return true;
    }
};
}
