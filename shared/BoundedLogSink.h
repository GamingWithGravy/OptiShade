#pragma once
#include <spdlog/sinks/base_sink.h>
#include <spdlog/sinks/rotating_file_sink.h>
#include <fstream>
#include <filesystem>
#include <mutex>

namespace OptiShadeLog {
// Keep the first warnings/errors independently of the rolling tail. Large debug
// records are truncated before formatting/writing, so one record cannot defeat
// the storage bound. Uses the established spdlog formatting and synchronization.
class BoundedFileSink final : public spdlog::sinks::base_sink<std::mutex> {
    spdlog::sinks::rotating_file_sink_mt rolling_;
    std::ofstream first_;
    size_t firstBytes_ = 0;
    const size_t firstLimit_;
public:
    BoundedFileSink(const spdlog::filename_t& path, size_t bytes, size_t archives = 2,
                    size_t firstLimit = 256 * 1024)
        : rolling_(path, bytes, archives, true), first_(std::filesystem::path(path).concat(".first.log"), std::ios::binary | std::ios::trunc),
          firstLimit_(firstLimit) {}
protected:
    void sink_it_(const spdlog::details::log_msg& msg) override {
        auto bounded = msg;
        constexpr size_t maxRecord = 16 * 1024;
        if (bounded.payload.size() > maxRecord)
            bounded.payload = spdlog::string_view_t(msg.payload.data(), maxRecord);
        if (msg.level >= spdlog::level::warn && first_.is_open() && firstBytes_ < firstLimit_) {
            spdlog::memory_buf_t formatted;
            formatter_->format(bounded, formatted);
            const size_t count = (std::min)(formatted.size(), firstLimit_ - firstBytes_);
            first_.write(formatted.data(), static_cast<std::streamsize>(count));
            firstBytes_ += count;
            // Preserve the initial failure even if a locked rolling archive
            // makes the independent rotation sink throw below.
            first_.flush();
        }
        rolling_.log(bounded);
    }
    void flush_() override { rolling_.flush(); first_.flush(); }
    void set_pattern_(const std::string& pattern) override {
        spdlog::sinks::base_sink<std::mutex>::set_pattern_(pattern);
        rolling_.set_pattern(pattern);
    }
    void set_formatter_(std::unique_ptr<spdlog::formatter> formatter) override {
        rolling_.set_formatter(formatter->clone());
        spdlog::sinks::base_sink<std::mutex>::set_formatter_(std::move(formatter));
    }
};
}
