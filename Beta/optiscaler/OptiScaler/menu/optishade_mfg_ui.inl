// OptiShade additions, GPL-3.0-or-later. Native controls; no second renderer.
#include "../../../shared/MfgBackgroundStatus.h"
#include "../../../shared/MfgDraft.h"
#include "../../../shared/OptiMfgPreferences.h"
#include "../../../shared/NativeMfgControl.h"
#include "../../../shared/RuntimeRenderContext.h"
#include "native_mfg_ui_state.h"
#include "native_mfg_ui_diagnostics.h"
#include "../../shared/OptiMfgLiveBridge.h"
#include "../dlssnr/SelfHelp.h"
#include <hooks/Streamline_Hooks.h>
namespace OptiShadeMfgUI {
static bool DrawOptiMfgComponent(bool connected);
static void DrawNative(API api);
static void DrawFrameGeneration();
static constexpr const char* ActivationHelp="OptiShade can prepare MFG, but the current blocker is that the game/provider has not exposed a compatible live DLSS Frame Generation path. This is a game/provider compatibility limitation, not an OptiShade installation failure. If you expected the game to support MFG, or are unsure, send diagnostics to Discord.";
using optishade::mfg::Settings;
using optishade::mfg::Snapshot;
static bool ReplacesOrdinaryControls(const Snapshot& s,bool supported){return s.verified&&s.owned&&supported;}
template<class Configuration> static bool SaveSettings(Configuration& config,bool owned){
    if(owned){config.ExternalFrameGeneration=true;config.FGDLSSGAdaMfgUnlock=false;config.FGDLSSGAmpereMfgUnlock=false;}
    return config.SaveIni();
}
static optishade::mfg::Draft panel;
static optishade::native_mfg::UiDraft nativePanel;
static optishade::optimfg::LiveBridge optiMfgBridge;
static void DrawFrameGeneration(){
    // The Performance page has one frame-generation control surface: OptiMFG.
    // Keep it visible while disconnected so the user sees the connection
    // instructions; never silently fall back to the older native controls.
    const bool connected=optiMfgBridge.Open()&&optiMfgBridge.Ready();
    DrawOptiMfgComponent(connected);
}
static std::wstring OptiMfgControlsPath(){
    wchar_t image[32768]{};const DWORD length=GetModuleFileNameW(nullptr,image,static_cast<DWORD>(std::size(image)));
    if(!length||length>=std::size(image))return {};
    std::wstring path(image,length);const auto slash=path.find_last_of(L"\\/");if(slash==std::wstring::npos)return {};
    path.resize(slash);path+=L"\\OptiShadeData\\OptiMFG\\controls.ini";return path;
}
static LONG LoadOptiMfgRequest(){return optishade::optimfg::LoadPreference(OptiMfgControlsPath());}
static bool SaveOptiMfgRequest(LONG value){return optishade::optimfg::SavePreference(OptiMfgControlsPath(),value);}
static LONG savedOptiMfgRequest=LoadOptiMfgRequest();
static bool savedOptiMfgRequestPending=true;
static LONG lastActiveOptiMfgRequest=savedOptiMfgRequest>=2?savedOptiMfgRequest:2;
static std::string optiMfgSaveFeedback;
static bool SaveCurrentOptiMfgChoice(){
    const bool ok=SaveOptiMfgRequest(savedOptiMfgRequest)&&LoadOptiMfgRequest()==savedOptiMfgRequest;
    optiMfgSaveFeedback=ok?"MFG choice saved for future starts":"MFG choice could not be saved; check game-folder write access";
    savedOptiMfgRequestPending=ok;
    return ok;
}
static bool SetHotkeyRequest(LONG request){
    if(request < -1 || request > 6 || request == 1)return false;
    const bool connected=optiMfgBridge.Open()&&optiMfgBridge.Ready();
    if(!connected&&!optiMfgBridge.Installed())return false;
    if(request>=2){
        lastActiveOptiMfgRequest=request;
        if(connected&&optiMfgBridge.StateCalls()>0){
            const LONG generatedMaximum=optiMfgBridge.MaximumGenerated();
            if(generatedMaximum>=1)request=std::min(request,generatedMaximum+1);
        }
    }
    savedOptiMfgRequest=request;
    if(!SaveCurrentOptiMfgChoice())return false;
    if(connected&&optiMfgBridge.Request(request))savedOptiMfgRequestPending=false;
    return true;
}
static void HotkeyToggle(){
    const bool connected=optiMfgBridge.Open()&&optiMfgBridge.Ready();
    const LONG reported=connected?optiMfgBridge.RequestValue():savedOptiMfgRequest;
    const LONG current=(reported==-1||reported==0||(reported>=2&&reported<=6))?reported:savedOptiMfgRequest;
    if(current>=2)lastActiveOptiMfgRequest=current;
    SetHotkeyRequest(current>=2?0:lastActiveOptiMfgRequest);
}
static void HotkeyAdjustMultiplier(int delta){
    if(delta!=1&&delta!=-1)return;
    const bool connected=optiMfgBridge.Open()&&optiMfgBridge.Ready();
    if(!connected&&!optiMfgBridge.Installed())return;
    LONG maximum=6;
    if(connected&&optiMfgBridge.StateCalls()>0){const LONG generated=optiMfgBridge.MaximumGenerated();if(generated>=1)maximum=std::clamp(generated+1,2L,6L);}
    const LONG reported=connected?optiMfgBridge.RequestValue():savedOptiMfgRequest;
    const LONG requested=(reported>=2&&reported<=6)?reported:savedOptiMfgRequest;
    const LONG current=(requested>=2&&requested<=maximum)?requested:2;
    const LONG next=std::clamp(current+delta,2L,maximum);
    SetHotkeyRequest(next);
}
static const char* OptiMfgRequestLabel(LONG request){
    if(request==-1)return "Follow game";if(request==0)return "Off";
    static thread_local std::string label;label=std::to_string(request)+"x";return label.c_str();
}
static bool NativeDirty(){return nativePanel.dirty;}
static bool NativeAwaiting(){return nativePanel.awaiting;}
static bool NativeConflict(){return nativePanel.conflict;}
static bool NativeOwnerAvailable(const optishade::native_mfg::Snapshot& s,bool compatibilityOwned,const optishade::runtime_render::Snapshot& live){
    const auto& runtime=State::Instance();
    const bool alternateOutputOwns=runtime.activeFgInput!=FGInput::DLSSG&&runtime.activeFgOutput==FGOutput::DLSSG;
    return optishade::native_mfg::Control::CanConfigure(s)&&
        optishade::runtime_render::NativeCapabilityBound(live,s,GetTickCount64())&&
        !live.native.passive&&!compatibilityOwned&&!alternateOutputOwns;
}
static bool NativeOwnerAvailable(const optishade::native_mfg::Snapshot& s){
    return NativeOwnerAvailable(s,optishade::mfg::UiStatus().worker.Peek()->state.owned,optishade::runtime_render::State().Read());
}
struct NativeSaveAvailability {bool canSave=false;const char* footer="";const char* detail="";};
static NativeSaveAvailability GetNativeSaveAvailability(){
    if(nativePanel.awaiting)return {false,"Applying frame-generation change","The game is applying the previous frame-generation change."};
    if(nativePanel.conflict)return {false,"Provider state changed; reload draft","The provider state changed. Your draft is retained; discard it to reload the current settings before trying again."};
    if(!nativePanel.dirty)return {false,"No pending frame-generation changes","No unsaved frame-generation changes."};
    const auto s=optishade::native_mfg::Session().Read();
    if(!NativeOwnerAvailable(s))return {false,"Waiting for live FG control; draft retained","Save & Go is waiting for fresh native frame-generation control of this live output. Your draft is retained; keep the game's supported FG option enabled and return to a rendered scene."};
    if(s.generation!=nativePanel.generation||s.revision!=nativePanel.revision)return {false,"FG state changed; reload draft","The provider session changed. Your draft is retained; reload the current settings and stage the choice again."};
    if(!optishade::native_mfg::Control::CanRequest(s,nativePanel.desired,nativePanel.dynamic))return {false,"Provider cannot accept this choice","The active provider does not currently accept this frame-generation choice. Your draft is retained."};
    return {true,"Frame-generation changes ready to save",""};
}
static bool NativeCanSave(){return GetNativeSaveAvailability().canSave;}
static const char* NativeSaveBlockedReason(){return GetNativeSaveAvailability().detail;}
static const char* NativeSaveFooterStatus(){return GetNativeSaveAvailability().footer;}
static bool OwnsFrameGeneration(bool supported){
    const auto snapshot=optishade::mfg::UiStatus().worker.Peek();
    return ReplacesOrdinaryControls(snapshot->state,supported);
}
static const char* ModeLabel(const Settings& s){return s.overrideOff?"Override off":s.followGame?"Follow game":s.dynamic?"Dynamic":"Fixed multiplier";}
static void DrawStatus(const Snapshot& s){
    ImGui::SeparatorText("Requested and observed");
    ImGui::TextWrapped("Saved request: %s",ModeLabel(s.settings));
    if(!s.settings.followGame&&!s.settings.dynamic)ImGui::Text("Requested multiplier: %ux",s.settings.multiplier);
    if(!s.live){ImGui::TextWrapped("%s",s.message.c_str());ImGui::TextDisabled("Current output: not observed");return;}
    const auto& live=s.status;
    if(!live.savedRequestObserved)ImGui::TextWrapped("Waiting for the backend to read the saved request.");
    else if(!live.setOptionsAccepted&&live.setOptionsResult==38){ImGui::TextWrapped("The game/provider rejected the MFG change (Invalid State). OptiShade did not receive acceptance, so the previous option remains active. If you did not expect this, send diagnostics to Discord.");}
    else if(live.pending)ImGui::TextWrapped("The backend has a pending change; previous output may still be active.");
    else if(optishade::mfg::CurrentAcknowledgement(s)){
        // The source ABI does not expose an accepted-Follow flag. Do not invent it.
        if(s.sourceBuilt)ImGui::TextWrapped("Current request accepted by source provider; reported multiplier: %ux",live.appliedMultiplier);
        else if(live.appliedFollowGame)ImGui::TextUnformatted("Accepted mode: Follow game");
        else if(live.appliedDynamic)ImGui::TextUnformatted("Accepted mode: Dynamic");
        else ImGui::Text("Accepted fixed multiplier: %ux",live.appliedMultiplier);
    }else if(s.sourceBuilt&&!live.bridgeReady&&!live.gameFgOn&&!s.settings.overrideOff)ImGui::TextWrapped("No active game frame-generation request was observed in this scene. Enable DLSS Frame Generation in the game's graphics settings and resume a rendered scene. OptiShade preserves an Off request from the game.");
    else if(s.sourceBuilt&&!live.bridgeReady){ImGui::TextWrapped("The game requested frame generation, but OptiShade could not match its backbuffer to a presentation target. This is an OptiShade compatibility issue; send diagnostics to Discord. Your multiplier is saved as a request only; generated output is not confirmed.");}
    else ImGui::TextWrapped("Waiting for a usable game frame-generation connection.");
    if(!live.gameFgOn&&!s.settings.overrideOff&&!s.sourceBuilt)ImGui::TextWrapped("Enable the supported frame-generation option in the game's graphics settings.");
    if(live.presetRestart)ImGui::TextWrapped("The preset change requires a game restart.");
    if(optishade::mfg::RecentTiming(s)){
        if(ImGui::BeginTable("Frame rate cards",2,ImGuiTableFlags_SizingStretchSame)){
            ImGui::TableNextColumn();optishade::panel::Card("Game FPS",[&]{ImGui::TextDisabled("GAME FRAME RATE");ImGui::PushFontSize(ImGui::GetFontSize()*2.f);ImGui::Text("%.1f",live.realFpsMilli/1000.f);ImGui::PopFontSize();ImGui::SameLine();ImGui::TextDisabled("FPS");});
            ImGui::TableNextColumn();optishade::panel::Card("Presented FPS",[&]{ImGui::TextDisabled("DISPLAYED FRAME RATE");ImGui::PushFontSize(ImGui::GetFontSize()*2.f);ImGui::Text("%.1f",live.outputFpsMilli/1000.f);ImGui::PopFontSize();ImGui::SameLine();ImGui::TextDisabled("FPS");});ImGui::EndTable();
        }
        ImGui::TextDisabled("Sample age: %llu ms",static_cast<unsigned long long>(live.fpsAgeMs));
    }else ImGui::TextWrapped("Game / presentation FPS: unavailable or stale. No value is calculated from your selected multiplier.");
    ImGui::TextWrapped("Accepted settings and presentation counters are not a distinct-frame visual test.");
    if(ImGui::CollapsingHeader("Provider details")){
        ImGui::TextWrapped("Provider: %s",s.sourceBuilt?"OptiShade source-built compatibility backend":"Pinned upstream RTXMFG backend");
        ImGui::TextWrapped("Identity: %s",s.identity.c_str());
        ImGui::TextWrapped("Capability stage: %s",optishade::mfg::CapabilityStage(s));
        if(s.renderingLuid)ImGui::Text("Rendering adapter LUID: %llu",static_cast<unsigned long long>(s.renderingLuid));
        else ImGui::TextWrapped("Rendering adapter LUID: not exposed by this provider");
        ImGui::Text("Request revision: %llu / accepted: %llu",static_cast<unsigned long long>(live.requestRevision),static_cast<unsigned long long>(live.appliedRevision));
        ImGui::TextWrapped("%s",s.message.c_str());
        ImGui::TextWrapped("Older-GPU output remains subject to game, driver and hardware validation.");
    }
}
static const char* RuntimeFooterStatus(const Snapshot& s){
    if(!s.sourceBuilt||!s.live)return nullptr;
    const auto& live=s.status;
    if(!live.gameFgOn)return "MFG request saved, not applied: the game has not exposed an active DLSS Frame Generation path.";
    if(!live.bridgeReady)return "MFG request saved, not applied: waiting for the game's live frame-generation output.";
    if(!optishade::mfg::CurrentAcknowledgement(s))return "MFG request saved, not applied: waiting for provider acknowledgement.";
    return "MFG settings accepted; generated frames are not yet verified.";
}
static bool Save(bool supported){
    auto& service=optishade::mfg::UiStatus();const auto result=service.worker.Peek();const auto snapshot=service.Read(result);
    panel.Complete(result->completedRequest,result->save,result->saveMessage,snapshot);panel.Observe(snapshot);
    const bool editable=ReplacesOrdinaryControls(snapshot,supported)&&snapshot.editable&&snapshot.live&&!panel.conflict&&!panel.awaiting&&panel.dirty&&
        (snapshot.sourceBuilt||(snapshot.status.bridgeReady&&snapshot.status.gpuFamily==1));
    if(!editable){panel.feedback="Save unavailable: provider busy, unavailable or settings changed. Your draft is retained.";return false;}
    const auto id=service.Save(panel.value,snapshot);
    if(id)panel.Submitted(id);else panel.feedback="Save not queued: status changed or another request is busy. Your draft is retained.";
    return id!=0;
}
static void DrawReview(bool supported){
    if(ImGui::Button("Save"))Save(supported);
    ImGui::SameLine();if(ImGui::Button("Back"))optishade::panel::CloseDetail();
    if(!panel.feedback.empty())ImGui::TextWrapped("%s",panel.feedback.c_str());
}
static bool DrawOptiMfgComponent(bool connected){
    const bool installed=optiMfgBridge.Installed();
    // Prefer the live channel as the source of truth. A separately launched
    // OptiMFG controller can be connected even when its component payload was
    // not staged under this game's folder; in that case the in-game controls
    // should still be available here instead of exposing a second UI.
    ImGui::PushID("OptiMFG component controls");
    ImGui::TextUnformatted(connected?"Connected":installed?"Waiting for game connection":"OptiMFG not installed");
    if(!installed&&!connected){
        if(optishade::optimfg::ComponentExecutableMissing()){
            ImGui::TextWrapped("OptiMFG's folder is here but OptiMFG_Live.exe is missing. Antivirus removing it is the usual cause.");
            ImGui::TextWrapped("Try this: %s",optishade::selfhelp::AntivirusSteps());
            ImGui::PopID();return true;
        }
        ImGui::TextWrapped("OptiMFG is optional. Use the game's native frame-generation settings, or close the game and install OptiMFG from the manager for external controls.");
        ImGui::PopID();return true;
    }
    ImGui::TextWrapped("These controls send requests to the external OptiMFG app. Choose a multiplier; the saved choice is reused on future simulator starts.");
    LONG generatedMaximum=connected?optiMfgBridge.MaximumGenerated():-1;
    const bool runtimeReady=connected&&optiMfgBridge.StateCalls()>0&&generatedMaximum>=1;
    if(runtimeReady&&savedOptiMfgRequestPending&&optiMfgBridge.Request(savedOptiMfgRequest))savedOptiMfgRequestPending=false;
    const LONG request=savedOptiMfgRequest;
    const LONG sequence=connected?optiMfgBridge.CommandSequence():0;
    if(!connected){
        // Say which step failed and what to try, so the player can fix it without diagnostics.
        optishade::selfhelp::MfgFacts facts;
        facts.autoStartGame=optishade::optimfg::StartsWithThisGame();
        facts.startDisabled=optishade::optimfg::StartWithGameDisabled();
        facts.startAttempted=optishade::optimfg::controllerStartAttempted.load();
        facts.startError=optishade::optimfg::controllerStartError.load();
        facts.channelOpen=optiMfgBridge.Mapped();
        facts.heartbeatFresh=optiMfgBridge.Fresh();
        const auto advice=optishade::selfhelp::MfgNotConnected(facts);
        ImGui::TextWrapped("OptiMFG is installed but not connected: %s",advice.cause.c_str());
        ImGui::TextWrapped("Try this: %s",advice.tryThis.c_str());
        ImGui::TextWrapped("Your saved choice (%s) will be applied after OptiMFG connects.",OptiMfgRequestLabel(request));
        ImGui::PopID();return true;
    }
    ImGui::TextWrapped("%s",optishade::optimfg::StatusText(optiMfgBridge.Status()));
    if(!runtimeReady){
        ImGui::TextWrapped("Waiting for the game's live frame-generation capability report. Controls stay unavailable until the game and OptiMFG are connected.");
        ImGui::PopID();return true;
    }
    ImGui::Text("Runtime-reported output maximum: %s",std::to_string(generatedMaximum+1).c_str());
    if(generatedMaximum==1)ImGui::TextWrapped("The connected provider currently exposes 2x only. For older RTX unlocks, close the game and update the OptiMFG component in Update Manager. Higher multipliers require a ready compatible backend.");
    ImGui::Text("Controller request: %s",OptiMfgRequestLabel(optiMfgBridge.RequestValue()));
    ImGui::TextDisabled("Accepted settings and runtime counters are not proof of displayed generated frames.");
    for(LONG multiplier=2;multiplier<=6;++multiplier){
        if(multiplier>2)ImGui::SameLine();
        const bool active=request==multiplier;
        ImGui::BeginDisabled(multiplier-1>generatedMaximum);
        if(active)ImGui::PushStyleColor(ImGuiCol_Button,ImGui::GetStyleColorVec4(ImGuiCol_ButtonActive));
        if(ImGui::Button((std::to_string(multiplier)+"x").c_str())){
            savedOptiMfgRequest=multiplier;lastActiveOptiMfgRequest=multiplier;savedOptiMfgRequestPending=true;
            if(!SaveCurrentOptiMfgChoice())ImGui::OpenPopup("OptiMFG preference could not be saved");
            else if(connected&&optiMfgBridge.Request(multiplier))savedOptiMfgRequestPending=false;
        }
        if(active)ImGui::PopStyleColor();
        ImGui::EndDisabled();
    }
    ImGui::TextWrapped("Saved choice: %s. Select another multiplier to apply it now; the choice is kept for future simulator starts.",OptiMfgRequestLabel(request));
    if(ImGui::Button("Follow game")){savedOptiMfgRequest=-1;savedOptiMfgRequestPending=true;if(!SaveCurrentOptiMfgChoice())ImGui::OpenPopup("OptiMFG preference could not be saved");else if(connected&&optiMfgBridge.Request(-1))savedOptiMfgRequestPending=false;}
    ImGui::SameLine();if(ImGui::Button("Off")){savedOptiMfgRequest=0;savedOptiMfgRequestPending=true;if(!SaveCurrentOptiMfgChoice())ImGui::OpenPopup("OptiMFG preference could not be saved");else if(connected&&optiMfgBridge.Request(0))savedOptiMfgRequestPending=false;}
    if(!optiMfgSaveFeedback.empty())ImGui::TextWrapped("%s",optiMfgSaveFeedback.c_str());
    if(savedOptiMfgRequestPending)ImGui::TextWrapped("Saved locally; waiting to send this request when OptiMFG has a live connection.");
    else if(optiMfgBridge.Rejected())ImGui::TextWrapped("The external app rejected this request. Check its status or export diagnostics for the reason.");
    else if(connected&&sequence!=optiMfgBridge.AppliedSequence())ImGui::TextWrapped("Request sent; waiting for the game to acknowledge the latest options call.");
    if(ImGui::BeginPopup("OptiMFG preference could not be saved")){ImGui::TextUnformatted("The game folder could not save this preference. The current choice remains active for this session.");if(ImGui::Button("OK"))ImGui::CloseCurrentPopup();ImGui::EndPopup();}
    if(ImGui::BeginPopup("OptiMFG request busy")){ImGui::TextUnformatted("The tray controller is updating the same live session. Try again shortly.");ImGui::EndPopup();}
    ImGui::PopID();return true;
}
[[maybe_unused]] static bool Draw(bool supported){
    auto& service=optishade::mfg::UiStatus();
    const auto result=service.worker.Peek();const auto snapshot=service.Read(result);
    panel.Complete(result->completedRequest,result->save,result->saveMessage,snapshot);
    panel.Observe(snapshot);
    if(!ReplacesOrdinaryControls(snapshot,supported))return false;
    ImGui::PushID("OptiShade MFG");

    if(panel.conflict){
        ImGui::TextWrapped("The provider or saved settings changed. Your unsaved choices are retained; review the current state before saving.");
        ImGui::BeginDisabled(panel.awaiting!=0);
        if(ImGui::Button("Discard draft and load current settings"))panel.Discard(snapshot);
        ImGui::EndDisabled();
    }
    const bool editable=snapshot.editable&&snapshot.live&&!panel.conflict&&!panel.awaiting&&
        (snapshot.sourceBuilt||(snapshot.status.bridgeReady&&snapshot.status.gpuFamily==1));
    const bool canPreconfigure=optishade::mfg::CanPreconfigureFixed(snapshot.sourceBuilt,snapshot.status);
    const bool canChooseFixed=canPreconfigure||snapshot.status.bridgeReady;
    ImGui::BeginDisabled(!editable);
    auto& draft=panel.value;const auto beforeEdit=draft;
    if(snapshot.sourceBuilt){
        bool enabled=!draft.overrideOff;
        optishade::panel::SettingRow("Frame generation","Uses the installed compatibility component.",[&]{
            if(optishade::panel::Toggle("##mfg-enabled",&enabled)){draft.overrideOff=!enabled;if(enabled){draft.followGame=false;draft.dynamic=false;draft.multiplier=std::clamp(draft.multiplier,std::max(2u,snapshot.status.minMultiplier),std::max(2u,snapshot.status.maxMultiplier));}}
        });
    }else{
        bool useOverride=!draft.followGame;
        optishade::panel::SettingRow("OptiShade MFG override","Choose a multiplier and Save & Go. OFF returns control to the game.",[&]{
            if(optishade::panel::Toggle("##mfg-override-enabled",&useOverride)){draft.followGame=!useOverride;draft.dynamic=false;draft.overrideOff=false;}
        });
    }
    if(ImGui::CollapsingHeader("Advanced mode options")){
    ImGui::AlignTextToFramePadding();ImGui::TextUnformatted("Control");ImGui::SameLine(ImGui::GetWindowWidth()*.62f);ImGui::SetNextItemWidth(-1);
    if(ImGui::BeginCombo("##fg-mode",ModeLabel(draft))){
        if(snapshot.sourceBuilt&&ImGui::Selectable("Override off",draft.overrideOff)){draft.overrideOff=true;draft.followGame=true;draft.dynamic=false;draft.multiplier=2;}
        if(ImGui::Selectable("Follow game",draft.followGame&&!draft.overrideOff)){draft.overrideOff=false;draft.followGame=true;draft.dynamic=false;draft.multiplier=2;}
        ImGui::BeginDisabled(!canChooseFixed);
        if(ImGui::Selectable("Fixed multiplier",!draft.followGame&&!draft.dynamic)){
            draft.overrideOff=false;draft.followGame=false;draft.dynamic=false;
            draft.multiplier=std::clamp(draft.multiplier,std::max(2u,snapshot.status.minMultiplier),std::max(2u,snapshot.status.maxMultiplier));
        }
        ImGui::EndDisabled();
        ImGui::BeginDisabled(!snapshot.status.canDynamic);
        if(ImGui::Selectable("Dynamic",!draft.followGame&&draft.dynamic)){draft.overrideOff=false;draft.followGame=false;draft.dynamic=true;}
        ImGui::EndDisabled();ImGui::EndCombo();
    }
    }
    ImGui::TextDisabled("Extra frames can make movement look smoother.");ImGui::Spacing();ImGui::Separator();ImGui::Spacing();
    const bool fixed=!draft.followGame&&!draft.dynamic&&!draft.overrideOff;
    ImGui::TextUnformatted("Output multiplier");
    const float tile=(ImGui::GetContentRegionAvail().x-ImGui::GetStyle().ItemSpacing.x*4)/5.f;
    for(unsigned n=2;n<=6;++n){if(n!=2)ImGui::SameLine();const bool available=canChooseFixed&&n>=snapshot.status.minMultiplier&&n<=snapshot.status.maxMultiplier;
        ImGui::BeginDisabled(!available);ImGui::PushID(int(n));const bool selected=fixed&&draft.multiplier==n;
        if(selected)ImGui::PushStyleColor(ImGuiCol_Button,ImGui::GetStyleColorVec4(ImGuiCol_ButtonActive));
        const auto label=std::to_string(n)+"x";if(ImGui::Button(label.c_str(),ImVec2(tile,ImGui::GetFontSize()*2.5f))){draft.overrideOff=false;draft.followGame=false;draft.dynamic=false;draft.multiplier=n;}
        if(selected)ImGui::PopStyleColor();ImGui::PopID();ImGui::EndDisabled();
    }
    ImGui::TextDisabled("Choose a multiplier, then Save & Go to apply it to the running provider.");
    if(!snapshot.status.bridgeReady&&!canPreconfigure)ImGui::TextWrapped("Fixed multipliers are unavailable until the runtime reports a safe adapter-specific range.");
    else if(!snapshot.status.bridgeReady)ImGui::TextWrapped("You can save a multiplier now. It remains a request until the runtime verifies a unique game frame-generation output.");
    else if(snapshot.status.policyMaximumMultiplier>snapshot.status.maxMultiplier)
        ImGui::TextWrapped("The game runtime currently reports up to %ux. Provider policy allows up to %ux, but higher requests will be rejected until the runtime exposes them.",snapshot.status.maxMultiplier,snapshot.status.policyMaximumMultiplier);
    else if(!fixed)ImGui::TextWrapped("Choose a multiplier below to override the game, or leave it on Follow game.");
    else if(std::max(2u,snapshot.status.minMultiplier)==snapshot.status.maxMultiplier)
        ImGui::Text("This provider currently exposes %ux only.",snapshot.status.maxMultiplier);
    else ImGui::Text("This provider currently exposes %ux to %ux.",std::max(2u,snapshot.status.minMultiplier),snapshot.status.maxMultiplier);
    if(ImGui::CollapsingHeader("Pacing and advanced options")){
        if(!draft.followGame&&draft.dynamic){
            bool custom=draft.targetFps!=0;
            if(ImGui::Checkbox("Custom target FPS",&custom))draft.targetFps=custom?120u:0u;
            if(draft.targetFps){int fps=int(draft.targetFps);if(ImGui::SliderInt("Target FPS",&fps,1,1000,"%d",ImGuiSliderFlags_AlwaysClamp))draft.targetFps=unsigned(fps);}
            else ImGui::TextWrapped("Target follows display refresh. Actual output still needs measurement.");
        }else ImGui::TextWrapped("Dynamic target controls are available only when Dynamic mode is supported and selected.");
        if(!snapshot.sourceBuilt){
            const char* presets[]={"Game / driver","Preset A","Preset B"};int preset=int(std::min(draft.preset,2u));
            if(ImGui::Combo("MFG preset",&preset,presets,3))draft.preset=unsigned(preset);
            ImGui::TextWrapped("Changing this preset after FG starts may require restarting the game.");
            const bool reflex=snapshot.status.canReflex&&!(draft.dynamic&&!draft.followGame);
            ImGui::BeginDisabled(!reflex);
            bool limit=draft.reflexLimit!=0;if(ImGui::Checkbox("Limit FPS with Reflex",&limit))draft.reflexLimit=limit?60u:0u;
            if(draft.reflexLimit){int fps=int(draft.reflexLimit);if(ImGui::SliderInt("FPS limit",&fps,1,1000,"%d",ImGuiSliderFlags_AlwaysClamp))draft.reflexLimit=unsigned(fps);}
            ImGui::EndDisabled();if(!reflex)ImGui::TextWrapped("Reflex limiting is unavailable while Dynamic is active or Reflex is disconnected.");
        }else ImGui::TextWrapped("This source provider does not expose preset, Reflex or VSync overrides here.");
    }
    if(!panel.awaiting)panel.dirty=!optishade::mfg::SameRequest(draft,snapshot.settings);
    ImGui::EndDisabled();
    if(editable&&!optishade::mfg::SameRequest(beforeEdit,draft))panel.feedback="Changes staged. Save to apply them to the running game.";
    if(panel.awaiting)ImGui::TextUnformatted("Applying your choice...");
    if(!panel.feedback.empty())ImGui::TextWrapped("%s",panel.feedback.c_str());
    if(!snapshot.live)ImGui::TextWrapped("%s",snapshot.message.c_str());
    else if(optishade::mfg::CurrentAcknowledgement(snapshot)){
        if(snapshot.settings.overrideOff)ImGui::TextUnformatted("Provider accepted: Off");
        else if(snapshot.status.appliedFollowGame)ImGui::TextUnformatted("Provider accepted: Follow game");
        else if(snapshot.status.appliedDynamic)ImGui::TextUnformatted("Provider accepted: Dynamic");
        else ImGui::Text("Provider accepted: %ux",snapshot.status.appliedMultiplier);
    }else if(snapshot.status.setOptionsResult==38)ImGui::TextWrapped("The game could not apply the change in its current state. Previous settings may still be active.");
    else if(!snapshot.status.gameFgOn&&!snapshot.settings.overrideOff)ImGui::TextWrapped("Waiting for the game's frame-generation input. Saved settings have not been confirmed.");
    else if(!panel.awaiting)ImGui::TextWrapped("Waiting for the provider to confirm the saved choice.");
    if(ImGui::CollapsingHeader("Status and provider details"))DrawStatus(snapshot);
    ImGui::PopID();return true;
}
}

