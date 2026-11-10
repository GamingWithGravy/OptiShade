#pragma once
#include <cstdint>
#include <string>
#include <string_view>
#include <charconv>

namespace optishade::nr_source {
// OptiShade's own schema, not a mapping of undocumented RenoDX enum values.
inline constexpr uint32_t Schema=1;
enum class Policy { Auto, RequireNative, AllowCompatibility, Unknown };
inline Policy Decode(uint32_t version,std::string_view name) {
    if(version!=Schema)return Policy::Unknown;
    if(name=="auto")return Policy::Auto;
    if(name=="require-native")return Policy::RequireNative;
    if(name=="allow-compatibility")return Policy::AllowCompatibility;
    return Policy::Unknown;
}
inline const char* Name(Policy p) {
    switch(p){case Policy::Auto:return "Automatic";case Policy::RequireNative:return "Require native temporal inputs";
    case Policy::AllowCompatibility:return "Allow validated compatibility inputs";default:return "Unknown source policy; compatibility route suspended";}
}
inline bool AllowsEstimated(Policy p){return p==Policy::Auto||p==Policy::AllowCompatibility;}
inline bool AllowsTemporal(Policy p){return p!=Policy::Unknown;}
struct Settings {uint32_t version=Schema;std::string name="auto";bool migrated=false;};
template<class Ini> Settings Read(const Ini& ini) {
    Settings value;
    const char* version=ini.GetValue("DlssNr","SourcePolicySchema",nullptr);
    const char* name=ini.GetValue("DlssNr","SourcePolicy",nullptr);
    // R20-R22 wrote TaaFallback=false even while routing automatically. It
    // cannot reliably express user intent. Absent new keys migrate to Auto.
    if(!version&&!name){value.migrated=true;return value;}
    value.name=name?name:"";value.version=UINT32_MAX;
    if(version){uint32_t parsed=0;std::string_view text(version);auto result=std::from_chars(text.data(),text.data()+text.size(),parsed);
        if(result.ec==std::errc()&&result.ptr==text.data()+text.size())value.version=parsed;}
    return value;
}
template<class Ini> void Write(Ini& ini,const Settings& value) {
    // Unknown/future schemas are preserved, never translated by guesswork.
    if(Decode(value.version,value.name)==Policy::Unknown)return;
    ini.SetValue("DlssNr","SourcePolicySchema",std::to_string(value.version).c_str());
    ini.SetValue("DlssNr","SourcePolicy",value.name.c_str());
    ini.Delete("DlssNr","TaaFallback");
}
}
