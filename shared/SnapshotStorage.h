// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include <windows.h>
#include <shlobj.h>
#include <filesystem>
#include <fstream>
#include <bcrypt.h>
#include <vector>
#include <stdexcept>
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "bcrypt.lib")
namespace optishade::snapshot {
inline std::filesystem::path known(REFKNOWNFOLDERID id) {
 PWSTR value=nullptr;
 if(FAILED(SHGetKnownFolderPath(id,0,nullptr,&value)))throw std::runtime_error("Windows folder is unavailable");
 std::filesystem::path path(value);CoTaskMemFree(value);return path;
}
inline std::filesystem::path receipts(){return known(FOLDERID_LocalAppData)/L"OptiShade-SnapShot";}
inline bool safe(const std::filesystem::path& path){
 if(!path.is_absolute()||path!=path.lexically_normal())return false;
 for(auto p=path;!p.empty();){auto attrs=GetFileAttributesW(p.c_str());if(attrs!=INVALID_FILE_ATTRIBUTES&&(attrs&FILE_ATTRIBUTE_REPARSE_POINT))return false;auto parent=p.parent_path();if(parent==p)break;p=parent;}
 return true;
}
inline std::string hash(const std::filesystem::path& path){
 BCRYPT_ALG_HANDLE algorithm=nullptr;BCRYPT_HASH_HANDLE handle=nullptr;
 if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)return {};
 DWORD size=0,got=0;BCryptGetProperty(algorithm,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&size),sizeof(size),&got,0);
 std::vector<UCHAR> object(size);UCHAR digest[32]{};std::string result;
 if(BCryptCreateHash(algorithm,&handle,object.data(),size,nullptr,0,0)>=0){
  std::ifstream in(path,std::ios::binary);char buffer[65536];bool ok=in.is_open();
  while(ok&&in){in.read(buffer,sizeof(buffer));if(in.gcount()&&BCryptHashData(handle,reinterpret_cast<PUCHAR>(buffer),static_cast<ULONG>(in.gcount()),0)<0)ok=false;}
  if(ok&&in.eof()&&BCryptFinishHash(handle,digest,sizeof(digest),0)>=0){const char* hex="0123456789abcdef";for(auto b:digest){result+=hex[b>>4];result+=hex[b&15];}}
  BCryptDestroyHash(handle);
 }
 BCryptCloseAlgorithmProvider(algorithm,0);return result;
}
inline std::filesystem::path folder(const std::string& parent){
 auto p=std::filesystem::u8path(parent).lexically_normal();
 if(p.filename()!=L"Optishade Snapshots")p/=L"Optishade Snapshots";
 if(!safe(p))throw std::runtime_error("Choose an absolute, non-linked snapshot folder");
 return p;
}
inline std::wstring unique_name(){
 GUID id{};if(FAILED(CoCreateGuid(&id)))throw std::runtime_error("Cannot create snapshot name");
 wchar_t text[40]{};StringFromGUID2(id,text,40);
 SYSTEMTIME t{};GetLocalTime(&t);wchar_t date[40]{};
 swprintf_s(date,L"OptiShade-%04u%02u%02u-%02u%02u%02u-",t.wYear,t.wMonth,t.wDay,t.wHour,t.wMinute,t.wSecond);
 return std::wstring(date)+text+L".png";
}
// A receipt records exactly one file, never permission to remove a whole folder.
inline bool receipt(const std::filesystem::path& file){
 try {auto root=receipts();if(!safe(root)||!safe(file))return false;std::filesystem::create_directories(root);
 auto digest=hash(file);if(digest.empty())return false;
 auto target=root/(file.stem().wstring()+L".txt");
 std::ofstream out(target,std::ios::binary|std::ios::trunc);
 out<<file.u8string()<<'\n'<<std::filesystem::file_size(file)<<'\n'<<digest<<'\n';out.flush();return out.good();
 }catch(...){return false;}
}
}
