#include "pch.h"
#include "input_system_internal.h"
#include "InputDetourTransaction.h"

#include <detours/detours.h>

#include <tlhelp32.h>
#include <vector>
#include <string_view>

static bool messageHooks = false;
static bool keyStateHooks = false;
static bool getPosHooks = false;
static bool clipCursorHooks = false;
static bool message2Hooks = false;
static bool hidHooks = false;
static bool rawHooks = false;
static bool windowsHooks = false;
static bool positionHooks = false;
static bool positionIATHooks = false;
static bool inputHookTargetsPinned = false;

namespace OptiInput
{
template <typename Action>
static LONG WithDiagnosedInputTransaction(Action&& action)
{
    const char* stage = "unknown";
    const LONG result = OptiShade::Detours::WithProcessDetourTransaction(std::forward<Action>(action), &stage);
    if (result != NO_ERROR)
        LOG_WARN("Input detour transaction failed stage:{} result:{}; transaction safeguards retained", stage, result);
    return result;
}

SHORT RealGetAsyncKeyStateSafe(int vk)
{
    ScopedHookBypass bypass;

    if (o_GetAsyncKeyState != nullptr)
        return o_GetAsyncKeyState(vk);

    return ::GetAsyncKeyState(vk);
}

SHORT RealGetKeyStateSafe(int vk)
{
    ScopedHookBypass bypass;

    if (o_GetKeyState != nullptr)
        return o_GetKeyState(vk);

    return ::GetKeyState(vk);
}

BOOL RealGetCursorPosSafe(LPPOINT point)
{
    ScopedHookBypass bypass;

    if (o_GetCursorPos != nullptr)
        return o_GetCursorPos(point);

    return ::GetCursorPos(point);
}

namespace
{
struct IatPatch
{
    void** Entry = nullptr;
    void* Original = nullptr;
    void* Detour = nullptr;
    std::string Name;
};

std::vector<IatPatch> gCursorIatPatches;

bool IsSelfModule(HMODULE module)
{
    HMODULE selfModule = nullptr;

    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCWSTR>(&InstallHooks), &selfModule))
    {
        return false;
    }

    return module == selfModule;
}

bool PatchIatEntry(HMODULE module, const char* importName, void* original, void* detour)
{
    if (module == nullptr || importName == nullptr || original == nullptr || detour == nullptr)
        return false;

    if (IsSelfModule(module))
        return false;

    auto* base = reinterpret_cast<std::uint8_t*>(module);
    auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);

    if (dos->e_magic != IMAGE_DOS_SIGNATURE)
        return false;

    auto* nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);

    if (nt->Signature != IMAGE_NT_SIGNATURE)
        return false;

    const auto& importDir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];

    if (importDir.VirtualAddress == 0 || importDir.Size == 0)
        return false;

    auto* desc = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + importDir.VirtualAddress);
    bool patched = false;

    for (; desc->Name != 0; ++desc)
    {
        auto* thunkOrig = desc->OriginalFirstThunk != 0
                              ? reinterpret_cast<IMAGE_THUNK_DATA*>(base + desc->OriginalFirstThunk)
                              : nullptr;

        auto* thunkIat = reinterpret_cast<IMAGE_THUNK_DATA*>(base + desc->FirstThunk);

        if (thunkIat == nullptr)
            continue;

        for (size_t index = 0; thunkIat[index].u1.Function != 0; ++index)
        {
            const char* name = nullptr;

            if (thunkOrig != nullptr && !(thunkOrig[index].u1.Ordinal & IMAGE_ORDINAL_FLAG))
            {
                auto* byName = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + thunkOrig[index].u1.AddressOfData);
                name = reinterpret_cast<const char*>(byName->Name);
            }

            if (name == nullptr || strcmp(name, importName) != 0)
                continue;

            auto** entry = reinterpret_cast<void**>(&thunkIat[index].u1.Function);

            // Only patch entries that still point to the real API.
            // This avoids overwriting another hook chain.
            if (*entry == detour)
            {
                // Keep existing process-lifetime patches valid across input subsystem reinitialization.
                patched = true;
                continue;
            }

            if (*entry != original)
            {
                LOG_DEBUG("OptiInput IAT skip {} module:{} entry:{} current:{} expected:{}", importName,
                          static_cast<void*>(module), static_cast<void*>(entry), *entry, original);
                continue;
            }

            DWORD oldProtect = 0;
            if (!VirtualProtect(entry, sizeof(void*), PAGE_READWRITE, &oldProtect))
            {
                LOG_WARN("OptiInput IAT protect failed {} module:{} entry:{} gle:{}", importName,
                         static_cast<void*>(module), static_cast<void*>(entry), GetLastError());
                continue;
            }

            *entry = detour;

            DWORD ignored = 0;
            VirtualProtect(entry, sizeof(void*), oldProtect, &ignored);
            FlushInstructionCache(GetCurrentProcess(), entry, sizeof(void*));

            gCursorIatPatches.push_back({ entry, original, detour, importName });

            LOG_INFO("OptiInput IAT patched {} module:{} entry:{} original:{} detour:{}", importName,
                     static_cast<void*>(module), static_cast<void*>(entry), original, detour);

            patched = true;
        }
    }

    return patched;
}

