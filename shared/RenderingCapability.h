#pragma once
namespace optishade {
// Unknown is deliberate: absence of evidence must not be advertised as support.
enum class Evidence { Unknown, No, Yes };
enum class BackendStage { WaitingForInput, Unsupported, Unavailable, Detected, Loaded, Initialized, Active, Failed };
struct BackendEvidence {
    Evidence hardware = Evidence::Unknown;
    Evidence installed = Evidence::Unknown;
    Evidence loaded = Evidence::Unknown;
    Evidence gameInput = Evidence::Unknown;
    Evidence initialized = Evidence::Unknown;
    Evidence active = Evidence::Unknown;
    bool failed = false;
    bool experimental = false;
    bool fallback = false;
    const char* reason = "";
};
inline BackendStage ResolveBackendStage(const BackendEvidence& e) {
    if (e.failed) return BackendStage::Failed;
    if (e.hardware == Evidence::No) return BackendStage::Unsupported;
    if (e.installed == Evidence::No || e.loaded == Evidence::No) return BackendStage::Unavailable;
    if (e.gameInput != Evidence::Yes) return BackendStage::WaitingForInput;
    if (e.initialized == Evidence::Yes && e.active == Evidence::Yes) return BackendStage::Active;
    if (e.initialized == Evidence::Yes) return BackendStage::Initialized;
    if (e.loaded == Evidence::Yes) return BackendStage::Loaded;
    return BackendStage::Detected;
}
inline const char* BackendStageLabel(BackendStage stage) {
    switch (stage) {
    case BackendStage::WaitingForInput: return "Waiting for game upscaling input";
    case BackendStage::Unsupported: return "Unsupported on this rendering device";
    case BackendStage::Unavailable: return "Runtime unavailable";
    case BackendStage::Detected: return "Detected, not initialized";
    case BackendStage::Loaded: return "Runtime loaded, not initialized";
    case BackendStage::Initialized: return "Initialized, no recent upscaling frames";
    case BackendStage::Active: return "Active";
    case BackendStage::Failed: return "Initialization or rendering failed";
    }
    return "Unknown";
}
}
