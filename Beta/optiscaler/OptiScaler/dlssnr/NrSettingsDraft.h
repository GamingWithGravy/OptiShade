// OptiShade additions, GPL-3.0-or-later. UI draft, not a runtime/config owner.
#pragma once
struct SettingsDraft {
    Config* live;
    std::unique_ptr<Config> shadow;
    optishade::editing::Review review;
    template<class T> void Bind(const char* label,T Config::* member){
        review.Bind(label,shadow.get()->*member,[this,member]{return live->*member;},[this,member](const T& value){live->*member=value;});
    }
    explicit SettingsDraft(Config* config):live(config),shadow(std::make_unique<Config>(*config)){
        Bind("Run Before Sr", &Config::DlssNrRunBeforeSr);
        Bind("Finished Picture", &Config::DlssNrFinishedPicture);
        Bind("Source policy schema", &Config::DlssNrSourceSchema);
        Bind("Source policy", &Config::DlssNrSourcePolicy);
        Bind("Deferred Dlss", &Config::DlssNrDeferredDlss);
        Bind("Residual Across Rr", &Config::DlssNrResidualAcrossRr);
        Bind("Residual Across Rr Blend", &Config::DlssNrResidualAcrossRrBlend);
        Bind("Residual Fg", &Config::DlssNrResidualFg);
        Bind("Precision", &Config::DlssNrPrecision);
        Bind("Residual Fg Approx Camera", &Config::DlssNrResidualFgApproxCamera);
        Bind("Toggle Key", &Config::DlssNrToggleKey);
        Bind("Preset", &Config::DlssNrPreset);
        Bind("Intensity", &Config::DlssNrIntensity);
        Bind("Style", &Config::DlssNrStyle);
        Bind("Pass2 Preset", &Config::DlssNrPass2Preset);
        Bind("Pass2 Style", &Config::DlssNrPass2Style);
        Bind("Pass3 Preset", &Config::DlssNrPass3Preset);
        Bind("Pass3 Style", &Config::DlssNrPass3Style);
        Bind("Local Structure", &Config::DlssNrLocalStructure);
        Bind("Local Tone", &Config::DlssNrLocalTone);
        Bind("Skin Structure", &Config::DlssNrSkinStructure);
        Bind("Auto Mask", &Config::DlssNrAutoMask);
        Bind("Skin Protection", &Config::DlssNrSkinProtection);
        Bind("Skin Tone Enabled", &Config::DlssNrSkinToneEnabled);
        Bind("Skin Detail", &Config::DlssNrSkinDetail);
        Bind("Skin Colour", &Config::DlssNrSkinColour);
        Bind("Environment Detail", &Config::DlssNrEnvironmentDetail);
        Bind("Environment Colour", &Config::DlssNrEnvironmentColour);
        Bind("Show Skin Mask", &Config::DlssNrShowSkinMask);
        Bind("Pass2 Intensity", &Config::DlssNrPass2Intensity);
        Bind("Pass2 Local Structure", &Config::DlssNrPass2LocalStructure);
        Bind("Pass2 Local Tone", &Config::DlssNrPass2LocalTone);
        Bind("Pass2 Skin Structure", &Config::DlssNrPass2SkinStructure);
        Bind("Pass2 Auto Mask", &Config::DlssNrPass2AutoMask);
        Bind("Pass3 Intensity", &Config::DlssNrPass3Intensity);
        Bind("Pass3 Local Structure", &Config::DlssNrPass3LocalStructure);
        Bind("Pass3 Local Tone", &Config::DlssNrPass3LocalTone);
        Bind("Pass3 Skin Structure", &Config::DlssNrPass3SkinStructure);
        Bind("Pass3 Auto Mask", &Config::DlssNrPass3AutoMask);
        Bind("Unlock Passes", &Config::DlssNrUnlockPasses);
        Bind("Transfer Strength", &Config::DlssNrTransferStrength);
        Bind("Colour Strength", &Config::DlssNrColourStrength);
        Bind("Reversible Mode", &Config::DlssNrReversibleMode);
        Bind("Apply Model", &Config::DlssNrApplyModel);
        Bind("Pause On Low Memory", &Config::DlssNrPauseOnLowMemory);
        Bind("NR In VR Headset", &Config::DlssNrInVrHeadset);
        Bind("VR Working Scale", &Config::DlssNrVrWorkingScale);
        Bind("VR Foveated", &Config::DlssNrVrFoveated);
        Bind("VR Fovea Size", &Config::DlssNrVrFoveaSize);
        Bind("VR Fovea Feather", &Config::DlssNrVrFoveaFeather);
        Bind("Hold Frame", &Config::DlssNrHoldFrame);
        Bind("Max Ratio", &Config::DlssNrMaxRatio);
        Bind("Transfer", &Config::DlssNrTransfer);
        Bind("White Point From Exposure", &Config::DlssNrWhitePointFromExposure);
        Bind("Probe D3 D11", &Config::DlssNrProbeD3D11);
        Bind("Debug View", &Config::DlssNrDebugView);
        Bind("Compare", &Config::DlssNrCompare);
        Bind("Compare Split", &Config::DlssNrCompareSplit);
        Bind("Compare Zoom", &Config::DlssNrCompareZoom);
        Bind("Compare Swap", &Config::DlssNrCompareSwap);
        Bind("Compare Tags", &Config::DlssNrCompareTags);
        Bind("Tag Scale", &Config::DlssNrTagScale);
        Bind("Working Scale", &Config::DlssNrWorkingScale);
        Bind("Scaling Downscaler", &Config::DlssNrScalingDownscaler);
        Bind("Proxy Probe", &Config::DlssNrProxyProbe);
        Bind("Use Proxy", &Config::DlssNrUseProxy);
        Bind("Scan Exposure", &Config::DlssNrScanExposure);
        Bind("White Point Source", &Config::DlssNrWhitePointSource);
        Bind("Scan Meter", &Config::DlssNrScanMeter);
        Bind("Scan Anchor Value", &Config::DlssNrScanAnchorValue);
        Bind("Scan Anchor White Point", &Config::DlssNrScanAnchorWhitePoint);
        Bind("Scan Anchors", &Config::DlssNrScanAnchors);
        Bind("Scan Inverted", &Config::DlssNrScanInverted);
        Bind("White Point Trim", &Config::DlssNrWhitePointTrim);
        Bind("Scan Trim", &Config::DlssNrScanTrim);
        Bind("Passes", &Config::DlssNrPasses);
        Bind("Auto Capture", &Config::DlssNrAutoCapture);
        Bind("White Point Scale", &Config::DlssNrWhitePointScale);
        for(unsigned i=0;i<27;++i){
            auto& d=shadow->DlssNrExtraPasses[i];auto& actual=live->DlssNrExtraPasses[i];
            const auto prefix="Pass "+std::to_string(i+4)+" ";
            review.Bind(prefix+"style",d.style,[&actual]{return actual.style;},[&actual](const auto& value){actual.style=value;});
            review.Bind(prefix+"intensity",d.intensity,[&actual]{return actual.intensity;},[&actual](const auto& value){actual.intensity=value;});
            review.Bind(prefix+"structure",d.structure,[&actual]{return actual.structure;},[&actual](const auto& value){actual.structure=value;});
            review.Bind(prefix+"tone",d.tone,[&actual]{return actual.tone;},[&actual](const auto& value){actual.tone=value;});
            review.Bind(prefix+"skin",d.skin,[&actual]{return actual.skin;},[&actual](const auto& value){actual.skin=value;});
            review.Bind(prefix+"autoMask",d.autoMask,[&actual]{return actual.autoMask;},[&actual](const auto& value){actual.autoMask=value;});

        }
    }
};
inline SettingsDraft& MenuDraft(){static SettingsDraft state(Config::Instance());state.review.Sync();return state;}
