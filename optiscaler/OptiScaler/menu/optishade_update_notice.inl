// Read-only release notification. Network work never runs on the render thread.
#include <winhttp.h>
#include <atomic>
#include <regex>
namespace OptiShadeUpdates {
static std::atomic<bool> running=false,available=false;
static std::atomic<ULONGLONG> nextCheck{0};
static DWORD WINAPI Check(void* reference){
 bool succeeded=false;
 HMODULE http=LoadLibraryExW(L"winhttp.dll",nullptr,LOAD_LIBRARY_SEARCH_SYSTEM32);
 if(http){
#define OS_HTTP(name) auto name=reinterpret_cast<decltype(&::name)>(GetProcAddress(http,#name))
  OS_HTTP(WinHttpOpen);OS_HTTP(WinHttpSetTimeouts);OS_HTTP(WinHttpConnect);OS_HTTP(WinHttpOpenRequest);OS_HTTP(WinHttpSendRequest);OS_HTTP(WinHttpReceiveResponse);OS_HTTP(WinHttpReadData);OS_HTTP(WinHttpCloseHandle);OS_HTTP(WinHttpQueryHeaders);
#undef OS_HTTP
  if(WinHttpOpen&&WinHttpSetTimeouts&&WinHttpConnect&&WinHttpOpenRequest&&WinHttpSendRequest&&WinHttpReceiveResponse&&WinHttpReadData&&WinHttpCloseHandle&&WinHttpQueryHeaders){
   HINTERNET session=WinHttpOpen(L"OptiShade/0.20.7",WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,nullptr,nullptr,0);
   if(session){
    WinHttpSetTimeouts(session,3000,3000,3000,3000);
    HINTERNET connection=WinHttpConnect(session,L"api.github.com",INTERNET_DEFAULT_HTTPS_PORT,0);
    if(connection){
     HINTERNET request=WinHttpOpenRequest(connection,L"GET",L"/repos/GamingWithGravy/OptiShade/releases/latest",nullptr,nullptr,nullptr,WINHTTP_FLAG_SECURE);
     if(request){
      if(WinHttpSendRequest(request,nullptr,0,nullptr,0,0,0)&&WinHttpReceiveResponse(request,nullptr)){
       DWORD status=0,length=sizeof(status);
       if(WinHttpQueryHeaders(request,WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER,nullptr,&status,&length,nullptr)&&status==200){
        std::string body;char buffer[4096];DWORD count=0;ULONGLONG deadline=GetTickCount64()+10000;
        while(body.size()<262144&&GetTickCount64()<deadline&&WinHttpReadData(request,buffer,sizeof(buffer),&count)&&count)body.append(buffer,count);
        try{std::smatch match;std::regex tag("\"tag_name\"\\s*:\\s*\"v?([0-9]+)\\.([0-9]+)(?:\\.([0-9]+))?\"");
         if(std::regex_search(body,match,tag)){int major=std::stoi(match[1]),minor=std::stoi(match[2]),patch=match[3].matched?std::stoi(match[3]):0;available=(major>0||(major==0&&(minor>20||(minor==20&&patch>5))));succeeded=true;}
        }catch(...){}
       }
      }
      WinHttpCloseHandle(request);
     }WinHttpCloseHandle(connection);
    }WinHttpCloseHandle(session);
   }
  }FreeLibrary(http);
 }
 nextCheck=GetTickCount64()+(succeeded?300000ULL:60000ULL);running=false;
 FreeLibraryAndExitThread(static_cast<HMODULE>(reference),0);return 0;
}
static bool NeedsFrame(){return !running.load()&&GetTickCount64()>=nextCheck.load();}
static void Draw(bool){
 if(!NeedsFrame()||running.exchange(true))return;
 HMODULE reference=nullptr;
 if(GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(&Check),&reference)){
  HANDLE worker=CreateThread(nullptr,0,Check,reference,0,nullptr);
  if(worker){CloseHandle(worker);return;}FreeLibrary(reference);
 }
 nextCheck=GetTickCount64()+60000ULL;running=false;
}
static void DrawHeader(){
 if(!available.load())return;
 const char* title="UPDATE AVAILABLE";const char* detail="please check OptiShade manager";
 auto* font=ImGui::GetFont();float titleSize=ImGui::GetFontSize()*.9f,detailSize=ImGui::GetFontSize()*.75f;
 float right=ImGui::GetWindowPos().x+ImGui::GetWindowWidth()-20.f;
 float top=ImGui::GetItemRectMax().y+8.f;
 auto* draw=ImGui::GetWindowDrawList();
 draw->AddText(font,titleSize,ImVec2(right-font->CalcTextSizeA(titleSize,FLT_MAX,0,title).x,top),IM_COL32(181,119,255,255),title);
 draw->AddText(font,detailSize,ImVec2(right-font->CalcTextSizeA(detailSize,FLT_MAX,0,detail).x,top+titleSize+3.f),IM_COL32(196,168,225,255),detail);
}
}