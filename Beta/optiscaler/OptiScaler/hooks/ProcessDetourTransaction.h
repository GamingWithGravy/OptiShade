#pragma once

#include <Windows.h>
#include <detours/detours.h>
#include <tlhelp32.h>

#include <algorithm>
#include <mutex>
#include <unordered_set>
#include <vector>

namespace OptiShade::Detours
{
inline std::mutex& ProcessDetourTransactionMutex()
{
    // Detours keeps one transaction in process-global state. Hook discovery
    // can arrive concurrently from graphics initialization on different
    // threads, so serialize every transaction routed through this helper.
    static std::mutex transactionMutex;
    return transactionMutex;
}

inline LONG QueueProcessDetour(LONG previousResult, PVOID* original, PVOID detour)
{
    if (previousResult != NO_ERROR)
        return previousResult;
    return DetourAttach(original, detour);
}

// deniedThreads: when given, a thread that cannot be opened (access denied) is
// recorded there and skipped instead of failing the whole transaction.
inline LONG EnlistCurrentProcessThreads(std::vector<HANDLE>& enlistedHandles,std::vector<DWORD>* deniedThreads=nullptr)
{
    const DWORD processId = GetCurrentProcessId();
    const DWORD currentThreadId = GetCurrentThreadId();
    std::unordered_set<DWORD> seen;

    // Repeat until one full snapshot finds no new threads. The transaction is
    // short and hook setup is not a per-frame operation; fail closed if the
    // process keeps changing faster than we can enumerate.
    for (unsigned pass = 0; pass < 8; ++pass)
    {
        HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if (snapshot == INVALID_HANDLE_VALUE)
        {
            const DWORD error = GetLastError();
            return static_cast<LONG>(error != ERROR_SUCCESS ? error : ERROR_GEN_FAILURE);
        }

        THREADENTRY32 entry {};
        entry.dwSize = sizeof(entry);
        BOOL hasEntry = Thread32First(snapshot, &entry);
        bool discoveredNewThread = false;
        LONG result = NO_ERROR;
        if (!hasEntry)
        {
            const DWORD error = GetLastError();
            if (error != ERROR_NO_MORE_FILES)
                result = static_cast<LONG>(error != ERROR_SUCCESS ? error : ERROR_GEN_FAILURE);
        }

        while (hasEntry)
        {
            if (entry.th32OwnerProcessID == processId && entry.th32ThreadID != currentThreadId &&
                seen.insert(entry.th32ThreadID).second)
            {
                discoveredNewThread = true;
                HANDLE thread = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT, FALSE,
                                           entry.th32ThreadID);
                if (thread == nullptr)
                {
                    const DWORD error = GetLastError();
                    if (error == ERROR_ACCESS_DENIED && deniedThreads)
                        deniedThreads->push_back(entry.th32ThreadID);
                    else if (error != ERROR_INVALID_PARAMETER)
                        result = static_cast<LONG>(error);
                    else
                        seen.erase(entry.th32ThreadID); // It exited; permit a rapidly reused ID on the next pass.
                }
                else
                {
                    result = DetourUpdateThread(thread);
                    if (result == NO_ERROR)
                    {
                        try
                        {
                            enlistedHandles.push_back(thread);
                        }
                        catch (...)
                        {
                            CloseHandle(thread);
                            throw;
                        }
                    }
                    else
                    {
                        const bool exited = WaitForSingleObject(thread, 0) == WAIT_OBJECT_0;
                        CloseHandle(thread);
                        if (exited)
                            result = NO_ERROR; // The thread exited while the snapshot was being processed.
                    }
                }

                if (result != NO_ERROR)
                    break;
            }

            entry.dwSize = sizeof(entry);
            hasEntry = Thread32Next(snapshot, &entry);
            if (!hasEntry)
            {
                const DWORD error = GetLastError();
                if (error != ERROR_NO_MORE_FILES)
                    result = static_cast<LONG>(error != ERROR_SUCCESS ? error : ERROR_GEN_FAILURE);
            }
        }

        CloseHandle(snapshot);
        if (result != NO_ERROR)
            return result;

        // Remove handles for threads that exited before the transaction commits.
        enlistedHandles.erase(std::remove_if(enlistedHandles.begin(), enlistedHandles.end(), [](HANDLE thread) {
                                 if (WaitForSingleObject(thread, 0) != WAIT_OBJECT_0)
                                     return false;
                                 CloseHandle(thread);
                                 return true;
                             }),
                             enlistedHandles.end());

        if (!discoveredNewThread)
            return NO_ERROR;
    }

    return ERROR_RETRY;
}

template <typename Action>
LONG WithProcessDetourTransaction(Action&& action, const char** diagnosticStage = nullptr)
{
    std::lock_guard<std::mutex> transactionLock(ProcessDetourTransactionMutex());
    if (diagnosticStage) *diagnosticStage = "begin";
    LONG result = DetourTransactionBegin();
    if (result != NO_ERROR)
        return result;

    std::vector<HANDLE> threadHandles;
    try
    {
        if (diagnosticStage) *diagnosticStage = "current_thread";
        result = DetourUpdateThread(GetCurrentThread());
        if (result == NO_ERROR)
        {
            if (diagnosticStage) *diagnosticStage = "enlist_process_threads";
            result = EnlistCurrentProcessThreads(threadHandles);
        }
    }
    catch (...)
    {
        result = ERROR_NOT_ENOUGH_MEMORY;
    }

    if (result == NO_ERROR)
    {
        try
        {
            if (diagnosticStage) *diagnosticStage = "attach_targets";
            result = action();
        }
        catch (...)
        {
            result = ERROR_NOT_ENOUGH_MEMORY;
        }
    }

    if (result == NO_ERROR)
    {
        if (diagnosticStage) *diagnosticStage = "commit";
        result = DetourTransactionCommit();
    }
    else
        DetourTransactionAbort();

    for (HANDLE thread : threadHandles)
        CloseHandle(thread);

    return result;
}

inline LONG AttachProcessDetour(PVOID* original, PVOID detour)
{
    return WithProcessDetourTransaction([&]() { return QueueProcessDetour(NO_ERROR, original, detour); });
}
} // namespace OptiShade::Detours
