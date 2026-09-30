// Synthetic ImGui exercise. No game, graphics hook or optional DLL is loaded.
#define NOMINMAX
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <map>
#include <string>
#include "../optiscaler/OptiScaler/include/imgui/imgui.h"
#include "../optiscaler/OptiScaler/include/imgui/imgui_internal.h"

static std::map<ImGuiID,ImRect> rectangles;
static std::map<std::string,ImRect> items;
void ImGuiTestEngineHook_ItemAdd(ImGuiContext*,ImGuiID id,const ImRect& rect,const ImGuiLastItemData*){rectangles[id]=rect;}
void ImGuiTestEngineHook_ItemInfo(ImGuiContext*,ImGuiID id,const char* label,ImGuiItemStatusFlags){if(rectangles.count(id))items[label]=rectangles[id];}
void ImGuiTestEngineHook_Log(ImGuiContext*,const char*,...){}
const char* ImGuiTestEngine_FindItemDebugLabel(ImGuiContext*,ImGuiID){return "fixture";}
namespace OptiShadeUI {
// The panel depends on EffectSwitch's click result, not a checkbox mutation.
static bool EffectSwitch(const char* id,bool){
    ImGui::PushID(id);const bool clicked=ImGui::InvisibleButton("switch",ImVec2(40,22));
    items[id]=ImRect(ImGui::GetItemRectMin(),ImGui::GetItemRectMax());ImGui::PopID();return clicked;
}
}
#include "../optiscaler/OptiScaler/menu/optishade_mfg_ui.inl"

