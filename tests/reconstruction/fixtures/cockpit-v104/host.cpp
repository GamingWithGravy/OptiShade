#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include "optishade_cockpit_controls.hpp"
#include "dll_log.hpp"
#include <imgui.h>
#include <iostream>
#include <stdexcept>
namespace reshade::log {void message(level,const char*,...){}}
extern "C" const void* ReShadeGetImGuiFunctionTable(uint32_t);
extern "C" bool OptiShadeCockpitRead(optishade::cockpit::Snapshot*,uint32_t);
extern "C" bool OptiShadeCockpitSend(const optishade::cockpit::Command*,uint32_t);
#define CHECK(v) do{if(!(v))throw std::runtime_error(#v);++checks;}while(0)
int main(int argc,char**argv){try{
 int checks=0;CHECK(argc==2);auto dll=LoadLibraryA(argv[1]);CHECK(dll);
 auto table=(void(*)(const void*))GetProcAddress(dll,"FixtureSetTable");auto draw=(void(*)())GetProcAddress(dll,"FixtureDraw");CHECK(table&&draw);table(ReShadeGetImGuiFunctionTable(19250));
 ImGui::CreateContext();auto& io=ImGui::GetIO();io.DisplaySize={1000,800};io.DeltaTime=.016f;io.IniFilename=nullptr;io.LogFilename=nullptr;unsigned char* pixels;int w,h;io.Fonts->GetTexDataAsRGBA32(&pixels,&w,&h);
 auto poll=[&]{ImGui::NewFrame();ImGui::SetNextWindowPos({-20000,-20000});ImGui::SetNextWindowSize({900,1000});ImGui::Begin("fixture",nullptr,ImGuiWindowFlags_NoInputs|ImGuiWindowFlags_NoSavedSettings);auto p=oscockpit::Begin(1);oscockpit::active=&p;draw();oscockpit::active=nullptr;ImGui::End();oscockpit::End(p);ImGui::Render();for(auto* list:ImGui::GetDrawData()->CmdLists)for(const auto& cmd:list->CmdBuffer){
 const bool visibleClip=cmd.ClipRect.z>0&&cmd.ClipRect.w>0&&cmd.ClipRect.x<io.DisplaySize.x&&cmd.ClipRect.y<io.DisplaySize.y;
 if(!visibleClip)continue;
 for(unsigned i=0;i<cmd.ElemCount;++i){const auto& vertex=list->VtxBuffer[cmd.VtxOffset+list->IdxBuffer[cmd.IdxOffset+i]];CHECK(vertex.pos.x<0||vertex.pos.y<0||vertex.pos.x>=io.DisplaySize.x||vertex.pos.y>=io.DisplaySize.y);}
 }};
 using namespace optishade::cockpit;Snapshot s;CHECK(!OptiShadeCockpitRead(&s,sizeof(s)));poll();CHECK(OptiShadeCockpitRead(&s,sizeof(s)));CHECK(s.fields==All);CHECK(s.enabled==1&&s.smoothing==35&&s.glass==100&&s.tint==0&&s.flipped==0);CHECK(std::strstr(s.report,"FIXTURE"));
 uint64_t serial=0;
 for(auto field:{Enabled,Tint,Flipped,Smoothing,Glass}){
  Command c;c.field=field;c.value=field==Enabled?0:field==Smoothing?42:field==Glass?73:1;c.sequence=++serial;c.generation=s.generation;
  auto bad=c;bad.generation+=1;CHECK(!OptiShadeCockpitSend(&bad,sizeof(bad)));CHECK(OptiShadeCockpitSend(&c,sizeof(c)));CHECK(!OptiShadeCockpitSend(&c,sizeof(c)));poll();poll();CHECK(OptiShadeCockpitRead(&s,sizeof(s)));CHECK(s.applied==serial);CHECK(!OptiShadeCockpitSend(&c,sizeof(c)));
 }
 CHECK(s.enabled==0&&s.tint==1&&s.flipped==1&&s.smoothing==42&&s.glass==73);
 CHECK(std::strstr(s.report,"enabled=0 jitter_positive=0 tint=1 line_smoothing=42 extra_smoothing=0 glass_strength=73"));
 Command invalid;invalid.sequence=serial+1;invalid.generation=s.generation;invalid.field=Smoothing;invalid.value=51;CHECK(!OptiShadeCockpitSend(&invalid,sizeof(invalid)));invalid.field=Glass;invalid.value=101;CHECK(!Valid(invalid));invalid.field=32;CHECK(!Valid(invalid));
 oscockpit::sampledAt=oscockpit::Now()-1600;CHECK(!OptiShadeCockpitRead(&s,sizeof(s)));oscockpit::Missing();CHECK(!oscockpit::published.available);CHECK(oscockpit::pending.field==0);poll();CHECK(OptiShadeCockpitRead(&s,sizeof(s)));CHECK(s.generation>1);
 ImGui::DestroyContext();FreeLibrary(dll);std::cout<<checks<<" assertions passed against unchanged official v1.0.4 status_panel.cpp; stub settings only, no simulator output claim\n";
}catch(const std::exception&e){std::cerr<<e.what()<<"\n";return 1;}}
