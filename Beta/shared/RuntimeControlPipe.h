// OptiShade additions, GPL-3.0-or-later. Local same-user pipe, off the renderer thread.
#pragma once
#include "RuntimeControlProtocol.h"
#include <windows.h>
#include <sddl.h>
#include <atomic>
#include <thread>
#include <vector>
#pragma comment(lib,"advapi32.lib")
namespace optishade::control {
class PipeServer {
 std::atomic<bool> stop_{false};std::thread thread_;
 std::wstring name_;uint32_t pid_=0;std::string birth_;std::function<std::string(const std::string&)> handler_;
 bool Pause(){Sleep(5);return !stop_.load();}
 void Run(){
  HANDLE token=nullptr;DWORD size=0;
  if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return;
  GetTokenInformation(token,TokenUser,nullptr,0,&size);std::vector<unsigned char> info(size);
  if(!size||!GetTokenInformation(token,TokenUser,info.data(),size,&size)){CloseHandle(token);return;}CloseHandle(token);
  LPWSTR sid=nullptr;if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(info.data())->User.Sid,&sid))return;
  std::wstring sddl=L"D:P(A;;GA;;;"+std::wstring(sid)+L")";LocalFree(sid);
  PSECURITY_DESCRIPTOR descriptor=nullptr;if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(),SDDL_REVISION_1,&descriptor,nullptr))return;
  SECURITY_ATTRIBUTES security{sizeof(security),descriptor,FALSE};
  // Only this process may create the endpoint. A pre-existing name fails closed.
  HANDLE pipe=CreateNamedPipeW(name_.c_str(),PIPE_ACCESS_DUPLEX|FILE_FLAG_FIRST_PIPE_INSTANCE,PIPE_TYPE_MESSAGE|PIPE_READMODE_MESSAGE|PIPE_NOWAIT|PIPE_REJECT_REMOTE_CLIENTS,1,MaxResponse,MaxRequest,0,&security);
  LocalFree(descriptor);if(pipe==INVALID_HANDLE_VALUE)return;
  std::vector<char> bytes(MaxRequest);
  while(!stop_){
   const bool connected=ConnectNamedPipe(pipe,nullptr)||GetLastError()==ERROR_PIPE_CONNECTED;
   if(!connected){Pause();continue;}
   const auto deadline=GetTickCount64()+1000;bool replied=false;
   while(!stop_&&GetTickCount64()<deadline){
    DWORD count=0;
    if(ReadFile(pipe,bytes.data(),MaxRequest,&count,nullptr)&&count){
     const std::string request(bytes.data(),count);std::string requestId;Json envelope;
     if(mfg::Parse(request,MaxRequest,envelope))mfg::String(envelope,"id",requestId);
     std::string response;
     try{response=handler_(request);}catch(...){response=PipeError("internal_error",pid_,birth_,requestId).dump();}
     if(response.size()>MaxResponse)response=PipeError("snapshot_too_large",pid_,birth_,requestId).dump();
     DWORD written=0;replied=WriteFile(pipe,response.data(),static_cast<DWORD>(response.size()),&written,nullptr)&&written==response.size();break;
    }
    const auto error=GetLastError();if(error!=ERROR_NO_DATA&&error!=ERROR_PIPE_LISTENING)break;
    Pause();
   }
   // No FlushFileBuffers: that can wait indefinitely for a wedged client.
   // A client acknowledges receipt; abandoned clients consume at most 250 ms.
   const auto ackDeadline=GetTickCount64()+250;
   while(replied&&!stop_&&GetTickCount64()<ackDeadline){DWORD count=0;if(ReadFile(pipe,bytes.data(),MaxRequest,&count,nullptr)&&count)break;if(GetLastError()==ERROR_BROKEN_PIPE)break;Pause();}
   DisconnectNamedPipe(pipe);
  }
  CloseHandle(pipe);
 }
public:
 PipeServer(uint32_t pid,std::string birth,std::function<std::string(const std::string&)> handler):name_(L"\\\\.\\pipe\\OptiShade.Control.v1."+std::to_wstring(pid)),pid_(pid),birth_(std::move(birth)),handler_(std::move(handler)){}
 void Start(){thread_=std::thread([this]{Run();});}
 void Stop(){stop_=true;if(thread_.joinable())thread_.join();}
 ~PipeServer(){Stop();}
};
}
