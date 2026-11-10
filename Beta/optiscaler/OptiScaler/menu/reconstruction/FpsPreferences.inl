// Native view binding extracted without behavior changes from the reviewed R7 build.
            const char* sizeNames[]={"Auto (match resolution)","100%","125%","150%","175%","200%"};
            const float sizeValues[]={0.f,1.f,1.25f,1.5f,1.75f,2.f};
            ImGui::SeparatorText("FPS overlay");
            bool showFps=config->ShowFps.value_or_default();
            if(OptiShadeUI::EffectSwitch("Show FPS",showFps)){config->ShowFps=!showFps;saved=false;}
            ImGui::SameLine();ImGui::TextUnformatted("Show FPS overlay");
            bool horizontal=config->FpsOverlayHorizontal.value_or_default();
            if(OptiShadeUI::EffectSwitch("Horizontal FPS",horizontal)){config->FpsOverlayHorizontal=!horizontal;saved=false;}
            ImGui::SameLine();ImGui::TextUnformatted("Horizontal layout");
            const char* positions[]={"Top left","Top right","Bottom left","Bottom right"};
            int position=std::clamp((int)config->FpsOverlayPosition.value_or_default(),0,3);
            ImGui::SetNextItemWidth(240*uiScale);
            if(ImGui::Combo("Position",&position,positions,4)){config->FpsOverlayPosition=(FpsOverlayPos)position;saved=false;}
            const char* details[]={"FPS only","Simple","Detailed","Detailed with graph","Full","Full with graph","Reflex timings"};
            int detail=std::clamp((int)config->FpsOverlayType.value_or_default(),0,6);
            ImGui::SetNextItemWidth(240*uiScale);
            if(ImGui::Combo("Detail level",&detail,details,7)){config->FpsOverlayType=(FpsOverlay)detail;saved=false;}
            char fpsSizeLabel[40]{};
            if(config->FpsScale.has_value())sprintf_s(fpsSizeLabel,"%.0f%%",config->FpsScale.value()*100);else strcpy_s(fpsSizeLabel,"Match menu size");
            ImGui::SetNextItemWidth(240*uiScale);
            if(ImGui::BeginCombo("FPS text size",fpsSizeLabel)){
                for(int i=0;i<6;i++)if(ImGui::Selectable(i==0?"Match menu size":sizeNames[i],i==0?!config->FpsScale.has_value():(config->FpsScale.has_value()&&std::abs(config->FpsScale.value()-sizeValues[i])<.01f))){
                    if(i==0)config->FpsScale.reset();else config->FpsScale=sizeValues[i];saved=false;
                }
                ImGui::EndCombo();
            }
            float opacity=config->FpsOverlayAlpha.value_or_default()*100;
            ImGui::SetNextItemWidth(240*uiScale);
            if(ImGui::SliderFloat("Background opacity",&opacity,0,100,"%.0f%%",ImGuiSliderFlags_AlwaysClamp)){config->FpsOverlayAlpha=opacity/100;saved=false;}
            bool themed=config->OverlaysUseTheme.value_or_default();
            if(OptiShadeUI::EffectSwitch("FPS theme",themed)){config->OverlaysUseTheme=!themed;saved=false;}
            ImGui::SameLine();ImGui::TextUnformatted("Use OptiShade colours");
            if(ImGui::Button("Reset FPS overlay")){
                config->ShowFps.reset();config->FpsOverlayPosition.reset();config->FpsOverlayType.reset();config->FpsScale.reset();config->FpsOverlayAlpha.reset();config->FpsOverlayHorizontal.reset();config->OverlaysUseTheme.reset();saved=false;
            }
            ImGui::TextWrapped("These controls change the overlay only. Save settings keeps your choices for this game.");

