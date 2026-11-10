// OptiShade additions, GPL-3.0-or-later.
#pragma once
// Plain-language causes and fix steps for the in-game menu, so a player can act
// on a problem without sending diagnostics. Pure decisions over facts the
// caller reads from the runtime; nothing here touches the GPU or the game.
#include <string>
#include <vector>

namespace optishade::selfhelp {
struct Advice { std::string cause, tryThis; };

inline bool Has(const std::string& text, const char* part) { return text.find(part) != std::string::npos; }

// ---- Why NR is "waiting for supported frames" ----
struct NrFacts {
    bool memoryPaused = false;   // memory guard stopped NR (opt-in pause)
    bool headsetNrOff = false;   // VR session running and NR in the headset is off
    bool dx11Native = false;     // D3D11 game using its upscaler directly, not the D3D12 bridge
    std::string dx11Upscaler;
    bool upscalerActive = false; // the game has created a DLSS/FSR/XeSS feature
    bool taaRouteSeen = false;   // the TAA compatibility route reported within 2 s
    std::string taaStatus;       // its latest reason
    bool vulkan = false;         // Vulkan game (X-Plane 12)
    std::string vulkanStatus;
    bool ranEarlier = false;     // NR completed frames earlier this session
};

// The TAA route's reasons are written for the log; say what they mean to a player.
inline Advice TaaReason(const std::string& s) {
    if (Has(s, "depth and movement data") && Has(s, "Waiting"))
        return {"The game has not supplied depth and motion for this frame yet.",
                "Load into the scene. Menus and loading screens do not have the data NR needs."};
    if (Has(s, "not supported") || Has(s, "colour format"))
        return {"This game's picture, depth or motion format is not supported on the TAA route (" + s + ")",
                "Turn on DLSS (or another upscaler) in the game's graphics settings so NR can use the game's own inputs."};
    if (Has(s, "Repair OptiShade"))
        return {"OptiShade's files do not match each other (" + s + ")", "Close the game and run Repair in the OptiShade manager."};
    if (Has(s, "Restart the game"))
        return {"NR stopped after a graphics error (" + s + ")", "Restart the game. If it happens again, send diagnostics."};
    if (Has(s, "FG") || Has(s, "frame generation") || Has(s, "PresentStart") || Has(s, "native-FG"))
        return {"NR is waiting for the game's frame generation to hand it a frame (" + s + ")",
                "If this does not clear in a scene, temporarily turn off the game's frame generation, then send diagnostics."};
    if (Has(s, "standing aside"))
        return {"The game supplies its own upscaler inputs, so NR uses those instead of the TAA route.",
                "Load into the scene; NR starts on the upscaler's next frame."};
    return {s, "Load into the scene. If this message stays, send diagnostics."};
}

inline Advice NrWaiting(const NrFacts& f) {
    if (f.memoryPaused)
        return {"NR is paused because video memory is almost full.",
                "Lower texture quality or resolution, or turn off \"Pause NR when video memory is low\"."};
    if (f.headsetNrOff)
        return {"A VR headset session is running and NR is set to stay off in the headset.",
                "Turn on \"Use NR in the VR headset\" below."};
    if (f.dx11Native)
        return {"This DirectX 11 game is using " + (f.dx11Upscaler.empty() ? std::string("its upscaler") : f.dx11Upscaler) +
                    " directly; NR only runs on the D3D12 bridge.",
                "Press \"Use DLSS on the D3D12 bridge for NR\" below. The upscaler restarts once."};
    if (f.vulkan && !f.vulkanStatus.empty())
        return {"The Vulkan route has not accepted a frame yet (" + f.vulkanStatus + ")",
                "Load into a flight. If this stays, send diagnostics."};
    if (f.taaRouteSeen && !f.taaStatus.empty()) return TaaReason(f.taaStatus);
    if (f.ranEarlier)
        return {"NR ran earlier, but no new frames reached it in the last few seconds.",
                "This is normal in menus, loading screens and while the game is minimised. Go back to the scene."};
    if (!f.upscalerActive)
        return {"The game has not started DLSS, FSR or XeSS, so NR has no frames to work on.",
                "Choose DLSS (or another upscaler) in the game's graphics settings, then load into a scene. Many main menus do not use the upscaler."};
    return {"The upscaler is running but has not sent NR a frame yet.",
            "Load into the scene. If this stays for more than a minute, run Check my setup in the OptiShade Troubleshooter."};
}

// ---- Why OptiMFG is "installed but not connected" ----
struct MfgFacts {
    bool autoStartGame = true;   // OptiMFG starts itself only with MSFS
    bool startDisabled = false;  // start-with-game.disabled present
    bool startAttempted = false; // the game tried to start OptiMFG_Live.exe
    unsigned long startError = 0;// Windows error from that start, 0 if it started
    bool channelOpen = false;    // OptiMFG's shared status exists for this game
    bool heartbeatFresh = false; // and it updated recently
};
constexpr unsigned long kErrorFileNotFound = 2, kErrorPathNotFound = 3, kErrorAccessDenied = 5,
    kErrorVirusInfected = 225, kErrorVirusDeleted = 226, kErrorElevationRequired = 740;
inline const char* AntivirusSteps() {
    return "Open Windows Security > Virus & threat protection > Protection history. Restore any OptiShade or OptiMFG item, "
           "add the game's OptiShadeData folder as an exclusion, then run Repair on OptiMFG in the manager.";
}
inline Advice MfgNotConnected(const MfgFacts& f) {
    const unsigned long e = f.startError;
    if (e == kErrorVirusInfected || e == kErrorVirusDeleted)
        return {"Windows Security blocked OptiMFG_Live.exe when the game tried to start it.", AntivirusSteps()};
    if (e == kErrorFileNotFound || e == kErrorPathNotFound)
        return {"OptiMFG_Live.exe was missing when the game tried to start it. Antivirus removing it is the usual cause.", AntivirusSteps()};
    if (e == kErrorAccessDenied)
        return {"Windows refused to start OptiMFG_Live.exe (access denied). Antivirus or folder permissions are blocking it.", AntivirusSteps()};
    if (e == kErrorElevationRequired)
        return {"Windows asked for administrator rights to start OptiMFG, so it did not start.",
                "Do not set the game or OptiMFG to run as administrator. Start OptiMFG from its component card in the manager."};
    if (e != 0)
        return {"Windows could not start OptiMFG (error " + std::to_string(e) + ").",
                "Run Repair on OptiMFG in the manager. If it keeps happening, send diagnostics."};
    if (f.channelOpen && !f.heartbeatFresh)
        return {"OptiMFG was linked to this game but stopped responding.",
                "Close the game, exit OptiMFG from the system tray, then start the game again."};
    if (f.channelOpen)
        return {"OptiMFG is running but has not linked to the game's frame generation yet.",
                "Turn on DLSS Frame Generation in the game's graphics settings and load into a flight."};
    if (!f.autoStartGame)
        return {"OptiMFG starts by itself only with Microsoft Flight Simulator.",
                "Start it from its component card in the manager before you start this game."};
    if (f.startDisabled)
        return {"\"Start with game\" is turned off for OptiMFG.",
                "Turn it back on in the manager, or press Start on OptiMFG's component card."};
    if (!f.startAttempted)
        return {"OptiMFG starts once the game draws its first frame.", "Wait for the game's main menu."};
    return {"OptiMFG was started but is not running now; it closed or was blocked.",
            std::string("Check for blocks first: ") + AntivirusSteps() + " Check my setup in the Troubleshooter also lists blocked files."};
}

// ---- What could be causing flicker right now ----
struct FlickerFacts {
    bool nrOn = false;
    bool estimatedMotion = false;  // TAA/Vulkan compatibility route: motion is estimated from the picture
    bool beforeFrameGeneration = false; // pre-FG TAA route: NR feeds the game's frame generation
    bool deferredDlss = false;     // Generate before SR, apply after SR (experimental)
    bool hdrReplace = false;       // HDR mapping "... + replace"
    bool residualExperimental = false; // residual across RR / residual FG
    bool memoryLow = false;
    bool nrStopping = false;       // NR enabled but not completing frames now
};
inline std::vector<Advice> FlickerSuspects(const FlickerFacts& f) {
    std::vector<Advice> out;
    if (!f.nrOn) return out;
    if (f.nrStopping)
        out.push_back({"NR is switched on but is not finishing frames right now, so the picture can switch between NR and no NR.",
                       "Read the NR status above for the reason."});
    if (f.memoryLow)
        out.push_back({"Video memory is nearly full, so NR may stop and restart.", "Lower texture quality or resolution."});
    if (f.deferredDlss)
        out.push_back({"\"Generate before SR, apply after SR\" is on. It is experimental and may flicker.", "Turn it off in NR's experimental settings."});
    if (f.hdrReplace)
        out.push_back({"HDR mapping is set to a \"replace\" mode, which bypasses the strength controls and may flicker.", "Set HDR mapping to a \"composed\" mode or Off."});
    if (f.residualExperimental)
        out.push_back({"An experimental residual option (across Ray Reconstruction or frame generation) is on.", "Turn it off and compare."});
    if (f.beforeFrameGeneration)
        out.push_back({"NR runs before the game's frame generation.", "If the flicker appears only with frame generation on, temporarily turn off the game's frame generation."});
    if (f.estimatedMotion)
        out.push_back({"This game gives NR no motion vectors, so NR estimates motion from the picture. Fast movement can shimmer.",
                       "Turn on DLSS (or another upscaler) in the game, if it has one, so NR can use the game's motion."});
    return out;
}
} // namespace optishade::selfhelp
