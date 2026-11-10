#pragma once
#include <Windows.h>
#include <filesystem>
#include <string>
namespace optishade::diagnostics {
inline std::filesystem::path HelperPath(const std::filesystem::path& component) { return component.parent_path()/L"OptiShadeData"/L"Tools"/L"OptiShade-Troubleshooter.exe"; }
inline void Start(const std::filesystem::path& exe, const std::filesystem::path& component) {
    // The launcher supports arbitrary selected game executables. Keep the
    // automatic monitor game-neutral too; restricting it to simulator names
    // prevented other DLSS-G titles from producing current-session evidence.
    if(exe.empty()||component.empty())return;
    const auto tool=HelperPath(component);
    if(GetFileAttributesW(tool.c_str())==INVALID_FILE_ATTRIBUTES){OutputDebugStringW(L"OptiShade auto diagnostics: helper absent\n");return;}
    FILETIME birth{},exit{},kernel{},user{};if(!GetProcessTimes(GetCurrentProcess(),&birth,&exit,&kernel,&user))return;
    ULARGE_INTEGER stamp{};stamp.LowPart=birth.dwLowDateTime;stamp.HighPart=birth.dwHighDateTime;
    std::wstring command=L"\""+tool.wstring()+L"\" --auto-watch "+std::to_wstring(GetCurrentProcessId())+L" "+std::to_wstring(stamp.QuadPart)+L" \""+exe.wstring()+L"\"";
    STARTUPINFOW start{};start.cb=sizeof(start);start.dwFlags=STARTF_USESHOWWINDOW;start.wShowWindow=SW_HIDE;
    PROCESS_INFORMATION process{};
    // Called from the existing initialisation worker, after DllMain has returned.
    // No waiting on the monitor, no render-thread dump work, no inherited handles.
    if(CreateProcessW(tool.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW|BELOW_NORMAL_PRIORITY_CLASS,nullptr,tool.parent_path().c_str(),&start,&process)){
        CloseHandle(process.hThread);CloseHandle(process.hProcess);
    }else OutputDebugStringW(L"OptiShade auto diagnostics: helper launch failed\n");
}
}
