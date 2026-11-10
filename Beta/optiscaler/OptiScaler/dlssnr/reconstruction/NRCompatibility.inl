// Native view binding extracted without behavior changes from the reviewed R7 build.
        bool deferredDlss = config->DlssNrDeferredDlss.value_or_default();
        int precisionChoice = config->DlssNrPrecision.value_or_default() == 4 ? 1 : 0;
        const auto hybridUnavailable = DlssNrNative::HybridAvailability();
        if(ImGui::BeginCombo("Model precision",precisionChoice ? "Experimental hybrid (requested)" : "NVIDIA (FP8)")) {
            if(ImGui::Selectable("NVIDIA (FP8)",precisionChoice==0)) config->DlssNrPrecision=0u;
            ImGui::BeginDisabled(!hybridUnavailable.empty());
            if(ImGui::Selectable("Experimental (FP8+NVFP4 hybrid)",precisionChoice==1)) config->DlssNrPrecision=4u;
            ImGui::EndDisabled();ImGui::EndCombo();
        }
        if(!hybridUnavailable.empty()) ImGui::TextWrapped("%s",hybridUnavailable.c_str());
        else if(precisionChoice) ImGui::TextWrapped("Hybrid requested. Effective precision: %s. Recorded launches alone do not confirm completed output.",DlssNrNative::IsActive()?"hybrid recorded":"original FP8 / preparing");
        // Keep failure details in the log without displaying changing kernel counters in the menu.
        auto hybridStatus = DlssNrNative::Status();
        hybridStatus = hybridStatus.substr(0, hybridStatus.find(" |"));
        static std::string lastHybridWarning;
        if (hybridStatus.rfind("Restart required:", 0) == 0 || hybridStatus.find("fallback") != std::string::npos)
        {
            if (hybridStatus != lastHybridWarning)
                LOG_WARN("Hybrid: {}", hybridStatus);
            lastHybridWarning = hybridStatus;
        }
        else
            lastHybridWarning.clear();

