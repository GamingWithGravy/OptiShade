#pragma once
#include "../../../shared/HardwareTelemetry.h"
namespace OptiShadeHardware {
struct Monitor {
    HANDLE process=nullptr,pipe=nullptr,job=nullptr;
    std::filesystem::path root,settings;
    bool enabled=false,loaded=false,saveError=false,positionDirty=false;
    float x=.98f,y=.12f; uint64_t started=0,retry=0;
    optishade::hardware::Stream stream;
    ~Monitor(){Stop();}
    void Stop(){
        if(job)CloseHandle(job);job=nullptr;
        if(process)CloseHandle(process);process=nullptr;
        if(pipe)CloseHandle(pipe);pipe=nullptr;
        stream.Reset();
    }
    void Load(){
        if(loaded)return;loaded=true;root=Util::DllPath().parent_path();settings=root/L"OptiShadeData"/L"HardwareMonitor.ini";
        enabled=GetPrivateProfileIntW(L"Overlay",L"Enabled",0,settings.c_str())==1;
        x=std::clamp(GetPrivateProfileIntW(L"Overlay",L"X",980,settings.c_str()),0u,1000u)/1000.f;
        y=std::clamp(GetPrivateProfileIntW(L"Overlay",L"Y",120,settings.c_str()),0u,1000u)/1000.f;
    }
    void Save(){
        std::error_code ec;std::filesystem::create_directories(settings.parent_path(),ec);
        auto px=std::to_wstring((int)(x*1000)),py=std::to_wstring((int)(y*1000));
        saveError=!WritePrivateProfileStringW(L"Overlay",L"Enabled",enabled?L"1":L"0",settings.c_str());
        saveError=!WritePrivateProfileStringW(L"Overlay",L"X",px.c_str(),settings.c_str())||saveError;
        saveError=!WritePrivateProfileStringW(L"Overlay",L"Y",py.c_str(),settings.c_str())||saveError;
    }
    void Start(uint64_t now){
        retry=now+30000;auto exe=root/L"OptiShadeData"/L"Tools"/L"OptiShadeSensors.exe";
        std::error_code ec;if(!std::filesystem::is_regular_file(exe,ec))return;
        SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};HANDLE write=nullptr;
        if(!CreatePipe(&pipe,&write,&sa,0))return;
        SetHandleInformation(pipe,HANDLE_FLAG_INHERIT,0);
        HANDLE input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,0,nullptr);
        job=CreateJobObjectW(nullptr,nullptr);JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if(!job||!SetInformationJobObject(job,JobObjectExtendedLimitInformation,&limits,sizeof(limits))){CloseHandle(write);if(input!=INVALID_HANDLE_VALUE)CloseHandle(input);Stop();return;}
        // Limit inheritance to this helper's standard handles; never leak simulator handles.
        SIZE_T bytes=0;InitializeProcThreadAttributeList(nullptr,1,0,&bytes);
        std::vector<unsigned char> storage(bytes);auto attrs=reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
        bool initialized=InitializeProcThreadAttributeList(attrs,1,0,&bytes)!=FALSE;
        HANDLE handles[]={write,input};
        bool attributes=initialized&&input!=INVALID_HANDLE_VALUE&&UpdateProcThreadAttribute(attrs,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,handles,sizeof(handles),nullptr,nullptr);
        STARTUPINFOEXW si{};si.StartupInfo.cb=sizeof(si);si.StartupInfo.dwFlags=STARTF_USESTDHANDLES;
        si.StartupInfo.hStdOutput=write;si.StartupInfo.hStdError=write;si.StartupInfo.hStdInput=input;si.lpAttributeList=attrs;
        PROCESS_INFORMATION pi{};std::wstring cmd=L"\""+exe.wstring()+L"\" "+std::to_wstring(GetCurrentProcessId());
        bool created=attributes&&CreateProcessW(exe.c_str(),cmd.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW|CREATE_SUSPENDED|EXTENDED_STARTUPINFO_PRESENT,nullptr,root.c_str(),&si.StartupInfo,&pi);
        if(initialized)DeleteProcThreadAttributeList(attrs);CloseHandle(write);if(input!=INVALID_HANDLE_VALUE)CloseHandle(input);
        if(!created){Stop();return;}
        if(!AssignProcessToJobObject(job,pi.hProcess)){TerminateProcess(pi.hProcess,1);CloseHandle(pi.hProcess);CloseHandle(pi.hThread);Stop();return;}
        process=pi.hProcess;started=now;ResumeThread(pi.hThread);CloseHandle(pi.hThread);
    }
    void Tick(){
        Load();if(!enabled){Stop();return;}auto now=GetTickCount64();
        if(!process){if(now>=retry)Start(now);return;}
        DWORD available=0;if(!PeekNamedPipe(pipe,nullptr,0,nullptr,&available,nullptr)){Stop();return;}
        char buffer[4096];DWORD read=0;
        if(available&&ReadFile(pipe,buffer,std::min<DWORD>(available,sizeof(buffer)),&read,nullptr))stream.Feed(buffer,read,now);
        if(WaitForSingleObject(process,0)==WAIT_OBJECT_0||now-(stream.updated?stream.updated:started)>10000)Stop();
    }
};
static Monitor monitor;
static bool Enabled(){monitor.Load();return monitor.enabled;}
static void Settings(){
    ImGui::SeparatorText("Hardware monitor");bool value=Enabled();
    if(OptiShadeUI::EffectSwitch("Hardware temperatures",value)){monitor.enabled=!value;monitor.Save();if(!monitor.enabled)monitor.Stop();}
    ImGui::SameLine();ImGui::TextUnformatted("Show hardware temperatures");
    ImGui::TextWrapped("An on-screen overlay during gameplay. Open this menu to drag it. Preferences save automatically.");
    ImGui::TextWrapped("NVIDIA temperatures are read directly. CPU and other sensors use Libre Hardware Monitor when running. Unavailable readings are not estimates.");
    if(ImGui::Button("Reset hardware overlay position")){monitor.x=.98f;monitor.y=.12f;monitor.Save();}
    if(monitor.saveError)ImGui::TextWrapped("Could not save hardware monitor preferences. Check write access to this game's OptiShadeData folder.");
}
static void Draw(bool menuOpen,float scale){
    monitor.Tick();if(!monitor.enabled)return;
    auto& io=ImGui::GetIO();scale=std::clamp(scale,.5f,2.f);
    ImGui::SetNextWindowBgAlpha(.8f);
    ImGui::SetNextWindowPos(ImVec2(monitor.x*io.DisplaySize.x,monitor.y*io.DisplaySize.y),ImGuiCond_Always,ImVec2(monitor.x,monitor.y));
    ImGui::SetNextWindowSizeConstraints(ImVec2(0,0),ImVec2(std::max(100.f,io.DisplaySize.x-20),std::max(80.f,io.DisplaySize.y-20)));
    auto flags=ImGuiWindowFlags_NoTitleBar|ImGuiWindowFlags_AlwaysAutoResize|ImGuiWindowFlags_NoSavedSettings|ImGuiWindowFlags_NoFocusOnAppearing|ImGuiWindowFlags_NoNav;
    if(!menuOpen)flags|=ImGuiWindowFlags_NoInputs;
    if(ImGui::Begin("OptiShade hardware monitor",nullptr,flags)){
        ImGui::SetWindowFontScale(scale);
        ImGui::TextColored(ImGui::GetStyleColorVec4(ImGuiCol_CheckMark),"Hardware temperatures");
        if(monitor.stream.Fresh(GetTickCount64())){
            for(const auto& r:monitor.stream.readings){
                ImGui::PushTextWrapPos(ImGui::GetCursorPosX()+std::max(40.f,std::min(320*scale,ImGui::GetContentRegionAvail().x)));
                if(r.available)ImGui::Text("%s: %.0f C",r.label.c_str(),r.temperature);
                else ImGui::TextDisabled("%s: Unavailable",r.label.c_str());
                ImGui::PopTextWrapPos();
            }
        }else ImGui::TextDisabled("Temperatures unavailable / connecting");
        if(menuOpen&&ImGui::IsWindowHovered()&&ImGui::IsMouseDragging(ImGuiMouseButton_Left)){
            monitor.positionDirty=true;
            monitor.x=std::clamp(monitor.x+io.MouseDelta.x/std::max(1.f,io.DisplaySize.x-ImGui::GetWindowWidth()),0.f,1.f);
            monitor.y=std::clamp(monitor.y+io.MouseDelta.y/std::max(1.f,io.DisplaySize.y-ImGui::GetWindowHeight()),0.f,1.f);
        }
        if(monitor.positionDirty&&ImGui::IsMouseReleased(ImGuiMouseButton_Left)){monitor.Save();monitor.positionDirty=false;}
    }ImGui::End();
}
}

