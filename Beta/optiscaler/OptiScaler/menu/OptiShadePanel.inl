#include "../dlssnr/NrMenuActions.h"
#include "../../../shared/PanelActionPolicy.h"
#include "../../../shared/BuildDisplayLabel.h"
// OptiShade additions, GPL-3.0-or-later. One native overlay and one set of bindings.
void MenuCommon::RenderMainMenuWindow(RenderMenuContext& ctx){
    if(!ctx.newFrame)return;
    // Keep drawing the requested menu while the effects runtime is connecting.
    // DrawStartup owns its progress panel; a pending connection must not erase
    // the user's menu request or make the Vulkan overlay submit an empty frame.
    OptiShadeUI::DrawStartup(_isVisible);
    if(!_isVisible)return;
    auto config=ctx.config;
    static optishade::menu_settings::Draft<Config> menuSettings;
    menuSettings.Begin(*config);
    State::Instance().vulkanSkipHooks=true;
    const auto renderingGpu=ctx.state.api==API::Vulkan
        ? IdentifyGpu::getGpuForVulkanPhysicalDevice(ctx.state.currentVkPhysicalDevice)
        : RenderingGpu(ctx.state);
    ctx.primaryGpu=std::make_unique<std::decay_t<decltype(IdentifyGpu::getPrimaryGpu())>>(renderingGpu);
    State::Instance().vulkanSkipHooks=false;
    const float uiScale=std::clamp(ctx.menuResScale,.5f,2.f);
    const auto baseStyle=ImGui::GetStyle();
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,baseStyle.WindowPadding*uiScale);
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding,baseStyle.FramePadding*uiScale);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing,baseStyle.ItemSpacing*uiScale);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemInnerSpacing,baseStyle.ItemInnerSpacing*uiScale);
    ImGui::PushStyleVar(ImGuiStyleVar_ScrollbarSize,baseStyle.ScrollbarSize*uiScale);
    ImGui::PushFontSize(std::round(fontSize*uiScale));
    const optishade::menu_geometry::View view{ctx.io.DisplaySize.x,ctx.io.DisplaySize.y};
    static const auto modePath=Util::DllPath().parent_path()/L"OptiShadeData"/L"UI-mode.ini";
    static bool migratedLayout=false;
    if(!migratedLayout){
        if(GetPrivateProfileIntW(L"Interface",L"SidebarLayout",0,modePath.c_str())<1){
            const auto& preferred=mainMenuGeometry.Preferred();
            if(preferred&&preferred->rect.height>preferred->rect.width*1.25f)mainMenuGeometry.Reset(view,uiScale);
            WritePrivateProfileStringW(L"Interface",L"SidebarLayout",L"1",modePath.c_str());
        }
        migratedLayout=true;
    }
    const auto area=optishade::menu_geometry::Available(view);
    optishade::menu_geometry::Rect placement;
    if(mainMenuGeometry.Prepare(view,uiScale,placement)){
        ImGui::SetNextWindowSize(ImVec2(placement.width,placement.height),ImGuiCond_Always);
        ImGui::SetNextWindowPos(ImVec2(placement.x,placement.y),ImGuiCond_Always);
    }
    ImGui::SetNextWindowSizeConstraints(ImVec2(std::min(460.f*uiScale,area.width),std::min(420.f*uiScale,area.height)),ImVec2(std::min(1600.f*uiScale,area.width),area.height));
    bool visible=_isVisible;static bool saved=false;
    if(OptiShadeUI::lookEditorOpen){
        ImGui::SetNextWindowSizeConstraints(ImVec2(std::min(540.f*uiScale,area.width),std::min(420.f*uiScale,area.height)),ImVec2(area.width,area.height));
        ImGui::SetNextWindowSize(ImVec2(std::min(2200.f*uiScale,area.width*.98f),std::min(1600.f*uiScale,area.height*.96f)),ImGuiCond_FirstUseEver);
        ImGui::SetNextWindowPos(ImVec2(view.width*.5f,view.height*.5f),ImGuiCond_FirstUseEver,ImVec2(.5f,.5f));
        bool editorVisible=true;
        const bool editorContentsVisible=ImGui::Begin("OptiShade Look editor###OptiShadeLookEditorR30",&editorVisible,ImGuiWindowFlags_NoCollapse|ImGuiWindowFlags_NoTitleBar);
        const auto* editorDrawList=ImGui::GetWindowDrawList();
        const auto editorPosition=ImGui::GetWindowPos();
        const auto editorSize=ImGui::GetWindowSize();
        if(editorContentsVisible){
            optishade::panel::PageTitle("Look editor","Toggle shaders, tune every exposed setting and type exact values.");
            if(ImGui::Button("Close editor"))editorVisible=false;
            ImGui::SameLine();ImGui::TextDisabled("%s",std::filesystem::u8path(OptiShadeUI::fx.preset).filename().string().c_str());
            ImGui::BeginChild("Shader editor content",ImVec2(0,-ImGui::GetFontSize()*4.2f),ImGuiChildFlags_AlwaysUseWindowPadding);
            OptiShadeUI::DrawEffects(true);ImGui::EndChild();ImGui::Separator();
            if(OptiShadeUI::fx.dirty)ImGui::TextColored(ImVec4(1.f,.62f,.12f,1.f),"Live preview - unsaved changes");
            else ImGui::TextColored(ImVec4(.2f,.88f,.68f,1.f),"No unsaved changes");
            ImGui::Spacing();
            static char saveAsPath[1024]="";
            ImGui::BeginDisabled(!OptiShadeUI::fx.dirty||OptiShadeUI::fx.loading||OptiShadeUI::fx.performanceMode);
            if(ImGui::Button("Save")){osfx::Command c{};c.kind=osfx::Save;OptiShadeUI::Send(c);}
            ImGui::EndDisabled();ImGui::SameLine();
            if(ImGui::Button("Save as...")){
                auto current=std::filesystem::u8path(OptiShadeUI::fx.preset);auto folder=current.parent_path();if(folder.empty())folder=Util::DllPath().parent_path()/L"OptiShadeData"/L"Presets";
                auto stem=current.stem();if(stem.empty())stem=L"My look";auto suggested=folder/(stem.wstring()+L" copy.ini");auto encoded=suggested.u8string();strncpy_s(saveAsPath,(const char*)encoded.c_str(),_TRUNCATE);ImGui::OpenPopup("Save look as");
            }
            ImGui::SameLine();ImGui::BeginDisabled(!OptiShadeUI::fx.dirty||OptiShadeUI::fx.loading||OptiShadeUI::fx.performanceMode);
            if(ImGui::Button("Revert")){osfx::Command c{};c.kind=osfx::Discard;if(OptiShadeUI::Send(c))OptiShadeUI::preparing.clear();}
            ImGui::EndDisabled();
            ImGui::SetNextWindowPos(ImGui::GetMainViewport()->GetCenter(),ImGuiCond_Appearing,ImVec2(.5f,.5f));
            const float popupWidth=std::max(160.f,std::min(520.f,ImGui::GetMainViewport()->Size.x-32.f));ImGui::SetNextWindowSize(ImVec2(popupWidth,0),ImGuiCond_Appearing);
            if(ImGui::BeginPopupModal("Save look as",nullptr,ImGuiWindowFlags_AlwaysAutoResize)){
                ImGui::TextWrapped("Save this look to a new preset file. Existing files are protected.");
                ImGui::SetNextItemWidth(-1);ImGui::InputTextWithHint("Preset path","Full path ending in .ini",saveAsPath,sizeof(saveAsPath));
                std::error_code saveError;std::filesystem::path destination;bool valid=false;
                try{destination=std::filesystem::u8path(saveAsPath);valid=destination.is_absolute()&&destination.extension()==L".ini"&&std::filesystem::is_directory(destination.parent_path(),saveError)&&!std::filesystem::exists(destination,saveError);}catch(...){valid=false;}
                ImGui::BeginDisabled(!valid||OptiShadeUI::fx.loading||OptiShadeUI::fx.performanceMode);
                if(ImGui::Button("Save copy")){auto encoded=destination.u8string();osfx::Command c{};c.kind=osfx::SaveAs;strncpy_s(c.path,(const char*)encoded.c_str(),_TRUNCATE);if(OptiShadeUI::Send(c))ImGui::CloseCurrentPopup();}
                ImGui::EndDisabled();ImGui::SameLine();if(ImGui::Button("Cancel"))ImGui::CloseCurrentPopup();
                if(!valid)ImGui::TextDisabled("Choose a new .ini path in an existing folder.");
                ImGui::EndPopup();
            }
            if(ImGui::IsKeyPressed(ImGuiKey_Escape,false)&&!ImGui::IsAnyItemActive())editorVisible=false;
        }
        ImGui::End();
        const auto* editorViewport=ImGui::GetMainViewport();
        const bool editorIntersectsViewport=editorViewport&&editorPosition.x+editorSize.x>editorViewport->Pos.x&&
            editorPosition.y+editorSize.y>editorViewport->Pos.y&&editorPosition.x<editorViewport->Pos.x+editorViewport->Size.x&&
            editorPosition.y<editorViewport->Pos.y+editorViewport->Size.y;
        if(editorContentsVisible&&editorVisible&&editorDrawList&&editorDrawList->VtxBuffer.Size>0&&editorIntersectsViewport)
            _interactivePanelDrawList=editorDrawList;
        OptiShadeUI::lookEditorOpen=editorVisible;ImGui::PopFontSize();ImGui::PopStyleVar(5);return;
    }
    const bool mainContentsVisible=ImGui::Begin("optishade | fusion engine",&visible,ImGuiWindowFlags_NoCollapse|ImGuiWindowFlags_NoTitleBar|ImGuiWindowFlags_NoScrollbar|ImGuiWindowFlags_NoScrollWithMouse);
    const auto* mainDrawList=ImGui::GetWindowDrawList();
    if(mainContentsVisible){
        static bool loadedHelp=false;if(!loadedHelp){optishade::panel::CompactHelp()=GetPrivateProfileIntW(L"Interface",L"CompactHelp",0,modePath.c_str())!=0;loadedHelp=true;}
        static int page=std::clamp(int(GetPrivateProfileIntW(L"Interface",L"LastTab",0,modePath.c_str())),0,6);
        const int previousPage=page;
        static const std::string buildDisplay=optishade::build_display::Label(
            Util::DllPath().parent_path()/L"OptiShadeData"/L"BuildIdentity.json",OPTISHADE_VERSION_DISPLAY);
        optishade::panel::ShellHeader(buildDisplay.c_str(),
            ctx.state.api==API::Vulkan?"Vulkan":ctx.state.api==API::DX12?"DirectX 12":ctx.state.api==API::DX11?"DirectX 11":"Graphics API not observed",visible,page,uiScale);
        optishade::panel::BeginSidebarPage(page,true);
        OptiShadeUpdates::DrawHeader();
        static std::array<float,7> scroll{};static bool wasDetail=false;
        const bool detail=optishade::panel::Details().mode!=optishade::panel::DetailMode::None;
        if(!detail&&(wasDetail||previousPage!=page))ImGui::SetNextWindowScroll(ImVec2(-1.f,scroll[page]));
        if(detail&&!wasDetail)ImGui::SetNextWindowScroll(ImVec2(-1.f,0));
        if(!detail&&optishade::panel::Details().resetScroll){ImGui::SetNextWindowScroll(ImVec2(-1.f,0));optishade::panel::Details().resetScroll=false;}
        const float footerHeight=ImGui::GetFontSize()*5.5f;
        ImGui::PushStyleColor(ImGuiCol_ChildBg,ImVec4(0,0,0,0));
        ImGui::BeginChild("OptiShade content",ImVec2(0,-footerHeight));
        if(detail&&optishade::panel::Details().mode==optishade::panel::DetailMode::Review){
            const auto gpu=RenderingGpu(ctx.state);
            DlssNr::DrawMenuReview(gpu.vendorId!=VendorId::AMD&&gpu.vendorId!=VendorId::Intel);
        }
        else if(detail&&optishade::panel::Details().mode==optishade::panel::DetailMode::FxReview){
            optishade::panel::PageTitle("Review image effects","The preview is live. Saving replaces this preset with your current settings.");
            ImGui::TextWrapped("Preset: %s",OptiShadeUI::fx.preset);
            ImGui::TextWrapped("Only image effects and their values are saved. Neural rendering remains separate.");
            static std::string approvedPreset;static bool replace=false;
            if(approvedPreset!=OptiShadeUI::fx.preset){approvedPreset=OptiShadeUI::fx.preset;replace=false;}
            ImGui::Checkbox("Replace my current saved preset",&replace);
            ImGui::BeginDisabled(!replace||!OptiShadeUI::fx.dirty||OptiShadeUI::fx.loading||OptiShadeUI::fx.performanceMode);
            if(ImGui::Button("Save current preset")){osfx::Command command{};command.kind=osfx::Save;if(OptiShadeUI::Send(command)){replace=false;optishade::panel::CloseDetail();}}
            ImGui::EndDisabled();ImGui::SameLine();if(ImGui::Button("Keep editing")){replace=false;optishade::panel::CloseDetail();}
            ImGui::TextWrapped("To keep the original, return to Image effects > Save preset and choose a different name.");
        }
        else if(detail)optishade::panel::DrawDetail(page);
        else if(page==0){
#include "reconstruction/Performance.inl"
        }else if(page==1){
            const auto gpu=RenderingGpu(ctx.state);
            const bool unsupported=gpu.vendorId==VendorId::AMD||gpu.vendorId==VendorId::Intel;
            if(unsupported)ImGui::TextWrapped("This NVIDIA NR backend is unavailable on the current GPU. Image effects remain independent.");
            // Model preparation belongs to the component installer; RenderMenu
            // reports the actual runtime state, including missing model/input errors.
            ImGui::BeginDisabled(unsupported);DlssNr::RenderMenu(config,ctx.menuResScale);ImGui::EndDisabled();
        }else if(page==2){
            optishade::panel::PageTitle("Image effects","Choose a saved look or open the editor to create your own.");
            ImGui::Spacing();OptiShadeUI::DrawEffects();
        }
        else if(page==5){
            optishade::panel::PageTitle("Monitoring","Keep frame rates and hardware readings visible while you play.");
            optishade::panel::Card("Hardware monitor controls",[]{OptiShadeHardware::Settings();});
            optishade::panel::Card("FPS overlay controls",[&]{
#include "reconstruction/FpsPreferences.inl"
                if(ImGui::Button("Save monitoring settings"))saved=config->SaveIni();
            });
        }
        else if(page==4){
            optishade::panel::PageTitle("Glass cockpit","Screen correction, diagnostic tint and live status.");
            OptiShadeCockpitUI::Draw();
        }
        else{
            optishade::panel::PageTitle("Settings & status","Menu preferences, shortcuts and health.");
            optishade::panel::Card("Menu size",[&]{
                const char* sizes[]={"Auto (compact)","75%","85%","100%","125%","150%","175%","200%"};const float values[]={0,.75f,.85f,1.f,1.25f,1.5f,1.75f,2.f};int choice=0;for(int i=1;i<8;++i)if(config->MenuScale.has_value()&&std::abs(config->MenuScale.value()-values[i])<.01f)choice=i;
                optishade::panel::SettingRow("Menu size","Drag the bottom-right corner to resize.",[&]{if(ImGui::Combo("##menu-size",&choice,sizes,8)){if(choice)config->MenuScale=values[choice];else config->MenuScale.reset();}});
                if(ImGui::Button("Reset window size and position"))mainMenuGeometry.Reset(view,uiScale);
            });

            const char* names[]={"Purple","Blue","Teal","Green","Amber","Rose"};
            const ImVec4 colours[]={{.62f,.32f,1.f,1.f},{.28f,.56f,1.f,1.f},{.1f,.74f,.72f,1.f},{.3f,.76f,.4f,1.f},{1.f,.64f,.22f,1.f},{.94f,.36f,.62f,1.f}};
            optishade::panel::SettingsAppearance([&]{
                int selected=-1;for(int i=0;i<6;++i)if(std::abs(config->MenuAccentColorR.value_or_default()-colours[i].x)<.02f&&std::abs(config->MenuAccentColorG.value_or_default()-colours[i].y)<.02f&&std::abs(config->MenuAccentColorB.value_or_default()-colours[i].z)<.02f)selected=i;
                if(ImGui::BeginCombo("##theme-accent",selected<0?"Custom":names[selected])){for(int i=0;i<6;++i)if(ImGui::Selectable(names[i],i==selected)){config->MenuAccentColorR=colours[i].x;config->MenuAccentColorG=colours[i].y;config->MenuAccentColorB=colours[i].z;ApplyThemeStyle();}ImGui::EndCombo();}
            },[&]{
                float opacity=config->MenuBGColorA.value_or_default()*100.f;
                ImGui::SetNextItemWidth(std::max(50.f,ImGui::GetContentRegionAvail().x-ImGui::GetFontSize()*4.f));
                if(optishade::panel::StrengthTrack("##menu-opacity",&opacity,20.f,100.f)){config->MenuBGColorA=opacity/100.f;ApplyThemeStyle();}
                ImGui::SameLine();char label[16];snprintf(label,sizeof(label),"%.0f%%",opacity);optishade::panel::Keycap(label);
            },[&]{
                bool compact=optishade::panel::CompactHelp();if(optishade::panel::Toggle("Compact helper text",&compact)){optishade::panel::CompactHelp()=compact;WritePrivateProfileStringW(L"Interface",L"CompactHelp",compact?L"1":L"0",modePath.c_str());}
            });
            RenderKeybindSettings(ctx);
            optishade::panel::SettingsStatus(ctx.currentFeature?ctx.currentFeature->ShortName().c_str():"Not observed",ctx.state.api==API::Vulkan?"Vulkan":ctx.state.api==API::DX12?"DirectX 12":"DirectX 11","Beta",OPTISHADE_VERSION_DISPLAY);
            const auto settingsTarget=optishade::panel::Details().open;
            if(settingsTarget==optishade::panel::Section::Menu||settingsTarget==optishade::panel::Section::Cockpit)ImGui::SetNextItemOpen(true,ImGuiCond_Always);
            if(optishade::panel::Group("Help, updates & troubleshooting",optishade::panel::Section::Status,"Menu sizing, shortcuts, diagnostics and support")){
            if(ImGui::Button("Help with a problem"))optishade::panel::Open("Help and reports","",optishade::panel::DetailMode::Help);
            optishade::panel::RestoreLastItemFocus();
            if(optishade::panel::Group("Menu size and customisation",optishade::panel::Section::Menu)){
#include "reconstruction/MenuPreferences.inl"
                ImGui::TextWrapped("Menu preferences and shortcut changes are previewed now. Use Save or Discard below.");
            }

            if(ImGui::CollapsingHeader("Technical status and readiness evidence")){
#include "reconstruction/TechnicalStatus.inl"
                optishade::readiness::Snapshot decisions;
                if(optishade::readiness::State().Read(decisions)){
                    ImGui::Text("Readiness decisions recorded: %llu",static_cast<unsigned long long>(decisions.sequence));
                    if(decisions.hasFirstFailure)ImGui::TextWrapped("First captured failure: %s",optishade::readiness::Name(decisions.firstFailure.outcome));
                    if(ImGui::Button("Copy readiness report")){const auto report=optishade::readiness::Report(decisions);ImGui::SetClipboardText(report.c_str());}
                    ImGui::TextWrapped("Exact CPU readiness-check samples, not later fence readings. Match command/recording IDs with FGTRACE; this does not certify final output.");
                }else ImGui::TextWrapped("The readiness snapshot is busy; try again. The UI does not wait for it.");
            }
            if(ImGui::CollapsingHeader("About, credits and licences")){
                ImGui::TextWrapped("OptiShade, created by Gravy. Powered by Fusion Engine.");
                ImGui::TextWrapped("Includes OptiScaler, ReShade and other credited components. Full notices and licences are installed in OptiShadeData/Licenses.");
                ImGui::TextWrapped("Glass Cockpit DLSS Fix by IFreemz. Official v1.0.3 add-on shipped unchanged under GPL-3.0-only with explicit permission for OptiShade to bundle and update it. Source and notices: github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix");
                if(ImGui::Button("Copy screen-fix support link"))ImGui::SetClipboardText("https://github.com/IFreemz/msfs2024-glass-cockpit-dlss-fix/issues");
            }
            }
        }
        if(!detail)scroll[page]=ImGui::GetScrollY();
        ImGui::EndChild();ImGui::PopStyleColor();wasDetail=detail;
        if(previousPage!=page)WritePrivateProfileStringW(L"Interface",L"LastTab",std::to_wstring(page).c_str(),modePath.c_str());
        ImGui::Separator();
        const bool pendingNr=DlssNr::MenuHasChanges();
        const bool pendingMenu=menuSettings.Dirty(*config);
        const auto footerAction=optishade::panel::ChooseFooterAction({page,pendingMenu,pendingNr,false,
            OptiShadeUI::fx.dirty!=0,false,false,false,false,OptiShadeUI::fx.loading!=0});
        const bool reviewMenu=footerAction.kind==optishade::panel::FooterActionKind::Menu;
        const bool reviewFx=footerAction.kind==optishade::panel::FooterActionKind::Effects;
        const bool saveMfg=page==0&&!detail&&!pendingMenu&&!pendingNr&&!OptiShadeUI::fx.dirty;
        const bool actionable=footerAction.actionable||saveMfg;
        const auto recoveryKey=std::string("Ctrl+Shift+")+Keybind::KeyNameFromVirtualKeyCode(config->BackupShortcutKey.value_or_default());
        const char* menuStatus=reviewMenu?(menuSettings.feedback.empty()?"Menu preferences and shortcuts pending":menuSettings.feedback.c_str()):nullptr;
        const char* footerStatus=saveMfg?(OptiShadeMfgUI::optiMfgSaveFeedback.empty()?"MFG changes save automatically; Save verifies the current choice":OptiShadeMfgUI::optiMfgSaveFeedback.c_str()):reviewMenu?menuStatus:reviewFx?"Preset changes pending":pendingNr?"NR preview - not saved":menuSettings.feedback.empty()?"No pending changes":menuSettings.feedback.c_str();
        optishade::panel::ShellFooter(footerStatus,
            pendingMenu||pendingNr||OptiShadeUI::fx.dirty,actionable,!reviewMenu&&DlssNr::MenuCanUndo(),Keybind::KeyNameFromVirtualKeyCode(config->ShortcutKey.value_or_default()).c_str(),recoveryKey.c_str(),
            [&]{if(saveMfg){OptiShadeMfgUI::optiMfgSaveFeedback="MFG choice is already saved; select another multiplier to change it";}else if(reviewMenu){menuSettings.Discard(*config);ApplyThemeStyle();}else if(reviewFx){osfx::Command command{};command.kind=osfx::Discard;if(OptiShadeUI::Send(command))OptiShadeUI::preparing.clear();}else DlssNr::DiscardMenuChanges();},
            [&]{if(saveMfg){saved=OptiShadeMfgUI::SaveCurrentOptiMfgChoice();}else if(reviewMenu){saved=menuSettings.Commit(*config,[&]{return config->SaveMenuSettings();});}else if(reviewFx){osfx::Command command{};command.kind=osfx::Save;OptiShadeUI::Send(command);}else {const auto gpu=RenderingGpu(ctx.state);DlssNr::SaveMenuChanges(gpu.vendorId!=VendorId::AMD&&gpu.vendorId!=VendorId::Intel);}},
            [&]{if(DlssNr::StageMenuUndo()){const auto gpu=RenderingGpu(ctx.state);DlssNr::SaveMenuChanges(gpu.vendorId!=VendorId::AMD&&gpu.vendorId!=VendorId::Intel);}},
            saveMfg?"Save MFG choice":footerAction.saveLabel);
        optishade::panel::EndSidebarPage();


    }
    const auto position=ImGui::GetWindowPos();const auto size=ImGui::GetWindowSize();
    const auto* window=ImGui::GetCurrentWindow();const auto& imgui=*ImGui::GetCurrentContext();
    const bool editing=imgui.MovingWindow==window||imgui.ActiveIdWindow==window||imgui.NavWindowingTarget==window;
    mainMenuGeometry.Observe({position.x,position.y,size.x,size.y},editing,GetTickCount64());
    SaveMenuGeometryBoundary(false,editing);
    ImGui::End();
    const auto* mainViewport=ImGui::GetMainViewport();
    const bool mainIntersectsViewport=mainViewport&&position.x+size.x>mainViewport->Pos.x&&
        position.y+size.y>mainViewport->Pos.y&&position.x<mainViewport->Pos.x+mainViewport->Size.x&&
        position.y<mainViewport->Pos.y+mainViewport->Size.y;
    if(mainContentsVisible&&visible&&mainDrawList&&mainDrawList->VtxBuffer.Size>0&&mainIntersectsViewport)
        _interactivePanelDrawList=mainDrawList;
    ImGui::PopFontSize();ImGui::PopStyleVar(5);if(!visible)HideMenu();
}
