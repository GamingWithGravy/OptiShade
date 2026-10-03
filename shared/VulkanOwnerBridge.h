#pragma once
// Called only in the effects DLL, after Win32 declarations. The game-local
// consumer is the authority; a title match cannot claim an effects runtime.
inline bool OptiShadeIsOwnedVulkanWindow(void* hwnd)
{
    wchar_t path[MAX_PATH]{};
    if(!GetModuleFileNameW(nullptr,path,MAX_PATH))return false;
    auto slash=wcsrchr(path,L'\\');if(!slash)return false;
    wcscpy_s(slash+1,MAX_PATH-(slash+1-path),L"dxgi.dll");
    auto module=GetModuleHandleW(path);
    auto owns=module ? reinterpret_cast<bool(*)(uint64_t)>(GetProcAddress(module,"OptiShadeVulkanOwnsWindow")) : nullptr;
    return owns && owns(reinterpret_cast<uint64_t>(hwnd));
}
