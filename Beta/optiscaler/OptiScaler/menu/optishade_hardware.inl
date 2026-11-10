#pragma once
#include "../../../shared/HardwareTelemetry.h"
#include "../../../shared/HardwareRenderGpu.h"
#include "../../../shared/HardwareMonitorDisplay.h"
#include "../../../shared/HardwareSensorProcess.h"
namespace OptiShadeHardware {
struct Monitor : optishade::hardware::SensorProcess {
    std::string selectedGpu;
    std::string status="Starting hardware monitor";
    std::filesystem::path root,settings;
    bool enabled=false,loaded=false,saveError=false,positionDirty=false;
    float x=.98f,y=.12f; uint64_t started=0,retry=0; bool heartbeatLogged=false; std::string loggedProvider; uint64_t lastProviderLog=0;
    optishade::hardware::Detail detail=optishade::hardware::Detail::Simple;
    optishade::hardware::Stream stream;
    ~Monitor(){Stop();}
    void Stop(){
        optishade::hardware::SensorProcess::Stop();
        stream.Reset();
    }
    void Load(){
        if(loaded)return;loaded=true;root=Util::DllPath().parent_path();settings=root/L"OptiShadeData"/L"HardwareMonitor.ini";
        enabled=GetPrivateProfileIntW(L"Overlay",L"Enabled",0,settings.c_str())==1;
        detail=optishade::hardware::ClampDetail(GetPrivateProfileIntW(L"Overlay",L"Detail",0,settings.c_str()));
        x=std::clamp(GetPrivateProfileIntW(L"Overlay",L"X",980,settings.c_str()),0u,1000u)/1000.f;
        y=std::clamp(GetPrivateProfileIntW(L"Overlay",L"Y",120,settings.c_str()),0u,1000u)/1000.f;
    }
    void Save(){
        std::error_code ec;std::filesystem::create_directories(settings.parent_path(),ec);
        auto mode=std::to_wstring(static_cast<int>(detail));
        auto px=std::to_wstring((int)(x*1000)),py=std::to_wstring((int)(y*1000));
        saveError=!WritePrivateProfileStringW(L"Overlay",L"Enabled",enabled?L"1":L"0",settings.c_str());
        saveError=!WritePrivateProfileStringW(L"Overlay",L"Detail",mode.c_str(),settings.c_str())||saveError;
        saveError=!WritePrivateProfileStringW(L"Overlay",L"X",px.c_str(),settings.c_str())||saveError;
        saveError=!WritePrivateProfileStringW(L"Overlay",L"Y",py.c_str(),settings.c_str())||saveError;
    }
    void Start(uint64_t now){
        retry=now+30000;auto exe=root/L"OptiShadeData"/L"Tools"/L"OptiShadeSensors.exe";
        std::error_code ec;if(!std::filesystem::is_regular_file(exe,ec)){status="Sensor helper missing. Repair this installation.";LOG_WARN("Hardware monitor missing: helper executable not found");return;}
        if(!optishade::hardware::SensorProcess::Start(exe,root,optishade::hardware::SensorGpuArgument(selectedGpu))){status="Sensor helper could not start (Windows error "+std::to_string(error)+"). Check protection history and repair.";LOG_WARN("Hardware monitor start failed: Windows error={}",error);return;}
        heartbeatLogged=false;LOG_INFO("Hardware monitor helper started: pid={} nestedJobUnavailable={}",GetProcessId(process),nestedJobUnavailable);started=now;status="Starting hardware monitor";
    }

