#pragma once
#include <Windows.h>
#include <cwchar>
namespace optishade::xp12_provider {
// No global external-FG mode: exempt only the experiment's exact provider
// modules, only in XP12, only while its early-start helper is loaded.
inline bool Owned(HMODULE module){
 wchar_t exe[32768]{};if(!module||!GetModuleFileNameW(nullptr,exe,32768))return false;
 const auto slash=wcsrchr(exe,L'\\');if(_wcsicmp(slash?slash+1:exe,L"X-Plane.exe"))return false;
 const auto helper=GetModuleHandleW(L"OptiMFG_XP12Connection.dll");if(!helper)return false;
 using Owns=BOOL(WINAPI*)(HMODULE);
 const auto owns=reinterpret_cast<Owns>(GetProcAddress(helper,"OptiMFGXp12OwnsModuleV1"));
 return owns&&owns(module);
}
}
