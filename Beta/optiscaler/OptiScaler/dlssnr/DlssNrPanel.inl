// OptiShade additions, GPL-3.0-or-later.
// Native view adapter. Generated fragments preserve existing validated bindings,
// deferred-slider semantics and specialist controls from DlssNr_Menu.cpp.
static std::string saveFeedback;
void RenderMenu(Config* config,float menuResScale){
    if(!saveFeedback.empty())ImGui::TextWrapped("%s",saveFeedback.c_str());
    auto* liveConfig=config;
    auto& edits=MenuDraft();config=edits.shadow.get();
    const bool enabled=liveConfig->DlssNrEnabled.value_or_default();
    const auto observed=DlssNr::Observation();
    const bool taaFallback=observed.recent && (observed.owner.route==optishade::nr_observation::Route::EstimatedTAA||observed.owner.route==optishade::nr_observation::Route::PreFgTAA);
    const char* state="Waiting for runtime acknowledgement";
    std::string reason;
    if(!enabled&&!observed.requested)state="Off requested for this session";
    else if(!enabled)state="Disable requested; awaiting runtime acknowledgement";
    else if(observed.recent&&observed.completed){
        state=!observed.visible?"Model completed; diagnostic output is bypassed":
              observed.composed?"GPU composition completed; visible change not measured":
              "Model evaluated; output composition was not recorded";
        reason=std::string("Connection: ")+optishade::nr_observation::Name(observed.owner.route);
    }else{
        const auto* failure=DlssNr::FailureReason();
        if(failure&&*failure){state="Needs attention";reason=failure;}
        else{
            // Name the actual cause and what the player can try (self-help, no diagnostics needed).
            optishade::selfhelp::NrFacts facts;
            facts.memoryPaused=DlssNr::MemoryPressureStopped();
            facts.headsetNrOff=DlssNr::VrHeadsetActive()&&!liveConfig->DlssNrInVrHeadset.value_or_default();
            auto* feature=State::Instance().currentFeature;
            facts.upscalerActive=feature!=nullptr;
            facts.dx11Native=feature&&dynamic_cast<IFeature_Dx11*>(feature)&&!dynamic_cast<IFeature_Dx11wDx12*>(feature);
            if(facts.dx11Native)facts.dx11Upscaler=feature->Name();
            facts.taaRouteSeen=DlssNr::TaaRouteSeen();
            if(facts.taaRouteSeen)facts.taaStatus=DlssNr::TaaFallbackStatus();
            facts.vulkan=State::Instance().swapchainApi==API::Vulkan;
            if(facts.vulkan)facts.vulkanStatus=DlssNr::VulkanBridgeStatus();
            facts.ranEarlier=observed.completedFrame>0;
            const auto advice=optishade::selfhelp::NrWaiting(facts);
            state="Waiting for supported frames";reason=advice.cause+" Try this: "+advice.tryThis;
        }
    }
    if(enabled&&!liveConfig->DlssNrApplyModel.value_or_default())reason="The diagnostic output bypass is selected. Model processing may still have a GPU cost; check Troubleshooting.";
    // Session enable is an immediate runtime action, independent of tuning
    // previews. A tuning conflict must never prevent the user from stopping NR.
    config->DlssNrEnabled=liveConfig->DlssNrEnabled;
    const auto quality=std::to_string(config->DlssNrPasses.value_or_default())+" requested model pass(es)";
    const optishade::panel::NrModel view{config->DlssNrEnabled.value_or_default(),state,reason.c_str(),quality.c_str()};
    // Drawn inside the NR appearance card, below the page title and the NR
    // session card: DirectX 11 bridge prompt and video-memory status.
    auto nrAlerts=[&]{
        // DirectX 11: NR runs only on the D3D12 bridge (the "_on12" upscalers).
        // With native D3D11 DLSS/FSR/XeSS it never receives a frame; offer the switch.
        if(enabled){
            auto* active=State::Instance().currentFeature;
            if(active&&dynamic_cast<IFeature_Dx11*>(active)&&!dynamic_cast<IFeature_Dx11wDx12*>(active)){
                ImGui::PushStyleColor(ImGuiCol_Text,IM_COL32(255,190,131,255));
                ImGui::TextWrapped("NR is waiting: in DirectX 11 games NR runs on the D3D12 bridge, and this game is using %s directly in D3D11.",active->Name().c_str());
                ImGui::PopStyleColor();
                if(ImGui::Button("Use DLSS on the D3D12 bridge for NR")){
                    liveConfig->Dx11Upscaler=Upscaler::DLSS_on12;
                    State::Instance().newBackend=Upscaler::DLSS_on12;
                    for(auto& change:State::Instance().changeBackend)change.second=true;
                    const bool saved=Config::Instance()->SaveIni();
                    LOG_INFO("NR panel: DirectX 11 upscaler switched to DLSS on the D3D12 bridge for NR (saved={})",saved);
                }
                HelpMarker("Switches this game's DirectX 11 upscaler to DLSS running on the D3D12 bridge, which NR needs. The upscaler restarts once; the choice is saved.");
            }
        }
        // Video memory: by default NR keeps running and
        // only warns; pausing for memory is an opt-in, saved setting.
        if(enabled&&DlssNr::MemoryPressureStopped()){
            ImGui::TextWrapped("NR is paused: video memory is almost full and Pause NR when video memory is low is on. NR retries on its own once memory frees up.");
            if(ImGui::Button("Restart NR now"))DlssNr::RetryAfterFailure();
        }else if(enabled&&DlssNr::MemoryLow()){
            ImGui::PushStyleColor(ImGuiCol_Text,IM_COL32(255,190,131,255));
            ImGui::TextWrapped("Video memory is nearly full; NR may cause stutter. Lower graphics settings or resolution if it does.");
            ImGui::PopStyleColor();
        }
        bool pauseOnLowMemory=config->DlssNrPauseOnLowMemory.value_or_default();
        if(ImGui::Checkbox("Pause NR when video memory is low",&pauseOnLowMemory))config->DlssNrPauseOnLowMemory=pauseOnLowMemory;
        HelpMarker("Off (default): NR always runs; when video memory is full the game may stutter. On: NR waits for free video memory before starting or rebuilding, and retries on its own. Save settings to keep this choice.");
        bool inHeadset=config->DlssNrInVrHeadset.value_or_default();
        if(ImGui::Checkbox("Use NR in the VR headset",&inHeadset))config->DlssNrInVrHeadset=inHeadset;
        HelpMarker("On (default): NR runs on each eye in VR. Off: NR stays off while a headset session is running and frees its video memory; it still runs on a monitor. ReShade effects are not affected. The desktop mirror window never gets NR in VR. Save settings to keep this choice.");
        {
            static int pendingVrScale=-1;
            int vrPercent=pendingVrScale>=0?pendingVrScale:(int)lroundf(config->DlssNrVrWorkingScale.value_or_default()*100.0f);
            if(!inHeadset)ImGui::BeginDisabled();
            if(ImGui::SliderInt("VR model resolution",&vrPercent,25,100,"%d%%"))pendingVrScale=vrPercent;
            if(ImGui::IsItemDeactivatedAfterEdit()&&pendingVrScale>=0){config->DlssNrVrWorkingScale=std::clamp(pendingVrScale,25,100)/100.0f;pendingVrScale=-1;}
            if(!inHeadset)ImGui::EndDisabled();
            HelpMarker("NR resolution for each headset eye. 65% (default) does about 40% of the work of 100%: each eye at full resolution can cost more than a whole 90 Hz frame. Raise it if you have GPU time to spare; lower it if VR stutters with NR on. Monitor play uses Model resolution under Quality & speed.");
            bool foveated=config->DlssNrVrFoveated.value_or_default();
            if(ImGui::Checkbox("Foveated NR (centre of each eye)",&foveated))config->DlssNrVrFoveated=foveated;
            HelpMarker("NR works on the centre of each eye, where the lens is sharp, and fades into the untouched image towards the edges. Combined with VR model resolution this cuts NR's cost the most. Off: NR covers the whole eye.");
            if(!inHeadset||!foveated)ImGui::BeginDisabled();
            static int pendingFovea=-1,pendingFeather=-1;
            int fovea=pendingFovea>=0?pendingFovea:(int)lroundf(config->DlssNrVrFoveaSize.value_or_default()*100.0f);
            if(ImGui::SliderInt("Foveated area",&fovea,30,100,"%d%%"))pendingFovea=fovea;
            if(ImGui::IsItemDeactivatedAfterEdit()&&pendingFovea>=0){config->DlssNrVrFoveaSize=std::clamp(pendingFovea,30,100)/100.0f;pendingFovea=-1;}
            HelpMarker("Width and height of the centre window, as a share of each eye. 70% (default) covers about half the eye's area. Bigger reaches further out at more cost; 100% is the whole eye.");
            int feather=pendingFeather>=0?pendingFeather:(int)lroundf(config->DlssNrVrFoveaFeather.value_or_default()*100.0f);
            if(ImGui::SliderInt("Foveated edge softness",&feather,2,100,"%d%%"))pendingFeather=feather;
            if(ImGui::IsItemDeactivatedAfterEdit()&&pendingFeather>=0){config->DlssNrVrFoveaFeather=std::clamp(pendingFeather,2,100)/100.0f;pendingFeather=-1;}
            HelpMarker("How gradually NR fades out at the edge of the window, as a share of the way to its centre. Softer hides the edge better; harder keeps NR at full strength over more of the window.");
            if(!inHeadset||!foveated)ImGui::EndDisabled();
        }
        ImGui::TextWrapped("TAA and frame generation are detected automatically. Native DLSS inputs keep NR on the DLSS route; when the game uses TAA, the TAA route is used and validated before it feeds frame generation.");
        if(enabled&&DlssNr::VrHeadsetActive())
            ImGui::TextDisabled(liveConfig->DlssNrInVrHeadset.value_or_default()?"VR headset session running: NR runs in the headset, not on the desktop mirror.":"VR headset session running: NR is off in the headset.");
        // Self-check for flicker: what is on now that is known to cause it.
        if(enabled&&ImGui::CollapsingHeader("Seeing flicker or trails?")){
            const auto flicker=DlssNr::FlickerSuspects();
            for(const auto& suspect:flicker)ImGui::BulletText("%s Try this: %s",suspect.cause.c_str(),suspect.tryThis.c_str());
            ImGui::TextWrapped("%s",flicker.empty()?"Nothing known to flicker is on right now. Turn off one thing at a time: image effects (fog, ambient occlusion and depth of field first), NR, then frame generation. Keep the setting that fixes it; if nothing helps, send diagnostics.":
                "If none of these helps, turn off one thing at a time: image effects (depth-based ones first), NR, then frame generation. If nothing helps, send diagnostics.");
        }
        ImGui::Separator();
    };
    auto look=[&]{
        nrAlerts();
        optishade::panel::Appearance([&]{
            const char* styles[]={"Standard","Natural","Cinematic"};
            int style=int(std::min(config->DlssNrStyle.value_or_default(),2u));
            if(ImGui::Combo("##NR look",&style,styles,3))config->DlssNrStyle=uint32_t(style);
        },[&]{DeferredSlider("##NR strength",&config->DlssNrIntensity,0.f,2.f,1.f);});
        // Detail and colour strength sit with the look: testers could not find
        // them inside the collapsed per-pass header under Quality & speed.
        ImGui::PushItemWidth(std::min(220.f*menuResScale,ImGui::GetContentRegionAvail().x*.55f));
#include "reconstruction/NRStrength.inl"
        ImGui::PopItemWidth();
        ImGui::Separator();
        static bool restoreApplyModel=true;
        static bool diagnosticStartedHere=false;
        const bool highlight=liveConfig->DlssNrDebugView.value_or_default()==3;
        if(!enabled){
            ImGui::BeginDisabled();
            ImGui::Button("Highlight NR changes (diagnostic)");
            ImGui::EndDisabled();
            ImGui::TextDisabled("Enable NR and save before previewing its image changes.");
        }else if(!highlight){
            if(ImGui::Button("Highlight NR changes now")){
                restoreApplyModel=liveConfig->DlssNrApplyModel.value_or_default();
                liveConfig->DlssNrApplyModel=true;
                liveConfig->DlssNrDebugView=3u;
                diagnosticStartedHere=true;
            }
            ImGui::TextDisabled("Temporarily amplifies the image changes from NR. Click again to restore the normal view.");
        }else{
            if(ImGui::Button("Stop highlighting NR changes")){
                liveConfig->DlssNrDebugView=0u;
                if(diagnosticStartedHere)liveConfig->DlssNrApplyModel=restoreApplyModel;
                diagnosticStartedHere=false;
            }
            ImGui::TextWrapped("Close this menu and resume the scene. The highlighted comparison appears on the next evaluated game frame.");
        }
    };
    auto qualityControls=[&]{
        ImGui::PushItemWidth(std::min(220.f*menuResScale,ImGui::GetContentRegionAvail().x*.55f));
#include "reconstruction/NRQuality.inl"
        if(!taaFallback)ImGui::TextWrapped("Native TAA + FG prepares the entire requested pass stack before activation. Additional passes increase GPU time and memory use; private testing is required on your configuration.");
#include "reconstruction/NRPassNotice.inl"
#include "reconstruction/NRPlacement.inl"
        ImGui::EndDisabled(); // The placement fragment begins this TAA guard.
        if(ImGui::CollapsingHeader("Per-pass tuning")){
#include "reconstruction/NRPasses.inl"
        }
        ImGui::PopItemWidth();
    };
    auto compatibility=[&]{
        ImGui::PushItemWidth(std::min(220.f*menuResScale,ImGui::GetContentRegionAvail().x*.55f));
#include "reconstruction/NRConnection.inl"
        const bool finishedPicture=config->DlssNrFinishedPicture.value_or_default();
        const bool beforeSr=config->DlssNrRunBeforeSr.value_or_default()||(finishedPicture&&config->DlssNrDeferredDlss.value_or_default());
        const auto activeFeature=State::Instance().currentFeature;
        const bool rayReconstruction=activeFeature&&activeFeature->GetUpscalerType()==Upscaler::DLSSD;
        const bool deferredActive=!finishedPicture&&config->DlssNrDeferredDlss.value_or_default()&&!rayReconstruction;
#include "reconstruction/NRCompatibility.inl"
        if(optishade::panel::Group("Experimental routing",optishade::panel::Section::Experimental,"Specialist processing paths; availability depends on the active input")){
#include "reconstruction/NRExperimental.inl"
#include "reconstruction/NRHdr.inl"
        }
        if(optishade::panel::Group("Colour, masks and exposure",optishade::panel::Section::Colour)){
            // Colour's highlight guard uses the same persisted experimental cap.
            // Its editor lives in Quality; disclosure must only read this value.
            // Colour and calibration keep their existing live-preview owner.
            auto* staged=config;config=liveConfig;
            ImGui::TextWrapped("Colour and exposure calibration preview immediately; Save settings keeps their tuning.");
            const bool unlockPasses=config->DlssNrUnlockPasses.value_or_default();
#include "reconstruction/NRColour.inl"
            config=staged;
        }
        ImGui::PopItemWidth();
    };
    auto troubleshooting=[&]{
        bool apply=config->DlssNrApplyModel.value_or_default();
        if(ImGui::Checkbox("Show model output (diagnostic bypass)",&apply))config->DlssNrApplyModel=apply;
        HelpMarker("Off hides the output but the model still runs. Use the session-enable control to request stopping model processing.");
        if(optishade::panel::Group("Technical details",optishade::panel::Section::NrTechnical)){
#include "reconstruction/NRStatus.inl"
        ImGui::PushItemWidth(std::min(220.f*menuResScale,ImGui::GetContentRegionAvail().x*.55f));
#include "reconstruction/NRCompare.inl"
        ImGui::PopItemWidth();
        }
    };
    if(edits.review.Dirty())ImGui::TextWrapped("Previewing your NR changes. Save keeps this tuning; Discard restores it.");
    optishade::panel::DrawNr(view,[&](bool value){
        config->DlssNrEnabled=value;
        DlssNr::SetEnabled(value,"in-game-panel");
    },look,qualityControls,compatibility,troubleshooting);
    if(!edits.review.Preview())ImGui::TextWrapped("Preview paused: settings changed elsewhere. Your draft is retained.");
}

