#pragma once

#include "MenuGeometry.h"
#include "AtomicConfigWrite.h"
#include "../optiscaler/external/simpleini/SimpleIni.h"

namespace optishade::menu_geometry
{
inline std::optional<Geometry> LoadIni(CSimpleIniA& ini, const std::string& context)
{
    if (!ValidContext(context) || std::string(ini.GetValue("MenuGeometry", "Schema", "")) != "1") return {};
    return Parse(ini.GetValue("MenuGeometry", context.c_str(), ""));
}

inline bool SaveIni(CSimpleIniA& memory, const std::filesystem::path& path, const std::string& context, const Geometry& geometry)
{
    if (!ValidContext(context) || !Valid(geometry)) return false;
    // Read current disk values, not live tuning: moving the UI must not press
    // "Save settings" implicitly or discard an editor's unrelated changes.
    CSimpleIniA current;
    if (current.LoadFile(path.c_str()) < 0) {
        const DWORD attributes = GetFileAttributesW(path.c_str());
        const DWORD error = GetLastError();
        if (attributes != INVALID_FILE_ATTRIBUTES || (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND)) return false;
    }
    const std::string schema = current.GetValue("MenuGeometry", "Schema", "");
    if (!schema.empty() && schema != "1") return false;
    CSimpleIniA::TNamesDepend keys;
    current.GetAllKeys("MenuGeometry", keys);
    if (!current.GetValue("MenuGeometry", context.c_str()) && keys.size() >= 17) return false;
    const auto geometryText = Serialize(geometry);
    current.SetValue("MenuGeometry", "Schema", "1");
    current.SetValue("MenuGeometry", context.c_str(), geometryText.c_str());
    std::string fileText;
    if (current.Save(fileText) < 0 || !AtomicConfigWrite(path, fileText)) return false;
    memory.SetValue("MenuGeometry", "Schema", "1");
    memory.SetValue("MenuGeometry", context.c_str(), geometryText.c_str());
    return true;
}
}
