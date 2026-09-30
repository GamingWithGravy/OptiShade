/*
 * Copyright (C) 2014 Patrick Mours
 * SPDX-License-Identifier: BSD-3-Clause OR MIT
 */

#include "dll_log.hpp"
#include <cstdarg>
#include <Windows.h>
#include <mutex>
#include <algorithm>

struct scoped_file_handle
{
	scoped_file_handle(HANDLE handle = INVALID_HANDLE_VALUE) : handle(handle) {}
	~scoped_file_handle()
	{
		if (handle != INVALID_HANDLE_VALUE)
			CloseHandle(handle);
	}

	operator HANDLE() const { return handle; }

	void operator=(HANDLE new_handle)
	{
		handle = new_handle;
	}

private:
	HANDLE handle;
};

static scoped_file_handle s_log_file_handle;
static scoped_file_handle s_first_failure_handle;
static std::mutex s_log_mutex;
static std::filesystem::path s_log_path;
static uint64_t s_log_bytes = 0, s_first_bytes = 0;
#if RESHADE_VERBOSE_LOG
static constexpr uint64_t log_limit = 32 * 1024 * 1024;
#else
static constexpr uint64_t log_limit = 8 * 1024 * 1024;
#endif
static constexpr uint64_t first_limit = 256 * 1024;

bool reshade::log::open_log_file(const std::filesystem::path &path, std::error_code &ec)
{
	const std::lock_guard<std::mutex> lock(s_log_mutex);
	// Close the previous file first
	// Do this here, instead of in 'scoped_file_handle::operator=', so that the old handle is closed before the new handle is created
	if (s_log_file_handle != INVALID_HANDLE_VALUE)
		CloseHandle(s_log_file_handle);
	if (s_first_failure_handle != INVALID_HANDLE_VALUE)
		CloseHandle(s_first_failure_handle);
	s_first_failure_handle = INVALID_HANDLE_VALUE;
	s_log_path = path;
	s_log_bytes = s_first_bytes = 0;

	// Open the log file for writing (and flush on each write) and clear previous contents
	s_log_file_handle = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, NULL);

	if (s_log_file_handle != INVALID_HANDLE_VALUE)
	{
		s_first_failure_handle = CreateFileW((path.wstring() + L".first.log").c_str(), GENERIC_WRITE,
			FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
		// Last error may be ERROR_ALREADY_EXISTS if an existing file was overwritten, which can be ignored
		ec.clear();
		return true;
	}
	else
	{
		ec.assign(GetLastError(), std::system_category());
		return false;
	}
}

void reshade::log::message(level level, const char *format, ...)
{
	static constexpr char level_names[][6] = { "ERROR", "WARN ", "INFO ", "DEBUG" };

	if (static_cast<size_t>(level) == 0)
		level = level::error;
	if (static_cast<size_t>(level) > std::size(level_names))
		level = level::debug;

	SYSTEMTIME time;
	GetLocalTime(&time);

	std::string line_string(256, '\0');

	// Start a new line
	const auto meta_length = std::snprintf(line_string.data(), line_string.size(),
#if RESHADE_VERBOSE_LOG
		"%04hd-%02hd-%02hdT"
#endif
		"%02hd:%02hd:%02hd:%03hd [%5lu] | %.5s | ",
#if RESHADE_VERBOSE_LOG
		time.wYear, time.wMonth, time.wDay,
#endif
		time.wHour, time.wMinute, time.wSecond, time.wMilliseconds, GetCurrentThreadId(), level_names[static_cast<size_t>(level) - 1]);

	va_list args;
	va_start(args, format);
	const auto content_length = std::vsnprintf(line_string.data() + meta_length, line_string.size() + 1 - meta_length, format, args);
	va_end(args);

	// Bound before resizing/reformatting, including an encoding failure reported
	// as a negative length. A huge shader/compiler diagnostic must not allocate
	// its full formatted size only to be truncated afterwards.
	constexpr size_t max_record = 16 * 1024;
	if (content_length < 0)
	{
		line_string.resize(static_cast<size_t>(meta_length));
		line_string += "[log formatting failed]";
	}
	else
	{
		const size_t requested = static_cast<size_t>(meta_length) + static_cast<size_t>(content_length);
		const size_t bounded = (std::min)(requested, max_record - 32);
		const bool remaining_content = bounded > line_string.size();
		line_string.resize(bounded);
		if (remaining_content)
		{
			va_start(args, format);
			std::vsnprintf(line_string.data() + meta_length, line_string.size() + 1 - meta_length, format, args);
			va_end(args);
		}
		if (requested > bounded) line_string += " [record truncated]";
	}

	line_string += '\n'; // Terminate line with line feed
	if (line_string.size() > 16 * 1024)
		line_string = line_string.substr(0, 16 * 1024 - 20) + " [record truncated]\n";

	// Replace all LF with CRLF
	for (size_t offset = 0; (offset = line_string.find('\n', offset)) != std::string::npos; offset += 2)
		line_string.replace(offset, 1, "\r\n", 2);

	// Write line to the log file
	const std::lock_guard<std::mutex> lock(s_log_mutex);
	if (s_first_failure_handle != INVALID_HANDLE_VALUE && level <= level::warning && s_first_bytes < first_limit)
	{
		DWORD written = 0;
		const DWORD count = static_cast<DWORD>((std::min)(static_cast<uint64_t>(line_string.size()), first_limit - s_first_bytes));
		WriteFile(s_first_failure_handle, line_string.data(), count, &written, nullptr);
		s_first_bytes += written;
	}
	if (s_log_file_handle != INVALID_HANDLE_VALUE && s_log_bytes + line_string.size() > log_limit)
	{
		CloseHandle(s_log_file_handle);
		s_log_file_handle = INVALID_HANDLE_VALUE;
		const auto current = s_log_path.wstring();
		MoveFileExW((current + L".1").c_str(), (current + L".2").c_str(), MOVEFILE_REPLACE_EXISTING);
		// If another reader prevents rotation, stop this output rather than grow
		// indefinitely or overwrite the only retained failure record.
		if (MoveFileExW(current.c_str(), (current + L".1").c_str(), MOVEFILE_REPLACE_EXISTING))
		{
			s_log_file_handle = CreateFileW(current.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
				CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
			s_log_bytes = 0;
		}
	}
	if (s_log_file_handle != INVALID_HANDLE_VALUE)
	{
		DWORD written = 0;
		WriteFile(s_log_file_handle, line_string.data(), static_cast<DWORD>(line_string.size()), &written, nullptr);
		s_log_bytes += written;
	}

#ifndef NDEBUG
	// Write line to the debug output
	OutputDebugStringA(line_string.c_str());
#endif
}