bool MenuHasChanges(){return MenuDraft().review.Dirty();}
bool MenuCanUndo(){return MenuDraft().review.CanUndo();}
void DiscardMenuChanges(){MenuDraft().review.Discard();}
bool StageMenuUndo(){return MenuDraft().review.StageUndo();}
bool SaveMenuChanges(bool available){
    auto& edits=MenuDraft();const auto changes=edits.review.Changes();
    if(!available||changes.empty()||edits.review.Conflict()){
        saveFeedback="Cannot save this draft while the adapter is unavailable or settings conflict. Your edits are retained.";return false;
    }
    bool placementChanged=false;for(const auto& c:changes)if(c.label=="Finished Picture")placementChanged=true;
    const bool accepted=edits.review.Apply();
    if(accepted&&placementChanged)DlssNr::RetryAfterFailure();
    if(accepted){const bool saved=Config::Instance()->SaveIni();saveFeedback=saved?"Tuning saved. Session enable remains session-only.":"Applied for this session, but saving failed. Check folder permissions.";return saved;}
    saveFeedback="A setting changed externally or was rejected. Remaining edits are retained.";return false;
}
void DrawMenuReview(bool available){
    ImGui::TextWrapped("%s",saveFeedback.c_str());
    if(ImGui::Button("Save"))SaveMenuChanges(available);
    ImGui::SameLine();if(ImGui::Button("Back"))optishade::panel::CloseDetail();
}
