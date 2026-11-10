#include <windows.h>
#include <tlhelp32.h>
#include <nvapi.h>
#include <NvApiDriverSettings.h>
#include <nvapi_interface.h>
#include <array>
#include <filesystem>
#include <functional>
#include <string>
#include <iostream>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <stdexcept>

namespace omfg::driver {
struct Value {uint32_t id{},value{};bool local{};bool operator==(Value const&) const=default;};
struct Snapshot {std::wstring profile;std::array<Value,4> values;};
enum class Mode { Application, Off, X2, X3, X4, X5, X6 };
namespace fs = std::filesystem;
std::string Utf8(std::wstring const& text) {
    if (text.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (!n) throw std::runtime_error("Invalid UTF-16 text");
    std::string r(n, 0); WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), r.data(), n, nullptr, nullptr); return r;
}
std::wstring Wide(std::string const& text) {
    if (text.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (!n) throw std::runtime_error("Invalid UTF-8 text");
    std::wstring r(n, 0); MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), r.data(), n); return r;
}
std::string Json(std::string const& text) {
    std::string r = "\"";
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') { r += '\\'; r += static_cast<char>(c); }
        else if (c < 32) r += ' '; else r += static_cast<char>(c);
    }
    return r + '"';
}
static constexpr std::array<uint32_t,4> ids={NGX_DLSS_SR_OVERRIDE_ID,NGX_DLSS_SR_OVERRIDE_RENDER_PRESET_SELECTION_ID,NGX_DLSS_FG_OVERRIDE_ID,NGX_DLSS_FG_OVERRIDE_RENDER_PRESET_SELECTION_ID};
static void RequireClosed(std::wstring const& exe){
 HANDLE h=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);if(h==INVALID_HANDLE_VALUE)throw std::runtime_error("Cannot check game process state");
 PROCESSENTRY32W e{};e.dwSize=sizeof(e);bool found=false;
 if(!Process32FirstW(h,&e)){CloseHandle(h);throw std::runtime_error("Cannot enumerate running games");}
 do{if(!_wcsicmp(e.szExeFile,fs::path(exe).filename().c_str())){found=true;break;}}while(Process32NextW(h,&e));CloseHandle(h);
 if(found)throw std::runtime_error("Close the selected game before saving or restoring its driver profile");
}
static void Unicode(NvAPI_UnicodeString& out, std::wstring const& text) {
    if (text.size() >= NVAPI_UNICODE_STRING_MAX) throw std::runtime_error("Profile or executable name is too long");
    std::copy(text.begin(), text.end(), out); out[text.size()] = 0;
}
struct Api {
    HMODULE library{};
    using Query = void* (__cdecl*)(unsigned int);
    Query query{};
    template<class T> T Bind(char const* name) {
        for (auto const& entry : nvapi_interface_table) if (!strcmp(entry.func, name)) {
            auto p = query(entry.id); if (p) return reinterpret_cast<T>(p);
            break;
        }
        throw std::runtime_error(std::string("NVIDIA driver does not expose ") + name);
    }
#define API_FUNCTION(name) decltype(&NvAPI_##name) name{};
    API_FUNCTION(Initialize) API_FUNCTION(Unload) API_FUNCTION(GetErrorMessage)
    API_FUNCTION(SYS_GetDriverAndBranchVersion) API_FUNCTION(EnumPhysicalGPUs) API_FUNCTION(GPU_GetFullName)
    API_FUNCTION(DRS_CreateSession) API_FUNCTION(DRS_DestroySession) API_FUNCTION(DRS_LoadSettings)
    API_FUNCTION(DRS_SaveSettings) API_FUNCTION(DRS_FindApplicationByName) API_FUNCTION(DRS_GetProfileInfo)
    API_FUNCTION(DRS_GetSetting) API_FUNCTION(DRS_SetSetting) API_FUNCTION(DRS_DeleteProfileSetting)
    API_FUNCTION(DRS_GetSettingNameFromId) API_FUNCTION(DRS_CreateProfile) API_FUNCTION(DRS_DeleteProfile)
    API_FUNCTION(DRS_CreateApplication) API_FUNCTION(DRS_FindProfileByName)
#undef API_FUNCTION
    void Check(NvAPI_Status s, char const* operation) {
        if (s == NVAPI_OK) return;
        NvAPI_ShortString message{}; if (GetErrorMessage) GetErrorMessage(s, message);
        throw std::runtime_error(std::string(operation) + ": " + message + " (NVAPI " + std::to_string(s) + ")");
    }
    Api() {
        // Only load the installed Windows driver, never a DLL beside this executable.
        library = LoadLibraryExW(L"nvapi64.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!library) throw std::runtime_error("NVIDIA NVAPI driver unavailable. This controller requires an installed NVIDIA driver; AMD/Intel are not supported by this backend.");
        try {
            query = reinterpret_cast<Query>(GetProcAddress(library,"nvapi_QueryInterface"));
            if (!query) throw std::runtime_error("NVIDIA driver query interface missing");
#define LOAD(name) name = Bind<decltype(name)>("NvAPI_" #name);
            LOAD(Initialize) LOAD(Unload) LOAD(GetErrorMessage)
            Check(Initialize(), "Initialize");
            LOAD(SYS_GetDriverAndBranchVersion) LOAD(EnumPhysicalGPUs) LOAD(GPU_GetFullName)
            LOAD(DRS_CreateSession) LOAD(DRS_DestroySession) LOAD(DRS_LoadSettings) LOAD(DRS_SaveSettings)
            LOAD(DRS_FindApplicationByName) LOAD(DRS_GetProfileInfo) LOAD(DRS_GetSetting) LOAD(DRS_SetSetting)
            LOAD(DRS_DeleteProfileSetting) LOAD(DRS_GetSettingNameFromId) LOAD(DRS_CreateProfile)
            LOAD(DRS_DeleteProfile) LOAD(DRS_CreateApplication) LOAD(DRS_FindProfileByName)
#undef LOAD
        } catch (...) { if (Unload) Unload(); FreeLibrary(library); throw; }
    }
    ~Api() { if (Unload) Unload(); if (library) FreeLibrary(library); }
};
struct Session {
    Api& api; NvDRSSessionHandle handle{};
    Session(Api& a) : api(a) {
        api.Check(api.DRS_CreateSession(&handle),"CreateSession");
        try { api.Check(api.DRS_LoadSettings(handle),"LoadSettings"); }
        catch (...) { api.DRS_DestroySession(handle); throw; }
    }
    ~Session() { api.DRS_DestroySession(handle); }
    NvDRSProfileHandle Find(std::wstring const& executable) {
        NvAPI_UnicodeString name{}; Unicode(name, executable);
        auto application = std::make_unique<NVDRS_APPLICATION>(); application->version = NVDRS_APPLICATION_VER;
        NvDRSProfileHandle profile{};
        api.Check(api.DRS_FindApplicationByName(handle,name,&profile,application.get()),"FindApplicationByName (select the full MSFS executable if ambiguous)");
        return profile;
    }
    Snapshot Read(NvDRSProfileHandle profile) {
        auto info = std::make_unique<NVDRS_PROFILE>(); info->version = NVDRS_PROFILE_VER;
        api.Check(api.DRS_GetProfileInfo(handle,profile,info.get()),"GetProfileInfo");
        Snapshot result; result.profile = reinterpret_cast<wchar_t const*>(info->profileName);
        for (size_t i = 0; i < ids.size(); ++i) {
            auto setting = std::make_unique<NVDRS_SETTING>(); setting->version = NVDRS_SETTING_VER;
            auto status = api.DRS_GetSetting(handle,profile,ids[i],setting.get());
            if (status == NVAPI_SETTING_NOT_FOUND) { result.values[i] = {ids[i],0,false}; continue; }
            api.Check(status,"GetSetting");
            if (setting->settingType != NVDRS_DWORD_TYPE) throw std::runtime_error("Driver returned a non-DWORD MFG setting");
            result.values[i] = {ids[i],setting->u32CurrentValue,
                setting->settingLocation == NVDRS_CURRENT_PROFILE_LOCATION && !setting->isCurrentPredefined};
        }
        return result;
    }
    void Write(NvDRSProfileHandle profile, Value value) {
        if (!value.local) {
            auto status = api.DRS_DeleteProfileSetting(handle,profile,value.id);
            if (status != NVAPI_SETTING_NOT_FOUND) api.Check(status,"DeleteProfileSetting");
        } else {
            auto setting = std::make_unique<NVDRS_SETTING>(); setting->version = NVDRS_SETTING_VER;
            setting->settingId = value.id; setting->settingType = NVDRS_DWORD_TYPE;
            setting->u32CurrentValue = value.value;
            api.Check(api.DRS_SetSetting(handle,profile,setting.get()),"SetSetting");
        }
    }
    void Save() { api.Check(api.DRS_SaveSettings(handle),"SaveSettings"); }
};

struct Record {std::wstring exe;Snapshot before,after;};
static void SaveRecord(fs::path const& file,Record const& r){
 std::ofstream out(file,std::ios::binary|std::ios::trunc);out<<"OPTISHADE_DRIVER_V1\n"<<std::quoted(Utf8(r.exe))<<'\n'<<std::quoted(Utf8(r.before.profile))<<'\n';
 for(size_t i=0;i<4;++i)out<<ids[i]<<' '<<r.before.values[i].value<<' '<<r.before.values[i].local<<' '<<r.after.values[i].value<<' '<<r.after.values[i].local<<'\n';
 out.close();if(!out)throw std::runtime_error("Could not save driver backup; no settings saved");
}
static Record LoadRecord(fs::path const& file){
 std::ifstream in(file,std::ios::binary);std::string magic,exe,profile;std::getline(in,magic);Record r;
 if(magic!="OPTISHADE_DRIVER_V1"||!(in>>std::quoted(exe)>>std::quoted(profile)))throw std::runtime_error("Invalid review or backup file");
 r.exe=Wide(exe);r.before.profile=r.after.profile=Wide(profile);
 for(size_t i=0;i<4;++i){uint32_t id;auto& a=r.before.values[i];auto& b=r.after.values[i];if(!(in>>id>>a.value>>a.local>>b.value>>b.local)||id!=ids[i])throw std::runtime_error("Invalid backup values");a.id=b.id=id;}
 std::string extra;if(in>>extra)throw std::runtime_error("Unexpected backup content");return r;
}
static bool Same(Snapshot const& a,Snapshot const& b){return a.profile==b.profile&&a.values==b.values;}
static std::string Encode(Snapshot const& s,fs::path const& token){
 std::string out="{\"ok\":true,\"profile\":"+Json(Utf8(s.profile))+",\"record\":"+Json(Utf8(token.wstring()))+",\"values\":[";
 for(size_t i=0;i<4;++i){if(i)out+=',';out+="{\"value\":"+std::to_string(s.values[i].value)+",\"local\":"+(s.values[i].local?"true":"false")+"}";}
 return out+"]}";
}
static uint32_t Preset(wchar_t const* arg,bool sr){std::wstring p(arg);if(p==L"default")return 0;if(p==L"latest")return 0xffffff;if(p.size()==1&&((sr&&(p==L"K"||p==L"L"||p==L"M"))||(!sr&&(p==L"A"||p==L"B"))))return p[0]-L'A'+1;throw std::runtime_error("Unsupported preset selection");}
}
int wmain(int argc,wchar_t** argv){
 using namespace omfg::driver;
 if(argc!=7)return 2; // operation, executable, review/backup, SR, FG, output
 fs::path output(argv[6]);std::string result;int code=0;
 try{
  std::wstring op(argv[1]),exe(argv[2]);if(fs::path(exe).extension()!=L".exe")throw std::runtime_error("Choose a game executable (.exe)");
  Api api;Session s(api);auto profile=s.Find(exe);auto current=s.Read(profile);
  for(auto id:ids){NvAPI_UnicodeString name{};api.Check(api.DRS_GetSettingNameFromId(id,&name),"Driver preset availability");}
  fs::path record=output;record+=L".backup";
  if(op==L"read"){SaveRecord(record,{exe,current,current});result=Encode(current,record);}
  else{
   RequireClosed(exe);auto reviewed=LoadRecord(argv[3]);if(reviewed.exe!=exe||reviewed.before.profile!=current.profile)throw std::runtime_error("Review belongs to a different game/profile; Read current settings again");
   Snapshot desired=current;
   if(op==L"save"){
    if(!Same(current,reviewed.before))throw std::runtime_error("Driver profile changed since review; read again before saving");
    uint32_t sr=Preset(argv[4],true),fg=Preset(argv[5],false);
    desired.values={Value{ids[0],sr?1u:0u,true},Value{ids[1],sr,true},Value{ids[2],fg?1u:0u,true},Value{ids[3],fg,true}};
   }else if(op==L"restore"){
    if(!Same(current,reviewed.after))throw std::runtime_error("Driver settings changed after this save; restore stopped to preserve those changes");desired=reviewed.before;
   }else throw std::runtime_error("Unknown operation");
   SaveRecord(record,{exe,current,desired});
   for(auto v:desired.values)s.Write(profile,v);
   RequireClosed(exe);s.Save();
   Session verify(api);auto after=verify.Read(verify.Find(exe));
   if(!Same(after,desired))throw std::runtime_error("Driver readback differs; retained backup beside result file. Read settings before retrying");
   result=Encode(after,record);
  }
 }catch(std::exception const& e){result="{\"ok\":false,\"error\":"+Json(e.what())+"}";code=1;}
 std::ofstream out(output,std::ios::binary|std::ios::trunc);out<<result;out.close();return out?code:3;
}
