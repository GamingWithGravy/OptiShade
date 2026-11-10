#pragma once
#include <Windows.h>
#include <string>
#include <iterator>
#include <atomic>
#include <filesystem>
#include <cstdint>
#include <cwchar>
namespace optishade::optimfg {
inline bool ComponentInstalled() {
        wchar_t image[32768]{};
        const DWORD length = GetModuleFileNameW(nullptr, image, static_cast<DWORD>(std::size(image)));
        if (!length || length >= std::size(image)) return false;
        std::wstring path(image, length);
        const auto slash = path.find_last_of(L"\\/");
        if (slash == std::wstring::npos) return false;
        path.resize(slash + 1);
        path += L"OptiShadeData\\OptiMFG\\Runtime\\OptiMFG_Live.exe";
        const DWORD attributes = GetFileAttributesW(path.c_str());
        return attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY);
    }
// The game's own attempt to start OptiMFG_Live.exe, for the menu's
// not-connected explanation: whether it ran and the Windows error if it failed.
inline std::atomic<bool> controllerStartAttempted{false};
inline std::atomic<unsigned long> controllerStartError{0};
inline std::wstring ComponentPath(const wchar_t* relative) {
    wchar_t image[32768]{};
    const DWORD length=GetModuleFileNameW(nullptr,image,static_cast<DWORD>(std::size(image)));
    if(!length||length>=std::size(image))return {};
    std::wstring path(image,length);const auto slash=path.find_last_of(L"\\/");
    if(slash==std::wstring::npos)return {};
    path.resize(slash+1);return path+relative;
}
// The component folder is there but its EXE is gone: usually antivirus removed it.
inline bool ComponentExecutableMissing() {
    const auto folder=ComponentPath(L"OptiShadeData\\OptiMFG\\Runtime");
    const DWORD attributes=folder.empty()?INVALID_FILE_ATTRIBUTES:GetFileAttributesW(folder.c_str());
    return attributes!=INVALID_FILE_ATTRIBUTES&&(attributes&FILE_ATTRIBUTE_DIRECTORY)&&!ComponentInstalled();
}
inline bool StartWithGameDisabled() {
    const auto marker=ComponentPath(L"OptiShadeData\\OptiMFG\\start-with-game.disabled");
    return !marker.empty()&&GetFileAttributesW(marker.c_str())!=INVALID_FILE_ATTRIBUTES;
}
// Only Microsoft Flight Simulator starts OptiMFG by itself (StartControllerOnPresent).
inline bool StartsWithThisGame() {
    wchar_t image[32768]{};const auto count=GetModuleFileNameW(nullptr,image,static_cast<DWORD>(std::size(image)));
    if(!count||count>=std::size(image))return false;
    const auto leaf=std::filesystem::path(image).filename().wstring();
    return !_wcsicmp(leaf.c_str(),L"FlightSimulator2024.exe")||!_wcsicmp(leaf.c_str(),L"FlightSimulator.exe");
}


// Called from a real Present, never DllMain. Only an installed MSFS component
// starts a child; no logon task, service, polling process or elevation verb.
inline DWORD WINAPI StartControllerWorker(void* module) {
    try {
    wchar_t image[32768]{};
    const DWORD count=GetModuleFileNameW(nullptr,image,static_cast<DWORD>(std::size(image)));
    if(count&&count<std::size(image)) {
        const auto root=std::filesystem::path(image).parent_path();
        const auto executable=root/L"OptiShadeData/OptiMFG/Runtime/OptiMFG_Live.exe";
        const auto disabled=root/L"OptiShadeData/OptiMFG/start-with-game.disabled";
        if(GetFileAttributesW(disabled.c_str())==INVALID_FILE_ATTRIBUTES&&ComponentInstalled()) {
            FILETIME born{},end{},kernel{},user{};
            if(GetProcessTimes(GetCurrentProcess(),&born,&end,&kernel,&user)) {
                const auto birth=(uint64_t(born.dwHighDateTime)<<32)|born.dwLowDateTime;
                std::wstring args=L"\""+executable.wstring()+L"\" --tray --game-pid "+std::to_wstring(GetCurrentProcessId())+L" --game-birth "+std::to_wstring(birth);
                STARTUPINFOW si{};si.cb=sizeof(si);si.dwFlags=STARTF_USESHOWWINDOW;si.wShowWindow=SW_HIDE;
                PROCESS_INFORMATION child{};
                controllerStartAttempted=true;
                // Absolute application path, no inherited handles, no waiting on child.
                if(CreateProcessW(executable.c_str(),args.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,executable.parent_path().c_str(),&si,&child)) {
                    CloseHandle(child.hThread);CloseHandle(child.hProcess);
                } else {
                    controllerStartError=GetLastError();
                    wchar_t message[160]{};swprintf_s(message,L"OptiMFG game-triggered start failed: Windows error %lu (no elevation requested).\n",controllerStartError.load());OutputDebugStringW(message);
                }
            }
        }
    }
    } catch(...) { OutputDebugStringW(L"OptiMFG automatic launch failed; manual start remains available.\n"); }
    FreeLibraryAndExitThread(static_cast<HMODULE>(module),0);
}
inline void StartControllerOnPresent() noexcept {
    try {
    static std::atomic<bool> attempted{false};
    if(attempted.exchange(true))return;
    wchar_t image[32768]{};auto count=GetModuleFileNameW(nullptr,image,static_cast<DWORD>(std::size(image)));
    if(!count||count>=std::size(image))return;
    const auto leaf=std::filesystem::path(image).filename().wstring();
    if(_wcsicmp(leaf.c_str(),L"FlightSimulator2024.exe")&&_wcsicmp(leaf.c_str(),L"FlightSimulator.exe"))return;
    if(!ComponentInstalled())return;
    HMODULE self{};
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(&StartControllerWorker),&self))return;
    auto thread=CreateThread(nullptr,0,StartControllerWorker,self,0,nullptr);
    if(thread)CloseHandle(thread);else FreeLibrary(self);
    } catch(...) { OutputDebugStringW(L"OptiMFG automatic launch scheduling failed.\n"); }
}
}
