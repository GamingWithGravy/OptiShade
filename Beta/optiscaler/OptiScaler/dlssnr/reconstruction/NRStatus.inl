// Native view binding extracted without behavior changes from the reviewed R7 build.
        const auto observed = DlssNr::Observation();
        if (!observed.requested) ImGui::TextDisabled("NR off.");
        else if (observed.recent) {
            ImGui::TextWrapped("%s: %s",optishade::nr_observation::Name(observed.owner.route),
                observed.composed ? "GPU composition completed." : "Model work completed; no visible composition confirmed.");
            if (!observed.visible) ImGui::TextDisabled("Model changes are hidden; model processing still has a cost.");
            if (observed.gpuMilliseconds) ImGui::Text("GPU elapsed: %.2f ms",*observed.gpuMilliseconds);
            else ImGui::TextDisabled("Timing not available yet.");
        } else {
            const auto feature = State::Instance().currentFeature;
            const bool nativeVk = feature && feature->Api() == API::Vulkan && !feature->IsWithDx12();
            const char* reason = nativeVk ? DlssNr::FailureReasonVk() : DlssNr::FailureReason();
            if (reason && *reason) {
                ImGui::TextWrapped("NR stopped: %s",reason);
                if (!nativeVk && ImGui::SmallButton("Retry")) DlssNr::RetryAfterFailure();
            } else ImGui::TextWrapped(observed.evaluated
                ? "NR evaluation recorded; waiting for recent GPU completion from this route."
                : "NR requested; waiting for valid inputs and an evaluation from this route.");
            ImGui::TextDisabled("Timing not available yet.");
        }


