// Native view binding extracted without behavior changes from the reviewed R7 build.
        const bool xp12 = _wcsicmp(Util::ExePath().filename().c_str(), L"X-Plane.exe") == 0;
        if (xp12)
            ImGui::TextWrapped("X-Plane 12 Vulkan NR (experimental): no DLSS option is required. Estimated guide prerequisites are prepared while NR is requested. SDR only; model working extent up to 3840 x 2160 and 1-3 passes. Unsupported scale/pass requests are reported. NR starts off each launch. Restart after an actual GPU/NR submission failure.");
        ImGui::TextWrapped("Source policy: %s",optishade::nr_source::Name(config->SourcePolicy()));
        bool taaFallback = optishade::nr_source::AllowsEstimated(config->SourcePolicy());
        if (!xp12) {
        const auto routeState=DlssNr::Observation();
        const bool nativeActive=routeState.recent && (routeState.owner.route==optishade::nr_observation::Route::NativeD3D12||routeState.owner.route==optishade::nr_observation::Route::BeforeSR||routeState.owner.route==optishade::nr_observation::Route::FinishedPicture);
        if(routeState.recent){ImGui::TextWrapped("Active route: %s",optishade::nr_observation::Name(routeState.owner.route));
         const auto inputs=optishade::nr_observation::Provenance(routeState.owner.route);
         ImGui::TextWrapped("Motion source: %s. Stage: %s",inputs.motion,inputs.stage);
        }
        if(nativeActive)ImGui::TextWrapped("Native DLSS inputs are active; TAA compatibility is currently not needed.");
        ImGui::TextWrapped("Your game AA setting is unchanged.");
        ImGui::TextWrapped("Matching upscaler inputs take priority. Other inputs must satisfy the selected route contract.");
        if(taaFallback&&!nativeActive)ImGui::TextWrapped("%s",DlssNr::TaaFallbackStatus().c_str());
        }

        HelpMarker("Enhance lighting and material appearance with the NR model. Placement selects before or after upscaling.\nRequires nvngx_dlssnr.dll plus the included nvngx.dll_dlssnr.dll helper.");


