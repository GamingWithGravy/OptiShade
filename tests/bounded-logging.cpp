#include "../shared/BoundedLogSink.h"
#include "../shared/DiagnosticRateLimit.h"
#include <spdlog/logger.h>
#include <filesystem>
#include <cassert>
#include <iostream>
#include <Windows.h>

int main() {
    namespace fs = std::filesystem;
    const auto root = fs::path("test-run/log-fixture");
    fs::create_directories(root);
    auto sink = std::make_shared<OptiShadeLog::BoundedFileSink>((root / "Performance.log").string(), 32768, 2, 4096);
    spdlog::logger log("fixture", sink); log.set_pattern("%v");
    log.warn("FIRST_FAILURE");
    for (int i = 0; i < 20000; ++i) log.warn("{} {}", i, std::string(250, 'x'));
    log.warn("{}", std::string(1000000, 'x')); log.flush();
    std::ifstream first(root / "Performance.log.first.log");
    std::string marker; std::getline(first, marker); assert(marker == "FIRST_FAILURE");
    assert(fs::file_size(root / "Performance.log.first.log") <= 4096);
    for (const auto& name : {"Performance.log", "Performance.1.log", "Performance.2.log"})
        assert(fs::file_size(root / name) <= 32768);
    assert(!fs::exists(root / "Performance.3.log"));
    {
        const auto lockedPath = root / "locked.log";
        auto lockedSink = std::make_shared<OptiShadeLog::BoundedFileSink>(lockedPath.string(), 1024, 2, 4096);
        lockedSink->set_pattern("%v");
        std::string padding(800, 'x');
        lockedSink->log(spdlog::details::log_msg("fixture", spdlog::level::info, padding));
        lockedSink->flush();
        HANDLE reader = CreateFileW(lockedPath.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                    nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        assert(reader != INVALID_HANDLE_VALUE);
        bool rejected = false;
        std::string failure = "ROTATION_FAILURE " + std::string(500, 'y');
        try { lockedSink->log(spdlog::details::log_msg("fixture", spdlog::level::warn, failure)); }
        catch (const spdlog::spdlog_ex&) { rejected = true; }
        assert(rejected);
        std::ifstream retained(lockedPath.string() + ".first.log");
        std::getline(retained, marker); assert(marker.find("ROTATION_FAILURE") == 0);
        CloseHandle(reader);
    }
    OptiShadeLog::ReasonLimits<3> reasons;
    assert(reasons.record(0, 10)); assert(reasons.record(1, 11));
    for (int i = 0; i < 10000; ++i) assert(!reasons.record(i % 2, 100 + i));
    assert(reasons.count(0) == 5001 && reasons.count(1) == 5001);
    assert(reasons.record(0, 60010)); assert(!reasons.record(3, 60010));
    std::cout << "PASS: bounded rotations, first failure, oversized record and alternating reasons\n";
}