    void Tick(){
        Load();if(!enabled){Stop();return;}auto now=GetTickCount64();
        const auto gpu=optishade::hardware::GetRenderGpu();if(gpu.name!=selectedGpu){Stop();selectedGpu=gpu.name;retry=0;}
        if(!process){if(now>=retry)Start(now);return;}
        DWORD available=0;if(!PeekNamedPipe(pipe,nullptr,0,nullptr,&available,nullptr)){DWORD pipeError=GetLastError(),code=STILL_ACTIVE;GetExitCodeProcess(process,&code);LOG_WARN("Hardware monitor pipe disconnected: Windows error={} helperExit={}",pipeError,code);status="Sensor helper disconnected. Retrying.";Stop();return;}
        char buffer[4096];DWORD read=0;
        if(available&&ReadFile(pipe,buffer,std::min<DWORD>(available,sizeof(buffer)),&read,nullptr))stream.Feed(buffer,read,now);
        if(!stream.providerStatus.empty()&&stream.providerStatus!=loggedProvider&&now-lastProviderLog>=5000){loggedProvider=stream.providerStatus;lastProviderLog=now;LOG_INFO("Hardware monitor provider: {}",loggedProvider);}
        if(stream.updated&&!heartbeatLogged){heartbeatLogged=true;LOG_INFO("Hardware monitor heartbeat: pid={} rows={} firstHeartbeatMs={}",GetProcessId(process),stream.readings.size(),now-started);}
        if(WaitForSingleObject(process,0)==WAIT_OBJECT_0){DWORD code=0;GetExitCodeProcess(process,&code);status="Sensor helper exited (code "+std::to_string(code)+"). Retrying.";LOG_WARN("Hardware monitor helper exited: code={}",code);Stop();}
        else if(now-(stream.updated?stream.updated:started)>10000){status="Sensor helper sent no heartbeat. Retrying.";LOG_WARN("Hardware monitor: helper alive but no valid heartbeat within 10 seconds");Stop();}
    }
};
static Monitor monitor;
static bool Enabled(){monitor.Load();return monitor.enabled;}
static void Settings(){
    ImGui::SeparatorText("Hardware monitor");bool value=Enabled();
    if(OptiShadeUI::EffectSwitch("Hardware monitor",value)){monitor.enabled=!value;monitor.Save();if(!monitor.enabled)monitor.Stop();}
    ImGui::SameLine();ImGui::TextUnformatted("Show hardware monitor");
    ImGui::SetNextItemWidth(std::min(220.f,ImGui::GetContentRegionAvail().x));
    int detail=static_cast<int>(monitor.detail);
    if(ImGui::Combo("##HardwareMonitorDetail",&detail,"Simple\0Normal\0Advanced\0")){monitor.detail=optishade::hardware::ClampDetail(detail);monitor.Save();}
    ImGui::TextWrapped("Simple: CPU and main GPU temperatures, clocks and usage, plus RAM usage. Normal: adds memory totals. Advanced: more sensors for the main GPU.");
    ImGui::TextWrapped("An on-screen overlay during gameplay. Open this menu to drag it. Preferences save automatically.");
    if(ImGui::CollapsingHeader("Sensor details"))ImGui::TextWrapped("CPU usage, reported clock and RAM are automatic. NVIDIA temperatures, usage and clocks are read directly. Only the simulator rendering GPU is shown. No external monitoring app is required. CPU package temperature is unavailable where no safe provider exists. Unavailable readings are not estimates.");
    if(ImGui::Button("Reset hardware overlay position")){monitor.x=.98f;monitor.y=.12f;monitor.Save();}
    if(monitor.saveError)ImGui::TextWrapped("Could not save hardware monitor preferences. Check write access to this game's OptiShadeData folder.");
}
static void Draw(bool menuOpen,float scale){
    monitor.Tick();if(!monitor.enabled)return;
    auto& io=ImGui::GetIO();scale=std::clamp(scale,.5f,2.f);
    ImGui::SetNextWindowBgAlpha(.94f);
    ImGui::SetNextWindowPos(ImVec2(monitor.x*io.DisplaySize.x,monitor.y*io.DisplaySize.y),ImGuiCond_Always,ImVec2(monitor.x,monitor.y));
    ImGui::SetNextWindowSize(ImVec2(std::min(360.f*scale,std::max(100.f,io.DisplaySize.x-20)),0),ImGuiCond_Always);
    ImGui::SetNextWindowSizeConstraints(ImVec2(0,0),ImVec2(std::max(100.f,io.DisplaySize.x-20),std::max(80.f,io.DisplaySize.y*.65f)));
    auto flags=ImGuiWindowFlags_NoTitleBar|ImGuiWindowFlags_AlwaysAutoResize|ImGuiWindowFlags_NoSavedSettings|ImGuiWindowFlags_NoFocusOnAppearing|ImGuiWindowFlags_NoNav;
    if(!menuOpen)flags|=ImGuiWindowFlags_NoInputs;
    if(ImGui::Begin("OptiShade hardware monitor",nullptr,flags)){
        ImGui::SetWindowFontScale(scale);
        ImGui::TextColored(ImGui::GetStyleColorVec4(ImGuiCol_CheckMark),"OptiShade / Hardware");ImGui::Separator();
        if(monitor.stream.Fresh(GetTickCount64())){
            if(monitor.stream.providerStatus.find("active")==std::string::npos)ImGui::TextWrapped("%s",monitor.stream.providerStatus.c_str());
            const auto gpu=optishade::hardware::GetRenderGpu();
            ImGui::TextWrapped("Main GPU: %s",gpu.name.empty()?"Waiting for rendering device":gpu.name.c_str());
            for(const auto& r:monitor.stream.readings){
                if(!optishade::hardware::ShowReading(r,monitor.detail,gpu.vendor))continue;
                ImGui::PushTextWrapPos(ImGui::GetCursorPosX()+std::max(40.f,std::min(320*scale,ImGui::GetContentRegionAvail().x)));
                if(!r.text.empty())ImGui::Text("%s: %s",r.label.c_str(),r.text.c_str());
                else if(r.available)ImGui::Text("%s: %.1f %s",r.label.c_str(),r.temperature,r.unit.c_str());
                else ImGui::TextDisabled("%s: Unavailable",r.label.c_str());
                ImGui::PopTextWrapPos();
            }
        }else ImGui::TextWrapped("%s",monitor.status.c_str());
        if(menuOpen&&ImGui::IsWindowHovered()&&ImGui::IsMouseDragging(ImGuiMouseButton_Left)){
            monitor.positionDirty=true;
            monitor.x=std::clamp(monitor.x+io.MouseDelta.x/std::max(1.f,io.DisplaySize.x-ImGui::GetWindowWidth()),0.f,1.f);
            monitor.y=std::clamp(monitor.y+io.MouseDelta.y/std::max(1.f,io.DisplaySize.y-ImGui::GetWindowHeight()),0.f,1.f);
        }
        if(monitor.positionDirty&&ImGui::IsMouseReleased(ImGuiMouseButton_Left)){monitor.Save();monitor.positionDirty=false;}
    }ImGui::End();
}
}

