#include "pch.h"

#include "AmpereMfgLoader.h"

#include <Config.h>
#include <State.h>
#include <Util.h>
#include <misc/IdentifyGpu.h>
#include <misc/ActualRenderGpu.h>
#include <proxies/Ntdll_Proxy.h>

#include <fstream>
#include <sstream>
#include <mutex>

#ifndef NV_GPU_ARCHITECTURE_GA100
#define NV_GPU_ARCHITECTURE_GA100 0x00000170
#endif

namespace AmpereMfgLoader
{
namespace
{
Status s_status;
bool s_setupAttempted = false;
std::recursive_mutex s_mutex;
} // namespace

Status LastStatus()
{
    std::lock_guard lock(s_mutex);
    return s_status;
}

std::string ResolveAutoKernelImage()
{
    const auto actual=optishade::actual_gpu::Current();if(!actual)return "Auto";
    const auto& gpu=*actual;
    const bool onLinux = State::Instance().isRunningOnLinux || gpu.usesVkd3dProton;
    return ResolveAutoKernelImage(static_cast<uint32_t>(gpu.nvidiaArchInfo.architecture_id), gpu.name, onLinux);
}

std::string ResolveRouter()
{
    const auto live=optishade::runtime_render::State().Read();
    if(!live.Fresh(GetTickCount64())||!live.computeKnown)return {};
    return live.computeFamily==20?"SM75":live.computeFamily==30?"SM86":"";
}

namespace {
bool SameRenderingDevice(const optishade::runtime_render::Snapshot& expected) {
    const auto current=optishade::runtime_render::State().Read();
    return current.Fresh(GetTickCount64())&&current.device.identity==expected.device.identity&&
        current.device.luid==expected.device.luid&&current.context==expected.context&&
        current.computeKnown&&current.computeMajor==expected.computeMajor&&current.computeMinor==expected.computeMinor&&
        current.computeFamily==expected.computeFamily;
}
std::string GenerateIniForDevice(const GpuInformation& gpu,const optishade::runtime_render::Snapshot& measured) {
    auto* cfg=Config::Instance();
    const auto router=measured.computeFamily==20?"SM75":measured.computeFamily==30?"SM86":"";
    if(!*router)return {};
    auto kernel=cfg->FGDLSSGAmpereMfgKernelImage.value_or("Auto");
    if(kernel!="PTX"&&kernel!="Cubin")kernel="Auto";
    if(kernel=="Auto")kernel=ResolveAutoKernelImage(static_cast<uint32_t>(gpu.nvidiaArchInfo.architecture_id),
        gpu.name,State::Instance().isRunningOnLinux||gpu.usesVkd3dProton);
    return FormatIniContent(cfg->FGDLSSGAmpereMfgMaxFrames.value_or_default(),kernel,
        cfg->FGDLSSGAmpereMfgHardwareBilinear.value_or_default()?1:0,router,1);
}
}
std::string GenerateIniContent()
{
    const auto measured=optishade::runtime_render::State().Read();
    const auto actual=optishade::actual_gpu::Current();
    if(!actual||!SameRenderingDevice(measured)||
       measured.device.luid!=((uint64_t(uint32_t(actual->luid.HighPart))<<32)|actual->luid.LowPart))return {};
    return GenerateIniForDevice(*actual,measured);
}

void TrySetup()
{
    std::lock_guard lock(s_mutex);
    if (s_setupAttempted)
        return;

    auto* cfg = Config::Instance();
    if (!cfg->FGDLSSGAmpereMfgUnlock.value_or_default())
        return;

    const auto actual=optishade::actual_gpu::Current();
    const auto measured=optishade::runtime_render::State().Read();
    if(!actual||!optishade::runtime_render::CompatibilityMfgSetupContextReady(measured,GetTickCount64())||
       measured.device.luid!=((uint64_t(uint32_t(actual->luid.HighPart))<<32)|actual->luid.LowPart)){
        s_status.ErrorMessage="Waiting for the actual D3D12 rendering adapter and its exact-LUID compute capability.";
        return; // Do not consume the one-shot attempt before a device exists.
    }
    s_setupAttempted = true;

    s_status.Enabled = true;

    // Mutual exclusion: fail if Ada MFG unlock is also enabled
    if (cfg->FGDLSSGAdaMfgUnlock.value_or_default())
    {
        s_status.ErrorMessage = "Cannot enable SM86/SM75 MFG while Ada (RTX 40) MFG unlock is enabled.";
        LOG_ERROR("AmpereMfgLoader: {}", s_status.ErrorMessage);
        return;
    }

    // GPU guard: verify Nvidia Turing or Ampere architecture
    const auto& gpu = *actual;
    if (gpu.vendorId != VendorId::Nvidia)
    {
        s_status.ErrorMessage = "SM86/SM75 MFG requires an NVIDIA GPU.";
        LOG_ERROR("AmpereMfgLoader: {}", s_status.ErrorMessage);
        return;
    }

    const uint32_t archId = static_cast<uint32_t>(gpu.nvidiaArchInfo.architecture_id);
    const bool isAmpere = measured.computeFamily==30&&measured.computeMajor==8&&measured.computeMinor==6;
    const bool isTuring = measured.computeFamily==20&&measured.computeMajor==7&&measured.computeMinor==5;

    if (!isAmpere && !isTuring)
    {
        s_status.ErrorMessage = std::format(
            "SM86/SM75 MFG requires an RTX 20 series (Turing) or RTX 30 series (Ampere) GPU. Detected arch 0x{:x} ({}).",
            archId, gpu.name);
        LOG_ERROR("AmpereMfgLoader: {}", s_status.ErrorMessage);
        return;
    }

    // Locate dlssg_sm86.dll
    auto basePath = Util::DllPath().parent_path();
    auto dllPath = std::filesystem::path(cfg->MainDllPath.value_or(basePath.wstring())) /
                   L"dlssg_sm86" / L"dlssg_sm86.dll";
    std::error_code fileError;
    if (!std::filesystem::exists(dllPath, fileError))
        dllPath = basePath / L"OptiShadeData" / L"Engine" / L"dlssg_sm86" / L"dlssg_sm86.dll";
    if (!std::filesystem::exists(dllPath, fileError))
        dllPath = basePath / L"OptiScaler" / L"dlssg_sm86" / L"dlssg_sm86.dll";
    if (!std::filesystem::exists(dllPath, fileError))
    {
        dllPath = basePath / L"dlssg_sm86" / L"dlssg_sm86.dll";
    }
    if (!std::filesystem::exists(dllPath, fileError))
    {
        // Fallback: check directly beside OptiScaler DLL
        auto fallbackPath = basePath / L"dlssg_sm86.dll";
        if (std::filesystem::exists(fallbackPath, fileError))
        {
            dllPath = fallbackPath;
        }
        else
        {
            s_status.DllFound = false;
            s_status.ErrorMessage = "dlssg_sm86.dll not found in the configured OptiScaler path, OptiShadeData/Engine/dlssg_sm86/, or supported fallback folders.";
            LOG_ERROR("AmpereMfgLoader: {}", s_status.ErrorMessage);
            return;
        }
    }
    s_status.DllFound = true;

    // Generate and write companion dlssg_sm86.ini beside the DLL
    auto iniPath = dllPath.parent_path() / L"dlssg_sm86.ini";
    const auto iniContent=GenerateIniForDevice(gpu,measured);
    if(iniContent.empty()||!SameRenderingDevice(measured)){
        s_status.ErrorMessage="Rendering adapter changed before SM75/SM86 router preparation; restart before retrying.";return;
    }
    try
    {
        std::filesystem::create_directories(iniPath.parent_path());
        std::ofstream iniFile(iniPath, std::ios::out | std::ios::trunc);
        if (!iniFile.is_open())
        {
            s_status.IniWritten = false;
            s_status.ErrorMessage = "Failed to open dlssg_sm86.ini for writing.";
            LOG_ERROR("AmpereMfgLoader: Failed to open {} for writing", wstring_to_string(iniPath.wstring()));
            return;
        }
        iniFile << iniContent;
        iniFile.close();
        if (!iniFile)
            throw std::runtime_error("Could not finish writing dlssg_sm86.ini");
        s_status.IniWritten = true;
    }
    catch (const std::exception& ex)
    {
        s_status.IniWritten = false;
        s_status.ErrorMessage = std::string("Error writing dlssg_sm86.ini: ") + ex.what();
        LOG_ERROR("AmpereMfgLoader: Exception writing INI: {}", ex.what());
        return;
    }

    // File I/O ran on the existing worker. Recheck the actual owner before the
    // one process-lifetime load; an intervening output/device change cannot
    // reuse an earlier adapter's router selection.
    if(!SameRenderingDevice(measured)){
        s_status.ErrorMessage="Rendering device changed during provider preparation; restart before retrying.";return;
    }
    // Load dlssg_sm86.dll
    NtdllProxy::Init();
    LOG_INFO("AmpereMfgLoader: Loading {}", wstring_to_string(dllPath.wstring()));
    HMODULE hMod = NtdllProxy::LoadLibraryExW_Ldr(dllPath.c_str(), NULL, 0);
    if (!hMod)
        hMod = LoadLibraryW(dllPath.c_str());

    if (!hMod)
    {
        DWORD err = GetLastError();
        s_status.DllLoaded = false;
        s_status.ErrorMessage = "Failed to load dlssg_sm86.dll (error code " + std::to_string(err) + ").";
        LOG_ERROR("AmpereMfgLoader: Failed to load dlssg_sm86.dll, error: {}", err);
        return;
    }

    s_status.DllLoaded = true;
    s_status.ErrorMessage.clear();
    LOG_INFO("AmpereMfgLoader: SM86 MFG loaded successfully from {}", wstring_to_string(dllPath.wstring()));
}

} // namespace AmpereMfgLoader
