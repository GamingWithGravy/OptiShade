// Read-only release notification. Network work never runs on the render thread.
#include <winhttp.h>
#include <atomic>
#include <regex>
namespace OptiShadeUpdates {
static std::atomic<bool> checked=false,available=false;
static bool started=false,dismissed=false;
static double shownAt=-1;
static DWORD WINAPI Check(void* reference){
 HMODULE http=LoadLibraryExW(L"winhttp.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
 if(http){
#define OS_HTTP(name) auto name=reinterpret_cast<decltype(&::name)>(GetProcAddress(http,#name))
  OS_HTTP(WinHttpOpen);OS_HTTP(WinHttpSetTimeouts);OS_HTTP(WinHttpConnect);OS_HTTP(WinHttpOpenRequest);OS_HTTP(WinHttpSendRequest);OS_HTTP(WinHttpReceiveResponse);OS_HTTP(WinHttpReadData);OS_HTTP(WinHttpCloseHandle);OS_HTTP(WinHttpQueryHeaders);
#undef OS_HTTP
  if(WinHttpOpen&&WinHttpSetTimeouts&&WinHttpConnect&&WinHttpOpenRequest&&WinHttpSendRequest&&WinHttpReceiveResponse&&WinHttpReadData&&WinHttpCloseHandle&&WinHttpQueryHeaders){
   HINTERNET session=WinHttpOpen(L"OptiShade/0.19.18",WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,nullptr,nullptr,0);
   if(session){
    WinHttpSetTimeouts(session,3000,3000,3000,3000);
    HINTERNET connection=WinHttpConnect(session,L"api.github.com",INTERNET_DEFAULT_HTTPS_PORT,0);
    if(connection){
     HINTERNET request=WinHttpOpenRequest(connection,L"GET",L"/repos/GamingWithGravy/OptiShade_V0.19.17/releases/latest",nullptr,nullptr,nullptr,WINHTTP_FLAG_SECURE);
     if(request){
      if(WinHttpSendRequest(request,nullptr,0,nullptr,0,0,0)&&WinHttpReceiveResponse(request,nullptr)){
       DWORD status=0,length=sizeof(status);
       if(WinHttpQueryHeaders(request,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,nullptr,&status,&length,nullptr)&&status==200){
        std::string body;char buffer[4096];DWORD count=0;ULONGLONG deadline=GetTickCount64()+10000;
        while(body.size()<262144&&GetTickCount64()<deadline&&WinHttpReadData(request,buffer,sizeof(buffer),&count)&&count)body.append(buffer,count);
        try{std::smatch match;std::regex tag("\"tag_name\"\\s*:\\s*\"v?([0-9]+)\\.([0-9]+)\\.([0-9]+)\"");
         if(std::regex_search(body,match,tag)){int major=std::stoi(match[1]),minor=std::stoi(match[2]),patch=std::stoi(match[3]);available=(major>0||(major==0&&(minor>19||(minor==19&&patch>18))));}
        }catch(...){}
       }
      }
      WinHttpCloseHandle(request);
     }WinHttpCloseHandle(connection);
    }WinHttpCloseHandle(session);
   }
  }FreeLibrary(http);
 }
 checked=true;FreeLibraryAndExitThread(static_cast<HMODULE>(reference),0);return 0;
}
static bool NeedsFrame(){return !started||!checked.load()||(available.load()&&!dismissed);}
static void Draw(bool menuOpen){
 if(!started){started=true;HMODULE reference=nullptr;if(GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(&Check),&reference)){HANDLE worker=CreateThread(nullptr,0,Check,reference,0,nullptr);if(worker)CloseHandle(worker);else{FreeLibrary(reference);checked=true;}}else checked=true;}
 if(!available.load())return;
 if(shownAt<0)shownAt=ImGui::GetTime();
 if(ImGui::GetTime()-shownAt>15)dismissed=true;
 if(dismissed&&!menuOpen)return;
 ImGui::SetNextWindowPos(ImVec2(24,160),ImGuiCond_Always);ImGui::SetNextWindowBgAlpha(.94f);
 if(ImGui::Begin("OptiShade update notice",nullptr,ImGuiWindowFlags_NoDecoration|ImGuiWindowFlags_AlwaysAutoResize|ImGuiWindowFlags_NoSavedSettings|ImGuiWindowFlags_NoFocusOnAppearing|ImGuiWindowFlags_NoInputs)){
  ImGui::TextColored(ImVec4(.75f,.55f,1.f,1.f),"Update available - check the installer");
 }ImGui::End();
}
}