bool PatchCursorIatForModule(HMODULE module)
{
    bool patched = false;

    patched |= PatchIatEntry(module, "GetCursorPos", reinterpret_cast<void*>(o_GetCursorPos),
                             reinterpret_cast<void*>(hkGetCursorPos));

    patched |= PatchIatEntry(module, "SetCursorPos", reinterpret_cast<void*>(o_SetCursorPos),
                             reinterpret_cast<void*>(hkSetCursorPos));

    return patched;
}

bool InstallCursorIatHooks()
{
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, GetCurrentProcessId());
    if (snapshot == INVALID_HANDLE_VALUE)
    {
        LOG_WARN("OptiInput cursor IAT snapshot failed gle:{}", GetLastError());
        return false;
    }

    MODULEENTRY32W entry {};
    entry.dwSize = sizeof(entry);

    bool patchedAny = false;

    if (Module32FirstW(snapshot, &entry))
    {
        do
        {
            patchedAny |= PatchCursorIatForModule(entry.hModule);
        } while (Module32NextW(snapshot, &entry));
    }

    CloseHandle(snapshot);

    LOG_INFO("OptiInput cursor IAT hooks installed patched:{} entries:{}", patchedAny ? 1 : 0,
             gCursorIatPatches.size());

    return patchedAny;
}

void ForgetCursorIatHooks()
{
    // These entries live in game-owned modules and route to this pinned
    // process-lifetime DLL. Never rewrite an import while a game thread may
    // be calling it; a subsequent Initialize pass recognizes existing hooks.
    LOG_INFO("OptiInput cursor IAT hooks retained for process lifetime entries:{}", gCursorIatPatches.size());
    gCursorIatPatches.clear();
}

void ResolveOptionalUser32Exports()
{
    HMODULE user32 = GetModuleHandleW(L"user32.dll");

    if (user32 == nullptr)
        user32 = LoadLibraryW(L"user32.dll");

    if (user32 == nullptr)
        return;

    if (o_GetPhysicalCursorPos == nullptr)
    {
        o_GetPhysicalCursorPos =
            reinterpret_cast<GetPhysicalCursorPos_t>(GetProcAddress(user32, "GetPhysicalCursorPos"));
    }

    if (o_SetPhysicalCursorPos == nullptr)
    {
        o_SetPhysicalCursorPos =
            reinterpret_cast<SetPhysicalCursorPos_t>(GetProcAddress(user32, "SetPhysicalCursorPos"));
    }
}
} // namespace

