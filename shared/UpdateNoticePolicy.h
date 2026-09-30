#pragma once
#include <json.hpp>
#include <array>
#include <optional>
#include <regex>
#include <string>

namespace optishade::update_notice {
struct Version { std::array<int,4> core{}; bool beta=false; int revision=0; };
inline std::optional<Version> Parse(const std::string& text) {
    static const std::regex format(R"(^v?(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?(-beta(?:[.-]?(\d+))?)?$)");
    std::smatch match;
    if (text.size()>64 || !std::regex_match(text,match,format)) return std::nullopt;
    try {
        Version v;
        for(int i=0;i<4;++i) v.core[i]=match[i+1].matched?std::stoi(match[i+1]):0;
        v.beta=match[5].matched; v.revision=match[6].matched?std::stoi(match[6]):0;
        return v;
    } catch (...) { return std::nullopt; }
}
// This is a read-only notice. Installation remains the manager's separately
// verified, explicitly selected operation; beta never falls back to stable.
inline std::optional<bool> Available(const std::string& body,const std::string& currentText) {
    const auto current=Parse(currentText);
    if(!current || body.size()>262144) return std::nullopt;
    try {
        auto feed=nlohmann::json::parse(body);
        if(feed.is_object()) feed=nlohmann::json::array({feed});
        if(!feed.is_array() || feed.size()>1000) return std::nullopt;
        bool available=false;
        for(const auto& release:feed) {
            if(!release.is_object() || !release.contains("draft") || !release["draft"].is_boolean() ||
                release["draft"].get<bool>() || !release.contains("prerelease") || !release["prerelease"].is_boolean() ||
                !release.contains("tag_name") || !release["tag_name"].is_string()) continue;
            const auto version=Parse(release["tag_name"].get<std::string>());
            if(!version || version->beta!=current->beta || release["prerelease"].get<bool>()!=version->beta) continue;
            available |= version->core>current->core ||
                (version->core==current->core && version->beta && version->revision>current->revision);
        }
        return available;
    } catch (...) { return std::nullopt; }
}
}
