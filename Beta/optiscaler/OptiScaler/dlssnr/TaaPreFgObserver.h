// OptiShade additions, GPL-3.0-or-later.
#pragma once
// TAA NR before frame generation where OptiScaler does not own DLSS-G.
//
// The pre-FG TAA route (DlssNr_TaaNativeFg.inl) denoises the game's tagged
// HUD-less colour at PresentStart and hands DLSS-G the result, so generated
// frames are built from denoised real frames. It needs pass-through observers
// on slSetTag/slSetTagForFrame/slSetConstants/slGetNewFrameToken and an
// accepted-FG signature. Beta builds have always installed the observers for
// MSFS; stable builds install them automatically when the game's adapter
// exposes the external-FG observation contract. No UI opt-in or OptiMFG
// controller is required. The observer does not take over DLSS-G: native
// DLSS inputs continue on the DLSS route, while the validated TAA contract
// is used only for TAA input.
#include <cstdint>
#include <string_view>

namespace optishade::taa {

inline bool MsfsExecutable(std::wstring_view name) {
    const auto equal = [&](std::wstring_view expected) {
        if (name.size() != expected.size()) return false;
        for (size_t i = 0; i < name.size(); ++i) {
            auto c = name[i];
            if (c >= L'A' && c <= L'Z') c += L'a' - L'A';
            if (c != expected[i]) return false;
        }
        return true;
    };
    return equal(L"flightsimulator.exe") || equal(L"flightsimulator2024.exe");
}

// betaObserver: the existing beta-build MSFS observer. Stable MSFS builds
// install this pass-through observer automatically whenever the game's route
// contract supports observing external frame generation. It never takes over
// DLSS or decides the active AA mode; validated native DLSS inputs keep the
// TAA compatibility route out of the way.
inline bool PreFgObserver(bool betaObserver, bool msfs, bool routeObserver) {
    return betaObserver || (msfs && routeObserver);
}

// Same layout as a published SetOptions signature: mode in the high word,
// frames to generate in the low word. sl::DLSSGMode::eOn is 1.
inline constexpr uint64_t kDlssgModeOn = 1;
inline uint64_t StatusSignature(bool generating, uint32_t multiplier) {
    return generating && multiplier >= 2 ? (kDlssgModeOn << 32) | (multiplier - 1) : 0;
}

}
