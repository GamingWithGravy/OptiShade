// OptiShade additions, GPL-3.0-or-later.
#pragma once
// Whether the game's own frame generation is producing frames right now, read
// from the OptiMFG backend's status file in this process.
//
// When the game's DLSS-G runs through NVIDIA's downloaded Streamline plugins,
// OptiScaler's interposer hooks never see its options, so the TAA late route
// cannot tell that presents include generated frames. The backend sees every
// call; its status file is the evidence. It is trusted only for this process
// (pid and creation time) and only while its heartbeat is fresh.
#include <json.hpp>
#include <windows.h>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>

namespace optishade::external_fg_status {
using Json = nlohmann::json;

inline constexpr uint64_t kMaxHeartbeatAgeSeconds = 5;
inline constexpr uint64_t kRefreshMs = 500;
// DLSS-G in dynamic mode (and short dropouts) presents one frame at a time for
// about a second while frame generation stays on: OSD-XGNZ flipped TAA NR
// between the pre-FG route and the late route every second (a visible flicker,
// and the late route costs twice as much). Keep the last "generating" answer
// through such a pause, never through game FG off, a 1x request or a stale or
// foreign status.
inline constexpr uint64_t kPauseHoldMs = 5000;

enum class Generation { None, Paused, Generating };

// Pure check, for tests: generating means game FG on, more than one frame per
// present observed and a multiplier above 1x, from a fresh status of this process.
// Paused is the same status presenting one frame per present.
inline Generation Classify(const Json& j, uint32_t pid, uint64_t birth, uint64_t now, uint32_t* multiplier = nullptr) {
    if (!j.is_object() || !pid || !birth) return Generation::None;
    auto u64 = [&](const char* name, uint64_t& out) {
        const auto it = j.find(name);
        // A parsed file stores these as unsigned; accept any non-negative integer.
        if (it == j.end() || !it->is_number_integer() || (!it->is_number_unsigned() && it->get<int64_t>() < 0)) return false;
        out = it->get<uint64_t>(); return true;
    };
    auto flag = [&](const char* name) {
        const auto it = j.find(name);
        return it != j.end() && it->is_boolean() && it->get<bool>();
    };
    uint64_t statusPid = 0, statusBirth = 0, heartbeat = 0, applied = 0, presented = 0;
    if (!u64("pid", statusPid) || statusPid != pid || !u64("processBirth", statusBirth) || statusBirth != birth) return Generation::None;
    if (!u64("heartbeat", heartbeat) || heartbeat > now + 1 || now - heartbeat > kMaxHeartbeatAgeSeconds) return Generation::None;
    if (!flag("gameFrameGenerationOn") || !u64("appliedMultiplier", applied) || !u64("actualFramesPresented", presented)) return Generation::None;
    if (applied < 2) return Generation::None;
    if (multiplier) *multiplier = static_cast<uint32_t>(applied);
    return presented < 2 ? Generation::Paused : Generation::Generating;
}
inline bool IsGenerating(const Json& j, uint32_t pid, uint64_t birth, uint64_t now, uint32_t* multiplier = nullptr) {
    uint32_t found = 0;
    const bool generating = Classify(j, pid, birth, now, &found) == Generation::Generating;
    if (generating && multiplier) *multiplier = found;
    return generating;
}

// Pure hold, for tests: the answer the TAA routes use for one status reading.
struct PauseHold {
    uint64_t lastGenerating = 0;
    uint32_t multiplier = 0;
    bool holding = false;
    bool Update(Generation reading, uint32_t found, uint64_t tick, uint32_t& out) {
        if (reading == Generation::Generating) {
            lastGenerating = tick; multiplier = found; holding = false; out = found; return true;
        }
        holding = reading == Generation::Paused && lastGenerating && tick - lastGenerating <= kPauseHoldMs;
        if (!holding) { lastGenerating = 0; multiplier = 0; out = 0; return false; }
        out = multiplier; return true;
    }
};

class Reader {
    std::mutex mutex;
    uint64_t lastRead = 0;
    bool generating = false;
    uint32_t multiplier = 0;
    PauseHold hold;
    static uint64_t Birth() {
        FILETIME created{}, exited{}, kernel{}, user{};
        return GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)
            ? (uint64_t(created.dwHighDateTime) << 32) | created.dwLowDateTime : 0;
    }
    static uint64_t Now() {
        FILETIME time{}; GetSystemTimeAsFileTime(&time);
        return (((uint64_t(time.dwHighDateTime) << 32) | time.dwLowDateTime) / 10000000ull) - 11644473600ull;
    }
    static std::wstring Folder() {
        std::wstring path(32768, L'\0');
        const auto n = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
        if (!n || n >= path.size()) return {};
        path.resize(n);
        const auto slash = path.find_last_of(L"\\/");
        return slash == std::wstring::npos ? std::wstring{} : path.substr(0, slash + 1);
    }
    static bool ReadSmall(const std::wstring& path, std::string& out) {
        HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return false;
        LARGE_INTEGER size{};
        bool ok = GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart <= 256 * 1024;
        if (ok) {
            out.resize(static_cast<size_t>(size.QuadPart));
            DWORD got = 0;
            ok = ReadFile(file, out.data(), static_cast<DWORD>(out.size()), &got, nullptr) && got == out.size();
        }
        CloseHandle(file);
        return ok;
    }
    Generation ReadLocked(uint32_t& found) {
        const auto folder = Folder();
        if (folder.empty()) return Generation::None;
        std::wstring names[3] = {L"RTX40MFG-Universal.status.json", L"RTXMFG-Universal.status.json", {}};
        // The backend honours a relative override; anything that leaves the
        // game folder is ignored rather than followed.
        wchar_t custom[MAX_PATH]{};
        const auto length = GetEnvironmentVariableW(L"RTX40_MFG_STATUS_PATH", custom, MAX_PATH);
        if (length && length < MAX_PATH && !wcschr(custom, L':') && !wcsstr(custom, L"..") && custom[0] != L'\\' && custom[0] != L'/')
            names[2] = custom;
        const auto pid = GetCurrentProcessId();
        const auto birth = Birth();
        const auto now = Now();
        auto best = Generation::None;
        for (const auto& name : names) {
            if (name.empty()) continue;
            std::string text;
            if (!ReadSmall(folder + name, text)) continue;
            const auto parsed = Json::parse(text, nullptr, false);
            uint32_t value = 0;
            const auto reading = Classify(parsed, pid, birth, now, &value);
            if (reading == Generation::Generating) { found = value; return reading; }
            if (reading == Generation::Paused && best == Generation::None) { best = reading; found = value; }
        }
        return best;
    }

  public:
    // Throttled; safe to call every frame. File errors read as "not generating".
    bool Generating(uint32_t* applied = nullptr) {
        std::lock_guard lock(mutex);
        const auto tick = GetTickCount64();
        if (!lastRead || tick - lastRead >= kRefreshMs) {
            lastRead = tick;
            uint32_t found = 0;
            Generation reading = Generation::None;
            try { reading = ReadLocked(found); } catch (...) { reading = Generation::None; }
            generating = hold.Update(reading, found, tick, multiplier);
        }
        if (applied) *applied = multiplier;
        return generating;
    }
    // True while a pause is being held as generating (for the log).
    bool Holding() { std::lock_guard lock(mutex); return hold.holding; }
};

inline Reader& Session() { static Reader reader; return reader; }
}
