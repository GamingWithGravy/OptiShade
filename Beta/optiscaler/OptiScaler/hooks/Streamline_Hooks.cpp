#include <pch.h>
#include "../../../shared/Xp12ProviderOwnership.h"

#include "../../../shared/LastSession.h"
#include <framegen/dlssg/MfgUnlock.h>

#include "Streamline_Hooks.h"
#include "NativeFgStateQueryLock.h"
#include "SafeDlssGetState.h"
#include "../../../shared/OptiShadeStreamlinePolicy.h"
#include "../../../shared/TaaFgHookPolicy.h"
#include "../../../shared/SimulatorRouteHost.h"
#include "../../../shared/SourceMfgOutput.h"
#include "../../../shared/OptiShadeVersion.h"
#include "../../../shared/ExternalFgObserver.h"
#include "../../../shared/ExternalFgTelemetry.h"
#include "../../../shared/NativeMfgControl.h"
#include <misc/ActualRenderGpu.h>
#include "../../../shared/NativeFgStateQuery.h"
#include "StreamlineOptionsSnapshot.h"
#include "../../../shared/NativeFgPresentBoundary.h"
#include "../../../shared/NativeFgTagReplacement.h"
#include <set>
#include <tlhelp32.h>
#include "../../../shared/PassiveFgCapabilityProbe.h"

#include <Util.h>
#include <dlssnr/DlssNrFeature_Dx12.h>
#include <Config.h>

#include <nvapi/fakenvapi.h>
#include <misc/IdentifyGpu.h>
#include <hooks/Reflex_Hooks.h>
#include <menu/menu_overlay_base.h>
#include <framegen/nvngx/Nvngx_FG.h>
#include <proxies/KernelBase_Proxy.h>
#include <imgui/ImGuiNotify.hpp>
#include <hooks/ProcessDetourTransaction.h>

#include <json.hpp>
#include <sl1_reflex.h>
#include <magic_enum.hpp>
#include "detours/detours.h"

#include <intrin.h>
#pragma intrinsic(_ReturnAddress)

// The generic pass-through capability lane attaches only lookup/device exports.
// It does not own NR tags, marker callbacks, presentation, or provider options.
static std::atomic<bool> passiveInterposer{false};
// A fault in any resolved Streamline DLSS-G state callback is contained once,
// then all routes stop querying the provider for the rest of the process.
static std::atomic<bool> dlssgStateProviderFaulted{false};

static void RecordManagedDlssgOptions(const sl::DLSSGOptions& input,
                                     const sl::DLSSGOptions& forwarded,
                                     sl::Result result,
                                     const optishade::native_mfg::Snapshot& request,
                                     bool explicitRequest,
                                     uint32_t viewport,
                                     bool providerCallSkipped) {
    struct Recorder {
        std::mutex mutex;
        std::string signature;
        uint64_t calls = 0;
        uint64_t lastPersistMs = 0;
    };
    static Recorder recorder;
    const auto inputMode = std::string(magic_enum::enum_name(input.mode));
    const auto forwardedMode = std::string(magic_enum::enum_name(forwarded.mode));
    const auto resultName = std::string(magic_enum::enum_name(result));
    const auto signature = std::to_string(input.structVersion) + ":" + inputMode + ":" +
        std::to_string(input.numFramesToGenerate) + ">" + forwardedMode + ":" +
        std::to_string(forwarded.numFramesToGenerate) + ":" + std::to_string(static_cast<int>(result)) + ":" +
        (explicitRequest ? "1" : "0") + ":" + std::to_string(request.revision) + ":" + std::to_string(viewport) +
        ":" + (providerCallSkipped ? "skip" : "call");
    const auto now = GetTickCount64();
    const bool zeroGeneration = forwarded.mode != sl::DLSSGMode::eOff &&
        forwarded.mode != sl::DLSSGMode::eDynamic && forwarded.numFramesToGenerate == 0;
    uint64_t calls = 0;
    bool record = false;
    {
        std::lock_guard lock(recorder.mutex);
        calls = ++recorder.calls;
        record = recorder.signature != signature ||
            (zeroGeneration && (!recorder.lastPersistMs || now - recorder.lastPersistMs >= 30000));
        if (record) {
            recorder.signature = signature;
            recorder.lastPersistMs = now;
        }
    }
    if (!record) return;

    const auto inputModeText = inputMode.empty() ? std::to_string(static_cast<uint32_t>(input.mode)) : inputMode;
    const auto forwardedModeText = forwardedMode.empty() ? std::to_string(static_cast<uint32_t>(forwarded.mode)) : forwardedMode;
    const auto resultText = resultName.empty() ? std::to_string(static_cast<int>(result)) : resultName;
    optishade::session::State().PutCritical({
        {"FGSetOptionsObserved", "Yes"},
        {"FGSetOptionsCallCount", std::to_string(calls)},
        {"FGSetOptionsThreadId", std::to_string(GetCurrentThreadId())},
        {"FGSetOptionsViewport", std::to_string(static_cast<uint32_t>(viewport))},
        {"FGSetOptionsInputStructVersion", std::to_string(input.structVersion)},
        {"FGSetOptionsInputMode", inputModeText},
        {"FGSetOptionsInputAdditionalFrames", std::to_string(input.numFramesToGenerate)},
        {"FGSetOptionsForwardedMode", forwardedModeText},
        {"FGSetOptionsForwardedAdditionalFrames", std::to_string(forwarded.numFramesToGenerate)},
        {"FGSetOptionsProviderResult", resultText},
        {"FGSetOptionsProviderCallSkipped", providerCallSkipped ? "Yes" : "No"},
        {"FGSetOptionsProviderSkipReason", providerCallSkipped ? "Redundant OFF; provider already OFF" : "Not applicable"},
        {"FGSetOptionsExplicitRequest", explicitRequest ? "Yes" : "No"},
        {"FGSetOptionsRequestRevision", explicitRequest ? std::to_string(request.revision) : "Not applicable"}});
    if (zeroGeneration)
        LOG_WARN("Managed DLSS-G options requested an active mode with zero generated frames; input mode/count={}/{}, forwarded mode/count={}/{}, provider result={}, viewport={}, thread={}, callbacks={}",
            inputModeText, input.numFramesToGenerate, forwardedModeText, forwarded.numFramesToGenerate,
            resultText, static_cast<uint32_t>(viewport), GetCurrentThreadId(), calls);
    else
        LOG_INFO("Managed DLSS-G options changed; input mode/count={}/{}, forwarded mode/count={}/{}, provider result={}, explicit request={}, viewport={}, thread={}, callbacks={}",
            inputModeText, input.numFramesToGenerate, forwardedModeText, forwarded.numFramesToGenerate,
            resultText, explicitRequest ? "yes" : "no", static_cast<uint32_t>(viewport), GetCurrentThreadId(), calls);
}

static void RecordDlssGStateProviderFault(const char* controlPath,
                                         const optishade::native_mfg::GuardedStateCall& fault) {
    if(!fault.exceptionCode)return;
    char exceptionText[16]{},exceptionAddressText[24]{},faultAddressText[24]{},accessOperationText[16]{};
    sprintf_s(exceptionText,"0x%08lX",static_cast<unsigned long>(fault.exceptionCode));
    sprintf_s(exceptionAddressText,"0x%llX",static_cast<unsigned long long>(fault.exceptionAddress));
    sprintf_s(faultAddressText,"0x%llX",static_cast<unsigned long long>(fault.faultAddress));
    sprintf_s(accessOperationText,"%llu",static_cast<unsigned long long>(fault.accessOperation));
    optishade::session::State().PutCritical({
        {"FGControlPath",controlPath},{"FGStateProviderFaulted","Yes"},
        {"FGStateProviderExceptionCode",exceptionText},{"FGStateProviderExceptionAddress",exceptionAddressText},
        {"FGStateProviderAccessOperation",accessOperationText},{"FGStateProviderFaultAddress",faultAddressText},
        {"LastFailure","Streamline DLSS-G state callback faulted; further provider state queries were disabled."}});
    LOG_ERROR("Contained an access violation in the {} Streamline DLSS-G state callback: code={}, site={}, operation={}, address={}; disabling further state queries for this process",
              controlPath,exceptionText,exceptionAddressText,accessOperationText,faultAddressText);
}

static void RecordDlssGOptionsProviderFault(const char* controlPath,
                                           const optishade::native_mfg::GuardedStateCall& fault) {
    if(!fault.exceptionCode)return;
    char exceptionText[16]{},exceptionAddressText[24]{},faultAddressText[24]{},accessOperationText[16]{};
    sprintf_s(exceptionText,"0x%08lX",static_cast<unsigned long>(fault.exceptionCode));
    sprintf_s(exceptionAddressText,"0x%llX",static_cast<unsigned long long>(fault.exceptionAddress));
    sprintf_s(faultAddressText,"0x%llX",static_cast<unsigned long long>(fault.faultAddress));
    sprintf_s(accessOperationText,"%llu",static_cast<unsigned long long>(fault.accessOperation));
    optishade::session::State().PutCritical({
        {"FGSetOptionsProviderFaulted","Yes"},{"FGSetOptionsProviderExceptionCode",exceptionText},
        {"FGSetOptionsProviderExceptionAddress",exceptionAddressText},
        {"FGSetOptionsProviderAccessOperation",accessOperationText},
        {"FGSetOptionsProviderFaultAddress",faultAddressText},
        {"LastFailure","Streamline DLSS-G SetOptions callback faulted; further provider calls were disabled."}});
    LOG_ERROR("Contained an access violation in the {} Streamline DLSS-G SetOptions callback: code={}, site={}, operation={}, address={}; disabling further provider calls for this process",
              controlPath,exceptionText,exceptionAddressText,accessOperationText,faultAddressText);
}

static std::pair<std::string,std::string> DlssgCallerSite(void* returnAddress) {
    const auto module=Util::GetCallerModule(returnAddress);
    if(!module)return {"Unknown","Unknown"};
    const auto moduleName=Util::WhoIsTheCaller(returnAddress);
    const auto address=reinterpret_cast<uintptr_t>(returnAddress);
    const auto base=reinterpret_cast<uintptr_t>(module);
    if(!address||address<base||moduleName.empty())return {moduleName.empty()?"Unknown":moduleName,"Unknown"};
    char offset[24]{};
    sprintf_s(offset,"0x%llX",static_cast<unsigned long long>(address-base));
    return {moduleName,offset};
}

static std::wstring GetModulePath(HMODULE module)
{
    if (module == nullptr)
        return {};

    wchar_t buffer[MAX_PATH * 2] {};
    const auto len = GetModuleFileNameW(module, buffer, static_cast<DWORD>(std::size(buffer)));
    return std::wstring(buffer, len);
}

// Plugin may fail (denylist etc.) and leave pluginJSON empty
static bool HasPluginJson(bool result, const char** pluginJSON)
{
    return result && pluginJSON != nullptr && *pluginJSON != nullptr && **pluginJSON != '\0';
}

// SystemCaps lives inside sl.common's image. When Streamline drops one sl.common copy and keeps another,
// a pointer we got earlier can point into an unmapped (or reused) range, so check before every access.
static bool IsWritableMemory(const void* address, size_t size)
{
    if (address == nullptr)
        return false;

    MEMORY_BASIC_INFORMATION mbi {};
    if (VirtualQuery(address, &mbi, sizeof(mbi)) != sizeof(mbi))
        return false;

    if (mbi.State != MEM_COMMIT || (mbi.Protect & (PAGE_GUARD | PAGE_NOACCESS)) != 0)
        return false;

    constexpr DWORD writable = PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    if ((mbi.Protect & writable) == 0)
        return false;

    const auto end = reinterpret_cast<uintptr_t>(address) + size;
    const auto regionEnd = reinterpret_cast<uintptr_t>(mbi.BaseAddress) + mbi.RegionSize;
    return end <= regionEnd;
}

static bool IsSL1AndFGActive()
{
    const auto& state = State::Instance();

    return state.streamlineVersion.major == 1 && state.activeFgInput == FGInput::DLSSG &&
           state.activeFgOutput != FGOutput::NoFG;
}

// Game's SL1 DLSSG has to stay inert when we use its inputs or provide DLSSG ourselves,
// otherwise its swapchain hooks end up stacked on top of our FG swapchain
static bool IsSL1AndDLSSGManaged()
{
    const auto& state = State::Instance();

    return state.streamlineVersion.major == 1 &&
           (state.activeFgInput == FGInput::DLSSG || state.activeFgOutput == FGOutput::DLSSG);
}

enum class InterposerTagMode { Unknown, Legacy, Frame };
static std::atomic<InterposerTagMode> g_interposerTagMode{InterposerTagMode::Unknown};
static bool featureFunctionHooked=false;
// NativeFgPresentBoundary pairs only the outer Begin/End on this same thread.
// This is a borrowed synchronous completion marker, not a new frame owner.
static thread_local IDXGISwapChain* g_legacyProviderPresent=nullptr;

// Resolved exports are not installed hooks. Retain only attachments from a
// successful transaction so cleanup never detaches somebody else's entry.
struct InterposerDetour { PVOID* original{}; PVOID replacement{}; };
static std::array<InterposerDetour,24> g_interposerDetours{};
static size_t g_interposerDetourCount=0;
static bool HasInterposerDetour(PVOID* original)
{
    for(size_t i=0;i<g_interposerDetourCount;++i)
        if(g_interposerDetours[i].original==original)return true;
    return false;
}

class InterposerDetourTransaction
{
    // Detours transaction state is process-global. Share the same gate as the
    // common graphics hook installer while this custom attach batch is open.
    std::unique_lock<std::mutex> transactionLock{OptiShade::Detours::ProcessDetourTransactionMutex()};
    std::array<InterposerDetour,24> pending{};
    size_t count=0;
    std::vector<HANDLE> threadHandles;
    LONG result=NO_ERROR;
    bool active=false;
    const char* stage="begin";

    void CloseThreadHandles()
    {
        for(HANDLE thread:threadHandles)CloseHandle(thread);
        threadHandles.clear();
    }
public:
    InterposerDetourTransaction()
    {
        result=DetourTransactionBegin();active=result==NO_ERROR;
        if(active){stage="current thread";result=DetourUpdateThread(GetCurrentThread());}
        if(active&&result==NO_ERROR)
        {
            // A thread Windows will not let us open is skipped: otherwise one
            // protected thread stops every Streamline hook for the session.
            stage="process threads";
            try{result=OptiShade::Detours::EnlistCurrentProcessThreads(threadHandles,&deniedThreads);}
            catch(...){result=ERROR_NOT_ENOUGH_MEMORY;}
            if(result==NO_ERROR&&!deniedThreads.empty())
                LOG_WARN("Streamline hook: {} thread(s) could not be opened (access denied) and were not paused while hooking; first id {}",
                         deniedThreads.size(),deniedThreads.front());
        }
        if(active&&result!=NO_ERROR){DetourTransactionAbort();active=false;CloseThreadHandles();}
    }
    ~InterposerDetourTransaction(){if(active)DetourTransactionAbort();CloseThreadHandles();}
    std::vector<DWORD> deniedThreads;
    const char* Stage()const{return stage;}
    template<class F,class H> bool Attach(F& original,H replacement)
    {
        if(!original||result!=NO_ERROR)return false;
        if(count==pending.size()){result=ERROR_NOT_ENOUGH_MEMORY;return false;}
        auto slot=reinterpret_cast<PVOID*>(&original);
        auto hook=reinterpret_cast<PVOID>(replacement);
        stage="attach";
        result=DetourAttach(slot,hook);
        if(result!=NO_ERROR)return false;
        pending[count++]={slot,hook};return true;
    }
    LONG Commit()
    {
        if(!active)return result;
        active=false;
        if(result!=NO_ERROR){DetourTransactionAbort();CloseThreadHandles();return result;}
        stage="commit";
        result=DetourTransactionCommit();
        CloseThreadHandles();
        if(result==NO_ERROR){g_interposerDetours=pending;g_interposerDetourCount=count;}
        return result;
    }
};

static void ObserveAcceptedTagMode(InterposerTagMode mode,sl::Result result,uint32_t viewport)
{
    if(result!=sl::Result::eOk)return;
    if(mode==InterposerTagMode::Frame){
        const auto previous=g_interposerTagMode.exchange(mode,std::memory_order_acq_rel);
        if(previous==InterposerTagMode::Legacy)DlssNr::TaaFgInvalidate(viewport);
    }else{
        // An accepted frame-token API is never downgraded to legacy tags.
        auto expected=InterposerTagMode::Unknown;
        g_interposerTagMode.compare_exchange_strong(expected,mode,std::memory_order_acq_rel);
    }
}

static bool HasNullTaaFgResource(const sl::ResourceTag* tags, uint32_t count)
{
    if (!tags)
        return true;
    for (uint32_t i = 0; i < count; ++i)
    {
        const auto type = tags[i].type;
        const bool required = type == sl::kBufferTypeHUDLessColor ||
                              type == sl::kBufferTypeDepth ||
                              type == sl::kBufferTypeMotionVectors;
        if (required && (!tags[i].resource || !tags[i].resource->native))
            return true;
    }
    return false;
}

// OptiMFG's backend is a version.dll proxy in the game folder. This check runs
// when Streamline is first hooked, so it is an early module snapshot only; a
// missing game-folder module here does not prove that it never loads later.
static void LogOptiMfgBackendModule()
{
    static bool logged = false;
    if (logged)
        return;
    logged = true;
    wchar_t exe[MAX_PATH] {};
    if (!GetModuleFileNameW(nullptr, exe, MAX_PATH))
        return;
    const std::filesystem::path gameDir = std::filesystem::path(exe).parent_path();
    std::error_code ec;
    const bool inGameFolder = std::filesystem::exists(gameDir / L"version.dll", ec);
    std::vector<std::wstring> loadedVersionPaths;
    bool fromGame = false;
    bool enumerationSucceeded = false;
    const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, GetCurrentProcessId());
    if (snapshot != INVALID_HANDLE_VALUE)
    {
        MODULEENTRY32W module {};
        module.dwSize = sizeof(module);
        if (Module32FirstW(snapshot, &module))
        {
            enumerationSucceeded = true;
            do
            {
                if (_wcsicmp(module.szModule, L"version.dll") != 0)
                    continue;
                loadedVersionPaths.emplace_back(module.szExePath);
                const std::filesystem::path loadedPath(module.szExePath);
                if (CompareStringOrdinal(loadedPath.parent_path().c_str(), -1, gameDir.c_str(), -1, TRUE) == CSTR_EQUAL)
                    fromGame = true;
            } while (Module32NextW(snapshot, &module));
        }
        CloseHandle(snapshot);
    }

    std::string loadedPaths = "none";
    for (const auto& path : loadedVersionPaths)
    {
        if (loadedPaths == "none")
            loadedPaths.clear();
        else
            loadedPaths += "; ";
        loadedPaths += wstring_to_string(path);
    }
    LOG_INFO("OptiMFG backend check: version.dll in game folder={}; loaded version.dll module(s)={}; {}", inGameFolder,
             loadedPaths,
             fromGame ? "the game-folder backend is loaded"
             : !enumerationSucceeded ? "module enumeration failed; backend state is unknown"
             : inGameFolder ? "game-folder backend not observed in this Streamline-initialization snapshot; a later load is not ruled out"
                            : "no OptiMFG backend in the game folder");
}

static void PatchSL1PluginJson(nlohmann::json& configJson)
{
    if (!IsSL1AndDLSSGManaged())
        return;

    LOG_DEBUG("Patching SL1 plugin JSON for external FG management");

    if (configJson.contains("/hooks"_json_pointer))
        configJson["hooks"].clear();

    if (configJson.contains("/exclusive_hooks"_json_pointer))
        configJson["exclusive_hooks"].clear();

    if (configJson.contains("/external/feature/tags"_json_pointer))
        configJson["external"]["feature"]["tags"].clear();

    if (configJson.contains("/vsync/supported"_json_pointer))
        configJson["vsync"]["supported"] = true;

    if (configJson.contains("/external/hws/required"_json_pointer))
        configJson["external"]["hws"]["required"] = false;
}

char* StreamlineHooks::trimStreamlineLog(const char* msg)
{
    char* result = (char*) malloc(strlen(msg) + 1);
    if (!result)
        return nullptr;

    strcpy(result, msg);

    size_t length = strlen(result);
    if (length > 0 && result[length - 1] == '\n')
    {
        result[length - 1] = '\0';
    }

    return result;
}

void StreamlineHooks::streamlineLogCallback(sl::LogType type, const char* msg)
{
    if (msg == nullptr)
        return;

    char* trimmed_msg = trimStreamlineLog(msg);
    if (trimmed_msg != nullptr)
    {
        switch (type)
        {
        case sl::LogType::eWarn:
            LOG_WARN("{}", trimmed_msg);
            break;
        case sl::LogType::eInfo:
            LOG_INFO("{}", trimmed_msg);
            break;
        case sl::LogType::eError:
            LOG_ERROR("{}", trimmed_msg);
            break;
        case sl::LogType::eCount:
            LOG_ERROR("{}", trimmed_msg);
            break;
        }

        free(trimmed_msg);
    }

    if (o_logCallback != nullptr)
        o_logCallback(type, msg);
}

