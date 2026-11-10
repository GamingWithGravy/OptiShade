#include <DlssRuntimeSelection.h>

#include <cassert>
#include <chrono>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace fs = std::filesystem;

int main()
{
	const auto unique = std::to_string(
		std::chrono::steady_clock::now().time_since_epoch().count());
	const auto root = fs::temp_directory_path() / ("optishade-dlss-runtime-" + unique);
	const auto managedDirectory = root / "OptiShadeData" / "Engine";
	const auto gameDll = root / "nvngx_dlss.dll";
	fs::create_directories(managedDirectory);
	{
		const auto candidates = optishade::dlssruntime::Candidates(
			root / "custom" / "nvngx_dlss.dll",
			managedDirectory,
			gameDll,
			root);
		assert(candidates.size() == 3);
		assert(candidates[0] == (root / "custom" / "nvngx_dlss.dll"));
		assert(candidates[1] == (managedDirectory / "nvngx_dlss.dll"));
		assert(candidates[2] == gameDll);
	}
	{
		const auto candidates = optishade::dlssruntime::Candidates(
			std::nullopt,
			std::nullopt,
			"nvngx_dlss.dll",
			root);
		assert(candidates.size() == 1);
		assert(candidates.front() == gameDll);
	}
	{
		const auto managedDll = managedDirectory / "nvngx_dlss.dll";
		const auto candidates = optishade::dlssruntime::Candidates(
			managedDll,
			managedDll,
			gameDll,
			root);
		assert(candidates.size() == 2);
		assert(candidates.front() == managedDll);
		assert(candidates.back() == gameDll);
	}
	fs::remove_all(root);
	return 0;
}
