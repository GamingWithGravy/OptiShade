// Native view binding extracted without behavior changes from the reviewed R7 build.
        if(taaFallback)ImGui::TextWrapped("Native placement controls below do not change the independent TAA route. Your saved native settings are retained.");
        ImGui::BeginDisabled(taaFallback);
        bool finishedPicture = config->DlssNrFinishedPicture.value_or_default();
        if (ImGui::Checkbox("Apply NR to the finished picture", &finishedPicture))
        {
            config->DlssNrFinishedPicture = finishedPicture;
            // Retry is submitted only after review/apply.
        }
        HelpMarker("Apply NR after the game has finished its lighting and effects. This may help with green noise.\nWorks with frame generation on or off in native DirectX 12 games, including SDR, HDR10 and scRGB.\nIt can also change the HUD and menus. Enable Run the model before Super Resolution to generate the changes earlier.");
        if (finishedPicture && enabled)
        {
            const auto feature = State::Instance().currentFeature;
            if (feature && (feature->Api() != API::DX12 || feature->IsWithDx12()))
                ImGui::TextWrapped("This option needs a native DirectX 12 game.");
            else
                ImGui::TextWrapped("%s", DlssNr::FinishedPictureStatus().c_str());
        }

        bool beforeSr = config->DlssNrRunBeforeSr.value_or_default() ||
                        (finishedPicture && config->DlssNrDeferredDlss.value_or_default());
        const auto activeFeature = State::Instance().currentFeature;
        const bool rayReconstruction = activeFeature && activeFeature->GetUpscalerType() == Upscaler::DLSSD;
        const bool deferredActive = !finishedPicture && config->DlssNrDeferredDlss.value_or_default() && !rayReconstruction;
        if (deferredActive)
            ImGui::BeginDisabled();
        if (ImGui::Checkbox(finishedPicture ? "Run the model before Super Resolution" : "Apply before Super Resolution", &beforeSr))
        {
            config->DlssNrRunBeforeSr = beforeSr;
            if (finishedPicture) config->DlssNrDeferredDlss = false;
        }
        if (deferredActive)
            ImGui::EndDisabled();

        HelpMarker(finishedPicture ? "Run the model at the smaller input size, upscale its changes with DLSS, then apply them to the finished picture.\nExperimental: the colour transfer is approximate and may look different. Requires DLSS SR; does not support RR." :
            "On: apply NR before SR or combined RR+SR. Off: apply it afterward.\nBefore RR is experimental. Unsupported input layouts fall back after upscaling.");


