// Native view binding extracted without behavior changes from the reviewed R7 build.
        ImGui::SeparatorText("Model passes");
        ImGui::TextWrapped("Settings apply when you release a slider.");
        static const char* styles[] = { "Standard", "Natural", "Cinematic" };
        static const char* inheritedStyles[] = { "Auto (inherit pass 1)", "Standard", "Natural", "Cinematic" };

        if (ImGui::TreeNodeEx("Pass 1", ImGuiTreeNodeFlags_DefaultOpen))
        {
            DeferredSlider("Local structure", &config->DlssNrLocalStructure, 0.0f, 2.0f, 1.0f);
            DeferredSlider("Local tone", &config->DlssNrLocalTone, 0.0f, 2.0f, 1.0f);
            DeferredSlider("Skin structure", &config->DlssNrSkinStructure, -1.0f, 2.0f, -1.0f);
            bool mask = config->DlssNrAutoMask.value_or_default();
            if (ImGui::Checkbox("Auto skin mask", &mask))
                config->DlssNrAutoMask = mask;
            HelpMarker("Use the model's learned skin selection to apply Skin structure without an authored mask.\nAccuracy varies. This is separate from the colour-based mask below.");
            ImGui::TreePop();
        }

        if (ImGui::TreeNodeEx("Pass 2", ImGuiTreeNodeFlags_DefaultOpen))
        {
            ImGui::TextWrapped("Defaults: inherit Pass 1; Local tone = 0. Reset restores these defaults.");
            InheritedProfileCombo("Style", &config->DlssNrPass2Style, inheritedStyles, IM_ARRAYSIZE(inheritedStyles));
            DeferredSlider("Intensity", &config->DlssNrPass2Intensity, 0.0f, 2.0f, config->DlssNrIntensity.value_or_default(), "%.2f", true);
            DeferredSlider("Local structure", &config->DlssNrPass2LocalStructure, 0.0f, 2.0f, config->DlssNrLocalStructure.value_or_default(), "%.2f", true);
            DeferredSlider("Local tone", &config->DlssNrPass2LocalTone, 0.0f, 2.0f, 0.0f, "%.2f", true);
            DeferredSlider("Skin structure", &config->DlssNrPass2SkinStructure, -1.0f, 2.0f, config->DlssNrSkinStructure.value_or_default(), "%.2f", true);
            bool mask = config->DlssNrPass2AutoMask.has_value() ? config->DlssNrPass2AutoMask.value() : config->DlssNrAutoMask.value_or_default();
            if (ImGui::Checkbox("Auto skin mask", &mask))
                config->DlssNrPass2AutoMask = mask;
            ImGui::SameLine();
            if (ImGui::SmallButton("Reset##mask"))
                config->DlssNrPass2AutoMask = std::optional<bool> {};
            ImGui::TreePop();
        }

        if (ImGui::TreeNodeEx("Pass 3", ImGuiTreeNodeFlags_DefaultOpen))
        {
            ImGui::TextWrapped("Defaults: inherit Pass 1; Local tone = 0. Reset restores these defaults.");
            InheritedProfileCombo("Style", &config->DlssNrPass3Style, inheritedStyles, IM_ARRAYSIZE(inheritedStyles));
            DeferredSlider("Intensity", &config->DlssNrPass3Intensity, 0.0f, 2.0f, config->DlssNrIntensity.value_or_default(), "%.2f", true);
            DeferredSlider("Local structure", &config->DlssNrPass3LocalStructure, 0.0f, 2.0f, config->DlssNrLocalStructure.value_or_default(), "%.2f", true);
            DeferredSlider("Local tone", &config->DlssNrPass3LocalTone, 0.0f, 2.0f, 0.0f, "%.2f", true);
            DeferredSlider("Skin structure", &config->DlssNrPass3SkinStructure, -1.0f, 2.0f, config->DlssNrSkinStructure.value_or_default(), "%.2f", true);
            bool mask = config->DlssNrPass3AutoMask.has_value() ? config->DlssNrPass3AutoMask.value() : config->DlssNrAutoMask.value_or_default();
            if (ImGui::Checkbox("Auto skin mask", &mask))
                config->DlssNrPass3AutoMask = mask;
            ImGui::SameLine();
            if (ImGui::SmallButton("Reset##mask"))
                config->DlssNrPass3AutoMask = std::optional<bool> {};
            ImGui::TreePop();
        }

        const unsigned int visiblePasses = std::clamp(config->DlssNrPasses.value_or_default(), 1u, passLimit);
        for (unsigned int pass = 3; pass < visiblePasses; ++pass)
        {
            auto& settings = config->DlssNrExtraPasses[pass - 3];
            if (!ImGui::TreeNode(std::format("Pass {}", pass + 1).c_str()))
                continue;
            ImGui::TextWrapped("Defaults: inherit Pass 1; Local tone = 0.");
            InheritedProfileCombo("Style", &settings.style, inheritedStyles, IM_ARRAYSIZE(inheritedStyles));
            DeferredSlider("Intensity", &settings.intensity, 0.0f, 2.0f, config->DlssNrIntensity.value_or_default(), "%.2f", true);
            DeferredSlider("Local structure", &settings.structure, 0.0f, 2.0f, config->DlssNrLocalStructure.value_or_default(), "%.2f", true);
            DeferredSlider("Local tone", &settings.tone, 0.0f, 2.0f, 0.0f, "%.2f", true);
            DeferredSlider("Skin structure", &settings.skin, -1.0f, 2.0f, config->DlssNrSkinStructure.value_or_default(), "%.2f", true);
            bool mask = settings.autoMask.value_or(config->DlssNrAutoMask.value_or_default());
            if (ImGui::Checkbox("Auto skin mask", &mask))
                settings.autoMask = mask;
            ImGui::SameLine();
            if (ImGui::SmallButton("Reset##mask"))
                settings.autoMask = std::optional<bool> {};
            ImGui::TreePop();
        }

        if (ImGui::TreeNode("Advanced preset hints (effect unverified)"))
        {
            ImGui::TextWrapped("Runtime model hint. On DLSS-NR 310.9.16, Auto selects lightweight model B; Preset 1 selects standard model A; Preset 2 selects lightweight model B. Older runtimes may ignore this distinction. Style is a separate control.");
            static const char* presets[] = { "Auto (runtime default; B on 310.9.16)", "Preset 1 (A / standard on 310.9.16)", "Preset 2 (B / lightweight on 310.9.16)", "Preset 3 (unverified)" };
            static const char* inheritedPresets[] = { "Auto (inherit pass 1)", "Default", "Preset 1", "Preset 2", "Preset 3" };
            int preset = (int) std::min(config->DlssNrPreset.value_or_default(), 3u);
            if (ImGui::Combo("Pass 1 preset hint", &preset, presets, IM_ARRAYSIZE(presets)))
                config->DlssNrPreset = (uint32_t) preset;
            InheritedProfileCombo("Pass 2 preset hint", &config->DlssNrPass2Preset, inheritedPresets, IM_ARRAYSIZE(inheritedPresets));
            InheritedProfileCombo("Pass 3 preset hint", &config->DlssNrPass3Preset, inheritedPresets, IM_ARRAYSIZE(inheritedPresets));
            ImGui::TreePop();
        }
        ImGui::TextWrapped("Pass settings apply to SR and RR on DX12 and native Vulkan. The driver-proxy backend supports one pass.");


