// OptiShade controls for the verified optional MFG backend. Ordinary/native FG
// remains on its existing UI path when this backend does not own the session.
#include "../../../shared/MfgControlWin.h"
#include <regex>
namespace OptiShadeMfgUI
{
using optishade::mfg::Settings;
using optishade::mfg::Snapshot;

static bool SameSettings(const Settings& a,const Settings& b)
{
    return a.followGame==b.followGame && a.dynamic==b.dynamic && a.multiplier==b.multiplier &&
        a.targetFps==b.targetFps && a.preset==b.preset && a.vsyncMode==b.vsyncMode && a.reflexLimit==b.reflexLimit;
}
static bool SupportedRenderingGpu(bool hardwareNvidia,const std::string& name)
{
    static const std::regex rtx40(R"(\bRTX\s*40\d{2}\b)",std::regex_constants::icase);
    return hardwareNvidia && std::regex_search(name,rtx40);
}
static bool ReplacesOrdinaryControls(const Snapshot& snapshot,bool supportedRenderingGpu)
{ return snapshot.verified && snapshot.owned && supportedRenderingGpu; }

template<class Configuration>
static bool SaveSettings(Configuration& config,bool owned)
{
    // Persist the installation's existing owner. This does not change hooks or
    // claim that a different backend can take ownership during this session.
    if(owned){config.ExternalFrameGeneration=true;config.FGDLSSGAdaMfgUnlock=false;config.FGDLSSGAmpereMfgUnlock=false;}
    return config.SaveIni();
}

struct PanelState
{
    Settings draft{};
    bool initialized=false,dirty=false;
    std::string feedback,identity;
    void Observe(const Snapshot& snapshot)
    {
        if(!snapshot.verified){initialized=false;dirty=false;feedback.clear();identity.clear();return;}
        if(identity!=snapshot.identity){initialized=false;dirty=false;feedback.clear();identity=snapshot.identity;}
        if(!initialized || !dirty){draft=snapshot.settings;initialized=true;}
    }
};
static optishade::mfg::Bridge bridge;
static PanelState panel;

static bool OwnsFrameGeneration(bool supportedRenderingGpu)
{ return ReplacesOrdinaryControls(bridge.Refresh(),supportedRenderingGpu); }

static const char* ModeLabel(const Settings& settings)
{ return settings.followGame?"Follow game":settings.dynamic?"Dynamic":"Fixed multiplier"; }

static void DrawStatus(const Snapshot& snapshot)
{
    if(!snapshot.live){ImGui::TextWrapped("%s",snapshot.message.c_str());return;}
    const auto& status=snapshot.status;
    ImGui::TextWrapped("Saved request: %s",ModeLabel(snapshot.settings));
    if(!snapshot.settings.followGame && !snapshot.settings.dynamic)
        ImGui::Text("Requested multiplier: %ux",snapshot.settings.multiplier);
    if(!status.savedRequestObserved)ImGui::TextWrapped("Backend: waiting to read the saved request.");
    else if(status.pending)ImGui::TextWrapped("Backend: change pending.");
    else if(status.applied && status.setOptionsAccepted && status.requestRevision==status.appliedRevision)
        ImGui::TextWrapped("Backend: current options accepted. This alone does not confirm generated frames.");
    else ImGui::TextWrapped("Backend: waiting for the game's frame-generation pipeline.");
    if(!status.gameFgOn)ImGui::TextWrapped("Enable DLSS Frame Generation in the game's graphics settings.");
    if(status.presetRestart)ImGui::TextWrapped("Preset saved. Restart the game to apply it.");
    if(status.applied && status.savedRequestObserved && !status.pending && status.setOptionsAccepted && status.requestRevision==status.appliedRevision){
        if(status.appliedFollowGame)ImGui::TextDisabled("Accepted mode: Follow game");
        else if(status.appliedDynamic)ImGui::TextDisabled("Accepted mode: Dynamic");
        else ImGui::TextDisabled("Accepted fixed multiplier: %ux",status.appliedMultiplier);
    }
    if(status.realFpsMilli && status.outputFpsMilli && status.fpsAgeMs<=2000 && status.actualFramesPresented>1)
        ImGui::Text("Recent backend timing: %.1f game FPS / %.1f presentation FPS",status.realFpsMilli/1000.f,status.outputFpsMilli/1000.f);
    else ImGui::TextDisabled("Generated-frame timing is not available yet.");
}

template<class Save>
static void DrawPanel(const Snapshot& snapshot,PanelState& state,Save save)
{
    state.Observe(snapshot);
    ImGui::PushID("OptiShade MFG");
    ImGui::TextUnformatted("Multi Frame Generation - RTX 40");
    ImGui::TextWrapped("Control Multi Frame Generation using the supported NVIDIA backend. Enable DLSS Frame Generation in the game's graphics settings first.");
    if(snapshot.live && snapshot.status.gpuFamily!=1)
        ImGui::TextWrapped("The backend reported a different graphics-card family. These controls are unavailable.");
    ImGui::BeginDisabled(!snapshot.editable || !snapshot.status.bridgeReady || snapshot.status.gpuFamily!=1);
    auto& draft=state.draft;
    if(ImGui::BeginCombo("Mode",ModeLabel(draft)))
    {
        if(ImGui::Selectable("Follow game",draft.followGame)){draft.followGame=true;draft.dynamic=false;draft.multiplier=2;state.dirty=true;}
        if(ImGui::Selectable("Fixed multiplier",!draft.followGame&&!draft.dynamic)){
            draft.followGame=false;draft.dynamic=false;
            draft.multiplier=std::clamp(draft.multiplier,std::max(2u,snapshot.status.minMultiplier),std::max(2u,snapshot.status.maxMultiplier));state.dirty=true;
        }
        ImGui::BeginDisabled(!snapshot.status.canDynamic);
        if(ImGui::Selectable("Dynamic",!draft.followGame&&draft.dynamic)){draft.followGame=false;draft.dynamic=true;state.dirty=true;}
        ImGui::EndDisabled();ImGui::EndCombo();
    }
    if(!draft.followGame&&!draft.dynamic){
        const auto label=std::to_string(draft.multiplier)+"x";
        if(ImGui::BeginCombo("Multiplier",label.c_str())){
            for(unsigned value=std::max(2u,snapshot.status.minMultiplier);value<=std::min(6u,snapshot.status.maxMultiplier);++value){
                const auto choice=std::to_string(value)+"x";
                if(ImGui::Selectable(choice.c_str(),draft.multiplier==value)){draft.multiplier=value;state.dirty=true;}
            }
            ImGui::EndCombo();
        }
        ImGui::TextWrapped("Available multipliers follow the active game's runtime limit.");
    }
    if(!draft.followGame&&draft.dynamic){
        bool custom=draft.targetFps!=0;
        if(OptiShadeUI::EffectSwitch("Custom target FPS",custom)){draft.targetFps=custom?0u:120u;state.dirty=true;}
        ImGui::SameLine();ImGui::TextUnformatted("Custom target FPS");
        if(draft.targetFps){int fps=static_cast<int>(draft.targetFps);if(ImGui::SliderInt("Target FPS",&fps,1,1000,"%d",ImGuiSliderFlags_AlwaysClamp)){draft.targetFps=static_cast<unsigned>(fps);state.dirty=true;}}
        else ImGui::TextWrapped("Target follows the display refresh rate.");
        if(!snapshot.status.canDynamic)ImGui::TextWrapped("Dynamic is unavailable in the current pipeline. Choose Follow game or a fixed multiplier.");
    }
    const char* presets[]={"Game / driver","Preset A","Preset B"};int preset=static_cast<int>(std::min(draft.preset,2u));
    if(ImGui::Combo("MFG preset",&preset,presets,3)){draft.preset=static_cast<unsigned>(preset);state.dirty=true;}
    ImGui::TextWrapped("Changing the preset after frame generation starts may require a game restart.");
    const bool reflexAvailable=snapshot.status.canReflex && !(draft.dynamic&&!draft.followGame);
    ImGui::BeginDisabled(!reflexAvailable);
    bool limit=draft.reflexLimit!=0;
    if(OptiShadeUI::EffectSwitch("Limit FPS with Reflex",limit)){draft.reflexLimit=limit?0u:60u;state.dirty=true;}
    ImGui::SameLine();ImGui::TextUnformatted("Limit FPS with Reflex");
    if(draft.reflexLimit){int fps=static_cast<int>(draft.reflexLimit);if(ImGui::SliderInt("FPS limit",&fps,1,1000,"%d",ImGuiSliderFlags_AlwaysClamp)){draft.reflexLimit=static_cast<unsigned>(fps);state.dirty=true;}}
    ImGui::EndDisabled();
    if(!reflexAvailable)ImGui::TextWrapped("The manual limit is unavailable while Dynamic is active or Reflex is not connected.");
    state.dirty=!SameSettings(draft,snapshot.settings);
    ImGui::BeginDisabled(!state.dirty);
    if(ImGui::Button("Apply MFG settings")){
        std::string error;
        if(save(draft,error)){state.feedback="MFG settings saved. Waiting for the backend to apply the request.";state.dirty=false;state.initialized=false;}
        else state.feedback=error.empty()?"MFG settings could not be saved. Previous settings were kept.":error;
    }
    ImGui::SameLine();if(ImGui::Button("Discard changes")){draft=snapshot.settings;state.dirty=false;state.feedback.clear();}
    ImGui::EndDisabled();ImGui::EndDisabled();
    ImGui::TextWrapped("Apply MFG settings saves these controls for this game.");
    if(!state.feedback.empty())ImGui::TextWrapped("%s",state.feedback.c_str());
    DrawStatus(snapshot);
    ImGui::PopID();
}

static bool Draw(bool supportedRenderingGpu)
{
    const auto snapshot=bridge.Refresh();
    if(!ReplacesOrdinaryControls(snapshot,supportedRenderingGpu)){panel.Observe(Snapshot{});return false;}
    DrawPanel(snapshot,panel,[](const Settings& settings,std::string& error){return bridge.Save(settings,error);});
    return true;
}
}