bool InstallHooks()
{
    if (_state.HooksInstalled)
        return true;

    if (!inputHookTargetsPinned && !PinInputHookTargets(
            reinterpret_cast<void*>(&InstallHooks), o_PeekMessageA, o_PeekMessageW, o_GetMessageA, o_GetMessageW,
            o_GetAsyncKeyState, o_GetKeyState, o_GetKeyboardState, o_GetMessagePos, o_GetMouseMovePointsEx,
            o_ClipCursor, o_GetClipCursor, o_SendInput, o_mouse_event, o_PostMessageA, o_PostMessageW,
            o_SendMessageA, o_SendMessageW, o_CreateFileA, o_CreateFileW, o_ReadFile, o_DeviceIoControl,
            o_CloseHandle, o_GetRawInputData, o_GetRawInputBuffer, o_RegisterRawInputDevices, o_SetWindowsHookExA,
            o_SetWindowsHookExW, o_UnhookWindowsHookEx, o_GetCursorPos, o_SetCursorPos, o_GetPhysicalCursorPos,
            o_SetPhysicalCursorPos, hkPeekMessageA, hkPeekMessageW, hkGetMessageA, hkGetMessageW,
            hkGetAsyncKeyState, hkGetKeyState, hkGetKeyboardState, hkGetMessagePos, hkGetMouseMovePointsEx,
            hkClipCursor, hkGetClipCursor, hkSendInput, hkmouse_event, hkPostMessageA, hkPostMessageW,
            hkSendMessageA, hkSendMessageW, hkCreateFileA, hkCreateFileW, hkReadFile, hkDeviceIoControl,
            hkCloseHandle, hkGetRawInputData, hkGetRawInputBuffer, hkRegisterRawInputDevices, hkSetWindowsHookExA,
            hkSetWindowsHookExW, hkUnhookWindowsHookEx, hkGetCursorPos, hkSetCursorPos, hkGetPhysicalCursorPos,
            hkSetPhysicalCursorPos))
    {
        LOG_ERROR("Win32 input hooks were not installed because a callback or target module could not be pinned");
        return false;
    }
    inputHookTargetsPinned = true;

    LOG_INFO("installing Win32 input hooks currentPid:{} targetPid:{} inputPid:{}", _state.CurrentProcessId,
             _state.TargetProcessId, _state.InputProcessId);

    ResolveOptionalUser32Exports();

    if (!messageHooks)
    {
        const LONG result = WithDiagnosedInputTransaction([&] {
            LONG attachResult = NO_ERROR;

            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_PeekMessageA), reinterpret_cast<PVOID>(hkPeekMessageA));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_PeekMessageW), reinterpret_cast<PVOID>(hkPeekMessageW));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_GetMessageA), reinterpret_cast<PVOID>(hkGetMessageA));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_GetMessageW), reinterpret_cast<PVOID>(hkGetMessageW));

            return attachResult;
        });

        messageHooks = result == NO_ERROR;
        if (messageHooks)
            LOG_INFO("Win32 message hooks installed");
        else
            LOG_ERROR("Win32 message hook installation failed result:{}", result);
    }

    if (!keyStateHooks)
    {
        const LONG result = WithDiagnosedInputTransaction([&] {
            LONG attachResult = NO_ERROR;

            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_GetAsyncKeyState), reinterpret_cast<PVOID>(hkGetAsyncKeyState));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_GetKeyState), reinterpret_cast<PVOID>(hkGetKeyState));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_GetKeyboardState), reinterpret_cast<PVOID>(hkGetKeyboardState));

            return attachResult;
        });

        keyStateHooks = result == NO_ERROR;
        if (keyStateHooks)
            LOG_INFO("Win32 key state hooks installed");
        else
            LOG_ERROR("Win32 key state hook installation failed result:{}", result);
    }

    if (!getPosHooks)
    {
        const LONG result = WithDiagnosedInputTransaction([&] {
            LONG attachResult = NO_ERROR;

            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_GetMessagePos), reinterpret_cast<PVOID>(hkGetMessagePos));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_GetMouseMovePointsEx), reinterpret_cast<PVOID>(hkGetMouseMovePointsEx));

            return attachResult;
        });

        getPosHooks = result == NO_ERROR;
        if (getPosHooks)
            LOG_INFO("Win32 GetMessagePos hooks installed");
        else
            LOG_ERROR("Win32 GetMessagePos hook installation failed result:{}", result);
    }

    if (!clipCursorHooks)
    {
        const LONG result = WithDiagnosedInputTransaction([&] {
            LONG attachResult = NO_ERROR;

            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_ClipCursor), reinterpret_cast<PVOID>(hkClipCursor));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_GetClipCursor), reinterpret_cast<PVOID>(hkGetClipCursor));

            return attachResult;
        });

        clipCursorHooks = result == NO_ERROR;
        if (clipCursorHooks)
            LOG_INFO("Win32 clip cursor hooks installed");
        else
            LOG_ERROR("Win32 clip cursor hook installation failed result:{}", result);
    }

    if (!message2Hooks)
    {
        const LONG result = WithDiagnosedInputTransaction([&] {
            LONG attachResult = NO_ERROR;

            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_SendInput), reinterpret_cast<PVOID>(hkSendInput));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_mouse_event), reinterpret_cast<PVOID>(hkmouse_event));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_PostMessageA), reinterpret_cast<PVOID>(hkPostMessageA));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_PostMessageW), reinterpret_cast<PVOID>(hkPostMessageW));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_SendMessageA), reinterpret_cast<PVOID>(hkSendMessageA));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_SendMessageW), reinterpret_cast<PVOID>(hkSendMessageW));

            return attachResult;
        });

        message2Hooks = result == NO_ERROR;
        if (message2Hooks)
            LOG_INFO("Win32 message hooks installed");
        else
            LOG_ERROR("Win32 message hook installation failed result:{}", result);
    }

    if (!State::Instance().isRunningOnLinux && !hidHooks)
    {
        const LONG result = WithDiagnosedInputTransaction([&] {
            LONG attachResult = NO_ERROR;

            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_CreateFileA), reinterpret_cast<PVOID>(hkCreateFileA));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_CreateFileW), reinterpret_cast<PVOID>(hkCreateFileW));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_ReadFile), reinterpret_cast<PVOID>(hkReadFile));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_DeviceIoControl), reinterpret_cast<PVOID>(hkDeviceIoControl));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_CloseHandle), reinterpret_cast<PVOID>(hkCloseHandle));

            return attachResult;
        });

        hidHooks = result == NO_ERROR;
        if (hidHooks)
            LOG_INFO("Win32 HID hooks installed");
        else
            LOG_ERROR("Win32 HID hook installation failed result:{}", result);
    }

    if (!rawHooks)
    {
        const LONG result = WithDiagnosedInputTransaction([&] {
            LONG attachResult = NO_ERROR;

            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_GetRawInputData), reinterpret_cast<PVOID>(hkGetRawInputData));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_GetRawInputBuffer), reinterpret_cast<PVOID>(hkGetRawInputBuffer));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_RegisterRawInputDevices), reinterpret_cast<PVOID>(hkRegisterRawInputDevices));

            return attachResult;
        });

        rawHooks = result == NO_ERROR;
        if (rawHooks)
            LOG_INFO("Win32 raw input hooks installed");
        else
            LOG_ERROR("Win32 raw input installation failed result:{}", result);
    }

    if (!windowsHooks)
    {
        const LONG result = WithDiagnosedInputTransaction([&] {
            LONG attachResult = NO_ERROR;

            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_SetWindowsHookExA), reinterpret_cast<PVOID>(hkSetWindowsHookExA));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_SetWindowsHookExW), reinterpret_cast<PVOID>(hkSetWindowsHookExW));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_UnhookWindowsHookEx), reinterpret_cast<PVOID>(hkUnhookWindowsHookEx));

            return attachResult;
        });

        windowsHooks = result == NO_ERROR;
        if (windowsHooks)
            LOG_INFO("Win32 windows input hooks installed");
        else
            LOG_ERROR("Win32 windows input installation failed result:{}", result);
    }

    if (!positionHooks)
    {
        const LONG result = WithDiagnosedInputTransaction([&] {
            LONG attachResult = NO_ERROR;

            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_GetCursorPos), reinterpret_cast<PVOID>(hkGetCursorPos));
            attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_SetCursorPos), reinterpret_cast<PVOID>(hkSetCursorPos));

            if (o_GetPhysicalCursorPos != nullptr)
                attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_GetPhysicalCursorPos), reinterpret_cast<PVOID>(hkGetPhysicalCursorPos));

            if (o_SetPhysicalCursorPos != nullptr)
                attachResult = QueueInputDetour(attachResult, reinterpret_cast<PVOID*>(&o_SetPhysicalCursorPos), reinterpret_cast<PVOID>(hkSetPhysicalCursorPos));

            return attachResult;
        });

        positionHooks = result == NO_ERROR;
        if (positionHooks)
            LOG_INFO("Win32 position input hooks installed");
        else
            LOG_ERROR("Win32 position input installation failed result:{}", result);
    }

    // If CursorPos hooks are not installed, try to install
    // IAT (Import Address Table) hooks for CursorPos
    if (!positionHooks && !positionIATHooks)
        positionIATHooks = InstallCursorIatHooks();

    _state.HooksInstalled = messageHooks && keyStateHooks && getPosHooks && clipCursorHooks && message2Hooks &&
                            hidHooks && rawHooks && windowsHooks && (positionHooks || positionIATHooks);

    return _state.HooksInstalled;
}

void RemoveHooks()
{
    if (!_state.HooksInstalled)
        return;

    LOG_INFO("Win32 input hooks retained for process lifetime; blocking policies become inactive at shutdown");
    if (positionIATHooks)
        ForgetCursorIatHooks();
    positionIATHooks = false;
    _state.HooksInstalled = false;
}

} // namespace OptiInput