sl::Result StreamlineHooks::hkslInit(const sl::Preferences& pref, uint64_t sdkVersion)
{
    static thread_local bool inStreamlineInit = false;
    if (inStreamlineInit)
    {
        LOG_ERROR("Prevented recursive Streamline slInit callback; returning an error instead of overflowing the game stack");
        return sl::Result::eErrorExceptionHandler;
    }
    inStreamlineInit = true;
    struct InitRecursionReset { bool& value; ~InitRecursionReset() { value = false; } } reset{ inStreamlineInit };

    LOG_FUNC();

    if (State::Instance().externalFrameGeneration) {
        return o_slInit(pref,sdkVersion);
    }
    State::Instance().dlssgCapabilities.Reset();
    sl::Preferences localPref = pref;

    const auto& nativeVersion = State::Instance().streamlineVersion;
    const bool gamePluginsOnly = OptiShadeStreamlinePolicy::ApplyNativePolicy(
        Util::ExePath().filename().wstring(), nativeVersion.major, nativeVersion.minor, localPref);
    g_interposerTagMode.store(
        (static_cast<uint64_t>(localPref.flags) &
         static_cast<uint64_t>(sl::PreferenceFlags::eUseFrameBasedResourceTagging)) != 0
            ? InterposerTagMode::Frame : InterposerTagMode::Legacy,
        std::memory_order_release);
    if (gamePluginsOnly)
    {
        // Keep the game's interposer and plugins together. Old MSFS 2020
        // interposers do not implement all hooks advertised by newer OTA plugins.
        LOG_INFO("MSFS2020 native Streamline compatibility: game plugin paths preserved; OTA download/load disabled; sdk:{} flags:{}->{} paths:{} features:{}",
                 sdkVersion, static_cast<uint64_t>(pref.flags), static_cast<uint64_t>(localPref.flags),
                 pref.numPathsToPlugins, pref.numFeaturesToLoad);
    }

    if (localPref.logMessageCallback != &streamlineLogCallback)
        o_logCallback = localPref.logMessageCallback;
    localPref.logLevel = sl::LogLevel::eCount;
    localPref.logMessageCallback = &streamlineLogCallback;

    // renderAPI is optional so need to be careful, should only matter for Vulkan
    renderApi = localPref.renderAPI;

    State::Instance().slFGInputs.reportEngineType(localPref.engine);

    // Treat engine type set in Streamline as ground truth
    if (localPref.engine == sl::EngineType::eUnreal)
        State::Instance().gameQuirks |= GameQuirk::ForceUnrealEngine;

    std::filesystem::path localSlPath(Config::Instance()->MainDllPath.value());
    localSlPath = localSlPath / L"streamline"; // Hardcoded streamline folder

    auto localSlPathStr = localSlPath.wstring();

    std::vector<const wchar_t*> storage;

    // Replace the SL files to allow for MFG
    if (!gamePluginsOnly && State::Instance().activeFgInput == FGInput::NvngxFG && std::filesystem::exists(localSlPath / L"sl.common.dll"))
    {
        storage.assign(localPref.pathsToPlugins, localPref.pathsToPlugins + localPref.numPathsToPlugins);

        std::filesystem::path pluginsDir;

        // Find the first path that contains sl.common.dll
        // If storage is empty, look in the exe folder. pathsToPlugins is an optional field
        if (storage.empty())
        {
            std::filesystem::path exeFolder = Util::ExePath().parent_path();
            if (std::filesystem::exists(exeFolder / L"sl.common.dll"))
            {
                pluginsDir = exeFolder;
            }
        }
        else
        {
            for (const wchar_t* pathStr : storage)
            {
                if (!pathStr)
                    continue;

                std::filesystem::path p = pathStr;
                if (std::filesystem::exists(p / L"sl.common.dll"))
                {
                    pluginsDir = p;
                    break;
                }
            }
        }

        std::vector<std::string> missingDlls;
        bool hasNewerPlugin = false;

        // If we found the plugins folder, scan its contents
        if (!pluginsDir.empty() && std::filesystem::exists(pluginsDir))
        {
            for (const auto& entry : std::filesystem::directory_iterator(pluginsDir))
            {
                if (!entry.is_regular_file())
                    continue;

                std::wstring filename = entry.path().filename().wstring();

                std::wstring lowerName = filename;
                to_lower_in_place(lowerName);

                // Skip interposer
                if (lowerName == L"sl.interposer.dll")
                    continue;

                const bool isSlDll = lowerName.starts_with(L"sl.") && lowerName.ends_with(L".dll");
                const bool isNvLowLatency = lowerName == L"nvlowlatencyvk.dll";

                if (isSlDll || isNvLowLatency)
                {
                    std::filesystem::path localDllPath = localSlPath / filename;

                    // Check if localSlPath also has this DLL
                    if (!std::filesystem::exists(localDllPath))
                    {
                        missingDlls.push_back(entry.path().filename().string());
                    }
                    else
                    {
                        // Compare versions
                        version_t pluginVer, pluginProdVer;
                        version_t localVer, localProdVer;

                        bool gotPluginVer = Util::GetFileVersion(entry.path().wstring(), &pluginVer, &pluginProdVer);
                        bool gotLocalVer = Util::GetFileVersion(localDllPath.wstring(), &localVer, &localProdVer);

                        if (gotPluginVer && gotLocalVer)
                        {
                            if (localVer > pluginVer)
                            {
                                hasNewerPlugin = true;
                            }
                        }
                    }
                }
            }
        }

        // Insert local path only if a newer plugin was found
        if (hasNewerPlugin)
        {
            LOG_DEBUG("Making the game use local streamline files");

            storage.insert(storage.begin(), localSlPathStr.c_str());
            localPref.pathsToPlugins = storage.data();
            localPref.numPathsToPlugins = (uint32_t) storage.size();

            if (!missingDlls.empty())
            {
                std::string toastMsg = "You are missing the following dlls from the streamline folder:\n";
                for (const auto& missingDll : missingDlls)
                {
                    toastMsg += "- " + missingDll + "\n";
                }

                ImGui::InsertNotification({ ImGuiToastType::Warning, 20000, toastMsg.c_str() });
            }
        }
    }

    if (State::Instance().activeFgInput == FGInput::DLSSG || State::Instance().activeFgOutput == FGOutput::DLSSG)
    {
        std::vector<sl::Feature> localFeaturesToLoad(pref.featuresToLoad, pref.featuresToLoad + pref.numFeaturesToLoad);
        std::erase(localFeaturesToLoad, sl::kFeatureDLSS_G);

        localPref.featuresToLoad = localFeaturesToLoad.data();
        localPref.numFeaturesToLoad = (uint32_t) localFeaturesToLoad.size();

        // return so that localFeaturesToLoad is valid
        return o_slInit(localPref, sdkVersion);
    }

    // bool hookSetTag =
    //     (State::Instance().activeFgInput == FGInput::NvngxFG || State::Instance().activeFgInput == FGInput::DLSSG);

    // if (hookSetTag)
    //     localPref->flags &= ~(sl::PreferenceFlags::eAllowOTA | sl::PreferenceFlags::eLoadDownloadedPlugins);


    return o_slInit(localPref, sdkVersion);
}

sl::Result StreamlineHooks::hkslIsFeatureSupported(sl::Feature feature, const sl::AdapterInfo& adapterInfo)
{
    if (feature == sl::kFeatureDLSS_G)
        return sl::Result::eOk;

    return o_slIsFeatureSupported(feature, adapterInfo);
}

sl::Result StreamlineHooks::hkslIsFeatureLoaded(sl::Feature feature, bool& loaded)
{
    if (feature == sl::kFeatureDLSS_G)
    {
        loaded = true;
        return sl::Result::eOk;
    }

    return o_slIsFeatureLoaded(feature, loaded);
}

sl::Result StreamlineHooks::hkslGetFeatureRequirements(sl::Feature feature, sl::FeatureRequirements& requirements)
{
    if (feature == sl::kFeatureDLSS_G)
        return sl::Result::eOk;

    return o_slGetFeatureRequirements(feature, requirements);
}

sl::Result StreamlineHooks::hkslGetFeatureVersion(sl::Feature feature, sl::FeatureVersion& version)
{
    if (feature == sl::kFeatureDLSS_G)
    {
        version.versionSL = { State::Instance().streamlineVersion.major, State::Instance().streamlineVersion.minor,
                              State::Instance().streamlineVersion.patch };
        version.versionNGX = { 4, 2, 0 };

        return sl::Result::eOk;
    }

    return o_slGetFeatureVersion(feature, version);
}

static sl::Result dummy_slDLSSGGetState(const sl::ViewportHandle& viewport, sl::DLSSGState& state,
                                        const sl::DLSSGOptions* options)
{
    return optishade::native_mfg::DummyState(state);
}

static sl::Result dummy_slDLSSGSetOptions(const sl::ViewportHandle& viewport, const sl::DLSSGOptions& options)
{
    return sl::Result::eOk;
}

sl::Result StreamlineHooks::ResolveExternal(sl::Feature feature,const char* name,void*& function){
 function=nullptr;if(!o_slGetFeatureFunction||!hookedInterposerModule)return sl::Result::eErrorFeatureMissing;
 HMODULE pin=nullptr;if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(hookedInterposerModule),&pin))return sl::Result::eErrorFeatureMissing;
 const auto result=o_slGetFeatureFunction(feature,name,function);FreeLibrary(pin);return result;
}
sl::Result StreamlineHooks::ExternalOptions(const sl::ViewportHandle& view,const sl::DLSSGOptions& options){
 if(dlssgStateProviderFaulted.load(std::memory_order_acquire))return sl::Result::eErrorExceptionHandler;
 optishade::external_fg::Target<decltype(&slDLSSGSetOptions)> target(ResolveExternal,sl::kFeatureDLSS_G,"slDLSSGSetOptions");
 if(!target.function)return sl::Result::eErrorFeatureMissing;
 auto& control=optishade::native_mfg::Session();
 auto request=control.ForCall(target.NativeIdentity(),static_cast<uint32_t>(view));
 // Only the external EXE may override when its component owns this route.
 if(State::Instance().optiMfgExternalController){request.desired=-1;request.dynamic=false;}
 sl::DLSSGOptions changed{};const sl::DLSSGOptions* sent=&options;
 // Preserve the game's ABI and extension chain for this synchronous call.
 // Unknown layouts pass through unchanged and cannot receive an OptiShade override.
 if(request.desired>=0){
  if(!optishade::streamline_options::CopyKnownDlssgOptions(options,changed)){
   const auto result=optishade::native_mfg::InvokeProviderCallDirect([&]{return target.function(view,options);});
   if(!State::Instance().optiMfgExternalController)control.Complete(request,0,static_cast<int>(sl::Result::eErrorInvalidParameter));
   LOG_WARN("Native MFG request refused: unsupported DLSS-G options structure type/version {}",options.structVersion);
   return result;
  }
  if(request.desired==0)changed.mode=sl::DLSSGMode::eOff;
  else if(request.desired>0&&request.desired<=int(request.maximum)){
   // Match the native provider path: an explicit saved OptiShade request can
   // enable frame generation even when the game's options packet is Off.
   changed.mode=sl::DLSSGMode::eOn;changed.numFramesToGenerate=static_cast<uint32_t>(request.desired);
  }
  sent=&changed;
 }
 const auto result=optishade::native_mfg::InvokeProviderCallDirect([&]{return target.function(view,*sent);});
 sl::DLSSGOptions observed{};
 if(!optishade::streamline_options::CopyKnownDlssgOptions(*sent,observed))return result;
 if(!State::Instance().optiMfgExternalController)control.Complete(request,sent->mode==sl::DLSSGMode::eOff?0:sent->numFramesToGenerate,int(result));
 if(result==sl::Result::eOk){
  auto& state=State::Instance();state.dlssgLastSetMode=sent->mode;
  // Off can retain the previous count in the game's options struct. It is not
  // an accepted generation request; dynamic mode likewise has no fixed count.
  const uint64_t count=sent->structVersion>=1&&sent->mode!=sl::DLSSGMode::eDynamic&&sent->mode!=sl::DLSSGMode::eOff?sent->numFramesToGenerate:0;
  state.dlssgTemporalSignature.store(sent->mode==sl::DLSSGMode::eOff?0:(uint64_t(sent->mode)<<32)|count,std::memory_order_relaxed);
  const auto telemetry=optishade::external_fg_telemetry::Session().RecordAcceptedOptions(
   static_cast<uint32_t>(sent->mode),count);
  optishade::session::State().Put({
   {"FGControlPath","External resolved DLSS-G callback"},
   {"FGOptionsAcceptedMode",std::string(magic_enum::enum_name(sent->mode))},
   {"FGOptionsAcceptedAdditionalFrames",std::to_string(count)},
   {"FGOptionsMaxAcceptedAdditionalFramesThisRun",std::to_string(telemetry.maxAcceptedAdditionalFrames)},
   {"FGMode","External resolved mode="+std::to_string(unsigned(sent->mode))+" viewport="+std::to_string(static_cast<uint32_t>(view))+" acceptedAdditionalFrames="+std::to_string(count)}});
 }
 return result;
}
sl::Result StreamlineHooks::PassiveState(const sl::ViewportHandle& view,sl::DLSSGState& state,const sl::DLSSGOptions* options){
 const auto callerSite=DlssgCallerSite(_ReturnAddress());
 const auto stateCall=optishade::external_fg_telemetry::Session().RecordStateCall(GetCurrentThreadId(),GetTickCount64());
 optishade::external_fg::Target<decltype(&slDLSSGGetState)> target(ResolveExternal,sl::kFeatureDLSS_G,"slDLSSGGetState");
 if(!target.function){
  if(optishade::external_fg_telemetry::Session().ShouldPersistBlockedState(GetTickCount64(),3))
   optishade::session::State().PutCritical({
    {"FGStateQueryStage","Passive provider function unavailable"},{"FGStateResult","eErrorFeatureMissing"},
    {"FGControlPath","Passive DLSS-G observer"},{"FGProviderFunctionAvailable","No"},
    {"FGStateCallerModule",callerSite.first},{"FGStateCallerModuleOffset",callerSite.second},
    {"FGStateCallerThreadId",std::to_string(stateCall.lastStateThreadId)},
    {"FGStateQueryCount",std::to_string(stateCall.stateQueryCount)},
    {"FGStateAgeSincePresentMs",stateCall.hasPresentSample?std::to_string(stateCall.lastStateAgeSincePresentMs):"Unknown"},
    {"FGPresentSampleSource","Streamline provider Present boundary"},
    {"FGPresentCallerThreadId",stateCall.hasPresentSample?std::to_string(stateCall.lastPresentThreadId):"Unknown"},
    {"FGStateThreadMatchesLastPresent",stateCall.hasPresentSample?(stateCall.lastStateThreadMatchesPresent?"Yes":"No"):"Unknown"},
    {"FGPresentCallCount",std::to_string(stateCall.presentCallCount)}});
  optishade::runtime_render::State().NativeUnavailable("Provider function unavailable");return sl::Result::eErrorFeatureMissing;
 }
 if(dlssgStateProviderFaulted.load(std::memory_order_acquire)){
  optishade::runtime_render::State().NativeUnavailable("Provider query disabled after contained fault");
  optishade::session::State().Put({{"FGStateQueryStage","Provider query disabled after contained fault"},{"FGStateResult","eErrorExceptionHandler"}});
  return sl::Result::eErrorExceptionHandler;
 }
 optishade::native_mfg::StateQueryEvidence evidence;
 optishade::native_mfg::GuardedStateCall providerFailure{};
 const auto guardedProviderCall=[&](const sl::ViewportHandle& queryView,sl::DLSSGState& queryState,const sl::DLSSGOptions* queryOptions){
  const auto outcome=optishade::native_mfg::InvokeGetStateGuarded(target.function,queryView,queryState,queryOptions,&dlssgStateProviderFaulted);
  if(outcome.exceptionCode)providerFailure=outcome;
  return outcome.result;
 };
 // Observe the call the game actually made. No ABI promotion, retries, extra
 // queries, resource/fence consumption, options edits or provider activation.
 const auto result=optishade::native_mfg::QueryNativeStateOnce(guardedProviderCall,false,view,state,options,evidence);
 if(providerFailure.exceptionCode)RecordDlssGStateProviderFault("Passive DLSS-G observer",providerFailure);
 if(result==sl::Result::eOk&&evidence.stateKnown&&target.NativeIdentity()){
  auto& control=optishade::native_mfg::Session();control.Observe(target.NativeIdentity(),static_cast<uint32_t>(view),evidence.maximum,false,evidence.dynamicKnown,evidence.dynamicSupported);
  const auto caps=control.Read();
  optishade::runtime_render::State().NativeState(target.NativeIdentity(),caps.generation,static_cast<uint32_t>(view),evidence.providerFramesPresented,GetTickCount64(),true);
 }else optishade::runtime_render::State().NativeUnavailable();
 return result;
}
// MSFS initialises Streamline before OptiShade hooks it, so slInit never
// reports the API; the game's own D3D12 swapchain settles it. The tag hooks
// used this since R331 (OSD-6K6T, OSD-22P4), but the pre-FG prepare, provider
// Present and inputs-consumed paths still required slInit's API, so TAA NR ran
// only while the game's frame generation was paused (OSD-AFZJ: unfocused).
static sl::RenderAPI EffectiveRenderApi(sl::RenderAPI api)
{
    return api == sl::RenderAPI::eCount && State::Instance().swapchainApi == DX12 ? sl::RenderAPI::eD3D12 : api;
}
// EffectiveRenderApi opened the pre-FG marker and provider Present paths to every
// OptiMFG session from R342: DLSS NR sessions that never use TAA ran them on the
// game's present and marker calls each frame, including a session file update
// that can write to disk. R327 did the same and froze MSFS on R330. The R348
// freezes (OSD-VHTX, KCF5, ZXRV, CHMG: DLSS NR with OptiMFG; R336 is clean) fit
// that again. Stay out until TAA NR has run, and while it is selected.
namespace DlssNr { bool TaaPreFgUsed(); }
extern "C" bool OptiShadeTaaRequested();
static bool TaaPreFgRouteLive()
{
    return DlssNr::TaaPreFgUsed() && OptiShadeTaaRequested();
}
sl::Result StreamlineHooks::ExternalState(const sl::ViewportHandle& view,sl::DLSSGState& state,const sl::DLSSGOptions* options){
 const auto callerSite=DlssgCallerSite(_ReturnAddress());
 optishade::external_fg::Target<decltype(&slDLSSGGetState)> target(ResolveExternal,sl::kFeatureDLSS_G,"slDLSSGGetState");
 if(!target.function){
  const auto stateCall=optishade::external_fg_telemetry::Session().RecordStateCall(GetCurrentThreadId(),GetTickCount64());
  if(optishade::external_fg_telemetry::Session().ShouldPersistBlockedState(GetTickCount64(),4))
   optishade::session::State().PutCritical({
    {"FGStateQueryStage","External provider function unavailable"},{"FGStateResult","eErrorFeatureMissing"},
    {"FGControlPath","External resolved DLSS-G callback"},{"FGProviderFunctionAvailable","No"},
    {"FGStateCallerModule",callerSite.first},{"FGStateCallerModuleOffset",callerSite.second},
    {"FGStateCallerThreadId",std::to_string(stateCall.lastStateThreadId)},
    {"FGStateQueryCount",std::to_string(stateCall.stateQueryCount)},
    {"FGStateAgeSincePresentMs",stateCall.hasPresentSample?std::to_string(stateCall.lastStateAgeSincePresentMs):"Unknown"},
    {"FGPresentSampleSource","Streamline provider Present boundary"},
    {"FGPresentCallerThreadId",stateCall.hasPresentSample?std::to_string(stateCall.lastPresentThreadId):"Unknown"},
    {"FGPresentSwapchainId",stateCall.hasPresentSample?std::to_string(stateCall.lastPresentSwapchainId):"Unknown"},
    {"FGStateThreadMatchesLastPresent",stateCall.hasPresentSample?(stateCall.lastStateThreadMatchesPresent?"Yes":"No"):"Unknown"},
    {"FGPresentCallCount",std::to_string(stateCall.presentCallCount)}});
  optishade::runtime_render::State().NativeUnavailable("Provider function unavailable");
  return sl::Result::eErrorFeatureMissing;
 }
 const auto identity=target.NativeIdentity();
 const auto stateCall=optishade::external_fg_telemetry::Session().RecordStateCall(GetCurrentThreadId(),GetTickCount64());
 const bool threadMismatch=stateCall.hasPresentSample&&!stateCall.lastStateThreadMatchesPresent;
 const auto persistCallEvidence=[&](const char* stage,const char* result){
  const std::initializer_list<std::pair<const std::string,std::string>> values={
   {"FGStateQueryStage",stage},{"FGStateResult",result},
   {"FGStateCallerThreadId",std::to_string(stateCall.lastStateThreadId)},
   {"FGStateQueryCount",std::to_string(stateCall.stateQueryCount)},
   {"FGStateIntervalMs",stateCall.hasStateInterval?std::to_string(stateCall.lastStateIntervalMs):"Unknown"},
   {"FGStateAgeSincePresentMs",stateCall.hasPresentSample?std::to_string(stateCall.lastStateAgeSincePresentMs):"Unknown"},
   {"FGStateCallerModule",callerSite.first},{"FGStateCallerModuleOffset",callerSite.second},
   {"FGPresentSampleSource","Streamline provider Present boundary"},
   {"FGPresentCallerThreadId",stateCall.hasPresentSample?std::to_string(stateCall.lastPresentThreadId):"Unknown"},
   {"FGPresentSwapchainId",stateCall.hasPresentSample?std::to_string(stateCall.lastPresentSwapchainId):"Unknown"},
   {"FGStateThreadMatchesLastPresent",stateCall.hasPresentSample?(stateCall.lastStateThreadMatchesPresent?"Yes":"No"):"Unknown"},
   {"FGPresentCallCount",std::to_string(stateCall.presentCallCount)},
   {"FGPresentCallCountAtStateQuery",std::to_string(stateCall.presentCallCountAtLastState)}};
  if(!stateCall.hasPresentSample||threadMismatch||strcmp(stage,"Provider call pending")==0||strcmp(stage,"Provider access violation contained")==0)
   optishade::session::State().PutCritical(values);
  else optishade::session::State().Put(values);
 };
 // Streamline requires DLSS-G GetState to be synchronized with Present. A
 // pending query before the first observed Present, or from a different
 // thread, must not enter the provider: tester dumps show that this can crash
 // inside sl.dlss_g.dll before the callback returns.
 if(!stateCall.hasPresentSample||threadMismatch){
  const char* reason=stateCall.hasPresentSample?"Provider query skipped: caller is not synchronized with Present":"Provider query skipped: no Present thread has been observed";
  const uint32_t skipReason=stateCall.hasPresentSample?2u:1u;
  if(optishade::external_fg_telemetry::Session().ShouldPersistBlockedState(GetTickCount64(),skipReason))
   persistCallEvidence(reason,"eErrorFeatureMissing");
  optishade::runtime_render::State().NativeUnavailable(reason);
  return sl::Result::eErrorFeatureMissing;
 }
 if(dlssgStateProviderFaulted.load(std::memory_order_acquire)){
  persistCallEvidence("Provider query disabled after contained fault","eErrorExceptionHandler");
  optishade::runtime_render::State().NativeUnavailable();
  return sl::Result::eErrorExceptionHandler;
 }
 // The provider can fault before returning. Capture a rare thread mismatch
 // durably before entering that call so the crash report retains its trigger.
 persistCallEvidence("Provider call pending","Pending");
 optishade::native_mfg::StateQueryEvidence evidence;
 optishade::native_mfg::GuardedStateCall providerFailure{};
 const auto guardedProviderCall=[&](const sl::ViewportHandle& queryView,sl::DLSSGState& queryState,const sl::DLSSGOptions* queryOptions){
  const auto outcome=optishade::native_mfg::InvokeGetStateGuarded(target.function,queryView,queryState,queryOptions,&dlssgStateProviderFaulted);
  if(outcome.exceptionCode)providerFailure=outcome;
  return outcome.result;
 };
 // This is a read-only observer of the game's external provider. Preserve the
 // exact caller ABI and issue exactly one provider query: retrying a rejected
 // promoted query can consume provider state twice, and Streamline requires
 // GetState synchronization with its present thread for fence-bearing state.
 const auto result=optishade::native_mfg::QueryNativeStateOnce(guardedProviderCall,identity!=0,view,state,options,evidence,1);
 if(providerFailure.exceptionCode){
  persistCallEvidence("Provider access violation contained","0xC0000005");
  RecordDlssGStateProviderFault("External DLSS-G observer",providerFailure);
  optishade::runtime_render::State().NativeUnavailable();
  return result;
 }
 // This qualified external delegate exposes fixed/off/follow overrides only.
 // The game's reported Dynamic support remains untouched in its state result;
 // it does not grant an OptiShade Dynamic request without a matching setter.
 optishade::native_mfg::Session().Observe(target.NativeIdentity(),static_cast<uint32_t>(view),evidence.maximum,true,true,false);
 // Streamline exposes this fence as an opaque pointer. The native NR lease
 // tracker below is D3D12-only and dereferences it as ID3D12Fence; Vulkan may
 // provide a semaphore or another API-owned object here, so never cross APIs.
 if(EffectiveRenderApi(renderApi)==sl::RenderAPI::eD3D12&&result==sl::Result::eOk&&evidence.stateKnown&&state.structVersion>=3&&state.structVersion<=4)
  DlssNr::TaaFgInputsConsumed(static_cast<uint32_t>(view),static_cast<ID3D12Fence*>(state.inputsProcessingCompletionFence),state.lastPresentInputsProcessingCompletionFenceValue);
 const auto caps=optishade::native_mfg::Session().Read();
 if(result==sl::Result::eOk&&evidence.stateKnown&&identity)
  optishade::runtime_render::State().NativeState(identity,caps.generation,static_cast<uint32_t>(view),evidence.providerFramesPresented,GetTickCount64());
 else optishade::runtime_render::State().NativeUnavailable();
 const auto frameSample=result==sl::Result::eOk&&evidence.stateKnown
  ?optishade::external_fg_telemetry::Session().RecordStateSample(evidence.providerFramesPresented)
  :optishade::external_fg_telemetry::Session().Read();
 optishade::session::State().PutResolvedProviderCall({
  {"FGStateQueryStage","Provider call completed"},
  {"FGStateResult",std::to_string(static_cast<int>(result))},
  {"FGStateQueryCount",std::to_string(stateCall.stateQueryCount)},
  {"FGControlPath","External resolved DLSS-G callback"},
  {"FGStateQuery",identity?"Native provider identified":"Resolved provider outside native-control identity; no native override"},
  {"FGStateCallerThreadId",std::to_string(stateCall.lastStateThreadId)},
  {"FGStateQueryCount",std::to_string(stateCall.stateQueryCount)},
  {"FGStateIntervalMs",stateCall.hasStateInterval?std::to_string(stateCall.lastStateIntervalMs):"Unknown"},
  {"FGStateAgeSincePresentMs",stateCall.hasPresentSample?std::to_string(stateCall.lastStateAgeSincePresentMs):"Unknown"},
  {"FGPresentSampleSource","Streamline provider Present boundary"},
  {"FGPresentCallerThreadId",stateCall.hasPresentSample?std::to_string(stateCall.lastPresentThreadId):"Unknown"},
  {"FGPresentSwapchainId",stateCall.hasPresentSample?std::to_string(stateCall.lastPresentSwapchainId):"Unknown"},
  {"FGStateThreadMatchesLastPresent",stateCall.hasPresentSample?(stateCall.lastStateThreadMatchesPresent?"Yes":"No"):"Unknown"},
  {"FGPresentCallCount",std::to_string(stateCall.presentCallCount)},
  {"FGPresentCallCountAtStateQuery",std::to_string(stateCall.presentCallCountAtLastState)},
  {"FGStateCallerVersion",std::to_string(evidence.callerVersion)},
  {"FGStateExtendedQuery",evidence.promoted?"Yes":"No"},
  {"FGStateResult",std::to_string(static_cast<int>(result))},
  {"FGStateReportedMaximum",std::to_string(evidence.maximum)},
  {"FGProviderMaxFramesPerStateIntervalThisRun",std::to_string(frameSample.maxFramesSinceStateQuery)},
  {"FGOutputVerification",result==sl::Result::eOk?"Provider-reported presentation count only; scanout not observed":"No successful provider state sample; scanout not observed"},
  {"FGCapabilityKnown",caps.known?"Yes":"No"},{"FGSupportedAdditionalFrames",caps.known?std::to_string(caps.maximum):"Unknown"},{"FGOverrideAdditionalFrames",std::to_string(caps.desired)},{"FGWithdrawnAdditionalFrames",std::to_string(caps.withdrawn)},{"FGDisplayedFrames","Unknown - scanout not observed"}});
 return result;
}
void StreamlineHooks::ExternalPrepare(const sl::FrameToken& frame){
 if(!TaaPreFgRouteLive())return;
 const auto tagMode=g_interposerTagMode.load(std::memory_order_acquire);
 if(tagMode==InterposerTagMode::Unknown)return;
 if(tagMode==InterposerTagMode::Legacy&&optishade::native_fg_boundary::ready.load())return;
 if(EffectiveRenderApi(renderApi)!=sl::RenderAPI::eD3D12)return;
 optishade::session::State().Put({{"API","D3D12"},{"LastPresentStartToken",std::to_string(static_cast<uint32_t>(frame))}});
 sl::ResourceTag processed[4];uint32_t view=0,producer=0;
 const bool frameBased=tagMode==InterposerTagMode::Frame;
 if(DlssNr::TaaFgPrepare(static_cast<uint32_t>(frame),!frameBased,processed,view,producer)){
  const auto inputs=optishade::taa::ReplacementInputTags(processed);
  const sl::ViewportHandle viewport(view);auto result=sl::Result::eErrorFeatureMissing;
  if(frameBased){if(o_slSetTagForFrame)result=o_slSetTagForFrame(frame,viewport,inputs.data(),static_cast<uint32_t>(inputs.size()),nullptr);}
  else if(o_slSetTag)result=o_slSetTag(viewport,inputs.data(),static_cast<uint32_t>(inputs.size()),nullptr);
  DlssNr::TaaFgTagsAccepted(producer,view,result==sl::Result::eOk);
 }
}
void StreamlineHooks::NativeProviderPresentBegin(IDXGISwapChain* swap){
 optishade::mfg::source::ObservePresent(swap);
 const auto presentTelemetry=swap?optishade::external_fg_telemetry::Session().RecordPresentCall(
  GetCurrentThreadId(),GetTickCount64(),reinterpret_cast<uintptr_t>(swap)):
  optishade::external_fg_telemetry::Session().Read();
 if(!swap||g_legacyProviderPresent||g_interposerTagMode.load(std::memory_order_acquire)!=InterposerTagMode::Legacy||
    EffectiveRenderApi(renderApi)!=sl::RenderAPI::eD3D12||!optishade::route::ExternalFgObserver()||!TaaPreFgRouteLive())return;
 // TaaFgProviderPrepare may bind providerSwap even when no replacement is
 // ready. Its matching completion is still required if a callback changes
 // device/tag mode while the provider's real Present is running.
 g_legacyProviderPresent=swap;
 optishade::session::State().Put({{"API","D3D12"},
  {"FGPresentCallerThreadId",State::Instance().externalFrameGeneration?std::to_string(presentTelemetry.lastPresentThreadId):"Not applicable"},
  {"FGPresentCallCount",std::to_string(presentTelemetry.presentCallCount)}});
 sl::ResourceTag tags[4];uint32_t view=0,producer=0;
 if(DlssNr::TaaFgProviderPrepare(swap,tags,view,producer)){
  const auto inputs=optishade::taa::ReplacementInputTags(tags);
  const auto result=o_slSetTag?o_slSetTag(sl::ViewportHandle(view),inputs.data(),static_cast<uint32_t>(inputs.size()),nullptr):sl::Result::eErrorFeatureMissing;
  DlssNr::TaaFgTagsAccepted(producer,view,result==sl::Result::eOk);
  DlssNr::TaaFgProviderCommit(swap);
 }
}
void StreamlineHooks::NativeProviderPresentEnd(IDXGISwapChain* swap,HRESULT result){
 if(!swap||g_legacyProviderPresent!=swap)return;
 g_legacyProviderPresent=nullptr;
 DlssNr::TaaFgPresentResult(swap,result);
}
sl::Result StreamlineHooks::ExternalPcl(sl::PCLMarker marker,const sl::FrameToken& frame){
 static std::atomic_bool logged{false};
 if(!logged.exchange(true))LOG_INFO("Streamline PCL markers observed: first marker={} frame={}",static_cast<uint32_t>(marker),static_cast<uint32_t>(frame));
 return optishade::external_fg::Marker(ResolveExternal,sl::kFeaturePCL,"slPCLSetMarker",marker,frame,ExternalPrepare,[](const auto& f,sl::Result){DlssNr::TaaFgPresentReturned(static_cast<uint32_t>(f));});
}
sl::Result StreamlineHooks::ExternalReflex(sl::PCLMarker marker,const sl::FrameToken& frame){
 return optishade::external_fg::Marker(ResolveExternal,sl::kFeatureReflex,"slReflexSetMarker",marker,frame,ExternalPrepare,[](const auto& f,sl::Result){DlssNr::TaaFgPresentReturned(static_cast<uint32_t>(f));});
}

