#include "pch.h"
#include "FSR4ModelSelection.h"
#include "FSR4PresetPolicy.h"
#include <scanner/scanner.h>
#include <detours/detours.h>
#include <hooks/ProcessDetourTransaction.h>

PFN_getModelBlob FSR4ModelSelection::o_getModelBlobSDK = nullptr;
PFN_getModelBlob FSR4ModelSelection::o_getModelBlobDriver = nullptr;
PFN_createModel FSR4ModelSelection::o_createModelSDK = nullptr;
PFN_createModel FSR4ModelSelection::o_createModelDriver = nullptr;
PFN_createModel2 FSR4ModelSelection::o_createModelSDK2 = nullptr;
PFN_createModel2 FSR4ModelSelection::o_createModelDriver2 = nullptr;

namespace
{
std::mutex g_modelSelectionHookMutex;
HMODULE g_modelSelectionSdkModule = nullptr;
HMODULE g_modelSelectionDriverModule = nullptr;

bool PinModelSelectionModule(HMODULE module)
{
    HMODULE pinnedModule = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                            reinterpret_cast<LPCWSTR>(module), &pinnedModule))
    {
        LOG_ERROR("Unable to pin FSR4 model-selection module {:X}; refusing to install callbacks", (uintptr_t) module);
        return false;
    }

    return true;
}
} // namespace

uint32_t getCorrectedPreset(uint32_t preset)
{
	auto* feature = State::Instance().currentFeature;
	const uint32_t target = feature ? feature->TargetWidth() : 0;
	const uint32_t render = feature ? feature->RenderWidth() : 0;
	const bool overridePresent = Config::Instance()->Fsr4Preset.has_value();
	const uint32_t overridePreset = overridePresent ? Config::Instance()->Fsr4Preset.value() : preset;
	const auto correctedPreset = optishade::fsr4::CorrectPreset(preset, target, render, overridePresent, overridePreset);

    State::Instance().currentFsr4Preset = correctedPreset;

    return correctedPreset;
}

uint64_t FSR4ModelSelection::hkgetModelBlobSDK(uint32_t preset, uint64_t unknown, uint64_t* source, uint64_t* size)
{
    LOG_FUNC();

    preset = getCorrectedPreset(preset);

    auto result = o_getModelBlobSDK(preset, unknown, source, size);

    return result;
}

uint64_t FSR4ModelSelection::hkgetModelBlobDriver(uint32_t preset, uint64_t unknown, uint64_t* source, uint64_t* size)
{
    LOG_FUNC();

    preset = getCorrectedPreset(preset);

    auto result = o_getModelBlobDriver(preset, unknown, source, size);

    return result;
}

uint64_t FSR4ModelSelection::hkcreateModelSDK(void* context, uint32_t preset)
{
    LOG_FUNC();

    preset = getCorrectedPreset(preset);

    auto result = o_createModelSDK(context, preset);

    return result;
}

uint64_t FSR4ModelSelection::hkcreateModelDriver(void* context, uint32_t preset)
{
    LOG_FUNC();

    preset = getCorrectedPreset(preset);

    auto result = o_createModelDriver(context, preset);

    return result;
}

uint64_t FSR4ModelSelection::hkcreateModelDriver2(void* context, uint32_t preset, void** model)
{
    LOG_FUNC();

    preset = getCorrectedPreset(preset);

    auto result = o_createModelDriver2(context, preset, model);

    return result;
}

uint64_t FSR4ModelSelection::hkcreateModelSDK2(void* context, uint32_t preset, void** model)
{
    LOG_FUNC();

    preset = getCorrectedPreset(preset);

    auto result = o_createModelSDK2(context, preset, model);

    return result;
}

