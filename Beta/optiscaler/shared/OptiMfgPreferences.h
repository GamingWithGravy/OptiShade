#pragma once
#include <Windows.h>
#include <string>
namespace optishade::optimfg {
inline LONG LoadPreference(const std::wstring& path){
    if(path.empty())return -1;
    const LONG value=GetPrivateProfileIntW(L"OptiMFG",L"Request",-1,path.c_str());
    return value==-1||value==0||(value>=2&&value<=6)?value:-1;
}
inline bool SavePreference(const std::wstring& path,LONG value){
    if(path.empty()||(value!=-1&&value!=0&&(value<2||value>6)))return false;
    auto slash=path.find_last_of(L"\\/");if(slash==std::wstring::npos)return false;
    auto directory=path.substr(0,slash);
    if(!CreateDirectoryW(directory.c_str(),nullptr)&&GetLastError()!=ERROR_ALREADY_EXISTS)return false;
    if(!WritePrivateProfileStringW(L"OptiMFG",L"Request",std::to_wstring(value).c_str(),path.c_str()))return false;
    return LoadPreference(path)==value;
}
}