sl::Result StreamlineHooks::hkslGetFeatureFunction(sl::Feature feature, const char* functionName, void*& function)
{
    static thread_local bool inFeatureFunctionLookup = false;
    if (inFeatureFunctionLookup)
    {
        function = nullptr;
        LOG_ERROR("Prevented recursive Streamline slGetFeatureFunction callback for '{}'; returning feature-missing instead of overflowing the game stack",
                  functionName ? functionName : "(null)");
        return sl::Result::eErrorFeatureMissing;
    }
    inFeatureFunctionLookup = true;
    struct FeatureLookupRecursionReset { bool& value; ~FeatureLookupRecursionReset() { value = false; } } reset{ inFeatureFunctionLookup };

    // Once per function: which Streamline calls the game resolves, and whether
    // OptiShade observes them. The pre-FG TAA route depends on these.
    const auto noteLookup=[&](const char* handling){
        static std::mutex lock;static std::set<std::string> seen;
        const std::string key=std::to_string(static_cast<uint32_t>(feature))+":"+(functionName?functionName:"(null)");
        std::lock_guard guard(lock);
        if(seen.size()<64&&seen.insert(key).second)
            LOG_INFO("Streamline feature lookup: feature={} function={} handling={}",static_cast<uint32_t>(feature),functionName?functionName:"(null)",handling);
    };
    if(passiveInterposer){
        noteLookup("passive observer");
        const auto result=ResolveExternal(feature,functionName,function);
        if(result==sl::Result::eOk&&function&&functionName&&feature==sl::kFeatureDLSS_G&&strcmp(functionName,"slDLSSGGetState")==0)
            function=reinterpret_cast<void*>(&PassiveState);
        return result;
    }
    if(optishade::external_fg::NativeProviderObserver(State::Instance().externalFrameGeneration,optishade::route::ExternalFgObserver(),State::Instance().activeFgInput==FGInput::DLSSG)){
        const auto result=ResolveExternal(feature,functionName,function);
        if(result!=sl::Result::eOk||!function||!functionName||!optishade::route::ExternalFgObserver())return result;
        // OptiMFG owns DLSS-G control through its own injected helper and IPC.
        // Do not put OptiShade's guarded observer wrappers between MSFS and the
        // provider: MSFS also queries GetState while building its native
        // multiplier picker, and withholding an unsynchronized query leaves
        // that picker empty. The helper independently hooks the resolved
        // provider callbacks and keeps its request path intact.
        if((State::Instance().optiMfgExternalController||State::Instance().nativeGameFrameGeneration)&&feature==sl::kFeatureDLSS_G&&
           (strcmp(functionName,"slDLSSGSetOptions")==0||strcmp(functionName,"slDLSSGGetState")==0)){
            noteLookup(State::Instance().optiMfgExternalController?"native, not observed (OptiMFG controls DLSS-G)":"native, not observed (game frame generation)");
            return result;
        }
        noteLookup("observed wrapper where available");
        if(feature==sl::kFeatureDLSS_G&&strcmp(functionName,"slDLSSGSetOptions")==0)function=reinterpret_cast<void*>(&ExternalOptions);
        else if(feature==sl::kFeatureDLSS_G&&strcmp(functionName,"slDLSSGGetState")==0)function=reinterpret_cast<void*>(&ExternalState);
        else if(feature==sl::kFeaturePCL&&strcmp(functionName,"slPCLSetMarker")==0)function=reinterpret_cast<void*>(&ExternalPcl);
        else if(feature==sl::kFeatureReflex&&strcmp(functionName,"slReflexSetMarker")==0)function=reinterpret_cast<void*>(&ExternalReflex);
        return result;
    }

    noteLookup(feature==sl::kFeatureDLSS_G?"managed DLSS-G":"native");
    if (feature == sl::kFeatureDLSS_G)
    {
        if (functionName && strcmp(functionName, "slDLSSGGetState") == 0 && o_slGetFeatureFunction)
        {
            // Read-only capability discovery for routes where native DLSS-G is
            // deliberately not exposed to the game. Preserve the existing
            // dummy function returned below; never call the provider or enable
            // a compatibility backend from this probe.
            optishade::passive_fg::ProbeStateFunction(
                sl::Result::eOk,
                [&](void** nativeFunction) {
                    return o_slGetFeatureFunction(feature, functionName, *nativeFunction);
                },
                [&](sl::Result result, bool available) {
                    const auto api = renderApi == sl::RenderAPI::eCount
                        ? std::string("Unknown")
                        : std::string(magic_enum::enum_name(renderApi));
                    optishade::session::State().Put({
                        {"FGCapabilityProbe", "Passive native DLSS-G function lookup"},
                        {"FGProviderFunctionAvailable", available ? "Yes" : "No"},
                        {"FGProviderFunctionResult", std::to_string(static_cast<int>(result))},
                        {"FGProviderObservedMaximum", "Unknown - provider state was not queried"},
                        {"FGProviderGraphicsApi", api},
                        {"FGOutputVerification", "Not observed"}});
                });
        }
        if (strcmp(functionName, "slDLSSGSetOptions") == 0)
        {
            function = &dummy_slDLSSGSetOptions;

            return sl::Result::eOk;
        }

        if (strcmp(functionName, "slDLSSGGetState") == 0)
        {
            function = &dummy_slDLSSGGetState;

            return sl::Result::eOk;
        }
    }

    return o_slGetFeatureFunction(feature, functionName, function);
}

sl::Result StreamlineHooks::hkslGetNewFrameToken(sl::FrameToken*& token,const uint32_t* frameIndex) {
    const auto result=o_slGetNewFrameToken(token,frameIndex);
    if(result==sl::Result::eOk&&token)DlssNr::TaaFgNewFrameToken(static_cast<uint32_t>(*token));
    return result;
}
sl::Result StreamlineHooks::hkslSetFeatureLoaded(sl::Feature feature, bool loaded)
{
    if (!o_slSetFeatureLoaded)return sl::Result::eErrorFeatureMissing;
    if (!State::Instance().externalFrameGeneration && feature == sl::kFeatureDLSS_G &&
        (State::Instance().activeFgInput == FGInput::DLSSG || State::Instance().activeFgOutput == FGOutput::DLSSG))
        return sl::Result::eOk;
    return o_slSetFeatureLoaded(feature, loaded);
}

sl::Result StreamlineHooks::hkslSetTag(const sl::ViewportHandle& viewport, const sl::ResourceTag* tags,
                                       uint32_t numTags, sl::CommandBuffer* cmdBuffer)
{
    if (renderApi == sl::RenderAPI::eD3D11 || renderApi == sl::RenderAPI::eVulkan)
    {
        LOG_ERROR("hkslSetTag only supports DX12");
        return o_slSetTag(viewport, tags, numTags, cmdBuffer);
    }

    // Logged once: the game initialised Streamline before the hooks, so every
    // tag call would repeat it (about 18,000 lines a session in OSD-3NCN).
    static std::atomic<bool> incompleteLogged{false};
    if (renderApi == sl::RenderAPI::eCount && !incompleteLogged.exchange(true))
        LOG_WARN("Incomplete Streamline hooks: the game initialised Streamline before OptiShade hooked it; tag calls pass through");
    const auto api = EffectiveRenderApi(renderApi);

    if (tags == nullptr)
    {
        LOG_WARN("Game trying to remove a tag");
        if (api == sl::RenderAPI::eD3D12)
            DlssNr::TaaFgInvalidate(static_cast<uint32_t>(viewport));
        const auto result=o_slSetTag(viewport,tags,numTags,cmdBuffer);
        if(State::Instance().externalFrameGeneration)
            ObserveAcceptedTagMode(InterposerTagMode::Legacy,result,static_cast<uint32_t>(viewport));
        return result;
    }

    const bool invalidatesTaaFg = api == sl::RenderAPI::eD3D12 &&
                                  HasNullTaaFgResource(tags, numTags);
    if (invalidatesTaaFg)
        DlssNr::TaaFgInvalidate(static_cast<uint32_t>(viewport));
    else if(api==sl::RenderAPI::eD3D12 &&
            g_interposerTagMode.load(std::memory_order_acquire)==InterposerTagMode::Legacy)
        DlssNr::TaaFgLegacyTags(static_cast<ID3D12GraphicsCommandList*>(cmdBuffer),tags,numTags,static_cast<uint32_t>(viewport));
    if(State::Instance().externalFrameGeneration){
        const auto result=o_slSetTag(viewport,tags,numTags,cmdBuffer);
        ObserveAcceptedTagMode(InterposerTagMode::Legacy,result,static_cast<uint32_t>(viewport));
        optishade::mfg::source::ObserveAcceptedTags(static_cast<uint32_t>(viewport),tags,numTags,result==sl::Result::eOk);
        if(result!=sl::Result::eOk&&api==sl::RenderAPI::eD3D12)DlssNr::TaaFgInvalidate(static_cast<uint32_t>(viewport));
        return result;
    }

    if (State::Instance().activeFgInput == FGInput::DLSSG &&
        State::Instance().gameQuirks[GameQuirk::IgnoreTagsWithoutHudlessForFG])
    {
        bool hasDepth = false;
        bool hasMVs = false;
        bool hasHudless = false;

        for (uint32_t i = 0; i < numTags; i++)
        {
            if (tags[i].resource == nullptr || tags[i].resource->native == nullptr)
                continue;

            if (tags[i].type == sl::kBufferTypeDepth)
                hasDepth = true;

            if (tags[i].type == sl::kBufferTypeMotionVectors)
                hasMVs = true;

            if (tags[i].type == sl::kBufferTypeHUDLessColor)
                hasHudless = true;
        }

        // Try to skip a DLSS call
        if (hasDepth && hasMVs && !hasHudless)
        {
            LOG_DEBUG("Skipping the FG tagging of potential DLSS resources");
            return o_slSetTag(viewport, tags, numTags, cmdBuffer);
        }
    }

    for (uint32_t i = 0; i < numTags; i++)
    {
        const auto typeEnum = (BufferType) tags[i].type;

        if (tags[i].resource == nullptr || tags[i].resource->native == nullptr)
        {
            LOG_TRACE("Resource of type: {} is null, continuing", magic_enum::enum_name(typeEnum));
            continue;
        }

        // Cyberpunk hudless state fix for RDNA 2
        if (State::Instance().gameQuirks & GameQuirk::CyberpunkHudlessState &&
            tags[i].resource->state ==
                (D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE) &&
            tags[i].type == sl::kBufferTypeHUDLessColor)
        {
            tags[i].resource->state = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
            LOG_TRACE("Changing hudless resource state");
        }

        if (State::Instance().activeFgInput == FGInput::DLSSG &&
            (tags[i].type == sl::kBufferTypeHUDLessColor || tags[i].type == sl::kBufferTypeDepth ||
             tags[i].type == sl::kBufferTypeHiResDepth || tags[i].type == sl::kBufferTypeLinearDepth ||
             tags[i].type == sl::kBufferTypeMotionVectors || tags[i].type == sl::kBufferTypeUIColorAndAlpha ||
             tags[i].type == sl::kBufferTypeBidirectionalDistortionField))
        {
            State::Instance().slFGInputs.reportResource(tags[i], (ID3D12GraphicsCommandList*) cmdBuffer, 0);
        }
        else if (State::Instance().activeFgInput == FGInput::NvngxFG)
        {
            LOG_TRACE("Tagging resource of type: {}", magic_enum::enum_name(typeEnum));
        }
    }

    auto result = o_slSetTag(viewport, tags, numTags, cmdBuffer);
    return result;
}

