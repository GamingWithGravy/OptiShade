#include "../reshade/source/dll_log.hpp"
#include <fstream>
#include <thread>
#include <vector>
#include <iostream>
int main() {
    namespace fs = std::filesystem;
    fs::create_directories("test-run/log-fixture");
    const fs::path path = "test-run/log-fixture/ReShade.log";
    std::error_code ec;
    assert(reshade::log::open_log_file(path, ec));
    reshade::log::message(reshade::log::level::error, "FIRST_FAILURE");
    const std::string oversized(1000000, 'x');
    reshade::log::message(reshade::log::level::info, "%s", oversized.c_str());
    assert(fs::file_size(path) < 17 * 1024);
    const std::string payload(15000, 'x');
    std::vector<std::thread> threads;
    for (int t = 0; t < 3; ++t) threads.emplace_back([&] {
        for (int i = 0; i < 900; ++i) reshade::log::message(reshade::log::level::warning, "%s", payload.c_str());
    });
    for (auto& thread : threads) thread.join();
    for (const auto& suffix : {"", ".1", ".2"}) assert(fs::file_size(path.string() + suffix) <= 8 * 1024 * 1024);
    assert(!fs::exists(path.string() + ".3"));
    std::ifstream first(path.string() + ".first.log"); std::string line; std::getline(first, line);
    assert(line.find("FIRST_FAILURE") != std::string::npos);
    assert(fs::file_size(path.string() + ".first.log") <= 256 * 1024);
    assert(reshade::log::open_log_file("test-run/log-fixture/ReShade-reopened.log", ec));
    reshade::log::message(reshade::log::level::info, "reopened");
    std::cout << "PASS: actual ReShade logger rotations, concurrent writes, first failure and reopen\n";
}
