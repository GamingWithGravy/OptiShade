#pragma once
#include <Config.h>
#include <cstring>
#include <type_traits>
#include "../../../shared/NrObservation.h"
namespace DlssNr {
inline void ObserveRequest(const Config& cfg) {
    uint64_t key=1469598103934665603ULL;
    auto add=[&]<typename T>(const T& value){
        auto mix=[&](uint64_t n){key^=n;key*=1099511628211ULL;};
        if constexpr(std::is_same_v<T,std::string>){mix(value.size());for(unsigned char c:value)mix(c);}
        else if constexpr(std::is_floating_point_v<T>){uint64_t bits=0;std::memcpy(&bits,&value,sizeof(value));mix(bits);}
        else mix(static_cast<uint64_t>(value));
    };
    add(cfg.DlssNrEnabled.value_or_default());
    add(cfg.DlssNrRunBeforeSr.value_or_default());
    add(cfg.DlssNrFinishedPicture.value_or_default());
    add(cfg.DlssNrTaaFallback.value_or_default());
    add(cfg.DlssNrDeferredDlss.value_or_default());
    add(cfg.DlssNrResidualAcrossRr.value_or_default());
    add(cfg.DlssNrResidualAcrossRrBlend.value_or_default());
    add(cfg.DlssNrResidualFg.value_or_default());
    add(cfg.DlssNrPrecision.value_or_default());
    add(cfg.DlssNrResidualFgApproxCamera.value_or_default());
    add(cfg.DlssNrToggleKey.value_or_default());
    add(cfg.DlssNrPreset.value_or_default());
    add(cfg.DlssNrIntensity.value_or_default());
    add(cfg.DlssNrStyle.value_or_default());
    add(cfg.DlssNrPass2Preset.has_value());if(cfg.DlssNrPass2Preset.has_value()) add(cfg.DlssNrPass2Preset.value());
    add(cfg.DlssNrPass2Style.has_value());if(cfg.DlssNrPass2Style.has_value()) add(cfg.DlssNrPass2Style.value());
    add(cfg.DlssNrPass3Preset.has_value());if(cfg.DlssNrPass3Preset.has_value()) add(cfg.DlssNrPass3Preset.value());
    add(cfg.DlssNrPass3Style.has_value());if(cfg.DlssNrPass3Style.has_value()) add(cfg.DlssNrPass3Style.value());
    add(cfg.DlssNrLocalStructure.value_or_default());
    add(cfg.DlssNrLocalTone.value_or_default());
    add(cfg.DlssNrSkinStructure.value_or_default());
    add(cfg.DlssNrAutoMask.value_or_default());
    add(cfg.DlssNrSkinProtection.value_or_default());
    add(cfg.DlssNrSkinToneEnabled.value_or_default());
    add(cfg.DlssNrSkinDetail.value_or_default());
    add(cfg.DlssNrSkinColour.value_or_default());
    add(cfg.DlssNrEnvironmentDetail.value_or_default());
    add(cfg.DlssNrEnvironmentColour.value_or_default());
    add(cfg.DlssNrShowSkinMask.value_or_default());
    add(cfg.DlssNrPass2Intensity.has_value());if(cfg.DlssNrPass2Intensity.has_value()) add(cfg.DlssNrPass2Intensity.value());
    add(cfg.DlssNrPass2LocalStructure.has_value());if(cfg.DlssNrPass2LocalStructure.has_value()) add(cfg.DlssNrPass2LocalStructure.value());
    add(cfg.DlssNrPass2LocalTone.has_value());if(cfg.DlssNrPass2LocalTone.has_value()) add(cfg.DlssNrPass2LocalTone.value());
    add(cfg.DlssNrPass2SkinStructure.has_value());if(cfg.DlssNrPass2SkinStructure.has_value()) add(cfg.DlssNrPass2SkinStructure.value());
    add(cfg.DlssNrPass2AutoMask.has_value());if(cfg.DlssNrPass2AutoMask.has_value()) add(cfg.DlssNrPass2AutoMask.value());
    add(cfg.DlssNrPass3Intensity.has_value());if(cfg.DlssNrPass3Intensity.has_value()) add(cfg.DlssNrPass3Intensity.value());
    add(cfg.DlssNrPass3LocalStructure.has_value());if(cfg.DlssNrPass3LocalStructure.has_value()) add(cfg.DlssNrPass3LocalStructure.value());
    add(cfg.DlssNrPass3LocalTone.has_value());if(cfg.DlssNrPass3LocalTone.has_value()) add(cfg.DlssNrPass3LocalTone.value());
    add(cfg.DlssNrPass3SkinStructure.has_value());if(cfg.DlssNrPass3SkinStructure.has_value()) add(cfg.DlssNrPass3SkinStructure.value());
    add(cfg.DlssNrPass3AutoMask.has_value());if(cfg.DlssNrPass3AutoMask.has_value()) add(cfg.DlssNrPass3AutoMask.value());
    add(cfg.DlssNrUnlockPasses.value_or_default());
    add(cfg.DlssNrTransferStrength.value_or_default());
    add(cfg.DlssNrColourStrength.value_or_default());
    add(cfg.DlssNrReversibleMode.value_or_default());
    add(cfg.DlssNrApplyModel.value_or_default());
    add(cfg.DlssNrHoldFrame.value_or_default());
    add(cfg.DlssNrMaxRatio.value_or_default());
    add(cfg.DlssNrTransfer.value_or_default());
    add(cfg.DlssNrWhitePointFromExposure.value_or_default());
    add(cfg.DlssNrProbeD3D11.value_or_default());
    add(cfg.DlssNrDebugView.value_or_default());
    add(cfg.DlssNrCompare.value_or_default());
    add(cfg.DlssNrCompareSplit.value_or_default());
    add(cfg.DlssNrCompareZoom.value_or_default());
    add(cfg.DlssNrCompareSwap.value_or_default());
    add(cfg.DlssNrCompareTags.value_or_default());
    add(cfg.DlssNrTagScale.value_or_default());
    add(cfg.DlssNrWorkingScale.value_or_default());
    add(cfg.DlssNrScalingDownscaler.value_or_default());
    add(cfg.DlssNrProxyProbe.value_or_default());
    add(cfg.DlssNrUseProxy.value_or_default());
    add(cfg.DlssNrScanExposure.value_or_default());
    add(cfg.DlssNrWhitePointSource.value_or_default());
    add(cfg.DlssNrScanMeter.value_or_default());
    add(cfg.DlssNrScanAnchorValue.value_or_default());
    add(cfg.DlssNrScanAnchorWhitePoint.value_or_default());
    add(cfg.DlssNrScanAnchors.value_or_default());
    add(cfg.DlssNrScanInverted.value_or_default());
    add(cfg.DlssNrWhitePointTrim.value_or_default());
    add(cfg.DlssNrScanTrim.value_or_default());
    add(cfg.DlssNrPasses.value_or_default());
    add(cfg.DlssNrAutoCapture.value_or_default());
    add(cfg.DlssNrWhitePointScale.value_or_default());
    optishade::nr_observation::State().Request(cfg.DlssNrEnabled.value_or_default(),cfg.DlssNrApplyModel.value_or_default(),key);
}
optishade::nr_observation::Snapshot Observation();
}