sl::Result StreamlineHooks::hkslSetTagForFrame(const sl::FrameToken& frame, const sl::ViewportHandle& viewport,
                                               const sl::ResourceTag* resources, uint32_t numResources,
                                               sl::CommandBuffer* cmdBuffer)
{
    if (renderApi == sl::RenderAPI::eD3D11 || renderApi == sl::RenderAPI::eVulkan)
    {
        LOG_ERROR("hkslSetTagForFrame only supports DX12");
        return o_slSetTagForFrame(frame, viewport, resources, numResources, cmdBuffer);
    }

    // Logged once: the game initialised Streamline before the hooks, so every
    // tag call would repeat it (about 18,000 lines a session in OSD-3NCN).
    static std::atomic<bool> incompleteLogged{false};
    if (renderApi == sl::RenderAPI::eCount && !incompleteLogged.exchange(true))
        LOG_WARN("Incomplete Streamline hooks: the game initialised Streamline before OptiShade hooked it; tag calls pass through");
    const auto api = EffectiveRenderApi(renderApi);

    // The external provider owns initialization. Its first tag call establishes
    // the API only after acceptance; that first packet passes through unchanged.
    // Managed initialization retains its existing frame-token selection.
    if(!State::Instance().externalFrameGeneration)
        g_interposerTagMode.store(InterposerTagMode::Frame,std::memory_order_release);

    if (resources == nullptr)
    {
        LOG_WARN("Game trying to remove a tag");
        if (api == sl::RenderAPI::eD3D12)
            DlssNr::TaaFgInvalidate(static_cast<uint32_t>(viewport));
        const auto result=o_slSetTagForFrame(frame,viewport,resources,numResources,cmdBuffer);
        if(State::Instance().externalFrameGeneration)
            ObserveAcceptedTagMode(InterposerTagMode::Frame,result,static_cast<uint32_t>(viewport));
        return result;
    }

    LOG_DEBUG("frameIndex: {}", static_cast<uint32_t>(frame));

    const bool invalidatesTaaFg = api == sl::RenderAPI::eD3D12 &&
                                  HasNullTaaFgResource(resources, numResources);
    if (invalidatesTaaFg)
        DlssNr::TaaFgInvalidate(static_cast<uint32_t>(viewport));
    // Compose before either OptiShade or native Streamline snapshots FG inputs.
    else if(api==sl::RenderAPI::eD3D12&&
            g_interposerTagMode.load(std::memory_order_acquire)==InterposerTagMode::Frame)
        DlssNr::TaaFgBeforeTags(static_cast<ID3D12GraphicsCommandList*>(cmdBuffer),resources,numResources,static_cast<uint32_t>(frame),static_cast<uint32_t>(viewport));
    if(State::Instance().externalFrameGeneration){
        const auto result=o_slSetTagForFrame(frame,viewport,resources,numResources,cmdBuffer);
        ObserveAcceptedTagMode(InterposerTagMode::Frame,result,static_cast<uint32_t>(viewport));
        optishade::mfg::source::ObserveAcceptedTags(static_cast<uint32_t>(viewport),resources,numResources,result==sl::Result::eOk);
        if(result!=sl::Result::eOk&&api==sl::RenderAPI::eD3D12)DlssNr::TaaFgInvalidate(static_cast<uint32_t>(viewport));
        return result;
    }

    if (State::Instance().activeFgInput == FGInput::DLSSG &&
        State::Instance().gameQuirks[GameQuirk::IgnoreTagsWithoutHudlessForFG])
    {
        bool hasDepth = false;
        bool hasMVs = false;
        bool hasHudless = false;

        for (uint32_t i = 0; i < numResources; i++)
        {
            if (resources[i].resource == nullptr || resources[i].resource->native == nullptr)
                continue;

            if (resources[i].type == sl::kBufferTypeDepth)
                hasDepth = true;

            if (resources[i].type == sl::kBufferTypeMotionVectors)
                hasMVs = true;

            if (resources[i].type == sl::kBufferTypeHUDLessColor)
                hasHudless = true;
        }

        // Try to skip a DLSS call
        if (hasDepth && hasMVs && !hasHudless)
        {
            LOG_DEBUG("Skipping the FG tagging of potential DLSS resources");
            return o_slSetTagForFrame(frame, viewport, resources, numResources, cmdBuffer);
        }
    }

    for (uint32_t i = 0; i < numResources; i++)
    {
        const auto typeEnum = (BufferType) resources[i].type;

        if (resources[i].resource == nullptr || resources[i].resource->native == nullptr)
        {
            LOG_TRACE("Resource of type: {} is null, continuing", magic_enum::enum_name(typeEnum));
            continue;
        }

        if (State::Instance().activeFgInput == FGInput::DLSSG &&
            (resources[i].type == sl::kBufferTypeHUDLessColor || resources[i].type == sl::kBufferTypeDepth ||
             resources[i].type == sl::kBufferTypeHiResDepth || resources[i].type == sl::kBufferTypeLinearDepth ||
             resources[i].type == sl::kBufferTypeMotionVectors || resources[i].type == sl::kBufferTypeUIColorAndAlpha ||
             resources[i].type == sl::kBufferTypeBidirectionalDistortionField))
        {
            State::Instance().slFGInputs.reportResource(resources[i], (ID3D12GraphicsCommandList*) cmdBuffer,
                                                        (uint32_t) frame);
        }
        else if (State::Instance().activeFgInput == FGInput::NvngxFG)
        {
            LOG_TRACE("Tagging resource of type: {}", magic_enum::enum_name(typeEnum));
        }
    }

    auto result = o_slSetTagForFrame(frame, viewport, resources, numResources, cmdBuffer);
    return result;
}

sl::Result StreamlineHooks::hkslEvaluateFeature(sl::Feature feature, const sl::FrameToken& frame,
                                                const sl::BaseStructure** inputs, uint32_t numInputs,
                                                sl::CommandBuffer* cmdBuffer)
{
    LOG_DEBUG("frameIndex: {}", static_cast<uint32_t>(frame));

    if (State::Instance().activeFgInput == FGInput::DLSSG && numInputs > 0 && inputs != nullptr)
    {
        for (uint32_t i = 0; i < numInputs; i++)
        {
            if (inputs[i] == nullptr)
                continue;

            if (inputs[i]->structType == sl::ResourceTag::s_structType)
            {
                auto tag = (const sl::ResourceTag*) inputs[i];

                if (tag->type == sl::kBufferTypeHUDLessColor || tag->type == sl::kBufferTypeDepth ||
                    tag->type == sl::kBufferTypeHiResDepth || tag->type == sl::kBufferTypeLinearDepth ||
                    tag->type == sl::kBufferTypeMotionVectors || tag->type == sl::kBufferTypeUIColorAndAlpha ||
                    tag->type == sl::kBufferTypeBidirectionalDistortionField)
                {
                    State::Instance().slFGInputs.reportResource(*tag, (ID3D12GraphicsCommandList*) cmdBuffer,
                                                                (uint32_t) frame);
                }
            }
        }
    }

    auto result = o_slEvaluateFeature(feature, frame, inputs, numInputs, cmdBuffer);
    return result;
}

sl::Result StreamlineHooks::hkslAllocateResources(sl::CommandBuffer* cmdBuffer, sl::Feature feature,
                                                  const sl::ViewportHandle& viewport)
{
    if (feature == sl::kFeatureDLSS_G)
        return sl::Result::eOk;

    return o_slAllocateResources(cmdBuffer, feature, viewport);
}

sl::Result StreamlineHooks::hkslFreeResources(sl::Feature feature, const sl::ViewportHandle& viewport)
{
    if (feature == sl::kFeatureDLSS_G)
        return sl::Result::eOk;

    return o_slFreeResources(feature, viewport);
}

sl::Result StreamlineHooks::hkslGetNativeInterface(void* proxyInterface, void** baseInterface)
{
    LOG_FUNC();
    auto result = o_slGetNativeInterface(proxyInterface, baseInterface);
    return result;
}

sl::Result StreamlineHooks::hkslSetD3DDevice(void* d3dDevice)
{
    LOG_FUNC();
    auto result = o_slSetD3DDevice(d3dDevice);
    if(result==sl::Result::eOk){
        Microsoft::WRL::ComPtr<ID3D12Device> device;
        if(d3dDevice&&SUCCEEDED(static_cast<IUnknown*>(d3dDevice)->QueryInterface(IID_PPV_ARGS(&device))))
            optishade::runtime_render::State().StreamlineDevice(optishade::actual_gpu::Metadata(device.Get(),IdentifyGpu::getGpuForDevice(device.Get())));
        else optishade::runtime_render::State().StreamlineDevice({});
    }
    if(result==sl::Result::eOk&&State::Instance().externalFrameGeneration&&!passiveInterposer){
        // A successful device selection starts a fresh observation contract.
        // Null/non-D3D12 selections cannot retain an earlier D3D12 readiness.
        // Retire old input contracts through their existing fence-based owner;
        // a first accepted tag packet must not revive an earlier legacy frame.
        DlssNr::TaaFgReset();
        renderApi=sl::RenderAPI::eCount;
        g_interposerTagMode.store(InterposerTagMode::Unknown,std::memory_order_release);
        Microsoft::WRL::ComPtr<ID3D12Device> device;
        if(d3dDevice&&SUCCEEDED(static_cast<IUnknown*>(d3dDevice)->QueryInterface(IID_PPV_ARGS(&device)))){renderApi=sl::RenderAPI::eD3D12;optishade::mfg::source::ObserveDevice(static_cast<IUnknown*>(d3dDevice),true);}
    }
    return result;
}

void StreamlineHooks::streamlineLogCallback_sl1(sl1::LogType type, const char* msg)
{
    if (msg == nullptr)
        return;

    char* trimmed_msg = trimStreamlineLog(msg);

    if (trimmed_msg != nullptr)
    {
        switch (type)
        {
        case sl1::LogType::eLogTypeWarn:
            LOG_WARN("{}", trimmed_msg);
            break;
        case sl1::LogType::eLogTypeInfo:
            LOG_INFO("{}", trimmed_msg);
            break;
        case sl1::LogType::eLogTypeError:
            LOG_ERROR("{}", trimmed_msg);
            break;
        case sl1::LogType::eLogTypeCount:
            LOG_ERROR("{}", trimmed_msg);
            break;
        }

        free(trimmed_msg);
    }

    if (o_logCallback_sl1)
        o_logCallback_sl1(type, msg);
}

bool StreamlineHooks::hkslInit_sl1(const sl1::Preferences& pref, int applicationId)
{
    LOG_FUNC();

    sl1::Preferences localPref = pref;

    if (localPref.logMessageCallback != &streamlineLogCallback_sl1)
        o_logCallback_sl1 = localPref.logMessageCallback;
    localPref.logLevel = sl1::LogLevel::eLogLevelCount;
    localPref.logMessageCallback = &streamlineLogCallback_sl1;
    return o_slInit_sl1(localPref, applicationId);
}

bool StreamlineHooks::hkslSetTag_sl1(const sl1::Resource* resource, sl1::BufferType tag, uint32_t id,
                                     const sl1::Extent* extent)
{
    if (IsSL1AndFGActive())
        State::Instance().s_sl1FGInputs.setTag(resource, tag, id, extent);

    return o_slSetTag_sl1(resource, tag, id, extent);
}

bool StreamlineHooks::hkslSetConstants_sl1(const sl1::Constants& values, uint32_t frameIndex, uint32_t id)
{
    std::scoped_lock lock(setConstantsMutex);

    LOG_TRACE("SL1 slSetConstants frameIndex: {}, id: {}", frameIndex, id);

    if (IsSL1AndFGActive())
        State::Instance().s_sl1FGInputs.setConstants(values, frameIndex, id);

    return o_slSetConstants_interposer_sl1(values, frameIndex, id);
}

bool StreamlineHooks::hkslEvaluateFeature_sl1(sl1::CommandBuffer* cmdBuffer, sl1::Feature feature, uint32_t frameIndex,
                                              uint32_t id)
{
    LOG_TRACE("SL1 slEvaluateFeature feature: {}, frameIndex: {}, id: {}", magic_enum::enum_name(feature), frameIndex,
              id);

    if (IsSL1AndFGActive() && feature == sl1::Feature::eFeatureReflex)
    {
        const auto marker = (sl1::ReflexMarker) id;

        if (marker == sl1::ReflexMarker::eReflexMarkerRenderSubmitStart)
        {
            State::Instance().s_sl1FGInputs.evaluateState();
            State::Instance().s_sl1FGInputs.evaluateFeature(cmdBuffer, feature, frameIndex, id);
        }
        else if (marker == sl1::ReflexMarker::eReflexMarkerPresentStart)
        {
            State::Instance().s_sl1FGInputs.markPresent(frameIndex);
        }
    }

    return o_slEvaluateFeature_sl1(cmdBuffer, feature, frameIndex, id);
}

// Always re-read from params: the caps struct belongs to the sl.common copy Streamline currently uses,
// which can change (game plugins vs OTA plugins), so a cached pointer can go stale.
void StreamlineHooks::hookSystemCaps(sl::param::IParameters* params)
{
    if (params == nullptr)
        return;

    if (State::Instance().streamlineVersion.major > 1)
    {
        SystemCaps* caps = nullptr;
        sl::param::getPointerParam(params, sl::param::common::kSystemCaps, &caps);

        if (caps != nullptr && !IsWritableMemory(caps, sizeof(SystemCaps)))
        {
            LOG_WARN("SystemCaps pointer {:X} is not valid memory, skipping arch spoofing", (size_t) caps);
            caps = nullptr;
        }

        systemCaps = caps;
    }
    else if (State::Instance().streamlineVersion.major == 1)
    {
        // This should be Streamline 1.5 as previous versions don't even have slOnPluginLoad
        LOG_TRACE("Attempting to get system caps for Streamline v1, this could fail depending on the exact version");

        SystemCapsSl15* caps = nullptr;
        sl::param::getPointerParam(params, sl::param::common::kSystemCaps, &caps);

        if (caps != nullptr && !IsWritableMemory(caps, sizeof(SystemCapsSl15)))
        {
            LOG_WARN("SystemCaps (SL1) pointer {:X} is not valid memory, skipping arch spoofing", (size_t) caps);
            caps = nullptr;
        }

        systemCapsSl15 = caps;
    }
}

uint32_t StreamlineHooks::getSystemCapsArch(SystemCaps* altSystemCaps)
{
    uint32_t highestArch = 0;

    if (!fakenvapi::isUsingAsMainNvapi() && IdentifyGpu::hasNvidiaDlssCapableAdapter())
    {
        if (State::Instance().streamlineVersion.major > 1)
        {
            auto caps = altSystemCaps != nullptr ? altSystemCaps : systemCaps;
            if (caps && IsWritableMemory(caps, sizeof(SystemCaps)))
            {
                for (auto& adapter : caps->adapters)
                {
                    if (adapter.architecture > highestArch)
                        highestArch = adapter.architecture;
                }
            }
        }
        else if (State::Instance().streamlineVersion.major == 1)
        {
            if (systemCapsSl15 && IsWritableMemory(systemCapsSl15, sizeof(SystemCapsSl15)))
            {
                const auto count = (std::min) (systemCapsSl15->gpuCount, kMaxNumSupportedGPUs);
                for (uint32_t i = 0; i < count; i++)
                {
                    if (systemCapsSl15->architecture[i] > highestArch)
                        highestArch = systemCapsSl15->architecture[i];
                }
            }
        }
    }

    // By default spoof Pascal, gets Reflex but not DLSSD
    // Could be problematic if not using fakenvapi but nvapi might not be initialized yet
    if (highestArch == 0)
        highestArch = NV_GPU_ARCHITECTURE_GP100;

    return highestArch;
}

void StreamlineHooks::setArch(uint32_t arch, SystemCaps* altSystemCaps)
{
    const bool hasNvidiaDlssAdapter = IdentifyGpu::hasNvidiaDlssCapableAdapter();

    // altSystemCaps has to be sl2+
    if (State::Instance().streamlineVersion.major > 1 || altSystemCaps)
    {
        // Assumes that altCaps are always for SL2+
        auto caps = altSystemCaps != nullptr ? altSystemCaps : systemCaps;
        if (caps && !IsWritableMemory(caps, sizeof(SystemCaps)))
        {
            LOG_WARN("SystemCaps at {:X} is no longer valid, not writing arch", (size_t) caps);

            if (caps == systemCaps)
                systemCaps = nullptr;

            caps = nullptr;
        }

        if (caps)
        {
            const auto count = (std::min) (caps->gpuCount, kMaxNumSupportedGPUs);
            for (uint32_t i = 0; i < count; i++)
            {
                caps->adapters[i].architecture = arch;
                caps->adapters[i].vendor = VendorId::Nvidia;
            }

            if (fakenvapi::isUsingAsMainNvapi() || !hasNvidiaDlssAdapter)
                caps->driverVersionMajor = 999;

            caps->hwsSupported = true;
        }
    }
    else if (State::Instance().streamlineVersion.major == 1)
    {
        if (systemCapsSl15 && !IsWritableMemory(systemCapsSl15, sizeof(SystemCapsSl15)))
        {
            LOG_WARN("SystemCaps (SL1) at {:X} is no longer valid, not writing arch", (size_t) systemCapsSl15);
            systemCapsSl15 = nullptr;
        }

        if (systemCapsSl15)
        {
            const auto count = (std::min) (systemCapsSl15->gpuCount, kMaxNumSupportedGPUs);
            for (uint32_t i = 0; i < count; i++)
                systemCapsSl15->architecture[i] = arch;

            if (fakenvapi::isUsingAsMainNvapi() || !hasNvidiaDlssAdapter)
                systemCapsSl15->driverVersionMajor = 999;

            systemCapsSl15->hwSchedulingEnabled = true;
        }
    }
}

// Spoof arch based on feature and current arch
void StreamlineHooks::spoofArch(uint32_t currentArch, sl::Feature feature, SystemCaps* altSystemCaps)
{
    constexpr uint32_t maxArch = 0xFFFFFFFF;

    // Don't change arch for DLSS/DLSSD with turing and above
    if (feature == sl::kFeatureDLSS)
    {
        if (currentArch < NV_GPU_ARCHITECTURE_TU100)
            return setArch(maxArch, altSystemCaps);
    }

    // Don't spoof DLSSD at all
    else if (feature == sl::kFeatureDLSS_RR)
    {
        return;
    }

    // Don't change arch for DLSSG with ada and above
    else if (feature == sl::kFeatureDLSS_G)
    {
        if (State::Instance().activeFgNvngx != FGNvngxReplacement::None)
        {
            if (!Nvngx_FG::isDx12Available() && !Nvngx_FG::isVulkanAvailable())
                return setArch(0, altSystemCaps);
        }

        if (currentArch < NV_GPU_ARCHITECTURE_AD100)
            return setArch(maxArch, altSystemCaps);
    }

    else if (feature == sl::kFeatureReflex || feature == sl::kFeaturePCL)
    {
        if (fakenvapi::isUsingAsMainNvapi())
            return setArch(maxArch, altSystemCaps);
    }
}

