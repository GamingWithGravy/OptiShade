// Native view binding extracted without behavior changes from the reviewed R7 build.
            optishade::panel::PageTitle("Performance","Upscaling and smoother motion. Neural rendering has its own tab.");
            optishade::panel::Card("OptiMFG frame generation",[&]{
                optishade::panel::CardHeading("FRAME GENERATION","OptiMFG",8);
                OptiShadeMfgUI::DrawFrameGeneration();
            }); ImGui::Spacing();
            optishade::panel::Card("Upscaling card",[&]{ optishade::panel::CardHeading("IMAGE UPSCALING","",2);
            optishade::BackendEvidence backendEvidence;
            backendEvidence.gameInput = ctx.currentFeature ? optishade::Evidence::Yes : optishade::Evidence::Unknown;
            if (ctx.currentFeature) {
                backendEvidence.initialized = ctx.currentFeature->IsInited() ? optishade::Evidence::Yes : optishade::Evidence::No;
                backendEvidence.active = optishade::Evidence::Unknown; // Initialization is not fresh completion/output evidence.
            }
            const char* backendStatus = optishade::BackendStageLabel(optishade::ResolveBackendStage(backendEvidence));
            static std::string lastBackendStatus;
            if(lastBackendStatus != backendStatus){
                LOG_INFO("Performance page backend: {}; API: {}", backendStatus, (int)ctx.state.api);
                lastBackendStatus = backendStatus;
            }
            const bool upscalerConnected=ctx.currentFeature&&ctx.currentFeature->IsInited()&&!ctx.currentFeature->IsFrozen();
            static bool editUpscaler=false;
            optishade::panel::SettingRow("Control","Leave the game in charge, or request an override.",[&]{
                if(ImGui::BeginCombo("##upscale-control",editUpscaler?"Show upscaling controls":"Game settings")){
                    if(ImGui::Selectable("Game settings",!editUpscaler))editUpscaler=false;
                    ImGui::BeginDisabled(!upscalerConnected);if(ImGui::Selectable("Show upscaling controls",editUpscaler))editUpscaler=true;ImGui::EndDisabled();ImGui::EndCombo();
                }
            });
            if(editUpscaler&&upscalerConnected)RenderActiveUpscalerSettings(ctx);
            ImGui::Separator();ImGui::TextWrapped("Reconstructs a larger picture from a smaller one. Fine text can look different.");
            if(!upscalerConnected)ImGui::TextWrapped("Waiting for an active game upscaler. Select a supported upscaler in the game and enter a flight. TAA does not connect these controls.");
            ImGui::TextDisabled("Backend state: %s",backendStatus);
            const auto renderingGpu = RenderingGpu(ctx.state);

            static std::string lastRenderingGpu;
            if (!renderingGpu.name.empty() && renderingGpu.name != lastRenderingGpu) {
                LOG_INFO("Rendering adapter: {}; LUID={:08X}:{:08X}; vendor={:04X}; device={:04X}",
                    renderingGpu.name, (UINT)renderingGpu.luid.HighPart, renderingGpu.luid.LowPart,
                    (UINT)renderingGpu.vendorId, renderingGpu.deviceId);
                lastRenderingGpu = renderingGpu.name;
            }

            if(ImGui::CollapsingHeader("Compatibility and rendering capabilities")){
            ImGui::TextWrapped("Rendering GPU: %s",renderingGpu.name.empty()?"Not identified":renderingGpu.name.c_str());
            ImGui::TextWrapped("An installed NVIDIA DLL is not proof that DLSS or Neural Rendering is active. Enter a flight with supported upscaling enabled. If controls remain unavailable, save a diagnostic report in the launcher.");
            static bool capabilitiesWasOpen=false;
            const bool capabilitiesOpen=ImGui::CollapsingHeader("Rendering device capabilities");
            if(capabilitiesOpen!=capabilitiesWasOpen){
                LOG_INFO("Rendering device capabilities disclosure {} (NR requested={})",capabilitiesOpen?"opened":"closed",ctx.config->DlssNrEnabled.value_or_default()?"On":"Off");
                capabilitiesWasOpen=capabilitiesOpen;
            }
            if (capabilitiesOpen) {
                const auto primary=optishade::runtime_render::State().Read();
                if (primary.Fresh(GetTickCount64())&&primary.context.api=="d3d12"&&ctx.state.currentD3D12Device&&
                    primary.device.identity==reinterpret_cast<uint64_t>(optishade::ReShadeDeviceIdentity(ctx.state.currentD3D12Device).Get())) {
                    static Microsoft::WRL::ComPtr<ID3D12Device> cachedDevice;
                    static optishade::D3D12Capabilities cachedCapabilities{};
                    if(cachedDevice.Get()!=ctx.state.currentD3D12Device){
                        cachedDevice=ctx.state.currentD3D12Device;
                        cachedCapabilities=optishade::QueryD3D12Capabilities(ctx.state.currentD3D12Device);
                    }
                    const auto& caps=cachedCapabilities;
                    ImGui::Text("D3D12 native 16-bit shader operations: %s", optishade::EvidenceLabel(caps.native16));
                    ImGui::Text("D3D12 wave operations: %s", optishade::EvidenceLabel(caps.waves));
                    const char* blocked = optishade::NvidiaNeuralPreflight(caps);
                    ImGui::TextWrapped("NVIDIA neural backend: %s", blocked ? blocked : "Eligible for runtime initialization; not proof of model support");
                    ImGui::TextWrapped("Cross-vendor neural backend: not integrated. FSR/XeSS upscaling is a separate feature, not DLSS 5 Neural Rendering.");
                } else ImGui::TextWrapped("D3D12 capability evidence is unavailable for the current primary rendering device.");
            }
            }
            }); ImGui::Spacing();if(optishade::panel::Group("Advanced performance",optishade::panel::Section::Quality,"Tuning, diagnostics and experimental options")){
            ImGui::TextWrapped("A frame-rate limit can help keep motion steady and reduce GPU load.");
            if(ImGui::CollapsingHeader("Set a frame-rate limit"))RenderFramerateSettings(ctx);
            if(ImGui::CollapsingHeader("Sharpness and picture size"))RenderActiveImageSettings(ctx);


            }
