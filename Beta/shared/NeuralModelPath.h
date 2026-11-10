#pragma once
#include <filesystem>
#include <optional>
namespace optishade::model_path {
// Installer-selected model beside the actual game is authoritative. Never
// recursively select a model from backups, staging or an unrelated component.
inline std::optional<std::filesystem::path> Select(const std::filesystem::path& game,const std::filesystem::path& component){
 for(const auto& directory:{game,component}){std::error_code ec;auto path=directory/L"nvngx_dlssnr.dll";if(std::filesystem::is_regular_file(path,ec)&&!ec)return path;}
 return std::nullopt;
}
}