bool StreamlineHooks::hkdlss_slOnPluginLoad(sl::param::IParameters* params, const char* loaderJSON,
                                            const char** pluginJSON)
{
    LOG_FUNC();

    // TODO: do it better than "static" and hoping for the best
    static std::string config;

    uint32_t currentArch = 0;
    if (Config::Instance()->StreamlineSpoofing.value_or_default())
    {
        hookSystemCaps(params);
        currentArch = getSystemCapsArch();
        spoofArch(currentArch, sl::kFeatureDLSS);
    }

    auto result = o_dlss_slOnPluginLoad != nullptr && o_dlss_slOnPluginLoad(params, loaderJSON, pluginJSON);

    if (Config::Instance()->StreamlineSpoofing.value_or_default())
        setArch(currentArch);

    if (!HasPluginJson(result, pluginJSON))
        return result;

    nlohmann::json configJson = nlohmann::json::parse(*pluginJSON, nullptr, false);
    if (configJson.is_discarded())
    {
        LOG_ERROR("Failed to parse plugin JSON");
        return result;
    }

    if (!IdentifyGpu::hasNvidiaDlssCapableAdapter())
    {
        if (configJson.contains("/external/vk/instance/extensions"_json_pointer))
            configJson["external"]["vk"]["instance"]["extensions"].clear();

        if (configJson.contains("/external/vk/device/extensions"_json_pointer))
            configJson["external"]["vk"]["device"]["extensions"].clear();

        if (configJson.contains("/external/vk/device/1.2_features"_json_pointer))
            configJson["external"]["vk"]["device"]["1.2_features"].clear();

        if (configJson.contains("/external/vk/device/1.3_features"_json_pointer))
            configJson["external"]["vk"]["device"]["1.3_features"].clear();
    }

    PatchSL1PluginJson(configJson);

    config = configJson.dump();

    *pluginJSON = config.c_str();

    return result;
}

sl::Result StreamlineHooks::hkslDLSSGetOptimalSettings(const sl::DLSSOptions& options,
                                                       sl::DLSSOptimalSettings& settings)
{
    if (o_slDLSSGetOptimalSettings == nullptr)
        return sl::Result::eErrorFeatureMissing;

    static bool modesBroken = false;

    auto localOptions = options;

    if (localOptions.mode == sl::DLSSMode::eOff)
        modesBroken = true;

    if (modesBroken)
    {
        if (localOptions.mode == sl::DLSSMode::eMaxPerformance)
            localOptions.mode = sl::DLSSMode::eUltraPerformance;
        else if (localOptions.mode == sl::DLSSMode::eBalanced)
            localOptions.mode = sl::DLSSMode::eMaxPerformance;
        else if (localOptions.mode == sl::DLSSMode::eMaxQuality)
            localOptions.mode = sl::DLSSMode::eBalanced;
        else if (localOptions.mode == sl::DLSSMode::eUltraQuality)
            localOptions.mode = sl::DLSSMode::eMaxQuality;
        else if (localOptions.mode == sl::DLSSMode::eUltraPerformance)
            localOptions.mode = sl::DLSSMode::eDLAA;
    }

    return o_slDLSSGetOptimalSettings(localOptions, settings);
}

bool StreamlineHooks::hkdlssg_slOnPluginLoad(sl::param::IParameters* params, const char* loaderJSON,
                                             const char** pluginJSON)
{
    LOG_FUNC();

    // TODO: do it better than "static" and hoping for the best
    static std::string config;

    bool shouldSpoofArch =
        Config::Instance()->StreamlineSpoofing.value_or_default() &&
        (State::Instance().activeFgInput == FGInput::NvngxFG || State::Instance().activeFgInput == FGInput::DLSSG);

    uint32_t currentArch = 0;
    if (shouldSpoofArch)
    {
        hookSystemCaps(params);
        currentArch = getSystemCapsArch();
        spoofArch(currentArch, sl::kFeatureDLSS_G);
    }

    auto result = o_dlssg_slOnPluginLoad != nullptr && o_dlssg_slOnPluginLoad(params, loaderJSON, pluginJSON);

    if (shouldSpoofArch)
        setArch(currentArch);

    if (!HasPluginJson(result, pluginJSON))
        return result;

    nlohmann::json configJson = nlohmann::json::parse(*pluginJSON, nullptr, false);
    if (configJson.is_discarded())
    {
        LOG_ERROR("Failed to parse plugin JSON");
        return result;
    }

    // Kill the DLSSG streamline swapchain hooks
    if (State::Instance().activeFgInput == FGInput::DLSSG || State::Instance().activeFgOutput == FGOutput::DLSSG)
    {
        if (configJson.contains("/hooks"_json_pointer))
            configJson["hooks"].clear();

        if (configJson.contains("/exclusive_hooks"_json_pointer))
            configJson["exclusive_hooks"].clear();

        if (configJson.contains("/external/feature/tags"_json_pointer))
            configJson["external"]["feature"]["tags"].clear(); // We handle the DLSSG resources

        if (configJson.contains("/external/vk/device/queues/compute/count"_json_pointer))
            configJson["external"]["vk"]["device"]["queues"]["compute"]["count"] = 0;

        if (configJson.contains("/external/vk/device/queues/graphics/count"_json_pointer))
            configJson["external"]["vk"]["device"]["queues"]["graphics"]["count"] = 0;

        if (configJson.contains("/external/vk/device/1.2_features"_json_pointer))
            configJson["external"]["vk"]["device"]["1.2_features"].clear();

        if (configJson.contains("/external/vk/device/1.3_features"_json_pointer))
            configJson["external"]["vk"]["device"]["1.3_features"].clear();
    }

    if (State::Instance().activeFgInput == FGInput::DLSSG || State::Instance().activeFgInput == FGInput::NvngxFG)
    {
        if (configJson.contains("/vsync/supported"_json_pointer))
            configJson["vsync"]["supported"] = true; // disable eVSyncOffRequired

        if (configJson.contains("/external/hws/required"_json_pointer))
            configJson["external"]["hws"]["required"] = false; // disable eHardwareSchedulingRequired

        // if (configJson.contains("/external/vk/opticalflow/supported"_json_pointer))
        //     configJson["external"]["vk"]["opticalflow"]["supported"] = true;
    }

    if (!IdentifyGpu::hasNvidiaDlssCapableAdapter())
    {
        if (configJson.contains("/external/vk/instance/extensions"_json_pointer))
            configJson["external"]["vk"]["instance"]["extensions"].clear();

        if (configJson.contains("/external/vk/device/extensions"_json_pointer))
            configJson["external"]["vk"]["device"]["extensions"].clear();

        if (configJson.contains("/external/vk/device/1.2_features"_json_pointer))
            configJson["external"]["vk"]["device"]["1.2_features"].clear();

        if (configJson.contains("/external/vk/device/1.3_features"_json_pointer))
            configJson["external"]["vk"]["device"]["1.3_features"].clear();
    }

    PatchSL1PluginJson(configJson);

    config = configJson.dump();

    *pluginJSON = config.c_str();

    return result;
}

const char* StreamlineHooks::hkdlssg_slGetPluginJSONConfig_sl1()
{
    if (o_dlssg_slGetPluginJSONConfig_sl1 == nullptr)
        return nullptr;

    static std::string patchedConfig;

    const char* originalConfig = o_dlssg_slGetPluginJSONConfig_sl1();

    if (originalConfig == nullptr)
        return originalConfig;

    try
    {
        auto configJson = nlohmann::json::parse(originalConfig);

        LOG_DEBUG("SL1 DLSSG JSON before patch: {}", configJson.dump());

        PatchSL1PluginJson(configJson);
        // RemoveSL1DLSSGHookEntriesRecursive(configJson);

        patchedConfig = configJson.dump();

        LOG_DEBUG("SL1 DLSSG JSON after patch: {}", patchedConfig);

        return patchedConfig.c_str();
    }
    catch (const std::exception& e)
    {
        LOG_ERROR("Failed to patch SL1 DLSSG JSON config: {}", e.what());
        return originalConfig;
    }
}

bool StreamlineHooks::hklocal_dlssg_slOnPluginLoad(sl::param::IParameters* params, const char* loaderJSON,
                                                   const char** pluginJSON)
{
    LOG_FUNC();

    // TODO: do it better than "static" and hoping for the best
    static std::string config;

    bool shouldSpoofArch = Config::Instance()->StreamlineSpoofing.value_or_default();

    uint32_t currentArch = 0;
    SystemCaps* localSystemCaps = nullptr;
    if (shouldSpoofArch)
    {
        sl::param::getPointerParam(params, sl::param::common::kSystemCaps, &localSystemCaps);

        if (localSystemCaps && !IsWritableMemory(localSystemCaps, sizeof(SystemCaps)))
            localSystemCaps = nullptr;

        if (localSystemCaps)
        {
            currentArch = getSystemCapsArch(localSystemCaps);
            spoofArch(currentArch, sl::kFeatureDLSS_G, localSystemCaps);
        }
    }

    auto result =
        o_local_dlssg_slOnPluginLoad != nullptr && o_local_dlssg_slOnPluginLoad(params, loaderJSON, pluginJSON);

    if (shouldSpoofArch && localSystemCaps)
        setArch(currentArch, localSystemCaps);

    if (!HasPluginJson(result, pluginJSON))
        return result;

    nlohmann::json configJson = nlohmann::json::parse(*pluginJSON, nullptr, false);
    if (configJson.is_discarded())
    {
        LOG_ERROR("Failed to parse plugin JSON");
        return result;
    }

    if (configJson.contains("/external/hws/required"_json_pointer))
        configJson["external"]["hws"]["required"] = false; // disable eHardwareSchedulingRequired

    if (!IdentifyGpu::hasNvidiaDlssCapableAdapter())
    {
        if (configJson.contains("/external/vk/instance/extensions"_json_pointer))
            configJson["external"]["vk"]["instance"]["extensions"].clear();

        if (configJson.contains("/external/vk/device/extensions"_json_pointer))
            configJson["external"]["vk"]["device"]["extensions"].clear();

        if (configJson.contains("/external/vk/device/1.2_features"_json_pointer))
            configJson["external"]["vk"]["device"]["1.2_features"].clear();

        if (configJson.contains("/external/vk/device/1.3_features"_json_pointer))
            configJson["external"]["vk"]["device"]["1.3_features"].clear();
    }

    config = configJson.dump();

    *pluginJSON = config.c_str();

    return result;
}

sl::Result StreamlineHooks::hkslSetConstants(const sl::Constants& values, const sl::FrameToken& frame,
                                             const sl::ViewportHandle& viewport)
{
    sl::Result result;
    {
        std::scoped_lock lock(setConstantsMutex);
        LOG_TRACE("called with frameIndex: {}, viewport: {}", (unsigned int) frame, (unsigned int) viewport);
        if(!State::Instance().externalFrameGeneration)State::Instance().slFGInputs.setConstants(values, (uint32_t) frame);
        result=o_slSetConstants(values,frame,viewport);
    }
    // Publish outside the Streamline mutex: NR creation/evaluation must not add
    // an opposite lock order to an engine's constants callback.
    if(result==sl::Result::eOk)
        DlssNr::TaaFgAcceptedConstants(values,static_cast<uint32_t>(frame),static_cast<uint32_t>(viewport));
    return result;
}
bool StreamlineHooks::hkcommon_slOnPluginLoad(sl::param::IParameters* params, const char* loaderJSON,
                                              const char** pluginJSON)
{
    LOG_FUNC();

    // TODO: do it better than "static" and hoping for the best
    static std::string config;

    auto result = o_common_slOnPluginLoad != nullptr && o_common_slOnPluginLoad(params, loaderJSON, pluginJSON);

    if (!HasPluginJson(result, pluginJSON))
    {
        LOG_DEBUG("Plugin load failed or returned no JSON, skipping patching");
        return result;
    }

    try
    {
        nlohmann::json configJson = nlohmann::json::parse(*pluginJSON);

        auto& slVersion = State::Instance().streamlineVersion;

        // Grab a version of the potentially updated sl.common
        // Opti assumes that all plugins will have this version
        configJson.at("version").at("major").get_to(slVersion.major);
        configJson.at("version").at("minor").get_to(slVersion.minor);
        configJson.at("version").at("build").get_to(slVersion.patch);

        // Completely disables Streamline hooks
        // if (true)
        //    configJson["hooks"].clear();
        //    configJson["exclusive_hooks"].clear();
        //}

        PatchSL1PluginJson(configJson);

        config = configJson.dump();
        *pluginJSON = config.c_str();
    }
    catch (const std::exception& e)
    {
        LOG_ERROR("Failed to patch sl.common JSON: {}", e.what());
    }

    return result;
}

sl::Result StreamlineHooks::hkslDLSSGSetOptions(const sl::ViewportHandle& viewport, const sl::DLSSGOptions& options)
{
    if(dlssgStateProviderFaulted.load(std::memory_order_acquire))return sl::Result::eErrorExceptionHandler;
    if(State::Instance().externalFrameGeneration)return ExternalOptions(viewport,options);
    if (!o_slDLSSGSetOptions)return sl::Result::eErrorFeatureMissing;
    auto& state = State::Instance();
    auto& nativeControl=optishade::native_mfg::Session();
    const auto nativeProvider=static_cast<uint64_t>(reinterpret_cast<uintptr_t>(o_slDLSSGSetOptions));
    const auto nativeRequest=nativeControl.ForCall(nativeProvider,static_cast<uint32_t>(viewport));
    const bool explicitNativeRequest=nativeRequest.provider!=0&&nativeRequest.revision!=0;
    const bool followGameRequest=explicitNativeRequest&&nativeRequest.desired<0&&!nativeRequest.dynamic;
    bool providerCallSkipped=false;
    const auto setOptionsSafely=[&](const sl::DLSSGOptions& forwarded){
        if(optishade::streamline_options::IsRedundantDisabledOptions(forwarded,state.dlssgLastSetMode)){
            providerCallSkipped=true;
            LOG_INFO("Skipped redundant managed DLSS-G OFF callback; provider is already off, preserving native capability queries");
            return sl::Result::eOk;
        }
        const auto outcome=optishade::native_mfg::InvokeSetOptionsGuarded(
            o_slDLSSGSetOptions,viewport,forwarded,&dlssgStateProviderFaulted);
        if(outcome.exceptionCode)RecordDlssGOptionsProviderFault("Managed DLSS-G",outcome);
        return outcome.result;
    };

    // Avoid reading past the caller's versioned structure. Unknown layouts are
    // forwarded untouched; an OptiShade override is refused with a visible result.
    sl::DLSSGOptions newOptions {};
    if(!optishade::streamline_options::CopyKnownDlssgOptions(options,newOptions)){
        if(explicitNativeRequest&&(nativeRequest.desired>=0||nativeRequest.dynamic)){
            nativeControl.Complete(nativeRequest,0,static_cast<int>(sl::Result::eErrorInvalidParameter));
            LOG_WARN("Native MFG request refused: unsupported DLSS-G options structure type/version {}",options.structVersion);
        }
        if(state.activeFgInput!=FGInput::DLSSG&&state.activeFgOutput==FGOutput::DLSSG){
            LOG_ERROR("Refusing an unknown DLSS-G options layout while another frame-generation path owns output");
            return sl::Result::eErrorInvalidParameter;
        }
        return setOptionsSafely(options);
    }

    // Disable game's DLSSG when we are trying to create our own instance of DLSSG
    if (state.activeFgInput != FGInput::DLSSG && state.activeFgOutput == FGOutput::DLSSG)
    {
        newOptions.mode = sl::DLSSGMode::eOff;
        const auto result=setOptionsSafely(newOptions);
        if(result==sl::Result::eOk){
            state.dlssgLastSetMode=newOptions.mode;
            state.dlssgTemporalSignature.store(0,std::memory_order_relaxed);
        }
        return result;
    }

    const auto dlssgPotentiallyActive = newOptions.mode == sl::DLSSGMode::eOn ||
                                        newOptions.mode == sl::DLSSGMode::eAuto ||
                                        newOptions.mode == sl::DLSSGMode::eDynamic;

    const bool dynamicRequested=explicitNativeRequest?nativeRequest.dynamic:Config::Instance()->FGDLSSGOverrideForceDMFG.value_or_default();
    // Streamline's current DLSS-G guide limits Dynamic MFG to D3D12. Keep a
    // stale/misreported provider capability from exposing it on Vulkan.
    bool enableDynamicMode = dynamicRequested && state.api == API::DX12 &&
                             state.dlssgGameDMFGSupported && dlssgPotentiallyActive;

    if (enableDynamicMode)
    {
        newOptions.mode = sl::DLSSGMode::eDynamic;
    }

    if (!enableDynamicMode && optishade::streamline_options::ApplyObservedMinimumFrameCount(
            newOptions, static_cast<uint32_t>(state.dlssgMfgMax.value_or(0))))
    {
        LOG_INFO("Normalized zero-frame DLSS-G options to the valid one-frame minimum (mode={}, maximum additional frames={})",
                 magic_enum::enum_name(newOptions.mode),state.dlssgMfgMax.value_or(0));
    }

    if (newOptions.mode == sl::DLSSGMode::eDynamic && Config::Instance()->FGDLSSGFramerateTargetDMFG.has_value())
    {
        newOptions.dynamicTargetFrameRate = Config::Instance()->FGDLSSGFramerateTargetDMFG.value();
    }

    applyMenuDlssgInterlock(newOptions, dlssgPotentiallyActive||(explicitNativeRequest&&nativeRequest.desired>0));

    LOG_TRACE("DLSSG Modified Mode: {}", magic_enum::enum_name(newOptions.mode));

    if (!followGameRequest && dlssgPotentiallyActive && state.streamlineVersion >= feature_version { 2, 7, 1 })
    {
        // State/capability observations belong to the game's GetState callback.
        // Polling here consumes a presentation-count interval and may race that
        // non-thread-safe API. The last admitted state sample supplies the cap.
        MfgUnlock::TryApply();

        // Won't take effect with Dynamic
        if (!explicitNativeRequest && Config::Instance()->FGDLSSGOverrideInterpolationCount.has_value())
        {
            auto overrideCount = Config::Instance()->FGDLSSGOverrideInterpolationCount.value();
            if (overrideCount != 0 && state.dlssgMfgMax.has_value() &&
                overrideCount <= state.dlssgMfgMax.value())
                newOptions.numFramesToGenerate = overrideCount;
            else if (overrideCount == 0 && !enableDynamicMode)
                newOptions.mode = sl::DLSSGMode::eOff;
        }
    }
    else if (!explicitNativeRequest && dlssgPotentiallyActive && Config::Instance()->FGDLSSGOverrideInterpolationCount.has_value() &&
             Config::Instance()->FGDLSSGOverrideInterpolationCount.value() != 0)
    {
        // Once. slDLSSGSetOptions runs per frame.
        static bool warnedNoMfg = false;

        if (!warnedNoMfg)
        {
            warnedNoMfg = true;
            LOG_WARN("Interpolation count override ignored: Streamline {}.{}.{}, multi frame generation "
                     "needs 2.7.1",
                     state.streamlineVersion.major, state.streamlineVersion.minor, state.streamlineVersion.patch);
        }
    }

    // In-game changes are staged until Save, then applied through the running
    // Streamline session. An explicit UI ON request may enable the feature even
    // when the game's last options packet was Off.
    if(explicitNativeRequest){
        if(nativeRequest.desired==0)newOptions.mode=sl::DLSSGMode::eOff;
        else if(nativeRequest.desired>0&&nativeRequest.desired<=int(nativeRequest.maximum)){
            newOptions.mode=sl::DLSSGMode::eOn;
            newOptions.numFramesToGenerate=static_cast<uint32_t>(nativeRequest.desired);
        }
    }
    const auto result=setOptionsSafely(newOptions);
    RecordManagedDlssgOptions(options,newOptions,result,nativeRequest,explicitNativeRequest,static_cast<uint32_t>(viewport),providerCallSkipped);
    if(explicitNativeRequest){
        const auto generated=newOptions.mode==sl::DLSSGMode::eOff?0u:newOptions.numFramesToGenerate;
        optishade::native_mfg::Session().Complete(nativeRequest,generated,static_cast<int>(result),newOptions.mode==sl::DLSSGMode::eDynamic);
    }
    // A rejected request must not become the effective mode used by Reflex.
    if (result == sl::Result::eOk) {
        state.dlssgLastSetMode = newOptions.mode;
        // Dynamic frame counts can change every frame: only mode changes reset that history.
        const uint64_t count=newOptions.mode==sl::DLSSGMode::eDynamic?0:newOptions.numFramesToGenerate;
        state.dlssgTemporalSignature.store((uint64_t(newOptions.mode)<<32)|count,std::memory_order_relaxed);
    }
    return result;
}

