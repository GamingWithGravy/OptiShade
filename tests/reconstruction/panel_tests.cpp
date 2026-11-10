#include "PanelUi.h"
#include "PanelActionPolicy.h"
#include "EffectNumericUi.h"
#include <imgui/imgui_internal.h>
#include <iostream>
#include <stdexcept>
#include <cstring>
static unsigned checks=0;
#define CHECK(x) do{++checks;if(!(x))throw std::runtime_error(std::string(#x)+" @"+std::to_string(__LINE__));}while(0)
int main(){try{
 ImGui::CreateContext();auto& io=ImGui::GetIO();io.IniFilename=nullptr;io.LogFilename=nullptr;io.DisplaySize={1600,1200};io.DeltaTime=1.f/60;
 io.BackendFlags|=ImGuiBackendFlags_RendererHasTextures;io.Fonts->AddFontDefault();
 using namespace optishade::panel;
 {
  FooterActionInputs state;state.page=2;state.frameGenerationPending=true;state.nativeFrameGenerationCanSave=true;state.effectsPending=true;
  auto action=ChooseFooterAction(state);CHECK(action.kind==FooterActionKind::Effects&&action.actionable&&std::strcmp(action.saveLabel,"Save")==0);
  state.effectsPending=false;action=ChooseFooterAction(state);CHECK(action.kind==FooterActionKind::FrameGeneration&&action.actionable&&std::strcmp(action.saveLabel,"Save & Go")==0);
  state.nativeFrameGenerationCanSave=false;action=ChooseFooterAction(state);CHECK(action.kind==FooterActionKind::FrameGeneration&&!action.actionable);
  state.page=1;state.neuralPending=true;action=ChooseFooterAction(state);CHECK(action.kind==FooterActionKind::Neural&&action.actionable&&std::strcmp(action.saveLabel,"Save")==0);
  state.page=3;state.menuPending=true;action=ChooseFooterAction(state);CHECK(action.kind==FooterActionKind::Menu&&action.actionable);
  state.menuPending=false;state.page=0;state.neuralPending=false;state.frameGenerationPending=true;state.legacyFrameGeneration=true;state.frameGenerationAwaiting=true;
  action=ChooseFooterAction(state);CHECK(action.kind==FooterActionKind::FrameGeneration&&!action.actionable&&std::strcmp(action.saveLabel,"Save & Go")==0);
 }
 ApplyDefaultTheme(ImGui::GetStyle(),.75f);CHECK(ImGui::GetStyle().Colors[ImGuiCol_WindowBg].w==.75f);
 CHECK(ImGui::GetStyle().Colors[ImGuiCol_Text].x==243.f/255.f);
 CHECK(Contains("Neural rendering","RENDER"));CHECK(Contains("MFG", ""));CHECK(!Contains("Motion", "preset"));
 int quality=0,compat=0,trouble=0,look=0,enable=0;
 for(int frame=0;frame<6;++frame){
  ImGui::NewFrame();ImGui::SetNextWindowPos({15,15});ImGui::SetNextWindowSize({frame<2?460.f:620.f,1000.f});
  ImGui::Begin("Native panel harness",nullptr,ImGuiWindowFlags_NoSavedSettings);
  auto before=ImGui::GetStyle();
  DrawNr({false,"Not verified","Harness only; no game or GPU backend.",""},[&](bool){++enable;},[&]{++look;ImGui::TextUnformatted("Appearance binding");},[&]{++quality;},[&]{++compat;},[&]{++trouble;});
  auto after=ImGui::GetStyle();CHECK(before.ChildRounding==after.ChildRounding);CHECK(before.Colors[ImGuiCol_ChildBg].x==after.Colors[ImGuiCol_ChildBg].x);
  CHECK(ImGui::GetCursorPosY()<800);ImGui::End();ImGui::Render();
 }
 CHECK(look==6);CHECK(quality==0&&compat==0&&trouble==0);CHECK(enable==0);
 ImGui::NewFrame();ImGui::Begin("Native panel harness");Details().open=Section::Quality;
 CHECK(Group("Quality & speed",Section::Quality));CHECK(Details().open==Section::None);
 Details().open=Section::Colour;
 CHECK(Group("Compatibility",Section::Compatibility));CHECK(Details().open==Section::Colour);
 CHECK(Group("Colour, masks and exposure",Section::Colour));CHECK(Details().open==Section::None);
 Details().open=Section::Experimental;
 CHECK(Group("Compatibility",Section::Compatibility));CHECK(Details().open==Section::Experimental);
 CHECK(Group("Experimental routing",Section::Experimental));CHECK(Details().open==Section::None);
 Details().open=Section::NrTechnical;
 CHECK(Group("Troubleshooting",Section::Troubleshooting));CHECK(Details().open==Section::NrTechnical);
 CHECK(Group("Technical details",Section::NrTechnical));CHECK(Details().open==Section::None);
 CHECK(!Details().restoreFocus);
 Open("Explanation","Existing settings remain unchanged.");CHECK(Details().mode==DetailMode::Explain);int page=1;DrawDetail(page);CHECK(page==1);CloseDetail();CHECK(Details().mode==DetailMode::None);
 Open("Search","",DetailMode::Search);std::strcpy(Details().query,"mfg");DrawDetail(page);CHECK(page==1);CloseDetail();
 ImGui::End();ImGui::Render();
 // Inline help must never toggle the rendering request; the switch must still dispatch.
 Details()={};bool request=false;ImVec2 helpPoint{},switchPoint{};
 for(int frame=0;frame<10;++frame){
  if(frame==3||frame==4){io.AddMousePosEvent(helpPoint.x,helpPoint.y);io.AddMouseButtonEvent(0,frame==3);}
  if(frame==7||frame==8){io.AddMousePosEvent(switchPoint.x,switchPoint.y);io.AddMouseButtonEvent(0,frame==7);}
  ImGui::NewFrame();ImGui::SetNextWindowPos({0,0});ImGui::SetNextWindowSize({560,300});
  ImGui::Begin("Toggle interaction",nullptr,ImGuiWindowFlags_NoTitleBar|ImGuiWindowFlags_NoSavedSettings);
  const auto p=ImGui::GetCursorScreenPos();const float u=ImGui::GetFontSize(),width=ImGui::GetContentRegionAvail().x;
  helpPoint={p.x+HeadingFont()->CalcTextSizeA(u*1.12f,10000,0,"Enable for this session").x+u*1.2f,p.y+u*.8f};switchPoint={p.x+width-u*1.9f,p.y+u*.95f};
  Toggle("Enable for this session",&request,"Session help");
  ImGui::End();ImGui::Render();
  if(frame==5){CHECK(!request);CHECK(Details().mode==DetailMode::Explain);CloseDetail();}
 }
 CHECK(request);
 // Draw-list text must obey ImGui's hidden-ID convention in custom toggles.
 ImGui::NewFrame();ImGui::SetNextWindowPos({0,0});ImGui::SetNextWindowSize({650,400});
 ImGui::Begin("Hidden toggle labels",nullptr,ImGuiWindowFlags_NoTitleBar|ImGuiWindowFlags_NoSavedSettings);
 auto* toggleDraw=ImGui::GetWindowDrawList();bool toggleValue=false;
 int beforeVertices=toggleDraw->VtxBuffer.Size;Toggle("##native-mfg-enabled",&toggleValue);int hiddenVertices=toggleDraw->VtxBuffer.Size-beforeVertices;
 beforeVertices=toggleDraw->VtxBuffer.Size;ImGui::PushID("empty-label");Toggle("",&toggleValue);ImGui::PopID();int emptyVertices=toggleDraw->VtxBuffer.Size-beforeVertices;
 beforeVertices=toggleDraw->VtxBuffer.Size;Toggle("Frame generation##other-id",&toggleValue);int visibleVertices=toggleDraw->VtxBuffer.Size-beforeVertices;
 CHECK(hiddenVertices==emptyVertices);CHECK(visibleVertices>hiddenVertices);
 ImGui::End();ImGui::Render();
 float numeric=1.f;ImVec2 inputPoint{};bool submitted=false;
 for(int frame=0;frame<13;++frame){
  if(frame==3||frame==4){io.AddMousePosEvent(inputPoint.x,inputPoint.y);io.AddMouseButtonEvent(0,frame==3);}
  if(frame==5){io.AddKeyEvent(ImGuiMod_Ctrl,true);io.AddKeyEvent(ImGuiKey_A,true);}
  if(frame==6){io.AddKeyEvent(ImGuiMod_Ctrl,false);io.AddKeyEvent(ImGuiKey_A,false);io.AddInputCharactersUTF8("1.375");}
  if(frame==9)io.AddKeyEvent(ImGuiKey_Enter,true);
  if(frame==10)io.AddKeyEvent(ImGuiKey_Enter,false);
  ImGui::NewFrame();ImGui::SetNextWindowPos({0,0});ImGui::SetNextWindowSize({650,220});
  ImGui::Begin("Exact value interaction",nullptr,ImGuiWindowFlags_NoTitleBar|ImGuiWindowFlags_NoSavedSettings);
  submitted|=optishade::effects_ui::Numeric("Shader strength",numeric,false,true,0.f,2.f);
  const auto lo=ImGui::GetItemRectMin(),hi=ImGui::GetItemRectMax();inputPoint={(lo.x+hi.x)/2,(lo.y+hi.y)/2};
  ImGui::End();ImGui::Render();
  if(frame==8)CHECK(numeric==1.f); // Partial typing must not send intermediate values.
 }
 CHECK(submitted);CHECK(numeric==1.375f);
 // Clicking outside also commits, and declared shader bounds are enforced.
 for(int frame=0;frame<13;++frame){
  if(frame==3||frame==4){io.AddMousePosEvent(inputPoint.x,inputPoint.y);io.AddMouseButtonEvent(0,frame==3);}
  if(frame==5){io.AddKeyEvent(ImGuiMod_Ctrl,true);io.AddKeyEvent(ImGuiKey_A,true);}
  if(frame==6){io.AddKeyEvent(ImGuiMod_Ctrl,false);io.AddKeyEvent(ImGuiKey_A,false);io.AddInputCharactersUTF8("3.25");}
  if(frame==9||frame==10){io.AddMousePosEvent(300,150);io.AddMouseButtonEvent(0,frame==9);}
  ImGui::NewFrame();ImGui::SetNextWindowPos({0,0});ImGui::SetNextWindowSize({650,220});
  ImGui::Begin("Exact value interaction",nullptr,ImGuiWindowFlags_NoTitleBar|ImGuiWindowFlags_NoSavedSettings);
  optishade::effects_ui::Numeric("Shader strength",numeric,false,true,0.f,2.f);
  ImGui::End();ImGui::Render();if(frame==8)CHECK(numeric==1.375f);
 }
 CHECK(numeric==2.f);
 ImGui::DestroyContext();
 std::cout<<checks<<" native ImGui layout/control assertions passed (headless UI; not a Windows/game render)\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
