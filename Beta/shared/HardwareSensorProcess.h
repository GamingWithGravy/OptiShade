#pragma once
#include <Windows.h>
#include <filesystem>
#include <string>
#include <vector>
namespace optishade::hardware {
// Only owns a process created here. The PID heartbeat also prevents an orphan
// if a simulator job's restrictions prohibit assignment to our nested job.
struct SensorProcess {
    HANDLE process=nullptr,pipe=nullptr,job=nullptr; DWORD error=0;
    bool nestedJobUnavailable=false;
    ~SensorProcess(){Stop();}
    void Stop(){
        if(process){if(WaitForSingleObject(process,0)==WAIT_TIMEOUT)TerminateProcess(process,0);CloseHandle(process);}process=nullptr;
        if(job)CloseHandle(job);job=nullptr;
        if(pipe)CloseHandle(pipe);pipe=nullptr;
    }
    bool Start(const std::filesystem::path& exe,const std::filesystem::path& root,const std::wstring& arguments=L""){
        Stop();error=0;nestedJobUnavailable=false;
        SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};HANDLE write=nullptr;
        if(!CreatePipe(&pipe,&write,&sa,0)){error=GetLastError();return false;}
        SetHandleInformation(pipe,HANDLE_FLAG_INHERIT,0);
        HANDLE input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,nullptr);
        SIZE_T bytes=0;InitializeProcThreadAttributeList(nullptr,1,0,&bytes);
        std::vector<unsigned char> storage(bytes);auto attrs=reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
        bool initialized=InitializeProcThreadAttributeList(attrs,1,0,&bytes)!=FALSE;
        HANDLE handles[]={write,input};
        bool attributes=initialized&&input!=INVALID_HANDLE_VALUE&&UpdateProcThreadAttribute(attrs,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,handles,sizeof(handles),nullptr,nullptr);
        STARTUPINFOEXW si{};si.StartupInfo.cb=sizeof(si);si.StartupInfo.dwFlags=STARTF_USESTDHANDLES;
        si.StartupInfo.hStdOutput=write;si.StartupInfo.hStdError=write;si.StartupInfo.hStdInput=input;si.lpAttributeList=attrs;
        PROCESS_INFORMATION pi{};std::wstring cmd=L"\""+exe.wstring()+L"\" "+std::to_wstring(GetCurrentProcessId())+arguments;
        bool created=attributes&&CreateProcessW(exe.c_str(),cmd.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW|CREATE_SUSPENDED|EXTENDED_STARTUPINFO_PRESENT,nullptr,exe.parent_path().c_str(),&si.StartupInfo,&pi);
        if(!created)error=GetLastError();
        if(initialized)DeleteProcThreadAttributeList(attrs);CloseHandle(write);if(input!=INVALID_HANDLE_VALUE)CloseHandle(input);
        if(!created){Stop();return false;}
        process=pi.hProcess;
        job=CreateJobObjectW(nullptr,nullptr);JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if(!job||!SetInformationJobObject(job,JobObjectExtendedLimitInformation,&limits,sizeof(limits))||!AssignProcessToJobObject(job,process)){
            nestedJobUnavailable=true;if(job)CloseHandle(job);job=nullptr;
        }
        if(ResumeThread(pi.hThread)==DWORD(-1)){error=GetLastError();CloseHandle(pi.hThread);Stop();return false;}
        CloseHandle(pi.hThread);return true;
    }
};
}