sl::Result StreamlineHooks::hkslDLSSGGetState(const sl::ViewportHandle& viewport, sl::DLSSGState& state,
                                              const sl::DLSSGOptions* options)
{
    if(State::Instance().externalFrameGeneration)return ExternalState(viewport,state,options);
    const auto callerSite=DlssgCallerSite(_ReturnAddress());
    const auto stateCall=optishade::external_fg_telemetry::Session().RecordStateCall(GetCurrentThreadId(),GetTickCount64());
    if (!o_slDLSSGGetState){
        if(optishade::external_fg_telemetry::Session().ShouldPersistBlockedState(GetTickCount64(),5))
            optishade::session::State().PutCritical({
                {"FGStateQueryStage","Managed provider function unavailable"},{"FGStateResult","eErrorFeatureMissing"},
                {"FGControlPath","Managed DLSS-G plugin callback"},{"FGProviderFunctionAvailable","No"},
                {"FGStateCallerModule",callerSite.first},{"FGStateCallerModuleOffset",callerSite.second},
                {"FGStateCallerThreadId",std::to_string(stateCall.lastStateThreadId)},
                {"FGStateQueryCount",std::to_string(stateCall.stateQueryCount)},
                {"FGStateAgeSincePresentMs",stateCall.hasPresentSample?std::to_string(stateCall.lastStateAgeSincePresentMs):"Unknown"},
                {"FGPresentSampleSource","OptiScaler primary game swapchain Present"},
                {"FGPresentCallerThreadId",stateCall.hasPresentSample?std::to_string(stateCall.lastPresentThreadId):"Unknown"},
                {"FGPresentSwapchainId",stateCall.hasPresentSample?std::to_string(stateCall.lastPresentSwapchainId):"Unknown"},
                {"FGStateThreadMatchesLastPresent",stateCall.hasPresentSample?(stateCall.lastStateThreadMatchesPresent?"Yes":"No"):"Unknown"},
                {"FGPresentCallCount",std::to_string(stateCall.presentCallCount)}});
        optishade::runtime_render::State().NativeUnavailable("Provider function unavailable");return sl::Result::eErrorFeatureMissing;
    }

    // Preserve the same thread/cadence evidence for the managed plugin callback
    // as for the separately resolved provider path. Streamline warns that this
    // query must be synchronized with Present; a mismatch is captured before
    // entering the provider because it may fault without returning.
    const bool threadMismatch=stateCall.hasPresentSample&&!stateCall.lastStateThreadMatchesPresent;
    const auto persistStateCall=[&](const char* stage,const std::string& result){
        const std::initializer_list<std::pair<const std::string,std::string>> values={
            {"FGStateQueryStage",stage},{"FGStateResult",result},
            {"FGStateCallerThreadId",std::to_string(stateCall.lastStateThreadId)},
            {"FGStateQueryCount",std::to_string(stateCall.stateQueryCount)},
            {"FGStateIntervalMs",stateCall.hasStateInterval?std::to_string(stateCall.lastStateIntervalMs):"Unknown"},
            {"FGStateAgeSincePresentMs",stateCall.hasPresentSample?std::to_string(stateCall.lastStateAgeSincePresentMs):"Unknown"},
            {"FGStateCallerModule",callerSite.first},{"FGStateCallerModuleOffset",callerSite.second},
            {"FGPresentSampleSource","OptiScaler primary game swapchain Present"},
            {"FGPresentCallerThreadId",stateCall.hasPresentSample?std::to_string(stateCall.lastPresentThreadId):"Unknown"},
            {"FGPresentSwapchainId",stateCall.hasPresentSample?std::to_string(stateCall.lastPresentSwapchainId):"Unknown"},
            {"FGStateThreadMatchesLastPresent",stateCall.hasPresentSample?(stateCall.lastStateThreadMatchesPresent?"Yes":"No"):"Unknown"},
            {"FGPresentCallCount",std::to_string(stateCall.presentCallCount)},
            {"FGPresentCallCountAtStateQuery",std::to_string(stateCall.presentCallCountAtLastState)}};
        if(!stateCall.hasPresentSample||threadMismatch||strcmp(stage,"Provider call pending")==0||strcmp(stage,"Provider access violation contained")==0)
            optishade::session::State().PutCritical(values);
        else optishade::session::State().Put(values);
    };
    const auto serveCachedCapabilities=[&](const char* stage){
        const auto cached=State::Instance().dlssgCapabilities.Read();
        if(!optishade::native_mfg::PopulateCachedCapabilityState(state,cached,static_cast<uint32_t>(viewport)))
            return false;
        persistStateCall(stage,"eOk");
        optishade::session::State().PutResolvedProviderCall({
            {"FGStateQueryStage",stage},{"FGStateResult","eOk"},
            {"FGStateReportedMaximum",std::to_string(cached.maximum)},
            {"FGStateGameResponse","Cached capabilities only; frame count and completion fence cleared"},
            {"FGOutputVerification","Capability response only; native output unverified"}});
        optishade::runtime_render::State().NativeUnavailable("Provider unavailable; cached MFG capabilities served");
        return true;
    };
    // Streamline requires DLSS-G GetState to be synchronized with Present. A
    // pending query before the first observed Present, or from a different
    // thread, must not enter the provider: tester dumps show that this can crash
    // inside sl.dlss_g.dll before the callback returns.
    if(!stateCall.hasPresentSample||threadMismatch){
        const char* reason=stateCall.hasPresentSample?"Provider query skipped: caller is not synchronized with Present":"Provider query skipped: no Present thread has been observed";
        if(serveCachedCapabilities(threadMismatch?
            "Cached capability served; provider query skipped off Present thread":
            "Cached capability served; no Present sample available"))return sl::Result::eOk;
        persistStateCall(reason,"eErrorFeatureMissing");
        optishade::runtime_render::State().NativeUnavailable(reason);
        return sl::Result::eErrorFeatureMissing;
    }
    MfgUnlock::TryApply();
    persistStateCall("Provider call pending","Pending");
    if(dlssgStateProviderFaulted.load(std::memory_order_acquire)){
        if(serveCachedCapabilities("Cached capability served after contained provider fault"))
            return sl::Result::eOk;
        persistStateCall("Provider query disabled after contained fault","eErrorExceptionHandler");
        optishade::runtime_render::State().NativeUnavailable();
        return sl::Result::eErrorExceptionHandler;
    }
    optishade::native_mfg::StateQueryEvidence evidence;
    // Observe only capability fields present in the game's original state
    // allocation. Do not promote its ABI or retry this consuming provider call.
    optishade::native_mfg::GuardedStateCall providerFailure{};
    const auto guardedProviderCall=[&](const sl::ViewportHandle& queryViewport,sl::DLSSGState& queryState,const sl::DLSSGOptions* queryOptions){
        // The provider call remains synchronous on the intercepted caller
        // thread; fault publication follows the callback before returning.
        const auto outcome=optishade::native_mfg::InvokeGetStateGuarded(o_slDLSSGGetState,queryViewport,queryState,queryOptions,&dlssgStateProviderFaulted);
        if(outcome.exceptionCode)providerFailure=outcome;
        return outcome.result;
    };
    const auto result=optishade::native_mfg::QueryNativeStateOnce(
        guardedProviderCall,true,viewport,state,options,evidence,4);
    if(providerFailure.exceptionCode){
        char exceptionText[16]{};
        sprintf_s(exceptionText,"0x%08lX",static_cast<unsigned long>(providerFailure.exceptionCode));
        persistStateCall("Provider access violation contained",exceptionText);
        RecordDlssGStateProviderFault("Managed DLSS-G callback",providerFailure);
        if(serveCachedCapabilities("Cached capability served after contained GetState fault"))
            return sl::Result::eOk;
        optishade::runtime_render::State().NativeUnavailable();
        return sl::Result::eErrorExceptionHandler;
    }
    persistStateCall("Provider call completed",std::to_string(static_cast<int>(result)));
    if(result!=sl::Result::eOk||!evidence.stateKnown){
        if(serveCachedCapabilities("Cached capability served after provider state query failure"))
            return sl::Result::eOk;
        optishade::session::State().PutResolvedProviderCall({
            {"FGStateQueryStage","Provider call completed"},
            {"FGStateResult",std::to_string(static_cast<int>(result))},
            {"FGStateQueryCount",std::to_string(stateCall.stateQueryCount)},
            {"FGStateCallerThreadId",std::to_string(stateCall.lastStateThreadId)}});
        optishade::runtime_render::State().NativeUnavailable();return result;
    } // Unknown layouts pass through unchanged.

    auto& optiState=State::Instance();
    const auto nativeMfgApi=optiState.api==API::DX12?optishade::native_mfg::GraphicsApi::Direct3D12:
        optiState.api==API::Vulkan?optishade::native_mfg::GraphicsApi::Vulkan:
        optiState.api==API::DX11?optishade::native_mfg::GraphicsApi::Direct3D11:
        optishade::native_mfg::GraphicsApi::Unknown;
    const bool dynamicSupported=optishade::native_mfg::DynamicSupported(
        nativeMfgApi,evidence.dynamicKnown,evidence.dynamicSupported);
    if(!optiState.dlssgCapabilities.Observe(evidence.maximum,static_cast<uint32_t>(viewport),evidence.dynamicKnown,dynamicSupported)){
        LOG_WARN("Ignoring invalid DLSS-G maximum from the game's GetState callback: {}",evidence.maximum);
    }else{
        LOG_INFO("Observed DLSS-G capabilities on the game's GetState callback: max additional frames={}, dynamic known={}, dynamic supported={}",
                 evidence.maximum,evidence.dynamicKnown,dynamicSupported);
    }
    if(evidence.dynamicKnown){
        optiState.dlssgGameDMFGSupported=dynamicSupported;
        if(!dynamicSupported)Config::Instance()->FGDLSSGOverrideForceDMFG.set_volatile_value(false);
    }

    // Preserve raw provider evidence before an optional game-facing emulation.
    // A patched Ada ceiling is a capability override, never presentation proof.
    const auto providerMaximum=evidence.maximum;
    auto effectiveMaximum=providerMaximum;
    if(const auto unlocked=MfgUnlock::UnlockedMax();effectiveMaximum&&unlocked>effectiveMaximum)
        effectiveMaximum=unlocked;
    optishade::native_mfg::ExposeProviderMfgMaximum(state,effectiveMaximum);

    if(optiState.streamlineVersion>=feature_version{2,7,1}&&!MfgUnlock::Pending()&&
       effectiveMaximum>0&&effectiveMaximum<6){
        optiState.dlssgMfgMax=effectiveMaximum;
        if(Config::Instance()->FGDLSSGOverrideInterpolationCount.has_value()&&
           Config::Instance()->FGDLSSGOverrideInterpolationCount.value()>effectiveMaximum)
            Config::Instance()->FGDLSSGOverrideInterpolationCount.set_volatile_value(effectiveMaximum);
    }

    const bool emulated=optiState.activeFgInput==FGInput::DLSSG;
    // Keep the provider's reported capability visible to the game. Clamping
    // this managed Streamline path to one additional frame removes every
    // selectable multiplier from MSFS's native multiplier dialog, even when
    // the provider reports a valid range. OptiShade's own controls are
    // independently gated on the live OptiMFG bridge.
    if(o_slDLSSGSetOptions){
        const auto identity=static_cast<uint64_t>(reinterpret_cast<uintptr_t>(o_slDLSSGSetOptions));
        optishade::native_mfg::Session().Observe(identity,static_cast<uint32_t>(viewport),effectiveMaximum,true,evidence.dynamicKnown,dynamicSupported);
        const auto caps=optishade::native_mfg::Session().Read();
        optishade::runtime_render::State().NativeState(identity,caps.generation,static_cast<uint32_t>(viewport),evidence.providerFramesPresented,GetTickCount64());
    }
        optishade::session::State().PutResolvedProviderCall({
        {"FGStateQueryStage","Provider call completed"},
        {"FGStateResult",std::to_string(static_cast<int>(result))},
        {"FGStateQueryCount",std::to_string(stateCall.stateQueryCount)},
        {"FGControlPath","Managed DLSS-G plugin callback"},
        {"FGStateCallerVersion",std::to_string(evidence.callerVersion)},
        {"FGStateExtendedQuery",evidence.promoted?"Yes":"No"},
        {"FGStateReportedMaximum",std::to_string(providerMaximum)},
        {"FGProviderFramesSinceStateQuery",std::to_string(evidence.providerFramesPresented)},
        {"FGGameStateResponse",emulated?"Managed Streamline route; provider capability preserved":"Provider interval"},
        {"FGOutputVerification",emulated?"Emulated game response; native output unverified":"Provider-reported interval only; scanout not observed"}});
    return result;
}

bool StreamlineHooks::hkreflex_slOnPluginLoad(sl::param::IParameters* params, const char* loaderJSON,
                                              const char** pluginJSON)
{
    LOG_FUNC();

    // TODO: do it better than "static" and hoping for the best
    static std::string config;

    uint32_t currentArch = 0;
    if (Config::Instance()->StreamlineSpoofing.value_or_default())
    {
        hookSystemCaps(params);
        currentArch = getSystemCapsArch();
        spoofArch(currentArch, sl::kFeatureReflex);
    }

    auto result = o_reflex_slOnPluginLoad != nullptr && o_reflex_slOnPluginLoad(params, loaderJSON, pluginJSON);

    if (Config::Instance()->StreamlineSpoofing.value_or_default())
        setArch(currentArch);

    if (!HasPluginJson(result, pluginJSON))
        return result;

    nlohmann::json configJson = nlohmann::json::parse(*pluginJSON, nullptr, false);
    if (configJson.is_discarded())
    {
        LOG_ERROR("Failed to parse plugin JSON");
        return result;
    }

    if (!IdentifyGpu::hasNvidiaDlssCapableAdapter())
    {
        if (configJson.contains("/external/vk/instance/extensions"_json_pointer))
            configJson["external"]["vk"]["instance"]["extensions"].clear();

        if (configJson.contains("/external/vk/device/extensions"_json_pointer))
            configJson["external"]["vk"]["device"]["extensions"].clear();

        if (configJson.contains("/external/vk/device/1.2_features"_json_pointer))
            configJson["external"]["vk"]["device"]["1.2_features"].clear();

        if (configJson.contains("/external/vk/device/1.3_features"_json_pointer))
            configJson["external"]["vk"]["device"]["1.3_features"].clear();
    }

    PatchSL1PluginJson(configJson);

    config = configJson.dump();

    *pluginJSON = config.c_str();

    return result;
}

sl::Result StreamlineHooks::hkslReflexSetOptions(const sl::ReflexOptions& options)
{
    if (o_slReflexSetOptions == nullptr)
        return sl::Result::eErrorFeatureMissing;

    reflexGamesLastMode = options.mode;

    sl::ReflexOptions newOptions = options;

    if (Config::Instance()->FN_ForceReflex == ForceReflex::ForceEnable)
        newOptions.mode = sl::ReflexMode::eLowLatencyWithBoost;

    // Will cause a pink screen when used with DLSSG
    // if (Config::Instance()->FN_ForceReflex == 1)
    //     newOptions.mode = sl::ReflexMode::eOff;

    return o_slReflexSetOptions(newOptions);
}

sl::Result StreamlineHooks::hkslReflexSleep(const sl::FrameToken& frame)
{
    if (o_slReflexSleep == nullptr)
        return sl::Result::eErrorFeatureMissing;

    // if (State::Instance().activeFgOutput == FGOutput::DLSSG && StreamlineProxy::IsD3D12Inited() &&
    //     Config::Instance()->FGDLSSGUseGamesReflexMarkers.value_or_default())
    //{
    //     return StreamlineProxy::ReflexSleep()(frame);
    // }

    return o_slReflexSleep(frame);
}

void* StreamlineHooks::hkdlss_slGetPluginFunction(PFN_slGetPluginFunction original, const char* functionName,
                                                  void* caller)
{
    LOG_DEBUG("{}", functionName);

    if (strcmp(functionName, "slOnPluginLoad") == 0)
    {
        o_dlss_slOnPluginLoad = (PFN_slOnPluginLoad) original(functionName);
        return &hkdlss_slOnPluginLoad;
    }

    if (strcmp(functionName, "slDLSSGetOptimalSettings") == 0 &&
        State::Instance().gameQuirks & GameQuirk::PregmataFixDLSSModes)
    {
        o_slDLSSGetOptimalSettings = (decltype(&slDLSSGetOptimalSettings)) original(functionName);
        return &hkslDLSSGetOptimalSettings;
    }

    return original(functionName);
}

void* StreamlineHooks::hkdlssg_slGetPluginFunction(PFN_slGetPluginFunction original, const char* functionName,
                                                   void* caller)
{
    if(State::Instance().externalFrameGeneration){
        auto target=original?original(functionName):nullptr;
        if(target&&strcmp(functionName,"slDLSSGSetOptions")==0){o_slDLSSGSetOptions=reinterpret_cast<decltype(o_slDLSSGSetOptions)>(target);return reinterpret_cast<void*>(&hkslDLSSGSetOptions);}
        if(target&&strcmp(functionName,"slDLSSGGetState")==0){o_slDLSSGGetState=reinterpret_cast<decltype(o_slDLSSGGetState)>(target);return reinterpret_cast<void*>(&hkslDLSSGGetState);}
        return target;
    }
    // LOG_DEBUG("{}", functionName);

    if (strcmp(functionName, "slOnPluginLoad") == 0)
    {
        o_dlssg_slOnPluginLoad = (PFN_slOnPluginLoad) original(functionName);
        return &hkdlssg_slOnPluginLoad;
    }

    if (strcmp(functionName, "slDLSSGSetOptions") == 0)
    {
        o_slDLSSGSetOptions = (decltype(&slDLSSGSetOptions)) original(functionName);

        // Give steam overlay the original as it seems to be hooking it
        auto steamOverlay = KernelBaseProxy::GetModuleHandleA_()("gameoverlayrenderer64.dll");
        if (steamOverlay != nullptr)
        {
            if (HMODULE callerModule = Util::GetCallerModule(caller); callerModule == steamOverlay)
                return o_slDLSSGSetOptions;
        }

        return &hkslDLSSGSetOptions;
    }

    if (strcmp(functionName, "slDLSSGGetState") == 0)
    {
        o_slDLSSGGetState = (decltype(&slDLSSGGetState)) original(functionName);

        // Give steam overlay the original as it seems to be hooking it
        auto steamOverlay = KernelBaseProxy::GetModuleHandleA_()("gameoverlayrenderer64.dll");
        if (steamOverlay != nullptr)
        {
            if (HMODULE callerModule = Util::GetCallerModule(caller); callerModule == steamOverlay)
                return o_slDLSSGGetState;
        }

        return &hkslDLSSGGetState;
    }

    if (strcmp(functionName, "slGetPluginJSONConfig") == 0 && IsSL1AndDLSSGManaged())
    {
        o_dlssg_slGetPluginJSONConfig_sl1 = reinterpret_cast<PFN_slGetPluginJSONConfig_sl1>(original(functionName));

        if (o_dlssg_slGetPluginJSONConfig_sl1 != nullptr)
        {
            LOG_WARN("Hooking SL1 DLSSG slGetPluginJSONConfig");
            return &hkdlssg_slGetPluginJSONConfig_sl1;
        }
    }

    // Ensure that we have those DLSSG calls
    if (!o_slDLSSGSetOptions)
        o_slDLSSGSetOptions = (decltype(&slDLSSGSetOptions)) original("slDLSSGSetOptions");

    if (!o_slDLSSGGetState)
        o_slDLSSGGetState = (decltype(&slDLSSGGetState)) original("slDLSSGGetState");

    return original(functionName);
}

void* StreamlineHooks::hklocal_dlssg_slGetPluginFunction(PFN_slGetPluginFunction original, const char* functionName,
                                                         void* caller)
{
    // LOG_DEBUG("{}", functionName);

    if (strcmp(functionName, "slOnPluginLoad") == 0 && State::Instance().activeFgNvngx != FGNvngxReplacement::None)
    {
        o_local_dlssg_slOnPluginLoad = (PFN_slOnPluginLoad) original(functionName);
        return &hklocal_dlssg_slOnPluginLoad;
    }

    return original(functionName);
}

bool StreamlineHooks::hkreflex_slSetConstants_sl1(const void* data, uint32_t frameIndex, uint32_t id)
{
    if (o_reflex_slSetConstants_sl1 == nullptr)
        return false;

    // Streamline v1's version of slReflexSetOptions + slPCLSetMarker
    static sl1::ReflexConstants constants {};
    constants = *(const sl1::ReflexConstants*) data;

    reflexGamesLastMode = (sl::ReflexMode) constants.mode;

    LOG_DEBUG("mode: {}, frameIndex: {}, id: {}", (uint32_t) constants.mode, frameIndex, id);

    if (Config::Instance()->FN_ForceReflex == ForceReflex::ForceEnable)
        constants.mode = sl1::ReflexMode::eReflexModeLowLatencyWithBoost;

    // Will cause a pink screen when used with DLSSG
    // else if (Config::Instance()->FN_ForceReflex == 1)
    //     constants.mode = sl1::ReflexMode::eReflexModeOff;

    return o_reflex_slSetConstants_sl1(&constants, frameIndex, id);
}

