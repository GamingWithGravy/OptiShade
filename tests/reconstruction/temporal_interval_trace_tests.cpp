#include "temporal_interval_trace.h"

#include <Windows.h>

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

static uint64_t Size(const fs::path& path)
{
    return fs::exists(path) ? fs::file_size(path) : 0;
}

static bool Contains(const fs::path& path, const std::string& value)
{
    std::ifstream input(path, std::ios::binary);
    std::string contents((std::istreambuf_iterator<char>(input)), {});
    return contents.find(value) != std::string::npos;
}

static uint64_t ReadDataRows(const fs::path& path,
    std::set<std::string>& sequences)
{
    std::ifstream input(path, std::ios::binary);
    std::string line;
    uint64_t rows = 0;
    while (std::getline(input, line))
    {
        if (line.empty() || line[0] == '#' || line.rfind("sequence,", 0) == 0)
            continue;
        const size_t comma = line.find(',');
        if (comma == std::string::npos
            || !sequences.insert(line.substr(0, comma)).second)
            return UINT64_MAX;
        ++rows;
    }
    return rows;
}

static bool CreateAgedFile(const fs::path& path, uint32_t daysOld)
{
    {
        std::ofstream output(path, std::ios::binary);
        if (!output)
            return false;
        output << "trace fixture\n";
    }
    HANDLE file = CreateFileW(path.c_str(), FILE_WRITE_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        return false;
    FILETIME now{};
    GetSystemTimeAsFileTime(&now);
    ULARGE_INTEGER aged{};
    aged.LowPart = now.dwLowDateTime;
    aged.HighPart = now.dwHighDateTime;
    aged.QuadPart -= static_cast<uint64_t>(daysOld) * 864000000000ull;
    FILETIME writeTime{aged.LowPart, aged.HighPart};
    const bool okay = SetFileTime(file, nullptr, nullptr, &writeTime) != FALSE;
    CloseHandle(file);
    return okay;
}

int wmain(int argc, wchar_t** argv)
{
    if (argc != 2)
        return 2;
    const fs::path directory(argv[1]);
    fs::create_directories(directory);
    const DWORD pid = GetCurrentProcessId();
    constexpr DWORD stalePidA = MAXDWORD - 1;
    constexpr DWORD stalePidB = MAXDWORD - 2;
    const std::wstring staleStemA = L"MfgUnlock-intervals-"
        + std::to_wstring(stalePidA);
    const std::wstring staleStemB = L"MfgUnlock-intervals-"
        + std::to_wstring(stalePidB);
    const fs::path staleCurrent = directory / (staleStemA + L".csv");
    const fs::path stalePrevious = directory
        / (staleStemA + L".previous.csv");
    const fs::path recent = directory / (staleStemB + L".csv");
    const fs::path protectedCurrent = directory
        / (L"MfgUnlock-intervals-" + std::to_wstring(pid) + L".csv");
    const fs::path unrelated = directory / L"Other-intervals-4294967294.csv";
    if (!CreateAgedFile(staleCurrent,
            temporal_interval_trace::kTraceRetentionDays + 1)
        || !CreateAgedFile(stalePrevious,
            temporal_interval_trace::kTraceRetentionDays + 1)
        || !CreateAgedFile(recent, 0)
        || !CreateAgedFile(protectedCurrent,
            temporal_interval_trace::kTraceRetentionDays + 1)
        || !CreateAgedFile(unrelated,
            temporal_interval_trace::kTraceRetentionDays + 1))
    {
        std::cerr << "Could not create trace-retention fixtures\n";
        return 1;
    }
    const uint32_t removed = temporal_interval_trace::PruneInactiveFiles(
        directory.c_str(), pid);
    if (removed != 2 || fs::exists(staleCurrent) || fs::exists(stalePrevious)
        || !fs::exists(recent) || !fs::exists(protectedCurrent)
        || !fs::exists(unrelated))
    {
        std::cerr << "Stale trace pruning removed an unsafe file or retained an expired PID pair\n";
        return 1;
    }
    temporal_interval_trace::Initialize(directory.c_str(), pid);
    temporal_interval_trace::SetEnabled(true);

    constexpr uint32_t producerCount = 4;
    constexpr uint32_t eventsPerProducer = 1000;
    std::atomic<bool> producersDone{false};
    std::thread flusher([&]() {
        while (!producersDone.load(std::memory_order_acquire))
        {
            temporal_interval_trace::Flush();
            SwitchToThread();
        }
        temporal_interval_trace::Flush();
    });
    std::vector<std::thread> producers;
    for (uint32_t producer = 0; producer < producerCount; ++producer)
    {
        producers.emplace_back([&]() {
            for (uint32_t event = 0; event < eventsPerProducer; ++event)
                temporal_interval_trace::Record(nullptr, nullptr, false);
        });
    }
    for (auto& producer : producers)
        producer.join();
    producersDone.store(true, std::memory_order_release);
    flusher.join();
    temporal_interval_trace::Flush();

    std::set<std::string> concurrentSequences;
    const fs::path concurrentCurrent = directory
        / (L"MfgUnlock-intervals-" + std::to_wstring(pid) + L".csv");
    const uint64_t concurrentRows = ReadDataRows(concurrentCurrent,
        concurrentSequences);
    const auto concurrentSnapshot = temporal_interval_trace::ReadSnapshot();
    if (concurrentRows != producerCount * eventsPerProducer
        || concurrentSequences.size() != concurrentRows
        || concurrentSnapshot.invalidSamples != concurrentRows
        || concurrentSnapshot.droppedSamples != 0)
    {
        std::cerr << "Concurrent producers lost or duplicated trace requests: rows="
                  << concurrentRows << " invalid="
                  << concurrentSnapshot.invalidSamples << " dropped="
                  << concurrentSnapshot.droppedSamples << "\n";
        return 1;
    }

    constexpr uint64_t eventCount = 160000;
    for (uint64_t first = 0; first < eventCount; first += 1024)
    {
        const uint64_t end = (first + 1024 < eventCount)
            ? first + 1024 : eventCount;
        for (uint64_t sequence = first; sequence < end; ++sequence)
            temporal_interval_trace::Record(nullptr, nullptr, false);
        temporal_interval_trace::Flush();
    }

    const std::wstring stem = L"MfgUnlock-intervals-" + std::to_wstring(pid);
    const fs::path current = directory / (stem + L".csv");
    const fs::path previous = directory / (stem + L".previous.csv");
    constexpr uint64_t limit = 4ull * 1024ull * 1024ull;
    const uint64_t currentBytes = Size(current);
    const uint64_t previousBytes = Size(previous);
    if (currentBytes == 0 || previousBytes == 0
        || currentBytes > limit || previousBytes > limit)
    {
        std::cerr << "Unexpected trace segment sizes: current=" << currentBytes
                  << " previous=" << previousBytes << "\n";
        return 1;
    }
    if (!Contains(current, "sequence,qpc,")
        || !Contains(previous, "sequence,qpc,")
        || !Contains(current, "160000,"))
    {
        std::cerr << "Trace headers or newest event are missing\n";
        return 1;
    }

    // Fill the fixed event pool without draining it. Extra requests must be
    // counted as drops without allocating or losing the accepted tail.
    for (uint64_t index = 0; index < 4106; ++index)
        temporal_interval_trace::Record(nullptr, nullptr, false);
    temporal_interval_trace::Flush();
    const auto snapshot = temporal_interval_trace::ReadSnapshot();
    if (snapshot.droppedSamples != 10
        || Size(current) > limit || Size(previous) > limit
        || !Contains(current, "164096,"))
    {
        std::cerr << "Fixed-pool overflow accounting or bounded trace tail failed\n";
        return 1;
    }
    std::cout << "Stale inactive PID traces expire after the retention window; "
                 "recent, active-PID and unrelated files are retained.\n"
                 "Concurrent producers and the worker preserve every accepted "
                 "request without duplicating sequence IDs.\n"
                 "Two trace segments remain within 4 MiB; rotation preserves "
                 "the newest event and fixed-pool overflow is counted.\n";
    return 0;
}
