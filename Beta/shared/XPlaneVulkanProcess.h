#pragma once
#include <windows.h>
#include <filesystem>
#include <fstream>
#include <string>
#include <json.hpp>
#include "XPlaneVulkanTarget.h"
#include "XPlaneGraphicsRoute.h"
namespace optishade::xplane_layer {
struct ProcessGraphicsRoute { bool xplane=false; GraphicsRoute route=GraphicsRoute::NativeVulkan; };
inline const ProcessGraphicsRoute& ProcessRoute(){
 // Immutable for this process. Changes in the manager take effect after a
 // restart, never while hooks/queues from the old route remain live.
 static const ProcessGraphicsRoute selection=[] {
  wchar_t executable[32768]{};const auto length=GetModuleFileNameW(nullptr,executable,32768);
  if(!length||length>=32768)return ProcessGraphicsRoute{};
  const std::filesystem::path path(executable);
  if(!IsXPlaneProcessName(path.filename().wstring()))return ProcessGraphicsRoute{};
  const auto file=path.parent_path()/L"OptiShadeData"/L"XPlane-compatibility.ini";
  wchar_t value[64]{};
  const auto count=GetPrivateProfileStringW(L"XPlane",L"GraphicsRoute",L"native-vulkan",value,64,file.c_str());
  return ProcessGraphicsRoute{true,count>=63?GraphicsRoute::NativeVulkan:ParseGraphicsRoute(value)};
 }();return selection;
}
inline GraphicsRoute CurrentRoute(){return ProcessRoute().route;}
inline std::wstring Env(const wchar_t* name){wchar_t b[32768]{};DWORD n=GetEnvironmentVariableW(name,b,32768);return n&&n<32768?std::wstring(b,n):L"";}
inline std::wstring Merge(std::wstring first,const std::wstring& rest,wchar_t separator=L';',bool removeStock=false){
 size_t begin=0;while(begin<rest.size()){auto end=rest.find(separator,begin);auto part=rest.substr(begin,end==std::wstring::npos?end:end-begin);
 if(!part.empty()&&(!removeStock||part!=L"VK_LAYER_reshade")){
 bool duplicate=false;size_t pos=0;while(pos<first.size()){auto stop=first.find(separator,pos);if(first.substr(pos,stop==std::wstring::npos?stop:stop-pos)==part)duplicate=true;if(stop==std::wstring::npos)break;pos=stop+1;}
 if(!duplicate){if(!first.empty())first+=separator;first+=part;}}
 if(end==std::wstring::npos)break;begin=end+1;}return first;
}
inline bool ConfigureRouteBeforeEffects(){
 if(!ProcessRoute().xplane)return true;
 const auto route=CurrentRoute();
 if(UsesNativeEffects(route))return SetEnvironmentVariableW(L"RESHADE_DISABLE_GRAPHICS_HOOK",L"1")!=FALSE;
 const auto names=WithoutEffectsLayers(Env(L"VK_INSTANCE_LAYERS"),L';');
 const auto enabled=WithoutEffectsLayers(Env(L"VK_LOADER_LAYERS_ENABLE"),L',');
 const auto xrNames=WithoutEffectsLayers(Env(L"XR_ENABLE_API_LAYERS"),L';');
 const auto disabled=Merge(Merge(Env(L"VK_LOADER_LAYERS_DISABLE"),L"VK_LAYER_OptiShade_effects",L','),L"VK_LAYER_reshade",L',');
 if(disabled.size()>=32767)return false;
 // Process scope only. Remove inherited explicit requests from manager/Steam
 // and block stock implicit ReShade; never enable two effects routes.
 return SetEnvironmentVariableW(L"VK_INSTANCE_LAYERS",names.empty()?nullptr:names.c_str())&&
  SetEnvironmentVariableW(L"VK_LOADER_LAYERS_ENABLE",enabled.empty()?nullptr:enabled.c_str())&&
  SetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE",disabled.c_str())&&
  SetEnvironmentVariableW(L"DISABLE_VK_LAYER_reshade_1",L"1")&&
  SetEnvironmentVariableW(L"XR_ENABLE_API_LAYERS",xrNames.empty()?nullptr:xrNames.c_str())&&
  SetEnvironmentVariableW(L"DISABLE_XR_APILAYER_reshade_1",L"1")&&
  SetEnvironmentVariableW(L"RESHADE_DISABLE_GRAPHICS_HOOK",DisablesGraphicsHooks(route)?L"1":nullptr);
}
inline const char* Configure(const std::filesystem::path& executable){
 // The Vulkan layer is an X-Plane 12 path. Never pass its loader overrides into
 // unrelated games that happen to have the same game-local OptiShade files.
 if(!IsXPlaneProcessName(executable.filename().wstring()))return "not an X-Plane process";

 if(!UsesNativeEffects(CurrentRoute()))return ConfigureRouteBeforeEffects()?
  (CurrentRoute()==GraphicsRoute::MenuOnly?"menu-only diagnostic: native effects layer excluded":"legacy-dxgi test: native effects layer excluded"):
  "X-Plane graphics route environment configuration failed";

 auto game=executable.parent_path(),directory=game/L"OptiShadeData"/L"Vulkan",manifest=directory/L"OptiShade.json";
 std::error_code ec;
 if(!std::filesystem::is_regular_file(game/L"ReShade64.dll",ec)||ec)return "local ReShade DLL missing";
 auto size=std::filesystem::file_size(manifest,ec);if(ec||size>65536)return "local layer manifest missing or oversized";
 try{std::ifstream file(manifest);auto j=nlohmann::json::parse(file);auto& layer=j.at("layer");
 if(layer.at("name")!="VK_LAYER_OptiShade_effects"||layer.at("type")!="GLOBAL"||layer.at("library_path")!="..\\..\\ReShade64.dll")return "local layer manifest identity invalid";
 }catch(...){return "local layer manifest invalid JSON";}
 HANDLE token=nullptr;TOKEN_ELEVATION elevation{};DWORD bytes=0;
 if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return "process elevation unavailable";
 bool known=GetTokenInformation(token,TokenElevation,&elevation,sizeof(elevation),&bytes)!=FALSE;CloseHandle(token);
 if(!known||elevation.TokenIsElevated)return "local Vulkan discovery unavailable when elevated";
 auto overridePath=Env(L"VK_LAYER_PATH"),add=Env(L"VK_ADD_LAYER_PATH");
 auto paths=Merge(directory.wstring(),overridePath.empty()?add:Merge(overridePath,add));
 auto names=Merge(L"VK_LAYER_OptiShade_effects",Env(L"VK_INSTANCE_LAYERS"),L';',true);
 auto disable=Merge(Env(L"VK_LOADER_LAYERS_DISABLE"),L"VK_LAYER_reshade",L',');
 if(paths.size()>=32767||names.size()>=32767||disable.size()>=32767)return "local Vulkan environment too large";
 // This affects only the current simulator process; no registry or machine environment writes.
 if(!SetEnvironmentVariableW(overridePath.empty()?L"VK_ADD_LAYER_PATH":L"VK_LAYER_PATH",paths.c_str())||
 !SetEnvironmentVariableW(L"VK_INSTANCE_LAYERS",names.c_str())||
 !SetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE",disable.c_str())||
 !SetEnvironmentVariableW(L"DISABLE_VK_LAYER_reshade_1",L"1")||
 !SetEnvironmentVariableW(L"RESHADE_DISABLE_GRAPHICS_HOOK",L"1"))return "local Vulkan environment write failed";
 return "local Vulkan layer configured for this process";
}
}