namespace OptiShadeMfgUI {
static optishade::native_mfg::GraphicsApi NativeGraphicsApi(API api){
    switch(api){
    case API::DX11:return optishade::native_mfg::GraphicsApi::Direct3D11;
    case API::DX12:return optishade::native_mfg::GraphicsApi::Direct3D12;
    case API::Vulkan:return optishade::native_mfg::GraphicsApi::Vulkan;
    default:return optishade::native_mfg::GraphicsApi::Unknown;
    }
}
static const char* NativeAvailabilitySummary(optishade::native_mfg::AvailabilityReason reason){
    using Reason=optishade::native_mfg::AvailabilityReason;
    switch(reason){
    case Reason::CompatibilityProviderOwns:return "Compatibility MFG provider owns this session.";
    case Reason::ObservationOnly:return "Game-controlled frame generation; capability observation is read-only.";
    case Reason::TwoXOnly:return "The active game provider supports 2x frame generation in this session; higher MFG multipliers are not exposed.";
    case Reason::NoNativeProviderOnDirect3D11:return "DirectX 11 active; no current native DLSS-G provider range.";
    case Reason::NoNativeProviderOnDirect3D12:return "DirectX 12 active; no current native DLSS-G provider range.";
    case Reason::NoNativeProviderOnVulkan:return "Vulkan active; no current native DLSS-G provider range.";
    case Reason::GraphicsApiUnknown:return "Waiting for graphics API detection.";
    default:return "Use the active game provider and choose a supported output multiplier.";
    }
}
static const char* NativeAvailabilityDetail(optishade::native_mfg::AvailabilityReason reason){
    using Reason=optishade::native_mfg::AvailabilityReason;
    switch(reason){
    case Reason::CompatibilityProviderOwns:
        return "A separate OptiShade MFG provider owns this session; native DLSS-G controls are paused to prevent competing requests.";
    case Reason::TwoXOnly:
        return "The game has exposed a valid 2x frame-generation range. OptiShade can use that supported setting; 3x and higher MFG multipliers are unavailable from this provider session.";
    case Reason::ObservationOnly:
        return "OptiShade observed the game provider, but this route has no qualified options-control callback. Use the game settings. Auto can use the observation to prepare an eligible provider while the game is closed; generation output remains unverified.";
    case Reason::NoNativeProviderOnDirect3D11:
        return "DirectX 11 is active, but OptiShade has no fresh native DLSS-G capability report for this game. The API and installed files do not create that connection. Enable the game's supported frame-generation option, return to a rendered scene, then check again.";
    case Reason::NoNativeProviderOnDirect3D12:
        return "DirectX 12 is active, but OptiShade has not received a current Streamline DLSS-G state report. Enable the game's supported DLSS Frame Generation option and resume a rendered scene; if it stays locked, collect a report so the provider connection can be inspected.";
    case Reason::NoNativeProviderOnVulkan:
        return "Vulkan is active, but OptiShade has not received a current native DLSS-G capability report. A private Vulkan-to-D3D12 bridge used for neural rendering (including the X-Plane 12 route) does not establish a native MFG connection.";
    case Reason::GraphicsApiUnknown:
        return "Waiting for graphics API detection and a current native frame-generation capability report.";
    default:return "";
    }
}
static void DrawNative(API api){
    const auto s=optishade::native_mfg::Session().Read();
    const auto primary=optishade::runtime_render::State().Read();
    const bool providerFresh=optishade::runtime_render::NativeCapabilityBound(primary,s,GetTickCount64());
    nativePanel.Observe(s,providerFresh);
    const auto backend=optishade::mfg::UiStatus().worker.Peek();
    // A compatibility owner, including one still starting, has a separate
    // request path. Never let native controls compete with that owner.
    const char* capabilityQueryDetail=optishade::native_mfg_ui::CapabilityQueryDetail(primary.nativeUnavailableReason);
    const auto& runtime=State::Instance();
    const bool alternateOutputOwns=runtime.activeFgInput!=FGInput::DLSSG&&runtime.activeFgOutput==FGOutput::DLSSG;
    const bool available=NativeOwnerAvailable(s,backend->state.owned,primary);
    const bool lastKnownEnabled=optishade::native_mfg_ui::ToggleEnabled(available,nativePanel.initialized,nativePanel.desired,s.acceptedGenerated,nativePanel.dynamic,nativePanel.pendingProvider);
    const bool canStageOffWhileWaiting=!available&&!alternateOutputOwns&&!backend->state.owned&&
        nativePanel.initialized&&!nativePanel.conflict&&!nativePanel.awaiting&&lastKnownEnabled&&
        s.provider&&s.known&&s.generation==nativePanel.generation&&s.revision==nativePanel.revision;
    // Do not make the first in-game request depend on an install-time or
    // startup provider scan. Let the user stage the lowest-risk 2x request;
    // it remains local until a fresh, writable game provider is observed.
    const bool canStageProbe=optishade::native_mfg_ui::CanStageInitialRequest(
        available,nativePanel.initialized,nativePanel.conflict,nativePanel.awaiting)&&!nativePanel.pendingProvider;
    const bool canStagePending=!available&&nativePanel.pendingProvider&&
        !nativePanel.conflict&&!nativePanel.awaiting;
    const auto reason=optishade::native_mfg::ClassifyAvailability(providerFresh,backend->state.owned,NativeGraphicsApi(api),s.maximum,s.controllable);
    const char* availability=alternateOutputOwns?"Another OptiShade frame-generation path owns this output.":available?"Turn generation on or off, then choose an output multiplier.":nativePanel.awaiting?"Applying the saved choice; waiting for the game provider.":nativePanel.dirty?(nativePanel.desired==0?"OFF is staged; waiting for fresh provider control.":"ON is staged; waiting for fresh provider control."):lastKnownEnabled?"Last accepted state was ON; waiting for a fresh provider update.":NativeAvailabilitySummary(reason);
    optishade::panel::SettingRow("Frame generation",availability,[&]{
        bool enabled=lastKnownEnabled;ImGui::BeginDisabled((!available&&!canStageOffWhileWaiting&&!canStageProbe&&!canStagePending)||nativePanel.conflict||nativePanel.awaiting);
        if(optishade::panel::Toggle("##native-mfg-enabled",&enabled)){
            if(available)nativePanel.Stage(s,enabled?std::clamp(nativePanel.preferredGenerated,1,int(s.maximum)):0);
            else if(!enabled&&nativePanel.pendingProvider)nativePanel.Discard(s);
            else if(!enabled)optishade::native_mfg_ui::StageOffWhileWaiting(nativePanel,s);
            else if(canStageProbe||canStagePending)nativePanel.StagePending(s,1);
        }
        ImGui::EndDisabled();
    });
    ImGui::TextDisabled("Extra frames can make movement look smoother.");ImGui::Spacing();ImGui::Separator();ImGui::Spacing();
    ImGui::TextUnformatted("Output multiplier");
    const float tile=(ImGui::GetContentRegionAvail().x-ImGui::GetStyle().ItemSpacing.x*4)/5.f;
    for(int multiplier=2;multiplier<=6;++multiplier){
        if(multiplier!=2)ImGui::SameLine();
        const int generated=multiplier-1;
        const bool canSelect=(available&&generated<=int(s.maximum)||((canStageProbe||canStagePending)&&multiplier==2))&&!nativePanel.conflict&&!nativePanel.awaiting;
        ImGui::BeginDisabled(!canSelect);ImGui::PushID(multiplier);
        if(nativePanel.desired==generated)ImGui::PushStyleColor(ImGuiCol_Button,ImGui::GetStyleColorVec4(ImGuiCol_ButtonActive));
        const auto text=std::to_string(multiplier)+"x";
        if(ImGui::Button(text.c_str(),ImVec2(tile,ImGui::GetFontSize()*2.5f))){
            if(available)nativePanel.Stage(s,generated);else nativePanel.StagePending(s,generated);
        }
        if(nativePanel.desired==generated)ImGui::PopStyleColor();ImGui::PopID();ImGui::EndDisabled();
    }
    ImGui::TextDisabled("Turn ON, choose a multiplier, then Save & Go.");
    if(nativePanel.conflict){ImGui::TextWrapped("%s",nativePanel.feedback.c_str());ImGui::BeginDisabled(nativePanel.awaiting);if(ImGui::Button("Discard draft and load current settings"))nativePanel.Discard(s);ImGui::EndDisabled();}
    else if(nativePanel.dirty)ImGui::TextWrapped("%s",NativeCanSave()?(nativePanel.desired==0?"OFF staged; use Save & Go below to apply it to the running game.":"ON staged; choose a multiplier, then use Save & Go below."):NativeSaveBlockedReason());
    else if(nativePanel.awaiting)ImGui::TextWrapped("%s",nativePanel.feedback.c_str());
    else if(!nativePanel.feedback.empty())ImGui::TextWrapped("%s",nativePanel.feedback.c_str());
    if(nativePanel.pendingProvider&&nativePanel.dirty)ImGui::TextWrapped("Your MFG choice is staged locally. OptiShade will not send it until the live provider is writable and bound to the game's active output.");
    else if(alternateOutputOwns)ImGui::TextWrapped("Another installed provider controls frame generation in this session. You can stage a native MFG choice, but Save & Go waits until the active output has verified control.");
    else if(providerFresh&&!s.controllable){ImGui::TextWrapped("%s",ActivationHelp);ImGui::TextWrapped("%s",NativeAvailabilityDetail(reason));}
    else if(!available&&nativePanel.dirty&&nativePanel.pendingProvider)ImGui::TextWrapped("Your %s request is staged locally. Enable the game's DLSS Frame Generation option and return to a rendered scene; OptiShade will wait for its live provider before sending the request.",nativePanel.desired==0?"OFF":"2x MFG");
    else if(!available&&nativePanel.dirty)ImGui::TextWrapped("Your staged %s choice is retained while provider state is stale. Return to a rendered scene and use Save & Go when fresh control returns.",nativePanel.desired==0?"OFF":"ON");
    else if(!available&&lastKnownEnabled)ImGui::TextWrapped("The last accepted state was ON. The game has not sent a fresh provider update, so OptiShade keeps the display state and temporarily disables changes.");
    else if(!available){ImGui::TextWrapped("Frame-generation controls are locked: %s",capabilityQueryDetail[0]?capabilityQueryDetail:optishade::native_mfg_ui::ControlBlocker(s,backend->state.owned,alternateOutputOwns,primary,GetTickCount64()));if(reason==optishade::native_mfg::AvailabilityReason::NoNativeProviderOnDirect3D11||reason==optishade::native_mfg::AvailabilityReason::NoNativeProviderOnDirect3D12||reason==optishade::native_mfg::AvailabilityReason::NoNativeProviderOnVulkan)ImGui::TextWrapped("%s",ActivationHelp);}
    else if(s.pending)ImGui::TextWrapped("Applying... waiting for the game to accept your choice.");
    else if(s.attempted&&s.result!=0)ImGui::TextWrapped("The active provider rejected the MFG request (result %d). This does not by itself show that OptiShade is at fault; the game/provider may not support this request. If you expected MFG to work here, or are unsure, send diagnostics to Discord.",s.result);
    else if(s.attempted&&s.result==0)ImGui::Text("Provider accepted: %s",s.dynamic?"Dynamic":s.acceptedGenerated?std::format("{}x",s.acceptedGenerated+1).c_str():"Off");
    else ImGui::TextUnformatted("Ready to configure.");
    if(available)ImGui::TextWrapped("Supported by the active game provider: %s",optishade::native_mfg_ui::CapabilityRangeDetail(s.maximum).c_str());
    if(ImGui::CollapsingHeader("Status and provider details")){
        ImGui::TextWrapped("%s",capabilityQueryDetail[0]?capabilityQueryDetail:NativeAvailabilityDetail(reason));
        ImGui::TextWrapped("Control admission: %s",capabilityQueryDetail[0]?capabilityQueryDetail:optishade::native_mfg_ui::ControlBlocker(s,backend->state.owned,alternateOutputOwns,primary,GetTickCount64()));
        if(s.withdrawn>=0)ImGui::TextWrapped("A previous %dx request was withdrawn because the provider's supported range changed.",s.withdrawn+1);
        ImGui::Text("Provider result: %d; reported additional frames: %u",s.result,s.maximum);
        ImGui::TextWrapped("Requests apply on the game's own FG callback. If the game pauses FG, an ON request waits until it resumes. Accepted settings do not verify generated output.");
    }
}
template<class Configuration> static bool SaveNative(Configuration& config){
    auto& control=optishade::native_mfg::Session();const auto snapshot=control.Read();
    const auto primary=optishade::runtime_render::State().Read();
    // Reject a passive, replaced or conflicting owner before touching saved settings.
    if(!NativeCanSave()){nativePanel.feedback="Save unavailable: this route does not own the current native FG controls. Your draft is retained.";return false;}
    const typename Configuration::NativeMfgSave proposed{
        nativePanel.desired<0?std::nullopt:std::optional<int>(nativePanel.desired),nativePanel.dynamic};
    // Keep runtime-readable startup settings committed throughout disk I/O.
    // SetOptions may run here before the first explicit session request exists.
    if(!config.SaveIni(&proposed)){
        nativePanel.feedback="Could not save the MFG setting. The live request was not sent.";return false;
    }
    bool submitted=false;
    // Disk I/O stays outside the primary metadata lock. A resize, retirement
    // or device switch during Save cannot queue against the previous output.
    optishade::runtime_render::State().WithCurrent(primary,GetTickCount64(),[&]{
        if(NativeOwnerAvailable(snapshot,optishade::mfg::UiStatus().worker.Peek()->state.owned,primary))
            submitted=nativePanel.Submit(control,snapshot);
        if(submitted){
            if(proposed.interpolationCount)config.FGDLSSGOverrideInterpolationCount=*proposed.interpolationCount;
            else config.FGDLSSGOverrideInterpolationCount.reset();
            config.FGDLSSGOverrideForceDMFG=proposed.dynamic;
        }
    });
    if(!submitted){
        nativePanel.feedback="The primary rendering output changed or is busy. Your draft is retained; retry when its frame-generation controls are ready.";
        if(!config.SaveIni())nativePanel.feedback+=" Restoring the saved settings also failed; the live request was not sent.";
        return false;
    }
    StreamlineHooks::updateDlssgOptions();
    return true;
}
}