void FSR4ModelSelection::Hook(HMODULE module, FSR4Source source)
{
    if (module == nullptr)
        return;

    std::lock_guard<std::mutex> hookLock(g_modelSelectionHookMutex);

    auto& hookedModule = source == FSR4Source::SDK ? g_modelSelectionSdkModule : g_modelSelectionDriverModule;
    if (hookedModule != nullptr)
    {
        if (hookedModule != module)
        {
            LOG_WARN("FSR4 model-selection hooks for {} are already bound to {:X}; ignoring replacement module {:X} "
                     "to preserve active callbacks",
                     source == FSR4Source::SDK ? "SDK" : "driver", (uintptr_t) hookedModule, (uintptr_t) module);
        }
        return;
    }

    // These callbacks can run on arbitrary game threads. Detours transactions that enlist only the
    // discovery thread cannot prove callback quiescence, so keep the selected target mapped and
    // retain its hook for the process lifetime instead of detaching it during provider discovery.
    if (!PinModelSelectionModule(module))
    {
        return;
    }

    /// Hooks for getModelBlob

    // Older SDK and Driver use this
    const char* modelBlobPattern = "83 F9 05 0F 87";
    if (!o_getModelBlobSDK && source == FSR4Source::SDK)
    {
        o_getModelBlobSDK = (PFN_getModelBlob) scanner::GetAddress(module, modelBlobPattern);

        if (o_getModelBlobSDK)
        {
            LOG_DEBUG("Hooking model selection o_getModelBlobSDK: {:X}", (uintptr_t) o_getModelBlobSDK);

            auto detourResult = OptiShade::Detours::AttachProcessDetour(
                reinterpret_cast<PVOID*>(&o_getModelBlobSDK), reinterpret_cast<PVOID>(hkgetModelBlobSDK));
            if (detourResult != NO_ERROR)
            {
                LOG_ERROR("Failed to attach detour: {:X}", detourResult);
                o_getModelBlobSDK = nullptr;
            }
        }
    }
    else if (!o_getModelBlobDriver && source == FSR4Source::DriverDll)
    {
        o_getModelBlobDriver = (PFN_getModelBlob) scanner::GetAddress(module, modelBlobPattern);

        if (o_getModelBlobDriver)
        {
            LOG_DEBUG("Hooking model selection o_getModelBlobDriver: {:X}", (uintptr_t) o_getModelBlobDriver);

            auto detourResult = OptiShade::Detours::AttachProcessDetour(
                reinterpret_cast<PVOID*>(&o_getModelBlobDriver), reinterpret_cast<PVOID>(hkgetModelBlobDriver));
            if (detourResult != NO_ERROR)
            {
                LOG_ERROR("Failed to attach detour: {:X}", detourResult);
                o_getModelBlobDriver = nullptr;
            }
        }
    }

    /// Hooks for createModel

    // From amd_fidelityfx_upscaler_dx12 4.0.3.604 from FFX 2.1 SDK
    // Used by some versions of SDK and Driver
    const char* pattern403 =
        "48 89 5C 24 ? 55 56 57 41 54 41 55 41 56 41 57 48 8D AC 24 ? ? ? ? B8 ? ? ? ? E8 ? ? ? ? 48 2B E0 0F 29 B4 24 "
        "? ? ? ? 0F 29 BC 24 ? ? ? ? 48 8B 05 ? ? ? ? 48 33 C4 48 89 85 ? ? ? ? 44 8B F2";

    if (!o_createModelSDK && source == FSR4Source::SDK)
    {
        o_createModelSDK = (PFN_createModel) scanner::GetAddress(module, pattern403);

        if (!o_createModelSDK)
        {
            // From amd_fidelityfx_upscaler_dx12 4.1.0 from FFX 2.2 SDK
            const char* pattern410 =
                "48 8B C4 48 89 58 18 55 56 57 41 54 41 55 41 56 41 57 48 8D A8 28 F2 FF FF 48 81 EC A0 "
                "0E 00 00 0F 29 70 B8 0F 29 78 A8 48 8B ? ? ? ? ? 48 33 C4 48 89 85 78 0D 00 00 44 8B F2";
            o_createModelSDK = (PFN_createModel) scanner::GetAddress(module, pattern410);
        }

        if (o_createModelSDK)
        {
            LOG_DEBUG("Hooking model selection, o_createModelSDK: {:X}", (uintptr_t) o_createModelSDK);

            auto detourResult = OptiShade::Detours::AttachProcessDetour(
                reinterpret_cast<PVOID*>(&o_createModelSDK), reinterpret_cast<PVOID>(hkcreateModelSDK));
            if (detourResult != NO_ERROR)
            {
                LOG_ERROR("Failed to attach detour: {:X}", detourResult);
                o_createModelSDK = nullptr;
            }
        }
    }
    else if (!o_createModelDriver && source == FSR4Source::DriverDll)
    {
        o_createModelDriver = (PFN_createModel) scanner::GetAddress(module, pattern403);

        if (!o_createModelDriver)
        {
            // From amdxcffx64 2.1.0.968/2.2.0.1328
            const char* pattern =
                "48 8B C4 48 89 58 ? 55 56 57 41 54 41 55 41 56 41 57 48 8D A8 ? ? ? ? 48 81 EC ? ? ? ? 0F 29 70 ? 0F "
                "29 78 ? 48 8B 05 ? ? ? ? 48 33 C4 48 89 85 ? ? ? ? 44 8B F2 48 8B F1 E8";
            o_createModelDriver = (PFN_createModel) scanner::GetAddress(module, pattern);
        }

        if (o_createModelDriver)
        {
            LOG_DEBUG("Hooking model selection, o_createModelDriver: {:X}", (uintptr_t) o_createModelDriver);

            auto detourResult = OptiShade::Detours::AttachProcessDetour(
                reinterpret_cast<PVOID*>(&o_createModelDriver), reinterpret_cast<PVOID>(hkcreateModelDriver));
            if (detourResult != NO_ERROR)
            {
                LOG_ERROR("Failed to attach detour: {:X}", detourResult);
                o_createModelDriver = nullptr;
            }
        }
    }

    // From amdxcffx64 2.3.0 / amd_fidelityfx_upscaler_dx12 4.1.1.2740
    const char* pattern411 = "48 8B C4 48 89 58 ? 55 56 57 41 54 41 55 41 56 41 57 48 8D A8 ? ? ? ? 48 81 EC ? ? ? ? "
                             "0F 29 70 ? 0F 29 78 ? 48 8B 05 ? ? ? ? 48 33 C4 48 89 85 ? ? ? ? 4D 8B E8 8B FA 48 8B";

    if (!o_createModelDriver && !o_createModelDriver2 && source == FSR4Source::DriverDll)
    {
        o_createModelDriver2 = (PFN_createModel2) scanner::GetAddress(module, pattern411);

        if (o_createModelDriver2)
        {
            LOG_DEBUG("Hooking model selection, o_createModelDriver2: {:X}", (uintptr_t) o_createModelDriver2);

            auto detourResult = OptiShade::Detours::AttachProcessDetour(
                reinterpret_cast<PVOID*>(&o_createModelDriver2), reinterpret_cast<PVOID>(hkcreateModelDriver2));
            if (detourResult != NO_ERROR)
            {
                LOG_ERROR("Failed to attach detour: {:X}", detourResult);
                o_createModelDriver2 = nullptr;
            }
        }
    }

    else if (!o_createModelSDK && !o_createModelSDK2 && source == FSR4Source::SDK)
    {
        o_createModelSDK2 = (PFN_createModel2) scanner::GetAddress(module, pattern411);

        if (o_createModelSDK2)
        {
            LOG_DEBUG("Hooking model selection, o_createModelSDK2: {:X}", (uintptr_t) o_createModelSDK2);

            auto detourResult = OptiShade::Detours::AttachProcessDetour(
                reinterpret_cast<PVOID*>(&o_createModelSDK2), reinterpret_cast<PVOID>(hkcreateModelSDK2));
            if (detourResult != NO_ERROR)
            {
                LOG_ERROR("Failed to attach detour: {:X}", detourResult);
                o_createModelSDK2 = nullptr;
            }
        }
    }

    if (!o_createModelDriver && !o_getModelBlobDriver && !o_createModelDriver2 && source == FSR4Source::DriverDll)
        LOG_ERROR("Couldn't hook model selection from the driver dll");
    else if (!o_createModelSDK && !o_getModelBlobSDK && !o_createModelSDK2 && source == FSR4Source::SDK)
        LOG_ERROR("Couldn't hook model selection from the SDK dll");

    if ((source == FSR4Source::SDK && (o_createModelSDK || o_getModelBlobSDK || o_createModelSDK2)) ||
        (source == FSR4Source::DriverDll && (o_createModelDriver || o_getModelBlobDriver || o_createModelDriver2)))
    {
        hookedModule = module;
        LOG_DEBUG("Pinned FSR4 model-selection callbacks to module {:X} for process lifetime", (uintptr_t) module);
    }
}