void* StreamlineHooks::hkreflex_slGetPluginFunction(PFN_slGetPluginFunction original, const char* functionName,
                                                    void* caller)
{
    // LOG_DEBUG("{}", functionName);

    if (strcmp(functionName, "slSetConstants") == 0 && State::Instance().streamlineVersion.major == 1)
    {
        o_reflex_slSetConstants_sl1 = (PFN_slSetConstants_sl1) original(functionName);
        return &hkreflex_slSetConstants_sl1;
    }

    if (strcmp(functionName, "slOnPluginLoad") == 0)
    {
        o_reflex_slOnPluginLoad = (PFN_slOnPluginLoad) original(functionName);
        return &hkreflex_slOnPluginLoad;
    }

    if (strcmp(functionName, "slReflexSetOptions") == 0)
    {
        o_slReflexSetOptions = (decltype(&slReflexSetOptions)) original(functionName);
        return &hkslReflexSetOptions;
    }

    if (strcmp(functionName, "slReflexSleep") == 0)
    {
        o_slReflexSleep = (decltype(&slReflexSleep)) original(functionName);
        return &hkslReflexSleep;
    }

    // TODO: Hopefully a game doesn't call both, maybe separate
    if (strcmp(functionName, "slReflexSetMarker") == 0 &&
        (State::Instance().gameQuirks & GameQuirk::FixSlSimulationMarkers ||
         State::Instance().activeFgInput == FGInput::DLSSG || optishade::route::ExternalFgObserver()))
    {
        o_slPCLSetMarker = (decltype(&slPCLSetMarker)) original(functionName);
        return &hkslPCLSetMarker;
    }

    return original(functionName);
}

sl::Result StreamlineHooks::hkslPCLSetMarker(sl::PCLMarker marker, const sl::FrameToken& frame)
{
    if (o_slPCLSetMarker == nullptr)
        return sl::Result::eErrorFeatureMissing;
    // if (State::Instance().activeFgOutput == FGOutput::DLSSG && StreamlineProxy::IsD3D12Inited() &&
    //     Config::Instance()->FGDLSSGUseGamesReflexMarkers.value_or_default())
    //{
    //     return StreamlineProxy::PCLSetMarker()(marker, frame);
    // }

    // HACK for broken games
    if (State::Instance().gameQuirks & GameQuirk::FixSlSimulationMarkers)
    {
        static uint64_t last_simulation_end_id = 0;
        if (marker == sl::PCLMarker::eSimulationEnd)
        {
            last_simulation_end_id = frame;
        }

        if (marker == sl::PCLMarker::eSimulationStart && last_simulation_end_id >= frame && o_slGetNewFrameToken)
        {
            const uint64_t correction_offset = last_simulation_end_id - frame + 1;
            uint32_t newFrameId = static_cast<uint32_t>(frame + correction_offset);

            sl::FrameToken* newFramePointer {};
            auto result = o_slGetNewFrameToken(newFramePointer, &newFrameId);

            LOG_WARN("Simulation start marker sent after end marker, offset: {}", correction_offset);

            result = o_slPCLSetMarker(marker, *newFramePointer);
            return result;
        }
    }

    if (State::Instance().activeFgInput == FGInput::DLSSG)
    {
        if (State::Instance().streamlineVersion.major == 1)
        {
            if (marker == sl::PCLMarker::eRenderSubmitStart)
            {
                State::Instance().s_sl1FGInputs.evaluateState();
            }
            else if (marker == sl::PCLMarker::ePresentStart)
            {
                State::Instance().s_sl1FGInputs.markPresent(frame);
            }
        }
        else
        {
            if (marker == sl::PCLMarker::eRenderSubmitStart)
            {
                State::Instance().slFGInputs.evaluateState();
            }
            else if (marker == sl::PCLMarker::ePresentStart)
            {
                State::Instance().slFGInputs.markPresent(frame);
            }
        }
    }

    if(optishade::route::ExternalFgObserver())
        return optishade::external_fg::DispatchMarker(marker,frame,o_slPCLSetMarker,ExternalPrepare,
            [](const auto& f,sl::Result){DlssNr::TaaFgPresentReturned(static_cast<uint32_t>(f));});
    return o_slPCLSetMarker(marker, frame);
}

bool StreamlineHooks::hkpcl_slOnPluginLoad(sl::param::IParameters* params, const char* loaderJSON,
                                           const char** pluginJSON)
{
    LOG_FUNC();

    uint32_t currentArch = 0;
    if (Config::Instance()->StreamlineSpoofing.value_or_default())
    {
        hookSystemCaps(params);
        currentArch = getSystemCapsArch();
        spoofArch(currentArch, sl::kFeaturePCL);
    }

    auto result = o_pcl_slOnPluginLoad != nullptr && o_pcl_slOnPluginLoad(params, loaderJSON, pluginJSON);

    if (Config::Instance()->StreamlineSpoofing.value_or_default())
        setArch(currentArch);

    return result;
}

void* StreamlineHooks::hkpcl_slGetPluginFunction(PFN_slGetPluginFunction original, const char* functionName,
                                                 void* caller)
{
    // LOG_DEBUG("{}", functionName);

    if (strcmp(functionName, "slPCLSetMarker") == 0 &&
        (State::Instance().gameQuirks & GameQuirk::FixSlSimulationMarkers ||
         State::Instance().activeFgInput == FGInput::DLSSG || optishade::route::ExternalFgObserver()))
    {
        o_slPCLSetMarker = (decltype(&slPCLSetMarker)) original(functionName);
        return &hkslPCLSetMarker;
    }

    if (strcmp(functionName, "slOnPluginLoad") == 0)
    {
        o_pcl_slOnPluginLoad = (PFN_slOnPluginLoad) original(functionName);
        return &hkpcl_slOnPluginLoad;
    }

    return original(functionName);
}

bool StreamlineHooks::hk_setVoid(void* self, const char* key, void** value)
{
    // LOG_DEBUG("{}", key);

    if (strcmp(key, sl::param::common::kSystemCaps) == 0)
    {
        LOG_TRACE("Attempting to change system caps for Streamline v1, this could fail depending on the exact version");

        // SystemCapsSl15 is not entirely correct for Streamline 1.3
        // But we here only use the beginning that matches + extra
        auto caps = (SystemCapsSl15*) value;

        if (caps)
        {
            caps->gpuCount = 1;
            caps->architecture[0] = UINT_MAX;
            caps->driverVersionMajor = 999;

            // HAGS
            *((char*) value + 56) = (char) 0x01;
        }
    }

    return o_setVoid(self, key, value);
}

void StreamlineHooks::hkcommon_slSetParameters_sl1(void* params)
{
    LOG_FUNC();

    if (o_setVoid == nullptr && params)
    {
        void** vtable = *(void***) params;

        // It's flipped, 0 -> set void*, 7 -> get void*
        o_setVoid = (PFN_setVoid) vtable[0];

        const auto detourResult = OptiShade::Detours::WithProcessDetourTransaction([&]() -> LONG {
            if (o_setVoid == nullptr)
                return ERROR_INVALID_ADDRESS;
            return OptiShade::Detours::QueueProcessDetour(NO_ERROR, &(PVOID&) o_setVoid, hk_setVoid);
        });
        if (detourResult != NO_ERROR)
        {
            LOG_ERROR("Failed to hook setVoid: {:X}", detourResult);
            o_setVoid = nullptr;
        }
    }

    if (o_common_slSetParameters_sl1 != nullptr)
        o_common_slSetParameters_sl1(params);
}

void* StreamlineHooks::hkcommon_slGetPluginFunction(PFN_slGetPluginFunction original, const char* functionName,
                                                    void* caller)
{
    // LOG_DEBUG("{}", functionName);

    if (strcmp(functionName, "slOnPluginLoad") == 0)
    {
        o_common_slOnPluginLoad = (PFN_slOnPluginLoad) original(functionName);
        return &hkcommon_slOnPluginLoad;
    }

    // Used around Streamline v1.3, as 1.5 doesn't seem to have it anymore
    if (strcmp(functionName, "slSetParameters") == 0)
    {
        o_common_slSetParameters_sl1 = (PFN_slSetParameters_sl1) original(functionName);
        return &hkcommon_slSetParameters_sl1;
    }

    return original(functionName);
}

void StreamlineHooks::updateForceReflex()
{
    // Not needed for Streamline v1 as slSetConstants is sent every frame
    if (o_slReflexSetOptions)
    {
        sl::ReflexOptions options;

        auto forceReflex = Config::Instance()->FN_ForceReflex.value_or_default();

        if (forceReflex == ForceReflex::ForceEnable)
            options.mode = sl::ReflexMode::eLowLatencyWithBoost;
        else if (forceReflex == ForceReflex::ForceDisable)
            options.mode = sl::ReflexMode::eOff;
        else if (forceReflex == ForceReflex::InGame)
            options.mode = reflexGamesLastMode;

        auto result = o_slReflexSetOptions(options);
        if (result != sl::Result::eOk)
        {
            LOG_WARN("Failed to update Reflex mode with error code: {} ({:X})", magic_enum::enum_name(result),
                     (UINT) result);
        }
    }
}

void StreamlineHooks::updateDlssgOptions()
{
    // Never replay a cached options packet from the UI thread: its extension
    // chain may belong to the game's stack, and Streamline requires callers to
    // use the provider's synchronized game path. The pending request is applied
    // by the next game-owned SetOptions callback for its current viewport.
    LOG_TRACE("Native DLSS-G control change queued for the next game-owned options callback");
}

void StreamlineHooks::applyMenuDlssgInterlock(sl::DLSSGOptions& options, bool potentiallyActive)
{
    auto& state = State::Instance();
    if (state.externalFrameGeneration || (state.swapchainApi != API::Vulkan && !state.menuOverlayIsVulkan))
        return;
    if (potentiallyActive && !MenuOverlayBase::IsVisible())
        state.delayMenuRenderBy = 10;
    if (MenuOverlayBase::IsVisible())
    {
        options.mode = sl::DLSSGMode::eOff;
        options.flags |= sl::DLSSGFlags::eRetainResourcesWhenOff;
        ReflexHooks::setDlssgFrameCount(0);
    }
}

// SL INTERPOSER

void StreamlineHooks::clearInterposerPointers()
{
    // Call only after an aborted/failed install or a committed full detach.
    o_slInit=nullptr;o_slSetTag=nullptr;o_slSetTagForFrame=nullptr;
    o_slEvaluateFeature=nullptr;o_slAllocateResources=nullptr;o_slFreeResources=nullptr;
    o_slSetConstants=nullptr;o_slGetNativeInterface=nullptr;o_slSetD3DDevice=nullptr;
    o_slGetNewFrameToken=nullptr;nativeFrameTokenHooked=false;
    o_slIsFeatureSupported=nullptr;o_slIsFeatureLoaded=nullptr;
    o_slGetFeatureRequirements=nullptr;o_slGetFeatureVersion=nullptr;
    o_slGetFeatureFunction=nullptr;featureFunctionHooked=false;o_slSetFeatureLoaded=nullptr;
    o_slInit_sl1=nullptr;o_slSetTag_sl1=nullptr;
    o_slSetConstants_interposer_sl1=nullptr;o_slEvaluateFeature_sl1=nullptr;
    o_logCallback=nullptr;o_logCallback_sl1=nullptr;
    g_interposerDetours={};g_interposerDetourCount=0;
    g_legacyProviderPresent=nullptr;
    g_interposerTagMode.store(InterposerTagMode::Unknown,std::memory_order_release);
    renderApi=sl::RenderAPI::eCount;
    hookedInterposerModule=nullptr;passiveInterposer=false;
}

void StreamlineHooks::unhookInterposer()
{
    if(passiveInterposer){
        // Games can cache PassiveState after lookup. Removing its forwarding
        // trampoline while that pointer survives would break a later game call.
        // The selected interposer and observer follow the existing process-life
        // provider rule; an owner change requires a new game process.
        LOG_WARN("Passive Streamline observer remains bound until process exit; restart to change provider");
        return;
    }
    if(g_interposerDetourCount){
        // A simulator/game may be calling any interposer callback on another
        // thread. Detours adjusts only enlisted threads; this caller-only
        // transaction cannot prove callback quiescence. Keep the provider and
        // callbacks process-lifetime and require a process restart to replace it.
        LOG_WARN("Streamline interposer callbacks remain bound until process exit; restart to change provider");
        return;
    }
    clearInterposerPointers();
}

// Call it just after sl.interposer's load or if sl.interposer is already loaded
void StreamlineHooks::hookInterposer(HMODULE slInterposer)
{
    if(optishade::xp12_provider::Owned(slInterposer))return;
    // Loader notifications can overlap or re-enter while version lookup loads
    // dependencies. The Detours transaction lock alone is too late: another
    // caller could already have overwritten our original/trampoline pointers.
    // Never wait here (the caller may own the Windows loader lock). The active
    // attempt owns registration; subsequent notifications can retry on failure.
    static std::atomic_flag registrationInProgress = ATOMIC_FLAG_INIT;
    if (registrationInProgress.test_and_set(std::memory_order_acquire))
        return;
    struct RegistrationReset {
        std::atomic_flag& flag;
        ~RegistrationReset() { flag.clear(std::memory_order_release); }
    } registrationReset{registrationInProgress};

    if (State::Instance().externalFrameGeneration && !optishade::route::ExternalFgObserver()){
        if(!slInterposer||hookedInterposerModule==slInterposer)return;
        if(hookedInterposerModule){LOG_WARN("Passive Streamline provider replacement requires restart; retaining existing callbacks");return;}
        version_t version{};const auto path=GetModulePath(slInterposer);
        if(path.empty())return;
        Util::GetFileVersion(path,&version);if(version.major<2)return;
        auto lookup=reinterpret_cast<decltype(o_slGetFeatureFunction)>(KernelBaseProxy::GetProcAddress_()(slInterposer,"slGetFeatureFunction"));
        if(!lookup)return;
        HMODULE retained=nullptr;
        if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
            reinterpret_cast<LPCWSTR>(slInterposer),&retained))return;
        o_slGetFeatureFunction=lookup;
        InterposerDetourTransaction transaction;
        transaction.Attach(o_slGetFeatureFunction,hkslGetFeatureFunction);
        // The observer-only route must not detour slSetD3DDevice. MSFS can
        // resolve that export through a forwarding path which re-enters this
        // callback recursively (R250 crash: repeated hkslSetD3DDevice frames,
        // stack overflow in WINMM.dll). Device metadata is optional here; keep
        // native device selection entirely inside the game's Streamline path.
        // Visible before commit: callbacks immediately afterward select the
        // same pass-through lane. Commit failure rolls it back.
        hookedInterposerModule=slInterposer;passiveInterposer=true;
        if(transaction.Commit()!=NO_ERROR){clearInterposerPointers();return;}
        featureFunctionHooked=true;
        LOG_INFO("Passive Streamline capability observation active: game feature lookup only; device callback left untouched");
        return;
    }
    LOG_FUNC();

    if (!slInterposer)
    {
        LOG_WARN("Streamline module in NULL");
        return;
    }

    // Interposer needs this or it might end in an infinite loop calling itself
    if (hookedInterposerModule == slInterposer)
        return;

    // Looks like when reading DLL version load methods are called
    // To prevent loops disabling checks for sl.interposer.dll
    auto owner = State::GetOwner();
    State::DisableChecks(owner, "sl.interposer");

    if (hookedInterposerModule)
        unhookInterposer();

    if(hookedInterposerModule) {
        State::EnableChecks(owner);
        return; // Existing interposer callbacks require a process restart to replace.
    }

    {
        char dllPath[MAX_PATH];
        GetModuleFileNameA(slInterposer, dllPath, MAX_PATH);

        LOG_TRACE("slInterposer path: {}", dllPath);

        version_t sl_version;
        Util::GetFileVersion(string_to_wstring(dllPath), &sl_version);

        State::Instance().streamlineVersion.major = sl_version.major;
        State::Instance().streamlineVersion.minor = sl_version.minor;
        State::Instance().streamlineVersion.patch = sl_version.patch;

        LOG_INFO("Streamline version: {}.{}.{}", sl_version.major, sl_version.minor, sl_version.patch);

        if(State::Instance().externalFrameGeneration && sl_version.major < 2){
            LOG_WARN("MSFS2024 external-FG observation requires Streamline 2; native provider remains untouched.");
            clearInterposerPointers();State::EnableChecks(owner);return;
        }

        // Interposer callbacks can be entered by any game thread. Keep the
        // target image mapped for the full process lifetime so its trampolines
        // never point into an unloaded provider while a callback is in flight.
        HMODULE retainedInterposer=nullptr;
        if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
            reinterpret_cast<LPCWSTR>(slInterposer),&retainedInterposer)){
            LOG_WARN("Could not retain Streamline interposer for process lifetime; skipping interposer hooks");
            clearInterposerPointers();State::EnableChecks(owner);return;
        }

        hookedInterposerModule = slInterposer;
        if (sl_version.major >= 2)
        {
            o_slSetTag =
                reinterpret_cast<decltype(&slSetTag)>(KernelBaseProxy::GetProcAddress_()(slInterposer, "slSetTag"));
            o_slSetTagForFrame = reinterpret_cast<decltype(&slSetTagForFrame)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slSetTagForFrame"));
            // The companion owns external FG initialization. Detours can follow
            // its slInit hotpatch into a near relay and re-hook that relay.
            // Observe the real device and accepted tag APIs instead.
            o_slInit = State::Instance().externalFrameGeneration ? nullptr :
                reinterpret_cast<decltype(&slInit)>(KernelBaseProxy::GetProcAddress_()(slInterposer, "slInit"));
            o_slEvaluateFeature = reinterpret_cast<decltype(&slEvaluateFeature)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slEvaluateFeature"));
            o_slSetConstants = reinterpret_cast<decltype(&slSetConstants)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slSetConstants"));
            o_slGetNativeInterface = reinterpret_cast<decltype(&slGetNativeInterface)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slGetNativeInterface"));
            o_slSetD3DDevice = reinterpret_cast<decltype(&slSetD3DDevice)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slSetD3DDevice"));
            o_slGetNewFrameToken = reinterpret_cast<decltype(&slGetNewFrameToken)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slGetNewFrameToken")); // Native Beta TAA observer hooks this without changing token selection.

            // For making the game think DLSSG is loaded and supported
            // but making SL not actually load the plugin
            o_slIsFeatureSupported = reinterpret_cast<decltype(&slIsFeatureSupported)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slIsFeatureSupported"));
            o_slIsFeatureLoaded = reinterpret_cast<decltype(&slIsFeatureLoaded)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slIsFeatureLoaded"));
            o_slGetFeatureRequirements = reinterpret_cast<decltype(&slGetFeatureRequirements)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slGetFeatureRequirements"));
            o_slGetFeatureVersion = reinterpret_cast<decltype(&slGetFeatureVersion)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slGetFeatureVersion"));
            o_slGetFeatureFunction = reinterpret_cast<decltype(&slGetFeatureFunction)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slGetFeatureFunction"));
            o_slAllocateResources = reinterpret_cast<decltype(&slAllocateResources)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slAllocateResources"));
            o_slFreeResources = reinterpret_cast<decltype(&slFreeResources)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slFreeResources"));

            if(State::Instance().externalFrameGeneration&&!o_slGetFeatureFunction){
                LOG_WARN("External Streamline observer missing feature lookup export; no interposer hooks installed");
                clearInterposerPointers();State::EnableChecks(owner);return;
            }
            if (State::Instance().externalFrameGeneration || o_slInit != nullptr)
            {
                LOG_TRACE("Hooking v2");
                InterposerDetourTransaction transaction;

                if(!State::Instance().externalFrameGeneration)
                    transaction.Attach(o_slInit,hkslInit);

                if (!State::Instance().externalFrameGeneration && o_slEvaluateFeature != nullptr)
                    transaction.Attach(o_slEvaluateFeature,hkslEvaluateFeature);

                const bool nativeTaaObserver=DlssNr::TaaPreFgObserver();
                if (optishade::taa::AttachTaaTags(State::Instance().activeFgInput==FGInput::NvngxFG ||
                    State::Instance().activeFgInput==FGInput::DLSSG,nativeTaaObserver,State::Instance().externalFrameGeneration && !optishade::route::ExternalFgObserver()))
                {
                    if (nativeTaaObserver && o_slGetNewFrameToken != nullptr)
                        nativeFrameTokenHooked = transaction.Attach(o_slGetNewFrameToken,hkslGetNewFrameToken);
                    if (o_slSetTag != nullptr)
                        transaction.Attach(o_slSetTag,hkslSetTag);

                    if (o_slSetTagForFrame != nullptr)
                        transaction.Attach(o_slSetTagForFrame,hkslSetTagForFrame);

                    if (o_slSetConstants != nullptr)
                        transaction.Attach(o_slSetConstants,hkslSetConstants);
                }

                optishade::external_fg::Install(State::Instance().externalFrameGeneration||nativeTaaObserver,optishade::route::ExternalFgObserver(),[&]{
                    return featureFunctionHooked=transaction.Attach(o_slGetFeatureFunction,hkslGetFeatureFunction);});

                if (!State::Instance().externalFrameGeneration && State::Instance().activeFgInput == FGInput::DLSSG)
                {
                    if (o_slIsFeatureSupported != nullptr)
                        transaction.Attach(o_slIsFeatureSupported,hkslIsFeatureSupported);

                    if (o_slIsFeatureLoaded != nullptr)
                        transaction.Attach(o_slIsFeatureLoaded,hkslIsFeatureLoaded);

                    if (o_slGetFeatureRequirements != nullptr)
                        transaction.Attach(o_slGetFeatureRequirements,hkslGetFeatureRequirements);

                    if (o_slGetFeatureVersion != nullptr)
                        transaction.Attach(o_slGetFeatureVersion,hkslGetFeatureVersion);

                    if (o_slGetFeatureFunction != nullptr && !featureFunctionHooked)
                        featureFunctionHooked=transaction.Attach(o_slGetFeatureFunction,hkslGetFeatureFunction);

                    if (o_slSetFeatureLoaded != nullptr)
                        transaction.Attach(o_slSetFeatureLoaded,hkslSetFeatureLoaded);

                    if (o_slAllocateResources != nullptr)
                        transaction.Attach(o_slAllocateResources,hkslAllocateResources);

                    if (o_slFreeResources != nullptr)
                        transaction.Attach(o_slFreeResources,hkslFreeResources);
                }

                // if (o_slGetNativeInterface != nullptr)
                //     DetourAttach(&(PVOID&) o_slGetNativeInterface, hkslGetNativeInterface);

                // MSFS 2024's observer route has a forwarding/re-entry path for
                // slSetD3DDevice. R250 diagnostics show repeated entries into
                // hkslSetD3DDevice ending in a stack overflow during WinMain.
                // Leave the game's native device-selection callback untouched;
                // device telemetry is optional and must not take down startup.
                if(o_slSetD3DDevice != nullptr&&!optishade::route::ExternalFgObserver())
                    transaction.Attach(o_slSetD3DDevice,hkslSetD3DDevice);

                auto detourResult = transaction.Commit();
                if (detourResult != NO_ERROR)
                {
                    LOG_ERROR("Failed to hook sl.interposer v2: {:X} at stage '{}'", detourResult, transaction.Stage());
                    clearInterposerPointers();
                }
                LogOptiMfgBackendModule();
                if (detourResult == NO_ERROR)
                    LOG_INFO("Streamline hooks: externalFG={} observer={} nativeTaaObserver={} tags={} tagsForFrame={} frameToken={} featureLookup={} constants={}",
                             State::Instance().externalFrameGeneration,optishade::route::ExternalFgObserver(),nativeTaaObserver,
                             HasInterposerDetour(reinterpret_cast<PVOID*>(&o_slSetTag)),HasInterposerDetour(reinterpret_cast<PVOID*>(&o_slSetTagForFrame)),
                             nativeFrameTokenHooked,featureFunctionHooked,HasInterposerDetour(reinterpret_cast<PVOID*>(&o_slSetConstants)));
            }
            if(HasInterposerDetour(reinterpret_cast<PVOID*>(&o_slSetTag))&&optishade::route::ExternalFgObserver())
                optishade::native_fg_boundary::Install(slInterposer,NativeProviderPresentBegin,NativeProviderPresentEnd,[](IDXGISwapChain* swap,UINT interval,UINT flags){
                    static thread_local uint64_t last=0;const auto now=GetTickCount64();if(last&&now-last<30000)return;last=now;
                    DXGI_SWAP_CHAIN_DESC desc{};const auto hr=swap->GetDesc(&desc);
                    LOG_INFO("FG presentation input: swap={} interval={} flags={} descriptionHr={} windowed={} swapFlags={}; provider input only, physical scanout unconfirmed",reinterpret_cast<uintptr_t>(swap),interval,flags,unsigned(hr),desc.Windowed,desc.Flags);
                });
        }
        else if (sl_version.major == 1)
        {
            o_slInit_sl1 =
                reinterpret_cast<decltype(&sl1::slInit)>(KernelBaseProxy::GetProcAddress_()(slInterposer, "slInit"));
            o_slSetTag_sl1 = reinterpret_cast<decltype(&sl1::slSetTag)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slSetTag"));
            o_slSetConstants_interposer_sl1 = reinterpret_cast<decltype(&sl1::slSetConstants)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slSetConstants"));
            o_slEvaluateFeature_sl1 = reinterpret_cast<decltype(&sl1::slEvaluateFeature)>(
                KernelBaseProxy::GetProcAddress_()(slInterposer, "slEvaluateFeature"));

            LOG_INFO("SL1 exports - slInit: {}, slSetTag: {}, slSetConstants: {}, slEvaluateFeature: {}",
                     o_slInit_sl1 != nullptr, o_slSetTag_sl1 != nullptr, o_slSetConstants_interposer_sl1 != nullptr,
                     o_slEvaluateFeature_sl1 != nullptr);

            if (o_slInit_sl1 || o_slSetTag_sl1 || o_slSetConstants_interposer_sl1 || o_slEvaluateFeature_sl1)
            {
                LOG_TRACE("Hooking v1");
                InterposerDetourTransaction transaction;

                if (o_slInit_sl1)
                    transaction.Attach(o_slInit_sl1,hkslInit_sl1);

                if (IsSL1AndFGActive())
                {
                    if (o_slSetTag_sl1)
                        transaction.Attach(o_slSetTag_sl1,hkslSetTag_sl1);

                    if (o_slSetConstants_interposer_sl1)
                        transaction.Attach(o_slSetConstants_interposer_sl1,hkslSetConstants_sl1);

                    if (o_slEvaluateFeature_sl1)
                        transaction.Attach(o_slEvaluateFeature_sl1,hkslEvaluateFeature_sl1);
                }

                auto detourResult = transaction.Commit();
                if (detourResult != NO_ERROR)
                {
                    LOG_ERROR("Failed to hook sl.interposer v1: {:X}", detourResult);
                    clearInterposerPointers();
                }
            }
        }
    }

    if(!g_interposerDetourCount)clearInterposerPointers();
    State::EnableChecks(owner);
}

