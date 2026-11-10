#pragma once

#include <filesystem>
#include <fstream>
#include <string>
#include <string_view>

namespace optishade::build_display {

inline std::string ReadField(std::string_view json,std::string_view name){
    const std::string key="\""+std::string(name)+"\"";
    auto position=json.find(key);
    if(position==std::string_view::npos)return {};
    position=json.find(':',position+key.size());
    if(position==std::string_view::npos)return {};
    position=json.find('"',position+1);
    if(position==std::string_view::npos)return {};
    const auto end=json.find('"',position+1);
    if(end==std::string_view::npos)return {};
    return std::string(json.substr(position+1,end-position-1));
}

inline std::string Label(const std::filesystem::path& identityPath,std::string_view fallback){
    std::string json(64*1024,'\0');
    std::ifstream input(identityPath,std::ios::binary);
    if(input){
        input.read(json.data(),static_cast<std::streamsize>(json.size()));
        json.resize(static_cast<size_t>(input.gcount()));
    }else json.clear();

    std::string label(fallback);
    const auto version=ReadField(json,"Version");
    if(!version.empty()&&version.find_first_not_of("0123456789.")==std::string::npos){
        const auto channel=ReadField(json,"Channel");
        label=version+(channel.empty()?std::string{}:" "+channel);
    }

    const auto privateLabel=ReadField(json,"PrivateBuildLabel");
    constexpr std::string_view prefix="Rebuild R";
    if(privateLabel.starts_with(prefix)){
        const auto revision=std::string_view(privateLabel).substr(prefix.size());
        if(!revision.empty()&&revision.find_first_not_of("0123456789")==std::string_view::npos)
            label+=" / R"+std::string(revision);
    }
    return label;
}

} // namespace optishade::build_display
