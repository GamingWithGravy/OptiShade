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
inline std::string utf8(const std::filesystem::path& p){const auto s=p.u8string();return {reinterpret_cast<const char*>(s.data()),s.size()};}
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
 if(!p.is_absolute())throw std::runtime_error("Snapshot game folder must be absolute");
 // Resolve the existing game directory, including Xbox package aliases.
 HANDLE directory=CreateFileW(p.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr);
 if(directory==INVALID_HANDLE_VALUE)throw std::runtime_error("Cannot open snapshot game folder");
 std::vector<wchar_t> target(32768);
 DWORD count=GetFinalPathNameByHandleW(directory,target.data(),static_cast<DWORD>(target.size()),FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
 CloseHandle(directory);
 if(!count||count>=target.size())throw std::runtime_error("Cannot resolve snapshot game folder");
 std::wstring resolved(target.data(),count);
 if(resolved.compare(0,8,L"\\\\?\\UNC\\")==0)resolved=L"\\\\"+resolved.substr(8);
 else if(resolved.compare(0,4,L"\\\\?\\")==0)resolved=resolved.substr(4);
 p=std::filesystem::path(resolved).lexically_normal();
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
struct Settings { std::filesystem::path parent; bool jpeg=false; int quality=90; };
inline Settings settings(const std::filesystem::path& game) {
 Settings value{game,false};const auto file=game/L"OptiShadeData"/L"Snapshot-settings.ini";
 if(!std::filesystem::exists(file))return value;
 if(!safe(file)||std::filesystem::file_size(file)>65536)throw std::runtime_error("Snapshot settings are invalid");
 wchar_t path[32768]{};GetPrivateProfileStringW(L"SnapShot",L"Directory",L"",path,32768,file.c_str());
 if(path[0])value.parent=path;
 value.jpeg=GetPrivateProfileIntW(L"SnapShot",L"JPEG",0,file.c_str())==1;
 const int quality=static_cast<int>(GetPrivateProfileIntW(L"SnapShot",L"JPEGQuality",90,file.c_str()));
 value.quality=(quality>=1&&quality<=100)?quality:90;
 return value;
}
inline void save_settings(const std::filesystem::path& game,const Settings& value) {
 // Validate the selected existing directory before saving a preference. Capture
 // validates again and still owns only individually receipted image files.
 if(value.quality<1||value.quality>100)throw std::runtime_error("JPEG quality must be between 1 and 100");
 (void)folder(utf8(value.parent));
 const auto file=game/L"OptiShadeData"/L"Snapshot-settings.ini";
 if(!safe(file))throw std::runtime_error("Snapshot settings location is linked");
 std::filesystem::create_directories(file.parent_path());
 auto temporary=file;temporary+=L"."+unique_name()+L".tmp";
 struct Cleanup {std::filesystem::path p;~Cleanup(){std::error_code ec;std::filesystem::remove(p,ec);}} cleanup{temporary};
 const std::wstring text=L"[SnapShot]\r\nDirectory="+value.parent.wstring()+L"\r\nJPEG="+(value.jpeg?L"1":L"0")+L"\r\nJPEGQuality="+std::to_wstring(value.quality)+L"\r\n";
 if(value.parent.wstring().find_first_of(L"\r\n")!=std::wstring::npos)throw std::runtime_error("Invalid snapshot directory");
 std::ofstream out(temporary,std::ios::binary);const wchar_t bom=0xFEFF;out.write(reinterpret_cast<const char*>(&bom),2);out.write(reinterpret_cast<const char*>(text.data()),text.size()*2);out.close();
 if(!out||!MoveFileExW(temporary.c_str(),file.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))throw std::runtime_error("Could not save snapshot settings");
}
// A receipt records exactly one file, never permission to remove a whole folder.
inline bool receipt(const std::filesystem::path& file,const std::filesystem::path& game={}){
 try {auto root=receipts();if(!safe(root)||!safe(file))return false;std::filesystem::create_directories(root);
 auto digest=hash(file);if(digest.empty())return false;
 auto target=root/(file.stem().wstring()+L".txt");
 const auto temporary=root/(file.stem().wstring()+L".pending");
 struct PendingRecord { std::filesystem::path path; ~PendingRecord(){std::error_code ec;std::filesystem::remove(path,ec);} } cleanup{temporary};
 std::ofstream out(temporary,std::ios::binary|std::ios::trunc);
 out<<utf8(file)<<'\n'<<std::filesystem::file_size(file)<<'\n'<<digest<<'\n';if(!game.empty())out<<utf8(folder(utf8(game)).parent_path())<<'\n';out.flush();out.close();
 if(!out)return false;
 // A partial record must never enter the uninstall catalogue.
 return MoveFileExW(temporary.c_str(),target.c_str(),MOVEFILE_WRITE_THROUGH)!=FALSE;
 }catch(...){return false;}
}
}
