// Native view binding extracted without behavior changes from the reviewed R7 build.
        bool unlockPasses = config->DlssNrUnlockPasses.value_or_default();
        if (ImGui::Checkbox("Allow up to 5 model passes", &unlockPasses))
            config->DlssNrUnlockPasses = unlockPasses;
        HelpMarker("Raises the model pass limit from 3 to 5. Additional passes increase GPU load and can reduce frame rate. Start with one pass and increase gradually.");
        const unsigned int passLimit = unlockPasses ? MaxPassCount : DefaultMaxPassCount;

        {
            int passes = (int) std::clamp(config->DlssNrPasses.value_or_default(), 1u,
                                          passLimit);
            const ImVec4 colour = passes <= 1   ? ImVec4(0.35f, 0.88f, 0.38f, 1.0f)
                                  : passes == 2 ? ImVec4(0.95f, 0.70f, 0.20f, 1.0f)
                                                : ImVec4(0.92f, 0.30f, 0.25f, 1.0f);

            ImGui::PushStyleColor(ImGuiCol_Text, colour);
            ImGui::PushStyleColor(ImGuiCol_SliderGrab, colour);

            if (ImGui::SliderInt("Model passes", &passes, 1, (int) passLimit,
                                 passes == 1 ? "%d (normal)" : "%dx model cost"))
                config->DlssNrPasses = (uint32_t) std::clamp(passes, 1, (int) passLimit);

            ImGui::PopStyleColor(2);

            if(taaFallback)
                ImGui::TextWrapped("TAA input is active. Your requested count is %d; this route uses one pass to reduce flashing. The setting is saved and takes effect on a route that supports multiple passes.", passes);
            else
                HelpMarker("Process the image repeatedly. More passes strengthen the effect and increase GPU cost.\nEach pass has its own settings and history. Start with 1.");
        }

        // Any percentage, rather than a handful of steps somebody chose in advance. The lower bound
        // is 25%: below that the model is working on so little of the picture that its answer no
        // longer survives being enlarged onto it.
        // Applied when the handle is let go, not while it is moving.
        //
        // Every distinct value here is a different working size, and a different working size tears
        // down the scratch textures and rebuilds the model. Writing it on each pixel of a drag meant
        // dozens of rebuilds in a second, which is felt as the whole frame hitching. The slider still
        // reads live; only the commit waits.
        static int pendingScale = -1;

        int scalePercent = pendingScale >= 0
                               ? pendingScale
                               : (int) lroundf(config->DlssNrWorkingScale.value_or_default() * 100.0f);

        if (ImGui::SliderInt("Model resolution", &scalePercent, 25, 200, "%d%%"))
            pendingScale = scalePercent;

        if (ImGui::IsItemDeactivatedAfterEdit() && pendingScale >= 0)
        {
            config->DlssNrWorkingScale = std::clamp(pendingScale, 25, 200) / 100.0f;
            pendingScale = -1;
        }

        HelpMarker("NR resolution relative to the image it processes. 50% halves width and height; 100% uses the full size.\nLower values reduce cost and fine detail. Above 100% increases cost. Game output resolution is unchanged.");

        if (scalePercent > 100)
            ImGui::TextDisabled("NR scale: %.2fx. Higher resolution increases GPU cost.",
                                scalePercent / 100.0f);

        if (scalePercent > 100)
        {
            static const char* dsNames[] = { "FSR1", "Bicubic", "Catmull-Rom", "Lanczos2",
                                             "Lanczos3", "Kaiser2", "Kaiser3", "MAGIC" };
            int ds = (int) config->DlssNrScalingDownscaler.value_or_default();
            if (ds < 0 || ds >= IM_ARRAYSIZE(dsNames))
                ds = (int) Scaler::Lanczos3;

            if (ImGui::Combo("Downscaler (NR)", &ds, dsNames, IM_ARRAYSIZE(dsNames)))
                config->DlssNrScalingDownscaler = (Scaler) ds;

            HelpMarker("Filter used to reduce NR output when Model resolution exceeds 100%.\nSharper filters may introduce ringing around edges.");
        }


        // Meaningful only when the model runs BELOW the frame's size. At 100% -- and above, where
        // supersampling composites its down-legged answer at native -- the residual collapses to the
        // model's own picture and the two modes are identical, so the control says so by going grey.
        {
            const bool reduced = config->DlssNrWorkingScale.value_or_default() < 0.999f;

            if (!reduced)
                ImGui::BeginDisabled();

            static const char* enlargeNames[] = { "Classic", "Matched residual" };
            int enlarge = config->DlssNrTransfer.value_or_default() == 1 ? 1 : 0;

            if (ImGui::Combo("Enlargement", &enlarge, enlargeNames, IM_ARRAYSIZE(enlargeNames)))
                config->DlssNrTransfer = (uint32_t) enlarge;

            if (!reduced)
                ImGui::EndDisabled();

            HelpMarker("Below 100% model resolution: Classic enlarges the model output; Matched residual enlarges only its changes.\nMatched residual can reduce blur and colour shifts. No effect at 100% or above.");
        }


