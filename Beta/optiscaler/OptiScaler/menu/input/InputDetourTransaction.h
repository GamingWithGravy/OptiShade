#pragma once

#include <Windows.h>
#include <hooks/ProcessDetourTransaction.h>

#include <cstdint>
#include <utility>

namespace OptiInput
{
template <typename Target>
inline bool PinInputHookTarget(Target target)
{
    if (target == nullptr)
        return true;

    HMODULE owner = nullptr;
    return GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                              reinterpret_cast<LPCWSTR>(reinterpret_cast<std::uintptr_t>(target)), &owner) != FALSE;
}

template <typename... Targets>
inline bool PinInputHookTargets(Targets... targets)
{
    return (PinInputHookTarget(targets) && ...);
}

inline LONG QueueInputDetour(LONG previousResult, PVOID* original, PVOID detour)
{
    return OptiShade::Detours::QueueProcessDetour(previousResult, original, detour);
}

template <typename Action>
LONG WithInputDetourTransaction(Action&& action)
{
    return OptiShade::Detours::WithProcessDetourTransaction(std::forward<Action>(action));
}
} // namespace OptiInput