static optishade::mfg::Snapshot snapshot;
static OptiShadeMfgUI::PanelState state;
static int saves=0;
static bool failSave=false;
static std::string Frame(){
    auto& io=ImGui::GetIO();io.DeltaTime=1.f/60;items.clear();rectangles.clear();
    ImGui::NewFrame();ImGui::SetNextWindowPos(ImVec2(0,0));ImGui::SetNextWindowSize(ImVec2(1000,1100));
    ImGui::Begin("MFG fixture",nullptr,ImGuiWindowFlags_NoSavedSettings|ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoResize);
    GImGui->LogBuffer.clear();ImGui::LogToBuffer();
    OptiShadeMfgUI::DrawPanel(snapshot,state,[](const auto& value,std::string& error){
        ++saves;if(failSave){error="Fixture save denied; original settings retained.";return false;}
        snapshot.settings=value;return true;
    });
    // BeginCombo in this ImGui revision emits ItemAdd but not ItemInfo.
    ImGui::PushID("OptiShade MFG");for(const char* label:{"Mode","Multiplier","MFG preset"}){
        const auto id=ImGui::GetID(label);if(rectangles.count(id))items[label]=rectangles.at(id);
    }ImGui::PopID();
    std::string text=GImGui->LogBuffer.c_str();ImGui::LogFinish();
    ImGui::End();ImGui::Render();assert(ImGui::GetDrawData()->CmdListsCount>0);
    for(auto* texture:ImGui::GetPlatformIO().Textures){texture->SetTexID(1);texture->SetStatus(ImTextureStatus_OK);}return text;
}
static std::string Click(const char* label){
    Frame(); // Let a newly opened popup settle its auto-fit position.
    if(!items.count(label)){fprintf(stderr,"Missing UI item: %s\n",label);for(const auto& item:items)fprintf(stderr,"  %s\n",item.first.c_str());}
    assert(items.count(label));const auto center=items.at(label).GetCenter();auto& io=ImGui::GetIO();
    io.AddMousePosEvent(center.x,center.y);Frame();io.AddMouseButtonEvent(0,true);Frame();
    io.AddMouseButtonEvent(0,false);return Frame();
}
struct Configuration {
    bool ExternalFrameGeneration=false,FGDLSSGAdaMfgUnlock=true,FGDLSSGAmpereMfgUnlock=true;
    bool savedExternal=false,savedAda=false,savedAmpere=false,success=true;
    bool SaveIni(){savedExternal=ExternalFrameGeneration;savedAda=FGDLSSGAdaMfgUnlock;savedAmpere=FGDLSSGAmpereMfgUnlock;return success;}
};
int main(){
    using namespace OptiShadeMfgUI;
    for(const char* name:{"NVIDIA GeForce RTX 4090","NVIDIA GeForce RTX 4070 Ti SUPER","NVIDIA GeForce RTX 4060 Laptop GPU"})assert(SupportedRenderingGpu(true,name));
    for(const char* name:{"NVIDIA GeForce RTX 5090","NVIDIA GeForce RTX 3090","NVIDIA GeForce RTX 2080","AMD Radeon RX 9070 XT","","NVIDIA GeForce RTX 40900"})assert(!SupportedRenderingGpu(true,name));
    assert(!SupportedRenderingGpu(false,"NVIDIA GeForce RTX 4090"));
    snapshot.verified=true;snapshot.owned=true;
    assert(ReplacesOrdinaryControls(snapshot,true)); // stale status must keep conflicting controls locked
    assert(!ReplacesOrdinaryControls(snapshot,false));
    snapshot.owned=false;assert(!ReplacesOrdinaryControls(snapshot,true));snapshot.owned=true;
    snapshot.verified=false;assert(!ReplacesOrdinaryControls(snapshot,true));snapshot.verified=true;
    Configuration config;assert(SaveSettings(config,true));assert(config.savedExternal&&!config.savedAda&&!config.savedAmpere);
    config=Configuration{};assert(SaveSettings(config,false));assert(!config.savedExternal&&config.savedAda&&config.savedAmpere);
    config.success=false;assert(!SaveSettings(config,true));
    snapshot.identity="synthetic-game-a";state.Observe(snapshot);state.draft.multiplier=4;state.dirty=true;
    snapshot.settings.multiplier=3;state.Observe(snapshot);assert(state.draft.multiplier==4);
    snapshot.identity="synthetic-game-b";state.Observe(snapshot);assert(state.draft.multiplier==3&&!state.dirty);
    state.Observe({});assert(!state.initialized&&!state.dirty&&state.identity.empty());
    ImGui::CreateContext();auto& io=ImGui::GetIO();io.DisplaySize=ImVec2(1600,1200);io.IniFilename=nullptr;io.LogFilename=nullptr;
    io.BackendFlags|=ImGuiBackendFlags_RendererHasTextures;GImGui->TestEngineHookItems=true;
    snapshot.live=snapshot.editable=true;snapshot.status.gpuFamily=1;snapshot.status.bridgeReady=true;
    snapshot.status.minMultiplier=2;snapshot.status.maxMultiplier=4;snapshot.status.canDynamic=true;snapshot.status.canReflex=true;
    snapshot.settings={};Frame();Frame();Click("Mode");Click("Fixed multiplier");Frame();
    assert(!state.draft.followGame&&!state.draft.dynamic);Click("Multiplier");assert(!items.count("5x"));Click("4x");
    assert(state.draft.multiplier==4);Click("Apply MFG settings");assert(saves==1&&snapshot.settings.multiplier==4);
    Frame();Click("Mode");Click("Dynamic");Frame();Click("Custom target FPS");assert(state.draft.targetFps==120);
    Click("Custom target FPS");assert(state.draft.targetFps==0);
    Click("Discard changes");assert(SameSettings(state.draft,snapshot.settings));
    Frame();Click("Limit FPS with Reflex");assert(state.draft.reflexLimit==60);Click("Limit FPS with Reflex");assert(state.draft.reflexLimit==0);
    state.draft.multiplier=3;state.dirty=true;failSave=true;Frame();const auto failure=Click("Apply MFG settings");
    if(saves!=2||snapshot.settings.multiplier!=4||!state.dirty||failure.find("Fixture save denied")==std::string::npos)fprintf(stderr,"save fixture: saves=%d multiplier=%u dirty=%d text=%s\n",saves,snapshot.settings.multiplier,state.dirty,failure.c_str());
    assert(saves==2&&snapshot.settings.multiplier==4&&state.dirty&&failure.find("Fixture save denied")!=std::string::npos);
    failSave=false;snapshot.live=snapshot.editable=false;snapshot.message="MFG status is stale.";Frame();Click("Apply MFG settings");assert(saves==2);
    snapshot.live=snapshot.editable=true;snapshot.status.gpuFamily=2;Frame();Click("Apply MFG settings");assert(saves==2);
    snapshot.status.gpuFamily=1;snapshot.status.bridgeReady=false;Frame();Click("Apply MFG settings");assert(saves==2);
    snapshot.status.bridgeReady=true;snapshot.status.applied=true;snapshot.status.savedRequestObserved=true;
    snapshot.status.setOptionsAccepted=true;snapshot.status.requestRevision=snapshot.status.appliedRevision=3;
    snapshot.status.appliedMultiplier=4;auto text=Frame();assert(text.find("Accepted fixed multiplier: 4x")!=std::string::npos);
    snapshot.status.pending=true;text=Frame();assert(text.find("Accepted fixed multiplier")==std::string::npos&&text.find("change pending")!=std::string::npos);
    snapshot.status.pending=false;snapshot.status.appliedRevision=2;text=Frame();assert(text.find("Accepted fixed multiplier")==std::string::npos);
    snapshot.status.appliedRevision=3;snapshot.status.savedRequestObserved=false;text=Frame();assert(text.find("Accepted fixed multiplier")==std::string::npos);
    snapshot.status.realFpsMilli=40000;snapshot.status.outputFpsMilli=150000;snapshot.status.actualFramesPresented=4;snapshot.status.fpsAgeMs=500;
    text=Frame();assert(text.find("Recent backend timing: 40.0 game FPS / 150.0 presentation FPS")!=std::string::npos);
    snapshot.status.fpsAgeMs=3000;text=Frame();assert(text.find("Recent backend timing")==std::string::npos);
    ImGui::DestroyContext();puts("PASS: MFG UI mode/multiplier/toggle/apply/rollback, stale-owner isolation, native-GPU preservation, saved/accepted/timing distinctions");
}
