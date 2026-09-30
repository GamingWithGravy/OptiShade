#pragma once

#include <Windows.h>
#include <algorithm>
#include <atomic>
#include <filesystem>
#include <string>

namespace optishade
{
// Same-directory replacement: a failed/partial save never truncates the old INI.
// The caller serializes access to its configuration object.
inline bool AtomicConfigWrite(const std::filesystem::path& path, const std::string& data)
{
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES &&
        (attributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_READONLY))) return false;
    static std::atomic<unsigned long> sequence {0};
    auto temporary = path;
    temporary += L".save-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(++sequence) + L".tmp";
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    bool ok = true;
    for (size_t done = 0; done < data.size();) {
        DWORD written = 0;
        const DWORD count = static_cast<DWORD>(std::min<size_t>(data.size()-done, 1024*1024));
        if (!WriteFile(file, data.data()+done, count, &written, nullptr) || !written) { ok = false; break; }
        done += written;
    }
    if (ok) ok = FlushFileBuffers(file) != FALSE;
    if (!CloseHandle(file)) ok = false;
    if (ok) {
        if (attributes != INVALID_FILE_ATTRIBUTES)
            ok = ReplaceFileW(path.c_str(), temporary.c_str(), nullptr, 0, nullptr, nullptr) != FALSE;
        else
            ok = MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_WRITE_THROUGH) != FALSE;
    }
    if (!ok) DeleteFileW(temporary.c_str());
    return ok;
}
}
