// Native view binding extracted without behavior changes from the reviewed R7 build.
            ImGui::SeparatorText("Overlay colour");
            ImGui::TextWrapped("Choose an accent for your in-game menu. Purple is the default. This does not change your game's picture or your FX preset.");
            const char* paletteNames[]={"Purple","Blue","Teal","Green","Amber","Rose"};
            const ImVec4 palette[]={{.62f,.32f,1.f,1.f},{.28f,.56f,1.f,1.f},{.1f,.74f,.72f,1.f},{.3f,.76f,.4f,1.f},{1.f,.64f,.22f,1.f},{.94f,.36f,.62f,1.f}};
            auto setAccent=[&](const ImVec4& c){saved=false;config->MenuAccentColorR=c.x;config->MenuAccentColorG=c.y;config->MenuAccentColorB=c.z;ApplyThemeStyle();};
            for(int i=0;i<6;i++){
                if(i)ImGui::SameLine();
                ImGui::PushID(i);if(ImGui::ColorButton(paletteNames[i],palette[i],ImGuiColorEditFlags_NoTooltip,ImVec2(34*uiScale,28*uiScale)))setAccent(palette[i]);
                if(ImGui::IsItemHovered())ImGui::SetTooltip("%s",paletteNames[i]);ImGui::PopID();
            }
            float accent[]={config->MenuAccentColorR.value_or_default(),config->MenuAccentColorG.value_or_default(),config->MenuAccentColorB.value_or_default()};
            ImGui::SetNextItemWidth(280);
            if(ImGui::ColorEdit3("Custom colour",accent,ImGuiColorEditFlags_NoInputs))setAccent(ImVec4(accent[0],accent[1],accent[2],1.f));
            if(ImGui::Button("Reset to purple"))setAccent(palette[0]);
            ImGui::TextDisabled("Preview changes instantly. Use Save below to keep your choice for this game.");

