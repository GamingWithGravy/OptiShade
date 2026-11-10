#pragma once

#include <algorithm>
#include <filesystem>
#include <optional>
#include <system_error>
#include <vector>

namespace optishade::dlssruntime
{
inline std::vector<std::filesystem::path> Candidates(
	const std::optional<std::filesystem::path> &userOverride,
	const std::optional<std::filesystem::path> &managedRuntime,
	const std::filesystem::path &gameRuntime,
	const std::filesystem::path &gameRoot)
{
	std::vector<std::filesystem::path> result;
	const auto append = [&](const std::filesystem::path &candidate) {
		if (candidate.empty())
			return;

		auto resolved = (candidate.is_absolute() ? candidate : gameRoot / candidate).lexically_normal();
		std::error_code error;
		if (std::filesystem::is_directory(resolved, error))
			resolved /= std::filesystem::path("nvngx_dlss.dll");

		if (std::find(result.begin(), result.end(), resolved) == result.end())
			result.push_back(resolved);
	};

	// Explicit user choice wins; otherwise use the runtime selected by OptiShade's
	// managed engine directory, then preserve the game's own DLL as a fallback.
	if (userOverride)
		append(*userOverride);
	if (managedRuntime)
		append(*managedRuntime);
	append(gameRuntime);
	return result;
}
}
