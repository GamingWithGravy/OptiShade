// Native view binding extracted without behavior changes from the reviewed R7 build.
        ImGui::BeginDisabled(taaFallback);
        if (!finishedPicture)
        {
            bool residualAcrossRr = config->DlssNrResidualAcrossRr.value_or_default();
            ImGui::BeginDisabled(deferredActive || !beforeSr);
            if (ImGui::Checkbox("Carry the pre-SR edit across RR (experimental)", &residualAcrossRr))
                config->DlssNrResidualAcrossRr = residualAcrossRr;
            ImGui::EndDisabled();
            HelpMarker("Only with Apply before Super Resolution on and the game's Ray Reconstruction active.\nRuns the model before SR but leaves the colour input untouched, then adds its edit back onto the RR+SR output so it survives RR's denoise.\nThe edit is carried as a motion-vector-reprojected temporal accumulator: the per-frame ray-trace noise averages out, the enhancement stays. Inert otherwise.");

            ImGui::BeginDisabled(deferredActive || !beforeSr || !residualAcrossRr);
            float residualBlend = config->DlssNrResidualAcrossRrBlend.value_or_default();
            if (ImGui::SliderFloat("Detail accumulation rate", &residualBlend, 0.01f, 1.0f, "%.2f"))
                config->DlssNrResidualAcrossRrBlend = std::clamp(residualBlend, 0.01f, 1.0f);
            ImGui::EndDisabled();
            HelpMarker("How fast the carried edit builds up. Lower = stabler but slower to appear; 1.0 = no accumulation (each frame's raw residual, which flickers). Default 0.08.");

        }
        ImGui::EndDisabled();
        ImGui::BeginDisabled(taaFallback);
        if (!finishedPicture)
        {
            if (ImGui::Checkbox("Generate before SR, apply after SR (DLSS)", &deferredDlss))
                config->DlssNrDeferredDlss = deferredDlss;
            HelpMarker("Compute NR at input resolution, upscale its changes with DLSS, then apply them after SR.\nExperimental: may flicker and adds GPU cost. Requires DLSS on DX12 or its bridges; does not support RR.\nOverrides Apply before Super Resolution. Disable Hold frame, Compare and Debug view.");
            if (deferredDlss && rayReconstruction)
                ImGui::TextWrapped("Generate before / apply after is unavailable with RR. Apply before Super Resolution "
                                   "controls NR placement.");
            else if (deferredDlss)
                ImGui::TextWrapped("Residual DLSS: %s", DlssNr::DeferredDlssStatus().c_str());
            ImGui::BeginDisabled(finishedPicture || !deferredDlss || rayReconstruction);
            bool residualFg = config->DlssNrResidualFg.value_or_default();
            if (ImGui::Checkbox("NR every second frame (NVIDIA FG, experimental)", &residualFg))
                config->DlssNrResidualFg = residualFg;
            HelpMarker("Run NR every other rendered frame and use NVIDIA FG to interpolate its changes.\nRequires the option above. Adds one rendered frame of latency and may misalign effects or UI.\nIf motion vectors are unavailable, each NR result is reused for two frames.");
            bool approxCamera = config->DlssNrResidualFgApproxCamera.value_or_default();
            if (ImGui::Checkbox("Allow approximate FG camera guides (experimental)", &approxCamera))
                config->DlssNrResidualFgApproxCamera = approxCamera;
            HelpMarker("Use estimated camera data when the game does not provide it. May cause artifacts during camera movement.");
            ImGui::EndDisabled();

        }
        else if (beforeSr)
            ImGui::TextWrapped("Pre-SR changes: %s", DlssNr::DeferredDlssStatus().c_str());

        // The toggle can be bound to a key, and nobody would think to look for it under Keybinds
        // unless told. Dimmed, because it is a note rather than a setting.
        ImGui::TextDisabled("Set the NR toggle shortcut under Keybinds.");

        ImGui::EndDisabled();

