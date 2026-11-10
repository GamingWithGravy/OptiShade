#pragma once
#include <windows.h>
// Transaction double deliberately calls the hook before Commit returns.
inline void** pendingTrampoline=nullptr;
inline void (*atCommit)()=nullptr;
inline LONG DetourTransactionBegin(){return NO_ERROR;}
inline LONG DetourUpdateThread(HANDLE){return NO_ERROR;}
struct DetourTrampoline;using PDETOUR_TRAMPOLINE=DetourTrampoline*;
inline LONG DetourAttachEx(void** slot,void*,PDETOUR_TRAMPOLINE* result,void**,void**){pendingTrampoline=slot;*result=reinterpret_cast<PDETOUR_TRAMPOLINE>(*slot);return NO_ERROR;}
inline LONG DetourTransactionAbort(){pendingTrampoline=nullptr;return NO_ERROR;}
inline LONG DetourTransactionCommit(){if(atCommit)atCommit();pendingTrampoline=nullptr;return NO_ERROR;}
