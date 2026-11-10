// OptiShade additions, GPL-3.0-or-later. Live official controls, not a second settings store.
#include "../../../shared/CockpitControls.h"
namespace OptiShadeCockpitUI {
static void Draw(){
 using namespace optishade::cockpit;
 const auto host=GetModuleHandleW(L"ReShade64.dll");
 const auto read=host?reinterpret_cast<Read>(GetProcAddress(host,"OptiShadeCockpitRead")):nullptr;
 const auto send=host?reinterpret_cast<Send>(GetProcAddress(host,"OptiShadeCockpitSend")):nullptr;
 Snapshot s;const bool ready=read&&read(&s,sizeof(s));
 static uint64_t serial=0,awaiting=0,generation=0;
 static uint32_t expectedField=0,expectedValue=0;static uint64_t sentAt=0;
 static std::string message;
 static int smoothingDraft=35,glassDraft=100;static bool smoothingEdit=false,glassEdit=false;
 if(generation!=s.generation){generation=s.generation;awaiting=0;expectedField=0;message.clear();smoothingEdit=glassEdit=false;}
 if(awaiting&&GetTickCount64()-sentAt>2500){awaiting=0;message="No acknowledgement yet. Current runtime values are shown; retry when the simulator responds.";}
 if(awaiting&&s.applied>=awaiting){
   const auto value=expectedField==Enabled?s.enabled:expectedField==Tint?s.tint:expectedField==Flipped?s.flipped:expectedField==Smoothing?s.smoothing:s.glass;
   message=value==expectedValue?"Setting received by the official cockpit fix.":"The cockpit setting changed elsewhere. Current value reloaded.";
   awaiting=0;
 }
 auto request=[&](uint32_t field,uint32_t value){
   serial=std::max(serial,s.applied)+1;
   Command c;c.field=field;c.value=value;c.generation=s.generation;c.sequence=serial;
   if(send&&send(&c,sizeof(c))){awaiting=serial;sentAt=GetTickCount64();expectedField=field;expectedValue=value;message="Sending cockpit setting...";}
   else message="The cockpit runtime changed or is busy. Retry when its status reconnects.";
 };
 optishade::panel::Card("Glass cockpit correction",[&]{
   ImGui::TextUnformatted("Glass cockpit correction");
   ImGui::TextWrapped("Included with OptiShade for MSFS 2024. Powered by IFreemz's official Glass Cockpit DLSS Fix.");
   ImGui::TextDisabled("Independent of NR and your image-effects preset.");
   if(!ready&&s.report[0]){
     ImGui::TextWrapped("The cockpit add-on responded, but its control interface is not compatible with this OptiShade build. The screen correction may still be running. Update OptiShade and include the cockpit report in diagnostics.");
     if(ImGui::Button("Copy cockpit report"))ImGui::SetClipboardText(s.report);
     return;
   }
   if(!ready){ImGui::TextWrapped("Waiting for the bundled cockpit controls. Available with the matching MSFS 2024 runtime. Other simulators do not use this fix.");if(awaiting){awaiting=0;message="Connection lost; check current values before retrying.";}return;}
   // Upstream reports actual running/upscaler/screen evidence, never infer Working from loaded files.
   const std::string report=s.report;const auto start=report.find("status: ");
   if(start!=std::string::npos){const auto end=report.find('\n',start);ImGui::TextWrapped("%s",report.substr(start+8,end-start-8).c_str());}
   ImGui::Separator();
   ImGui::BeginDisabled(awaiting!=0);
   bool enabled=s.enabled!=0,tint=s.tint!=0;
   if(optishade::panel::Toggle("Fix enabled",&enabled))request(Enabled,enabled);
   if(!smoothingEdit&&!awaiting)smoothingDraft=static_cast<int>(s.smoothing);
   ImGui::SetNextItemWidth(-1);
   ImGui::SliderInt("Line smoothing",&smoothingDraft,0,50,"%d%%",ImGuiSliderFlags_AlwaysClamp);
   if(ImGui::IsItemActivated())smoothingEdit=true;
   if(ImGui::IsItemDeactivated()){smoothingEdit=false;if(smoothingDraft!=static_cast<int>(s.smoothing))request(Smoothing,smoothingDraft);}
   if(optishade::panel::Toggle("Green diagnostic tint",&tint))request(Tint,tint);
   ImGui::TextWrapped("Tint identifies the screens the fix actually covers. It is not saved between sessions.");
   if(ImGui::CollapsingHeader("Cockpit compatibility & advanced")){
     bool flipped=s.flipped!=0;if(ImGui::Checkbox("Flip jitter direction",&flipped))request(Flipped,flipped);
     if(!glassEdit&&!awaiting)glassDraft=static_cast<int>(s.glass);
     ImGui::SetNextItemWidth(-1);ImGui::SliderInt("Glass layer",&glassDraft,0,100,"%d%%",ImGuiSliderFlags_AlwaysClamp);
     if(ImGui::IsItemActivated())glassEdit=true;
     if(ImGui::IsItemDeactivated()){glassEdit=false;if(glassDraft!=static_cast<int>(s.glass))request(Glass,glassDraft);}
     ImGui::TextWrapped("Change jitter only when screen text shimmers at rest. Glass layer controls retained glare, dirt and reflections. This fix requires an eligible upscaling call; TAA alone does not establish that.");
   }
   ImGui::EndDisabled();
   if(!message.empty())ImGui::TextWrapped("%s",message.c_str());
   if(ImGui::Button("Copy cockpit report"))ImGui::SetClipboardText(s.report);
   if(ImGui::CollapsingHeader("Cockpit diagnostic details"))ImGui::TextWrapped("%s",s.report);
   ImGui::TextDisabled("IFreemz · official add-on · manager updates from verified developer releases");
   if(ImGui::SmallButton("Copy cockpit support link"))ImGui::SetClipboardText("https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/issues");
 });
}
}
