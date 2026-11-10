// OptiShade additions, GPL-3.0-or-later. Worker-thread driver inventory only.
#pragma once
#include "RenderingGpuPolicy.h"
#include <windows.h>
#include <winver.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
namespace optishade::gpu_probe {
struct Result {bool known=false;unsigned major=0,minor=0,family=0;std::string driver;};
inline std::string DriverIdentity(const std::wstring& cudaPath,const std::wstring& systemDirectory){
    const auto path=systemDirectory+L"\\version.dll";
    const auto module=LoadLibraryExW(path.c_str(),nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
    if(!module)return {};
    struct Release{HMODULE value;~Release(){FreeLibrary(value);}} release{module};
    using Size=DWORD(WINAPI*)(LPCWSTR,LPDWORD);
    using Info=BOOL(WINAPI*)(LPCWSTR,DWORD,DWORD,LPVOID);
    using Query=BOOL(WINAPI*)(LPCVOID,LPCWSTR,LPVOID*,PUINT);
    const auto size=reinterpret_cast<Size>(GetProcAddress(module,"GetFileVersionInfoSizeW"));
    const auto info=reinterpret_cast<Info>(GetProcAddress(module,"GetFileVersionInfoW"));
    const auto query=reinterpret_cast<Query>(GetProcAddress(module,"VerQueryValueW"));
    if(!size||!info||!query)return {};
    DWORD unused=0;const auto bytes=size(cudaPath.c_str(),&unused);
    if(!bytes||bytes>2u*1024*1024)return {};
    std::vector<unsigned char> data(bytes);
    if(!info(cudaPath.c_str(),0,bytes,data.data()))return {};
    VS_FIXEDFILEINFO* value=nullptr;UINT count=0;
    if(!query(data.data(),L"\\",reinterpret_cast<void**>(&value),&count)||!value||count<sizeof(*value)||value->dwSignature!=0xFEEF04BD)return {};
    return gpu_policy::DriverFileIdentity(HIWORD(value->dwFileVersionMS),LOWORD(value->dwFileVersionMS),
        HIWORD(value->dwFileVersionLS),LOWORD(value->dwFileVersionLS));
}
inline Result Query(uint64_t expectedLuid,const std::string& actualName){
    Result result;if(!expectedLuid)return result;
    wchar_t directory[MAX_PATH]{};const auto length=GetSystemDirectoryW(directory,MAX_PATH);
    if(!length||length>=MAX_PATH)return result;
    const std::wstring path=std::wstring(directory)+L"\\nvcuda.dll";
    const auto module=LoadLibraryExW(path.c_str(),nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
    if(!module)return result;
    struct Release{HMODULE value;~Release(){FreeLibrary(value);}} release{module};
    using Init=int(WINAPI*)(unsigned);using Count=int(WINAPI*)(int*);using Get=int(WINAPI*)(int*,int);
    using Luid=int(WINAPI*)(char*,unsigned*,int);using Attribute=int(WINAPI*)(int*,int,int);
    const auto init=reinterpret_cast<Init>(GetProcAddress(module,"cuInit"));
    const auto count=reinterpret_cast<Count>(GetProcAddress(module,"cuDeviceGetCount"));
    const auto get=reinterpret_cast<Get>(GetProcAddress(module,"cuDeviceGet"));
    const auto luid=reinterpret_cast<Luid>(GetProcAddress(module,"cuDeviceGetLuid"));
    const auto attribute=reinterpret_cast<Attribute>(GetProcAddress(module,"cuDeviceGetAttribute"));
    int total=0;if(!init||!count||!get||!luid||!attribute||init(0)||count(&total)||total<0||total>64)return result;
    unsigned matched=0;
    for(int ordinal=0;ordinal<total;++ordinal){
        int device=0,major=0,minor=0;unsigned node=0;char bytes[8]{};uint64_t identity=0;
        if(get(&device,ordinal)||luid(bytes,&node,device)||!node)continue;
        std::memcpy(&identity,bytes,sizeof(identity));if(identity!=expectedLuid)continue;
        if(++matched!=1||attribute(&major,75,device)||attribute(&minor,76,device)||major<=0||minor<0){result={};continue;}
        result.known=true;result.major=unsigned(major);result.minor=unsigned(minor);
        result.family=gpu_policy::Family(actualName,result.major,result.minor);
    }
    if(matched!=1)return {};
    result.driver=DriverIdentity(path,directory);
    return result;
}
}
