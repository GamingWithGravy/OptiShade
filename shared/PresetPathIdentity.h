#pragma once
#include <filesystem>
#include <cwchar>
namespace optishade::hotswap {
inline bool same_preset(const std::filesystem::path& a, const std::filesystem::path& b,
                        const std::filesystem::path& base) {
 if(a.empty() || b.empty()) return false;
 auto absolute=[&](const auto& p){return (p.is_relative()?base/p:p).lexically_normal();};
 auto left=absolute(a), right=absolute(b);
 std::error_code ec;
 // Resolve junctions, symlinks and alternate spellings of the same file.
 if(std::filesystem::equivalent(left,right,ec) && !ec) return true;
 return _wcsicmp(left.make_preferred().c_str(),right.make_preferred().c_str())==0;
}
inline std::filesystem::path next_preset(const std::filesystem::path& current,
 const std::filesystem::path& main, const std::filesystem::path& alternate,
 const std::filesystem::path& base) {
 return same_preset(current,alternate,base)?main:alternate;
}
}
