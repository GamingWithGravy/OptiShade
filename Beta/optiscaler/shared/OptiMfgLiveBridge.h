#pragma once

#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include <cstdint>
#include <iterator>
#include <string>
#include "OptiMfgControllerProtocol.h"
#include "OptiMfgComponent.h"

namespace optishade::optimfg {
class LiveBridge {
public:
    LiveBridge() = default;
    ~LiveBridge() { Close(); }
    LiveBridge(LiveBridge const&) = delete;
    LiveBridge& operator=(LiveBridge const&) = delete;

    bool Installed() const {return ComponentInstalled();}

    bool Open() {
        mapped_=channel_.Open(GetCurrentProcessId());
        valid_=mapped_&&channel_.Snapshot(snapshot_);
        return valid_;
    }
    // OptiMFG created this game's status channel; with !Fresh() it stopped updating it.
    bool Mapped() const { return mapped_; }
    bool Fresh() const { return valid_; }
    bool Ready() const { return valid_&&omfg::controller::Fresh(snapshot_,GetCurrentProcessId())&&snapshot_.connected; }
    LONG Status() const { return Ready()?snapshot_.status:-1; }
    LONG RequestValue() const { return snapshot_.activeRequest; }
    LONG AppliedSequence() const { return snapshot_.appliedSequence; }
    LONG CommandSequence() const { return snapshot_.commandSequence; }
    LONG MaximumGenerated() const { return Ready()?snapshot_.maximumGenerated:-1; }
    LONG StateCalls() const { return Ready()?snapshot_.stateCalls:0; }
    LONG EffectiveCount() const { return snapshot_.effectiveCount; }
    LONG LastResult() const { return snapshot_.lastResult; }
    bool Rejected() const {return snapshot_.receivedSequence==snapshot_.commandSequence&&snapshot_.commandResult<0;}
    bool Request(LONG value) { return Ready()&&channel_.Request(value); }
private:
    void Close(){channel_.Close();valid_=mapped_=false;}
    omfg::controller::Channel channel_;
    omfg::controller::State snapshot_;
    bool valid_{},mapped_{};
};

inline const char* StatusText(LONG value) {
    switch (value) {
    case 0: return "Observing game-controlled MFG";
    case 1: return "Waiting for the game's next frame-generation settings call";
    case 2: return "Waiting for live game capability state";
    case 3: return "The game currently has frame generation disabled";
    case 4: return "The selected multiplier exceeds the runtime's reported maximum";
    case 5: return "The game accepted the request; generated output still needs verification";
    case 6: return "The game rejected the request";
    case 7: return "Unsupported provider settings ABI; request passed through unchanged";
    case 8: return "Multiple game viewports detected; controls are paused for safety";
    case 9: return "Controller heartbeat expired; game control restored";
    case 10: return "OptiMFG helper initialization failed";
    case 300: return "NVIDIA profile forces frame generation Off. Close the game and select Application controlled in OptiMFG, then restart.";
    case 301: return "Settings accepted, but recent backend FPS telemetry shows little or no output uplift. Check limits and export all three diagnostic log types; displayed output still needs verification.";
    case 201: return "Backend waiting for an active frame-generation wrapper";
    case 202: return "Backend has not patched the active wrapper";
    case 203: return "Backend has not hooked the active settings entry";
    case 204: return "Backend has not hooked the active state entry";
    case 205: return "Backend settings structure is unsupported";
    case 206: return "Backend state structure is unsupported";
    case 207: return "Backend rejected an invalid structure chain";
    case 208: return "Backend waiting for a provider selected by frame-generation creation";
    case 209: return "Backend provider changed; restart the game";
    case 210: return "Backend cannot cover the active provider Create function";
    case 211: return "Backend cannot cover the active provider Evaluate function";
    case 212: return "Backend has not verified the rendering adapter";
    case 213: return "Backend interpolation was not ready when frame generation was created";
    case 214: return "Backend wrapper changed; restart the game";
    default: return "Waiting for OptiMFG controller";
    }
}
}
