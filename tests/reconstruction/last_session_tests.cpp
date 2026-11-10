#include "LastSession.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

static void Check(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}

static std::string Read(const std::filesystem::path &path) {
    std::ifstream input(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input), {});
}

int main() {
    const auto directory = std::filesystem::temp_directory_path() /
        ("OptiShade-last-session-" + std::to_string(GetTickCount64()) + "-" +
         std::to_string(GetCurrentProcessId()));
    const auto path = directory / "LastSession.json";
    try {
        optishade::session::Journal journal;
        journal.Configure(path, "Fixture.exe", "OptiShadeGeneric.dll");
        journal.Put({
            {"FGStateQueryStage", "Provider call completed"},
            {"FGStateResult", "0"},
            {"FGStateQueryCount", "1"},
            {"FGStateCallerThreadId", "19"},
            {"FGStateThreadMatchesLastPresent", "Yes"}});
        auto contents = Read(path);
        Check(contents.find("Provider call completed") != std::string::npos,
              "Initial LastSession record was not written.");
        const auto mfgOptionsPath = directory / "MfgOptionsSession.json";
        optishade::session::Journal mfgOptionsJournal;
        mfgOptionsJournal.Configure(mfgOptionsPath, "FlightSimulator2024.exe", "OptiShadeGeneric.dll");
        mfgOptionsJournal.PutCritical({
            {"FGSetOptionsObserved", "Yes"},
            {"FGSetOptionsInputMode", "eOn"},
            {"FGSetOptionsInputAdditionalFrames", "0"},
            {"FGSetOptionsForwardedMode", "eOn"},
            {"FGSetOptionsForwardedAdditionalFrames", "0"},
            {"FGSetOptionsProviderResult", "eErrorFeatureMissing"},
            {"FGSetOptionsThreadId", "19"},
            {"FGSetOptionsViewport", "4"}});
        contents = Read(mfgOptionsPath);
        Check(contents.find("\"FGSetOptionsInputAdditionalFrames\":\"0\"") != std::string::npos &&
              contents.find("\"FGSetOptionsForwardedMode\":\"eOn\"") != std::string::npos &&
              contents.find("\"FGSetOptionsProviderResult\":\"eErrorFeatureMissing\"") != std::string::npos &&
              contents.find("\"FGSetOptionsThreadId\":\"19\"") != std::string::npos,
              "The bounded MFG options snapshot was not persisted in LastSession.");

        const auto acquirePath = directory / "AcquireSession.json";
        optishade::session::Journal acquireJournal;
        acquireJournal.Configure(acquirePath, "X-Plane.exe", "OptiShadeXPlane12.dll");
        acquireJournal.Put(std::map<std::string, std::string>{
            {"XP12VulkanAcquireApi", "2"}, {"XP12VulkanAcquireResult", "1000001003"},
            {"XP12VulkanAcquireImageIndexValid", "true"}, {"XP12VulkanAcquireImageIndex", "4"}});
        const auto acquireContents = Read(acquirePath);
        Check(acquireContents.find("\"XP12VulkanAcquireApi\":\"2\"") != std::string::npos &&
              acquireContents.find("\"XP12VulkanAcquireResult\":\"1000001003\"") != std::string::npos &&
              acquireContents.find("\"XP12VulkanAcquireImageIndex\":\"4\"") != std::string::npos,
              "Batched acquire snapshot was not persisted by the LastSession map overload.");

        const std::initializer_list<std::pair<const std::string, std::string>> pending = {
            {"FGStateQueryStage", "Provider call pending"},
            {"FGStateResult", "Pending"},
            {"FGStateQueryCount", "2"},
            {"FGStateCallerThreadId", "20"},
            {"FGPresentSampleSource", "OptiScaler primary game swapchain Present"},
            {"FGPresentCallerThreadId", "19"},
            {"FGPresentSwapchainId", "4660"},
            {"FGStateThreadMatchesLastPresent", "No"}};
        journal.Put(pending); // Ordinary snapshots remain rate-limited.
        Check(Read(path).find("Provider call completed") != std::string::npos,
              "Ordinary per-frame updates bypassed the journal rate limit.");
        journal.PutCritical(pending);
        contents = Read(path);
        Check(contents.find("Provider call pending") != std::string::npos &&
                  contents.find("\"FGStateResult\":\"Pending\"") != std::string::npos &&
                  contents.find("\"FGStateQueryCount\":\"2\"") != std::string::npos &&
                  contents.find("\"FGStateCallerThreadId\":\"20\"") != std::string::npos &&
                  contents.find("\"FGPresentSwapchainId\":\"4660\"") != std::string::npos &&
                  contents.find("\"FGStateThreadMatchesLastPresent\":\"No\"") != std::string::npos,
              "Critical pre-provider mismatch evidence was not persisted before the call.");
        journal.PutResolvedProviderCall({
            {"FGStateQueryStage", "Provider call completed"},
            {"FGStateResult", "0"},
            {"FGStateQueryCount", "2"},
            {"FGStateReportedMaximum", "1"}});
        contents = Read(path);
        Check(contents.find("\"FGStateQueryStage\":\"Provider call completed\"") != std::string::npos &&
                  contents.find("\"FGStateResult\":\"0\"") != std::string::npos &&
                  contents.find("\"FGStateReportedMaximum\":\"1\"") != std::string::npos,
              "A completed provider callback did not immediately resolve a recently persisted pending snapshot.");
        journal.PutCritical(pending); // A later call still respects the pending-write throttle.
        contents = Read(path);
        Check(contents.find("\"FGStateQueryStage\":\"Provider call completed\"") != std::string::npos &&
                  contents.find("\"FGStateResult\":\"0\"") != std::string::npos,
              "A rate-limited later pending callback overwrote the latest completed provider result.");
        const auto nrActionPath = directory / "NrActionSession.json";
        optishade::session::Journal nrActionJournal;
        nrActionJournal.Configure(nrActionPath, "X-Plane.exe", "OptiShadeXPlane12.dll");
        nrActionJournal.RecordNRActivation(true, "in-game-panel", "Applied; waiting for eligible processing");
        nrActionJournal.RecordNRActivation(false, "hotkey", "Applied to runtime configuration");
        const auto nrActionContents = Read(nrActionPath);
        Check(nrActionContents.find("\"NRActivationAttemptCount\":\"2\"") != std::string::npos &&
                  nrActionContents.find("On source=in-game-panel") != std::string::npos &&
                  nrActionContents.find("Off source=hotkey") != std::string::npos &&
                  nrActionContents.find("\"NRActivationOutcome\":\"Applied to runtime configuration\"") != std::string::npos,
              "NR action history must preserve both the activation attempt and the final Off action with source and outcome.");
        nrActionJournal.RecordNRActivation(true,"in-game-panel");
        Check(nrActionJournal.RecordXP12BridgeBlock("XP12 temporal guide producer unavailable","Vulkan",101,202,303,404),
              "The first XP12 admission blocker should be recorded for an explicit active request.");
        Check(!nrActionJournal.RecordXP12BridgeBlock("later blocker must not replace the first","Vulkan",111,222,333,444),
              "A later XP12 blocker must not overwrite the first blocker for the same explicit request.");
        const auto xp12Contents=Read(nrActionPath);
        Check(xp12Contents.find("XP12 temporal guide producer unavailable")!=std::string::npos&&
              xp12Contents.find("\"XP12BridgeLatestBlockReason\":\"later blocker must not replace the first\"")!=std::string::npos&&
              xp12Contents.find("\"XP12BridgeBlockAPI\":\"Vulkan\"")!=std::string::npos&&
              xp12Contents.find("\"XP12BridgeBlockDevice\":\"101\"")!=std::string::npos&&
              xp12Contents.find("\"XP12BridgeBlockOwner\":\"202\"")!=std::string::npos&&
              xp12Contents.find("\"XP12BridgeBlockGeneration\":\"303\"")!=std::string::npos&&
              xp12Contents.find("\"XP12BridgeBlockQueue\":\"404\"")!=std::string::npos,
              "The first XP12 blocker must be durably bound to its API/device/owner/generation/queue context.");
        std::cout << "LastSession critical pre-provider snapshot, completion resolution and write throttling passed.\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        std::error_code cleanupError;
        std::filesystem::remove_all(directory, cleanupError);
        return 1;
    }
    std::error_code error;
    std::filesystem::remove_all(directory, error);
    return 0;
}
