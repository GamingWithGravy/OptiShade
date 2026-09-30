// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include <json.hpp>
#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <stdexcept>

namespace optishade::mfg {
// Update only alongside the verified, licensed OptionalMFG payload.
inline constexpr char kExpectedDllSha256[] = "e9ca3587854eeb723e0579f7ddf6cfb1e6cf4bed79b0d75bc716003ed98fe040";
using Json = nlohmann::json;
struct Settings {
    bool followGame = true, dynamic = false;
    uint32_t multiplier = 2, targetFps = 0, preset = 2, vsyncMode = 0, reflexLimit = 0;
};
struct Live {
    uint32_t gpuFamily = 0, maxMultiplier = 2, minMultiplier = 2;
    bool bridgeReady = false, gameFgOn = false, appliedFgOn = false;
    bool canDynamic = false, canReflex = false, presetFrozen = false, presetRestart = false;
    bool applied = false, pending = false, setOptionsAccepted = false;
    bool appliedFollowGame = false, appliedDynamic = false, savedRequestObserved = false;
    bool presetObservedValid = false, legacyPreset = false;
    uint32_t appliedMultiplier = 0, presetLatched = 0, presetObserved = 0, actualFramesPresented = 0;
    uint64_t requestRevision = 0, appliedRevision = 0, fpsAgeMs = 0;
    uint32_t realFpsMilli = 0, outputFpsMilli = 0;
};
struct Snapshot {
    bool detected = false, verified = false, owned = false, live = false, editable = false;
    Settings settings;
    Live status;
    std::string message;
    std::string identity;
};
inline bool Parse(const std::string& text, size_t limit, Json& out) {
    if (text.empty() || text.size() > limit) return false;
    bool valid = true;
    std::map<int, std::set<std::string>> keys;
    auto callback = [&](int depth, Json::parse_event_t event, Json& value) {
        if (depth > 32) throw std::runtime_error("MFG JSON nesting limit");
        if (event == Json::parse_event_t::object_start) keys[depth + 1].clear();
        if (event == Json::parse_event_t::key && !keys[depth].insert(value.get<std::string>()).second)
            valid = false; // Upstream reads first occurrences; never accept ambiguous duplicates.
        if (event == Json::parse_event_t::object_end) keys.erase(depth + 1);
        return true;
    };
    try { auto parsed = Json::parse(text, callback, false); if (!valid || !parsed.is_object()) return false; out = std::move(parsed); return true; }
    catch (...) { return false; }
}
inline bool U64(const Json& j, const char* key, uint64_t& value, uint64_t low, uint64_t high, bool required = true) {
    auto it = j.find(key); if (it == j.end()) return !required;
    if (!it->is_number_integer() || (it->is_number_integer() && !it->is_number_unsigned() && it->get<int64_t>() < 0)) return false;
    const auto v = it->get<uint64_t>(); if (v < low || v > high) return false; value = v; return true;
}
inline bool U32(const Json& j, const char* key, uint32_t& value, uint32_t low, uint32_t high, bool required = true) {
    uint64_t v = value; if (!U64(j, key, v, low, high, required)) return false; value = static_cast<uint32_t>(v); return true;
}
inline bool Bool(const Json& j, const char* key, bool& value, bool required = true) {
    auto it = j.find(key); if (it == j.end()) return !required; if (!it->is_boolean()) return false; value = it->get<bool>(); return true;
}
inline bool String(const Json& j, const char* key, std::string& value) {
    auto it = j.find(key); if (it == j.end() || !it->is_string()) return false; value = it->get<std::string>(); return true;
}
inline bool ReadSettings(const Json& j, Settings& value) {
    Settings s; s.followGame = false; // Missing legacy key means an explicit override.
    if (!Bool(j, "followGame", s.followGame, false) || !U32(j, "multiplier", s.multiplier, 1, 6) ||
        !U32(j, "dynamicTargetFrameRate", s.targetFps, 0, 1000, false) ||
        !U32(j, "dlssgPreset", s.preset, 0, 2, false) || !U32(j, "vsyncMode", s.vsyncMode, 0, 2, false) ||
        !U32(j, "reflexFrameLimitFps", s.reflexLimit, 0, 1000, false)) return false;
    std::string mode = "fixed";
    if (j.contains("mode") && !String(j, "mode", mode)) return false;
    if (mode != "fixed" && mode != "dynamic" && !(mode == "follow" && s.followGame)) return false;
    s.dynamic = !s.followGame && mode == "dynamic";
    bool ignored = false;
    for (auto name : {"generatedOnlyDebug", "intervalLogging", "dynamicExperimental56", "selectiveOtaDlssgWrapper"})
        if (!Bool(j, name, ignored, false)) return false;
    value = s; return true;
}
inline bool SameRequest(const Settings& a, const Settings& b) {
    return a.followGame == b.followGame && a.dynamic == b.dynamic && a.multiplier == b.multiplier &&
        a.targetFps == b.targetFps && a.preset == b.preset && a.vsyncMode == b.vsyncMode && a.reflexLimit == b.reflexLimit;
}
inline bool ReadDesired(const Json& status, Settings& value, Json* seed = nullptr) {
    Settings desired; std::string mode;
    bool generatedOnly = false, intervalLogging = false, experimental = false;
    if (!Bool(status,"followGame",desired.followGame) || !String(status,"mode",mode) ||
        !U32(status,"multiplier",desired.multiplier,1,6) ||
        !U32(status,"dynamicTargetFrameRate",desired.targetFps,0,1000) ||
        !U32(status,"dlssgPresetRequested",desired.preset,0,2) ||
        !U32(status,"vsyncMode",desired.vsyncMode,0,2) ||
        !U32(status,"reflexFrameLimitFps",desired.reflexLimit,0,1000) ||
        !Bool(status,"generatedOnlyDebug",generatedOnly) ||
        !Bool(status,"intervalLoggingEnabled",intervalLogging) ||
        !Bool(status,"dynamicExperimental56",experimental)) return false;
    if (mode != "fixed" && mode != "dynamic" && !(mode == "follow" && desired.followGame)) return false;
    desired.dynamic = !desired.followGame && mode == "dynamic";
    if (seed) *seed = Json{{"followGame",desired.followGame},{"mode",mode},{"multiplier",desired.multiplier},
        {"dynamicTargetFrameRate",desired.targetFps},{"dlssgPreset",desired.preset},{"vsyncMode",desired.vsyncMode},
        {"reflexFrameLimitFps",desired.reflexLimit},{"generatedOnlyDebug",generatedOnly},
        {"intervalLogging",intervalLogging},{"dynamicExperimental56",experimental},{"version",13}};
    value = desired; return true;
}
inline bool ReadLive(const Json& j, uint32_t pid, uint64_t birth, uint64_t now, const Settings& saved, Live& value) {
    uint32_t version = 0, statusPid = 0; uint64_t statusBirth = 0, heartbeat = 0;
    std::string product;
    if (!String(j,"product",product) || product != "RTXMFG" || !U32(j,"version",version,40,40) ||
        !U32(j,"pid",statusPid,pid,pid) || !birth || !U64(j,"processBirth",statusBirth,birth,birth) ||
        !U64(j,"heartbeat",heartbeat,0,now) || now-heartbeat > 5) return false;
    Live s; bool observed = false, dynamicKnown = false, dynamicSupported = false;
    uint32_t maxGenerated = 0;
    if (!U32(j,"gpuFamily",s.gpuFamily,1,2) || !U32(j,"safeMaximumMultiplier",s.maxMultiplier,2,6) ||
        !Bool(j,"bridgeReady",s.bridgeReady) || !Bool(j,"gameFrameGenerationOn",s.gameFgOn) ||
        !Bool(j,"appliedFrameGenerationOn",s.appliedFgOn) || !Bool(j,"activeWrapperObserved",observed) ||
        !Bool(j,"dynamicMfgSupportKnown",dynamicKnown) || !Bool(j,"dynamicMfgSupported",dynamicSupported) ||
        !U32(j,"numFramesToGenerateMax",maxGenerated,0,UINT32_MAX) ||
        !Bool(j,"applied",s.applied) || !Bool(j,"pending",s.pending) ||
        !Bool(j,"setOptionsAccepted",s.setOptionsAccepted) ||
        !U64(j,"requestRevision",s.requestRevision,0,UINT64_MAX) || !U64(j,"appliedRevision",s.appliedRevision,0,UINT64_MAX) ||
        !U32(j,"appliedMultiplier",s.appliedMultiplier,0,6)) return false;
    s.minMultiplier = s.gpuFamily == 2 ? 1 : 2;
    s.canDynamic = s.bridgeReady && dynamicKnown && dynamicSupported && maxGenerated > 0 &&
        maxGenerated < s.maxMultiplier && (s.gpuFamily != 2 || s.maxMultiplier == 6);
    std::string appliedMode;
    if (!String(j,"appliedMode",appliedMode) || (appliedMode != "follow" && appliedMode != "fixed" && appliedMode != "dynamic")) return false;
    s.appliedFollowGame = appliedMode == "follow"; s.appliedDynamic = appliedMode == "dynamic";
    if (!Bool(j,"reflexControlAvailable",s.canReflex) || !Bool(j,"dlssgPresetSelectionFrozen",s.presetFrozen) ||
        !Bool(j,"dlssgPresetRestartRequired",s.presetRestart) || !U32(j,"dlssgPresetLatched",s.presetLatched,0,2) ||
        !Bool(j,"dlssgPresetObservedValid",s.presetObservedValid) || !U32(j,"dlssgPresetObserved",s.presetObserved,0,2) ||
        !Bool(j,"ampereLegacySinglePreset",s.legacyPreset,s.gpuFamily == 2)) return false;
    // Desired state is independently compared to the saved request, since a fresh
    // heartbeat may still acknowledge the previous selection after an atomic save.
    Settings accepted;
    if (!ReadDesired(j,accepted)) return false;
    s.savedRequestObserved = SameRequest(saved, accepted);
    s.canReflex = s.canReflex && !saved.dynamic && !accepted.dynamic && !s.appliedDynamic;
    // Telemetry is optional. Invalid/missing/stale evidence remains unavailable.
    uint32_t frames = 0, real = 0, output = 0; uint64_t age = 0;
    if (U32(j,"actualFramesPresented",frames,0,UINT32_MAX) && U64(j,"fpsSampleAgeMs",age,0,UINT64_MAX) &&
        U32(j,"realFpsMilli",real,0,UINT32_MAX) && U32(j,"dlssFpsMilli",output,0,UINT32_MAX) && age <= 5000) {
        s.actualFramesPresented = frames; s.fpsAgeMs = age; s.realFpsMilli = real; s.outputFpsMilli = output;
    }
    value = s; return true;
}
inline bool MergeSettings(Json& document, const Settings& current, const Settings& requested, const Live& live, std::string& error) {
    if (requested.multiplier < 1 || requested.multiplier > 6 || requested.targetFps > 1000 || requested.preset > 2 || requested.vsyncMode > 2 || requested.reflexLimit > 1000) {
        error = "Invalid MFG setting."; return false;
    }
    const bool modeChanged = current.followGame != requested.followGame || current.dynamic != requested.dynamic ||
        current.multiplier != requested.multiplier || current.targetFps != requested.targetFps;
    if (modeChanged && (!live.bridgeReady || (!requested.followGame && (requested.multiplier < live.minMultiplier || requested.multiplier > live.maxMultiplier)) ||
        (!requested.followGame && requested.dynamic && (!live.canDynamic || requested.multiplier < 2)))) {
        error = "This MFG mode is not available from the current game backend."; return false;
    }
    if (current.preset != requested.preset && live.legacyPreset) { error = "This provider supports its original preset only."; return false; }
    if (current.reflexLimit != requested.reflexLimit && (!live.canReflex || requested.dynamic)) {
        error = "The Reflex frame limit is unavailable while Dynamic MFG is selected or active."; return false;
    }
    if (current.vsyncMode != requested.vsyncMode) { error = "VSync is managed by the current game settings."; return false; }
    document["followGame"] = requested.followGame;
    document["mode"] = requested.followGame ? "follow" : requested.dynamic ? "dynamic" : "fixed";
    document["multiplier"] = requested.followGame ? 2u : requested.multiplier;
    document["dynamicTargetFrameRate"] = requested.targetFps;
    document["dlssgPreset"] = requested.preset;
    document["reflexFrameLimitFps"] = requested.reflexLimit;
    document["vsyncMode"] = requested.vsyncMode;
    document["version"] = 13;
    return true;
}
}
