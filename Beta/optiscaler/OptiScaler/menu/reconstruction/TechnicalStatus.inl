// Native view binding extracted without behavior changes from the reviewed R7 build.
            ImGui::Spacing();ImGui::Separator();
            const auto inputStatus=OptiInput::GetDebugState();
            ImGui::Text("Overlay initialized | Input: %s | Focus: %s",inputStatus.Initialized?"initialized":"not initialized",inputStatus.Focused?"game":"other window");
            ImGui::Text("Graphics API: %d | Upscaler: %s",(int)ctx.state.swapchainApi,ctx.currentFeature?ctx.currentFeature->ShortName().c_str():"not connected");
            ImGui::TextWrapped("For flicker or trails, compare one change at a time: image effects, Neural Rendering, then frame generation. Keep the setting that avoids the artifact and export diagnostics. With NR on, the NR page's \"Seeing flicker or trails?\" lists settings on now that are known to flicker. No universal artifact fix has been confirmed.");
            RenderMainMenuGraphs(ctx);RenderLoggingSettings(ctx);
            if(ImGui::CollapsingHeader("Advanced compatibility")){RenderQuirksSettings(ctx);RenderAdvancedSettings(ctx);RenderUpscalerInputsSettings(ctx);RenderApiAndTextureSettings(ctx);}