// SL PLUGINS (sl.dlss, sl.dlss_g, sl.reflex, sl.pcl, sl.common)
//
// Streamline may load several copies of the same plugin, e.g. the game's sl.reflex.dll and then an OTA
// 1B0_E658703.dll, decide that one of them is not allowed (OTA denylist) and FreeLibrary it while it keeps
// using the other one. So every copy gets its own detour slot and stays hooked for as long as it's mapped.
// A slot is released after the module has been unmapped (onModuleFreed / releaseDeadSlots), which never
// writes into the freed (and possibly reused) address range.

const char* StreamlineHooks::pluginName(SlPlugin plugin)
{
    switch (plugin)
    {
    case SlPlugin::Dlss:
        return "sl.dlss";
    case SlPlugin::Dlssg:
        return "sl.dlss_g";
    case SlPlugin::LocalDlssg:
        return "local sl.dlss_g";
    case SlPlugin::Reflex:
        return "sl.reflex";
    case SlPlugin::Pcl:
        return "sl.pcl";
    case SlPlugin::Common:
        return "sl.common";
    default:
        return "unknown";
    }
}

std::mutex& StreamlineHooks::pluginMutex(SlPlugin plugin)
{
    switch (plugin)
    {
    case SlPlugin::Dlss:
        return mutexHookDlss;
    case SlPlugin::Dlssg:
        return mutexHookDlssg;
    case SlPlugin::LocalDlssg:
        return mutexHookLocalDlssg;
    case SlPlugin::Reflex:
        return mutexHookReflex;
    case SlPlugin::Pcl:
        return mutexHookPcl;
    case SlPlugin::Common:
    default:
        return mutexHookCommon;
    }
}

HMODULE& StreamlineHooks::activePluginModule(SlPlugin plugin)
{
    switch (plugin)
    {
    case SlPlugin::Dlss:
        return hookedDlssModule;
    case SlPlugin::Dlssg:
        return hookedDlssgModule;
    case SlPlugin::LocalDlssg:
        return hookedLocalDlssgModule;
    case SlPlugin::Reflex:
        return hookedReflexModule;
    case SlPlugin::Pcl:
        return hookedPclModule;
    case SlPlugin::Common:
    default:
        return hookedCommonModule;
    }
}

template <StreamlineHooks::SlPlugin P, size_t I> void* StreamlineHooks::slotGetPluginFunction(const char* functionName)
{
    auto original = pluginSlots[(size_t) P][I].original;

    // Can't happen while the module is mapped, but don't crash if it somehow does
    if (original == nullptr)
        return nullptr;

    return dispatchGetPluginFunction(P, original, functionName, _ReturnAddress());
}

void* StreamlineHooks::dispatchGetPluginFunction(SlPlugin plugin, PFN_slGetPluginFunction original,
                                                 const char* functionName, void* caller)
{
    if (functionName == nullptr)
        return original(functionName);

    switch (plugin)
    {
    case SlPlugin::Dlss:
        return hkdlss_slGetPluginFunction(original, functionName, caller);
    case SlPlugin::Dlssg:
        return hkdlssg_slGetPluginFunction(original, functionName, caller);
    case SlPlugin::LocalDlssg:
        return hklocal_dlssg_slGetPluginFunction(original, functionName, caller);
    case SlPlugin::Reflex:
        return hkreflex_slGetPluginFunction(original, functionName, caller);
    case SlPlugin::Pcl:
        return hkpcl_slGetPluginFunction(original, functionName, caller);
    case SlPlugin::Common:
        return hkcommon_slGetPluginFunction(original, functionName, caller);
    default:
        return original(functionName);
    }
}

StreamlineHooks::PFN_slGetPluginFunction StreamlineHooks::slotDetour(SlPlugin plugin, size_t index)
{
    static_assert(kMaxPluginInstances == 4, "Update the detour table below");
    static_assert((size_t) SlPlugin::Count == 6, "Update the detour table below");

    using PFN = PFN_slGetPluginFunction;
    static const PFN table[(size_t) SlPlugin::Count][kMaxPluginInstances] = {
        { &slotGetPluginFunction<SlPlugin::Dlss, 0>, &slotGetPluginFunction<SlPlugin::Dlss, 1>,
          &slotGetPluginFunction<SlPlugin::Dlss, 2>, &slotGetPluginFunction<SlPlugin::Dlss, 3> },
        { &slotGetPluginFunction<SlPlugin::Dlssg, 0>, &slotGetPluginFunction<SlPlugin::Dlssg, 1>,
          &slotGetPluginFunction<SlPlugin::Dlssg, 2>, &slotGetPluginFunction<SlPlugin::Dlssg, 3> },
        { &slotGetPluginFunction<SlPlugin::LocalDlssg, 0>, &slotGetPluginFunction<SlPlugin::LocalDlssg, 1>,
          &slotGetPluginFunction<SlPlugin::LocalDlssg, 2>, &slotGetPluginFunction<SlPlugin::LocalDlssg, 3> },
        { &slotGetPluginFunction<SlPlugin::Reflex, 0>, &slotGetPluginFunction<SlPlugin::Reflex, 1>,
          &slotGetPluginFunction<SlPlugin::Reflex, 2>, &slotGetPluginFunction<SlPlugin::Reflex, 3> },
        { &slotGetPluginFunction<SlPlugin::Pcl, 0>, &slotGetPluginFunction<SlPlugin::Pcl, 1>,
          &slotGetPluginFunction<SlPlugin::Pcl, 2>, &slotGetPluginFunction<SlPlugin::Pcl, 3> },
        { &slotGetPluginFunction<SlPlugin::Common, 0>, &slotGetPluginFunction<SlPlugin::Common, 1>,
          &slotGetPluginFunction<SlPlugin::Common, 2>, &slotGetPluginFunction<SlPlugin::Common, 3> },
    };

    return table[(size_t) plugin][index];
}

// Module still mapped at the same base, same file, and our patch is still in place
// (a freed + reloaded copy of the same dll at the same base would have fresh, unpatched code)
bool StreamlineHooks::isSlotAlive(const PluginHookSlot& slot)
{
    if (slot.module == nullptr || slot.target == nullptr || slot.path.empty())
        return false;

    const auto current = GetModulePath(slot.module);
    if (current.empty() || _wcsicmp(current.c_str(), slot.path.c_str()) != 0)
        return false;

    // Safe to read, the module checked above is mapped
    return memcmp(slot.target, slot.patchBytes, kPatchBytes) == 0;
}

// Plugin provided function pointers that point into the module that is gone
void StreamlineHooks::clearPluginPointersInRange(uintptr_t base, size_t size)
{
    if (base == 0 || size == 0)
        return;

    auto clear = [base, size](auto& ptr, const char* name)
    {
        const auto address = reinterpret_cast<uintptr_t>(ptr);
        if (ptr != nullptr && address >= base && address < base + size)
        {
            LOG_DEBUG("Clearing {}, it pointed into an unloaded plugin", name);
            ptr = nullptr;
        }
    };

    clear(o_dlss_slOnPluginLoad, "o_dlss_slOnPluginLoad");
    clear(o_slDLSSGetOptimalSettings, "o_slDLSSGetOptimalSettings");

    clear(o_dlssg_slOnPluginLoad, "o_dlssg_slOnPluginLoad");
    clear(o_dlssg_slGetPluginJSONConfig_sl1, "o_dlssg_slGetPluginJSONConfig_sl1");
    clear(o_slDLSSGSetOptions, "o_slDLSSGSetOptions");
    clear(o_slDLSSGGetState, "o_slDLSSGGetState");

    clear(o_local_dlssg_slOnPluginLoad, "o_local_dlssg_slOnPluginLoad");

    clear(o_reflex_slOnPluginLoad, "o_reflex_slOnPluginLoad");
    clear(o_reflex_slSetConstants_sl1, "o_reflex_slSetConstants_sl1");
    clear(o_slReflexSetOptions, "o_slReflexSetOptions");
    clear(o_slReflexSleep, "o_slReflexSleep");

    clear(o_pcl_slOnPluginLoad, "o_pcl_slOnPluginLoad");
    clear(o_slPCLSetMarker, "o_slPCLSetMarker");

    clear(o_common_slOnPluginLoad, "o_common_slOnPluginLoad");
    clear(systemCaps, "systemCaps");
    clear(systemCapsSl15, "systemCapsSl15");
    clear(o_common_slSetParameters_sl1, "o_common_slSetParameters_sl1");
}

// Caller holds pluginMutex(plugin); only release a slot after its module is no longer live.
void StreamlineHooks::releaseDeadSlot(SlPlugin plugin, size_t index)
{
    auto& slot = pluginSlots[(size_t) plugin][index];

    if (slot.module == nullptr)
        return;

    if (isSlotAlive(slot))
        return;

    // Never detach a live callback with a caller-only thread transaction, and never touch module memory
    // after it has been replaced or unmapped. Its slot can be reused once no mapped image matches.
    LOG_DEBUG("{} at {:X} is no longer loaded, releasing its hook slot", pluginName(plugin), (size_t) slot.module);
    clearPluginPointersInRange(reinterpret_cast<uintptr_t>(slot.module), slot.imageSize);

    const auto releasedModule = slot.module;

    slot.original = nullptr;
    slot.target = nullptr;
    slot.module = nullptr;
    slot.imageSize = 0;
    slot.path.clear();
    memset(slot.patchBytes, 0, sizeof(slot.patchBytes));

    // Point "active" module to another live copy, if any
    auto& active = activePluginModule(plugin);
    if (active == releasedModule)
    {
        active = nullptr;

        for (auto& other : pluginSlots[(size_t) plugin])
        {
            if (other.module != nullptr)
            {
                active = other.module;
                break;
            }
        }
    }
}

// Caller holds pluginMutex(plugin)
void StreamlineHooks::releaseDeadSlots(SlPlugin plugin)
{
    for (size_t i = 0; i < kMaxPluginInstances; i++)
    {
        const auto& slot = pluginSlots[(size_t) plugin][i];

        if (slot.module != nullptr && !isSlotAlive(slot))
            releaseDeadSlot(plugin, i);
    }
}

// Caller holds pluginMutex(plugin)
void StreamlineHooks::hookPlugin(SlPlugin plugin, HMODULE module)
{
    if(optishade::xp12_provider::Owned(module))return;
    if(!optishade::external_fg::PluginDetours(State::Instance().externalFrameGeneration))return;
    const auto name = pluginName(plugin);

    if (module == nullptr)
    {
        LOG_WARN("{} module is NULL", name);
        return;
    }

    // Drop copies that Streamline already unloaded (e.g. a rejected OTA plugin)
    releaseDeadSlots(plugin);

    auto& slots = pluginSlots[(size_t) plugin];

    for (auto& slot : slots)
    {
        if (slot.module == module)
        {
            LOG_TRACE("{} at {:X} is already hooked", name, (size_t) module);
            activePluginModule(plugin) = module;
            return;
        }
    }

    auto target =
        reinterpret_cast<PFN_slGetPluginFunction>(KernelBaseProxy::GetProcAddress_()(module, "slGetPluginFunction"));

    if (target == nullptr)
    {
        LOG_WARN("{} at {:X} has no slGetPluginFunction", name, (size_t) module);
        return;
    }

    size_t index = kMaxPluginInstances;
    for (size_t i = 0; i < kMaxPluginInstances; i++)
    {
        if (slots[i].module == nullptr)
        {
            index = i;
            break;
        }
    }

    if (index == kMaxPluginInstances)
    {
        LOG_ERROR("No free hook slot for {} at {:X}, {} copies are already loaded", name, (size_t) module,
                  kMaxPluginInstances);
        return;
    }

    auto& slot = slots[index];
    slot.original = target;

    LOG_TRACE("Hooking slGetPluginFunction in {} (slot {})", name, index);

    if (auto r = OptiShade::Detours::AttachProcessDetour(&(PVOID&) slot.original,
                                                         (PVOID) slotDetour(plugin, index)); r != NO_ERROR)
    {
        LOG_ERROR("Failed to hook {}: {:X}", name, r);
        slot.original = nullptr;
        return;
    }

    size_t imageSize = 0;
    {
        auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(module);
        if (dos->e_magic == IMAGE_DOS_SIGNATURE)
        {
            auto nt =
                reinterpret_cast<const IMAGE_NT_HEADERS*>(reinterpret_cast<const uint8_t*>(module) + dos->e_lfanew);
            if (nt->Signature == IMAGE_NT_SIGNATURE)
                imageSize = nt->OptionalHeader.SizeOfImage;
        }
    }

    slot.target = reinterpret_cast<void*>(target);
    slot.module = module;
    slot.imageSize = imageSize;
    slot.path = GetModulePath(module);
    memcpy(slot.patchBytes, slot.target, kPatchBytes);

    activePluginModule(plugin) = module;

    LOG_TRACE("Hooked {} at {:X} (slot {}): {}", name, (size_t) module, index, wstring_to_string(slot.path));
}

bool StreamlineHooks::isPluginHooked(SlPlugin plugin)
{
    for (const auto& slot : pluginSlots[(size_t) plugin])
    {
        if (slot.module != nullptr)
            return true;
    }

    return false;
}

void StreamlineHooks::onModuleFreed(PVOID module)
{
    if (module == nullptr)
        return;

    for (size_t p = 0; p < (size_t) SlPlugin::Count; p++)
    {
        const auto plugin = (SlPlugin) p;

        // Cheap pre-check without the lock, worst case we miss it here and releaseDeadSlots catches it later
        bool ours = false;
        for (const auto& slot : pluginSlots[p])
        {
            if (slot.module == (HMODULE) module)
            {
                ours = true;
                break;
            }
        }

        if (!ours)
            continue;

        // try_lock: never block here, FreeLibrary can be called from places we don't control.
        // If it's busy, the hook call holding it will release dead slots itself.
        std::unique_lock lock(pluginMutex(plugin), std::try_to_lock);
        if (!lock.owns_lock())
            continue;

        releaseDeadSlots(plugin);
    }
}

// SL DLSS

void StreamlineHooks::hookDlss(HMODULE slDlss)
{
    if (State::Instance().externalFrameGeneration)return;
    LOG_FUNC();
    hookPlugin(SlPlugin::Dlss, slDlss);
}

// SL DLSSG

void StreamlineHooks::hookDlssg(HMODULE slDlssg)
{
    if (State::Instance().externalFrameGeneration)return;
    LOG_FUNC();
    hookPlugin(SlPlugin::Dlssg, slDlssg);
}

// Local SL DLSSG

void StreamlineHooks::hookLocalDlssg(HMODULE slDlssg)
{
    if (State::Instance().externalFrameGeneration) return;
    LOG_FUNC();
    hookPlugin(SlPlugin::LocalDlssg, slDlssg);
}

// SL REFLEX

void StreamlineHooks::hookReflex(HMODULE slReflex)
{
    if (State::Instance().externalFrameGeneration)return;
    LOG_FUNC();
    hookPlugin(SlPlugin::Reflex, slReflex);
}

// SL PCL

void StreamlineHooks::hookPcl(HMODULE slPcl)
{
    if (State::Instance().externalFrameGeneration)return;
    LOG_FUNC();
    hookPlugin(SlPlugin::Pcl, slPcl);
}

// SL COMMON

void StreamlineHooks::hookCommon(HMODULE slCommon)
{
    if (State::Instance().externalFrameGeneration)return;
    LOG_FUNC();
    hookPlugin(SlPlugin::Common, slCommon);
}

bool StreamlineHooks::isInterposerHooked() { return hookedInterposerModule && g_interposerDetourCount!=0; }

bool StreamlineHooks::isDlssHooked() { return isPluginHooked(SlPlugin::Dlss); }

bool StreamlineHooks::isDlssgHooked() { return isPluginHooked(SlPlugin::Dlssg); }

bool StreamlineHooks::isLocalDlssgHooked() { return isPluginHooked(SlPlugin::LocalDlssg); }

bool StreamlineHooks::isCommonHooked() { return isPluginHooked(SlPlugin::Common); }

bool StreamlineHooks::isPclHooked() { return isPluginHooked(SlPlugin::Pcl); }

bool StreamlineHooks::isReflexHooked() { return isPluginHooked(SlPlugin::Reflex); }
