// feed_ngx_trust.h -- why NGX would not load the driver's own _nvngx.dll in this process.
//
// The NGX log that 1.18.0-beta.1 started collecting on failure (#136) gave the same picture on
// two machines, in two games (MK11 #132, RE2 #141), with the same files loading fine in host64:
//
//   [NGXLoadLibrary:326] error: failed to load NGXCore: 126 (<game folder>\_nvngx.dll)     <- absent, fine
//   [NGXLoadLibrary:326] error: failed to load NGXCore: 0 (<DriverStore>\_nvngx.dll)        <- refused
//
// The NGX SDK linked into this project does not LoadLibrary the core directly. Read from
// nvsdk_ngx_d.lib (NGXLoadLibrary -> ngx::nvLoadSignedLibraryExW -> nvVerifyFileSignatureW):
// it opens the file, runs WinVerifyTrust (WINTRUST_ACTION_GENERIC_VERIFY_V2, cache-only URL
// retrieval) through wintrust.dll and crypt32.dll that it loads itself, then walks the signer's
// chain and requires an NVIDIA signer and NVIDIA's subordinate CA key. Only then LoadLibraryExW.
// "126" is a missing file. A refusal from WinVerifyTrust itself leaves its TRUST_E_* code as the
// last error. A last error of 0 is what is left when Windows says the signature is good but the
// chain walk does not end at NVIDIA -- the signer or chain helper returned nothing, or the
// signer or issuer did not match. So whatever differs is inside this process: something that has
// hooked the file, loader or crypto functions NGX goes through, or that changed what they return.
//
// This re-runs the same check from here, step by step, so the next report says which step
// failed. It also says which of the functions involved are detoured, and into which module, and
// names every module in the process that does not ship with Windows. Diagnostic only: it runs
// after NGX has already failed. Header-only, shared with host64 (Requires <windows.h>).

#pragma once
#include <wincrypt.h>   // WIN32_LEAN_AND_MEAN leaves it out, and wintrust.h needs it
#include <wintrust.h>
#include <algorithm>

// The module an address belongs to, as a short name; "(no module: runtime-allocated code)"
// for a trampoline page, which is what hook libraries jump through.
static void FeedNgxModuleOf(const void *addr, char *out, size_t n, bool *is_system)
{
    HMODULE m = nullptr;
    *is_system = false;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            static_cast<LPCWSTR>(addr), &m) || m == nullptr)
    {
        strcpy_s(out, n, "(no module: runtime-allocated code, i.e. a hook's trampoline)");
        return;
    }
    wchar_t path[MAX_PATH] = {}, windir[MAX_PATH] = {};
    GetModuleFileNameW(m, path, MAX_PATH);
    GetWindowsDirectoryW(windir, MAX_PATH);
    const size_t wl = wcslen(windir);
    *is_system = wl > 0 && _wcsnicmp(path, windir, wl) == 0;
    WideCharToMultiByte(CP_UTF8, 0, path, -1, out, static_cast<int>(n), nullptr, nullptr);
}

// Where a function's first instruction goes, if it is a jump. Follows up to four hops, which is
// enough for a forwarder stub (kernel32 -> kernelbase) plus a hook library's relay page.
static const void *FeedNgxFollowJumps(const void *fn)
{
    const unsigned char *p = static_cast<const unsigned char *>(fn);
    for (int hop = 0; hop < 4 && p != nullptr; ++hop)
    {
        MEMORY_BASIC_INFORMATION mbi = {};
        if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0 || mbi.State != MEM_COMMIT ||
            (mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) == 0)
            return p;
        if (p[0] == 0xE9)                                     // jmp rel32
        { INT32 d; memcpy(&d, p + 1, 4); p = p + 5 + d; continue; }
        if (p[0] == 0xEB)                                     // jmp rel8
        { p = p + 2 + static_cast<signed char>(p[1]); continue; }
        if (p[0] == 0xFF && p[1] == 0x25)                     // jmp [rip+disp32] (x64) / jmp [abs32] (x86)
        {
            INT32 d; memcpy(&d, p + 2, 4);
#ifdef _WIN64
            const void *const *slot = reinterpret_cast<const void *const *>(p + 6 + d);
#else
            const void *const *slot = reinterpret_cast<const void *const *>(static_cast<UINT_PTR>(static_cast<UINT32>(d)));
#endif
            if (VirtualQuery(slot, &mbi, sizeof(mbi)) == 0 || mbi.State != MEM_COMMIT) return p;
            p = static_cast<const unsigned char *>(*slot);
            continue;
        }
#ifdef _WIN64
        if (p[0] == 0x48 && p[1] == 0xB8 && p[10] == 0xFF && p[11] == 0xE0)   // mov rax, imm64; jmp rax
        { const void *t; memcpy(&t, p + 2, sizeof(t)); p = static_cast<const unsigned char *>(t); continue; }
#endif
        return p;
    }
    return p;
}

static void FeedNgxHookScan(void (*log)(const char *, ...), const char *tag)
{
    struct Fn { const wchar_t *mod; const char *name; };
    static const Fn kFns[] = {
        { L"kernel32.dll", "LoadLibraryExW" },      { L"kernel32.dll", "CreateFileW" },
        { L"kernel32.dll", "GetFileAttributesW" },  { L"kernelbase.dll", "LoadLibraryExW" },
        { L"kernelbase.dll", "CreateFileW" },       { L"kernelbase.dll", "GetFileAttributesW" },
        { L"ntdll.dll", "LdrLoadDll" },             { L"ntdll.dll", "NtCreateFile" },
        { L"ntdll.dll", "NtOpenFile" },             { L"ntdll.dll", "NtCreateSection" },
        { L"ntdll.dll", "NtMapViewOfSection" },     { L"ntdll.dll", "NtQueryAttributesFile" },
        { L"wintrust.dll", "WinVerifyTrust" },      { L"wintrust.dll", "WTHelperProvDataFromStateData" },
        { L"wintrust.dll", "WTHelperGetProvSignerFromChain" },
        { L"crypt32.dll", "CryptQueryObject" },     { L"crypt32.dll", "CryptMsgGetParam" },
        { L"crypt32.dll", "CertGetNameStringA" },   { L"crypt32.dll", "CertGetIssuerCertificateFromStore" },
        { L"crypt32.dll", "CertFindCertificateInStore" },
    };
    int hooked = 0;
    for (const Fn &f : kFns)
    {
        HMODULE m = GetModuleHandleW(f.mod);
        if (m == nullptr) continue;
        const void *fn = reinterpret_cast<const void *>(GetProcAddress(m, f.name));
        if (fn == nullptr) continue;
        const void *end = FeedNgxFollowJumps(fn);
        if (end == fn) continue;
        char where[MAX_PATH * 3];
        bool sys = false;
        FeedNgxModuleOf(end, where, sizeof(where), &sys);
        if (sys) continue;   // kernel32 -> kernelbase forwarders and the like
        char modname[64] = {};
        WideCharToMultiByte(CP_UTF8, 0, f.mod, -1, modname, sizeof(modname), nullptr, nullptr);
        log("[%s]   hooked: %s!%s -> %s", tag, modname, f.name, where);
        ++hooked;
    }
    log("[%s]   %d of the file/loader/signature functions NGX goes through %s detoured in this process%s", tag, hooked,
        hooked == 1 ? "is" : "are", hooked == 0 ? "" : " (ReShade's own LoadLibrary hooks are expected; anything else is a suspect)");
}

// Every module in the process that is not under the Windows directory. That is the game, ReShade,
// the add-ons -- and whatever else came in: an overlay, a crack or emulator, an injector.
static void FeedNgxListForeignModules(void (*log)(const char *, ...), const char *tag)
{
    typedef BOOL (WINAPI *PFN_Enum)(HANDLE, HMODULE *, DWORD, DWORD *);
    const auto en = reinterpret_cast<PFN_Enum>(GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "K32EnumProcessModules"));
    if (en == nullptr) return;
    HMODULE mods[512];
    DWORD need = 0;
    if (!en(GetCurrentProcess(), mods, sizeof(mods), &need)) return;
    const DWORD count = (std::min)(static_cast<DWORD>(need / sizeof(HMODULE)), static_cast<DWORD>(512));
    wchar_t windir[MAX_PATH] = {};
    GetWindowsDirectoryW(windir, MAX_PATH);
    const size_t wl = wcslen(windir);
    char line[900] = {};
    int n = 0;
    for (DWORD i = 0; i < count; ++i)
    {
        wchar_t path[MAX_PATH] = {};
        if (GetModuleFileNameW(mods[i], path, MAX_PATH) == 0) continue;
        if (wl > 0 && _wcsnicmp(path, windir, wl) == 0) continue;
        char u8[MAX_PATH * 3];
        WideCharToMultiByte(CP_UTF8, 0, path, -1, u8, sizeof(u8), nullptr, nullptr);
        if (strlen(line) + strlen(u8) + 4 >= sizeof(line))
        {
            log("[%s]   modules not from Windows: %s", tag, line);
            line[0] = '\0';
        }
        if (line[0] != '\0') strcat_s(line, sizeof(line), " | ");
        strcat_s(line, sizeof(line), u8);
        ++n;
    }
    if (line[0] != '\0') log("[%s]   modules not from Windows: %s", tag, line);
    log("[%s]   (%d module(s) outside the Windows folder; anything here that is not the game, ReShade or a DLSS 5 add-on is "
        "the first thing to remove)", tag, n);
}

// The check NGX makes, made again: WinVerifyTrust, then the signer and its chain, by name.
// core_dir is the NGXCore FullPath from the registry. Returns true when every step passed here.
static bool FeedNgxTrustProbe(void (*log)(const char *, ...), const char *tag, const wchar_t *core_dir)
{
    wchar_t file[MAX_PATH];
    _snwprintf_s(file, _TRUNCATE, L"%s\\_nvngx.dll", core_dir);
    char file8[MAX_PATH * 3];
    WideCharToMultiByte(CP_UTF8, 0, file, -1, file8, sizeof(file8), nullptr, nullptr);
    if (GetFileAttributesW(file) == INVALID_FILE_ATTRIBUTES)
    {
        log("[%s]   trust probe: %s is not there (error %lu)", tag, file8, GetLastError());
        return false;
    }

    HMODULE wt = LoadLibraryExW(L"wintrust.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    HMODULE c32 = LoadLibraryExW(L"crypt32.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (wt == nullptr || c32 == nullptr)
    {
        log("[%s]   trust probe: wintrust.dll/crypt32.dll would not load from System32 (error %lu) -- NGX loads them "
            "the same way, so this alone stops it", tag, GetLastError());
        if (wt) FreeLibrary(wt);
        if (c32) FreeLibrary(c32);
        return false;
    }
    typedef LONG (WINAPI *PFN_WVT)(HWND, GUID *, LPVOID);
    typedef CRYPT_PROVIDER_DATA *(WINAPI *PFN_ProvData)(HANDLE);
    typedef CRYPT_PROVIDER_SGNR *(WINAPI *PFN_Signer)(CRYPT_PROVIDER_DATA *, DWORD, BOOL, DWORD);
    typedef CRYPT_PROVIDER_CERT *(WINAPI *PFN_Cert)(CRYPT_PROVIDER_SGNR *, DWORD);
    typedef DWORD (WINAPI *PFN_Name)(PCCERT_CONTEXT, DWORD, DWORD, void *, LPSTR, DWORD);
    const auto wvt    = reinterpret_cast<PFN_WVT>(GetProcAddress(wt, "WinVerifyTrust"));
    const auto pdata  = reinterpret_cast<PFN_ProvData>(GetProcAddress(wt, "WTHelperProvDataFromStateData"));
    const auto signer = reinterpret_cast<PFN_Signer>(GetProcAddress(wt, "WTHelperGetProvSignerFromChain"));
    const auto pcert  = reinterpret_cast<PFN_Cert>(GetProcAddress(wt, "WTHelperGetProvCertFromChain"));
    const auto cname  = reinterpret_cast<PFN_Name>(GetProcAddress(c32, "CertGetNameStringA"));
    bool ok = false;
    if (wvt && pdata && signer && pcert && cname)
    {
        GUID action = { 0x00AAC56B, 0xCD44, 0x11D0, { 0x8C, 0xC2, 0x00, 0xC0, 0x4F, 0xC2, 0x95, 0xEE } };   // GENERIC_VERIFY_V2
        WINTRUST_FILE_INFO fi = {};
        fi.cbStruct      = sizeof(fi);
        fi.pcwszFilePath = file;
        WINTRUST_DATA wd = {};
        wd.cbStruct            = sizeof(wd);
        wd.dwUIChoice          = WTD_UI_NONE;
        wd.fdwRevocationChecks = WTD_REVOKE_NONE;
        wd.dwUnionChoice       = WTD_CHOICE_FILE;
        wd.pFile               = &fi;
        wd.dwStateAction       = WTD_STATEACTION_VERIFY;
        wd.dwProvFlags         = WTD_CACHE_ONLY_URL_RETRIEVAL;   // what NGX passes
        SetLastError(0);
        const LONG st = wvt(static_cast<HWND>(INVALID_HANDLE_VALUE), &action, &wd);
        log("[%s]   trust probe: WinVerifyTrust(%s) -> 0x%08lX%s", tag, file8, static_cast<unsigned long>(st),
            st == 0 ? " (signature valid)" : st == static_cast<LONG>(0x800B0100) ? " (TRUST_E_NOSIGNATURE)"
            : st == static_cast<LONG>(0x80096010) ? " (TRUST_E_BAD_DIGEST: the file does not match its signature)"
            : st == static_cast<LONG>(0x800B0109) ? " (CERT_E_UNTRUSTEDROOT)" : "");
        if (st == 0)
        {
            CRYPT_PROVIDER_DATA *pd = pdata(wd.hWVTStateData);
            CRYPT_PROVIDER_SGNR *sg = pd != nullptr ? signer(pd, 0, FALSE, 0) : nullptr;
            if (pd == nullptr || sg == nullptr)
                log("[%s]   trust probe: the provider data / signer came back empty (error %lu) -- exactly the step "
                    "that leaves NGX with last error 0", tag, GetLastError());
            else
            {
                log("[%s]   trust probe: %lu certificate(s) in the signer's chain", tag, static_cast<unsigned long>(sg->csCertChain));
                ok = sg->csCertChain >= 2;
                for (DWORD i = 0; i < sg->csCertChain && i < 4; ++i)
                {
                    CRYPT_PROVIDER_CERT *pc = pcert(sg, i);
                    char nm[256] = "?";
                    if (pc != nullptr && pc->pCert != nullptr)
                        cname(pc->pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nullptr, nm, sizeof(nm));
                    log("[%s]     [%lu] %s", tag, static_cast<unsigned long>(i), nm);
                    if (i == 0 && strstr(nm, "NVIDIA") == nullptr) ok = false;
                }
                if (!ok)
                    log("[%s]   trust probe: the chain does not start at an NVIDIA signer with an issuer above it -- "
                        "NGX refuses that with last error 0", tag);
            }
        }
        wd.dwStateAction = WTD_STATEACTION_CLOSE;
        wvt(static_cast<HWND>(INVALID_HANDLE_VALUE), &action, &wd);
    }
    else
        log("[%s]   trust probe: wintrust.dll/crypt32.dll are missing exports NGX uses", tag);
    FreeLibrary(c32);
    FreeLibrary(wt);
    return ok;
}

// Everything above, in order, under one heading. Called once, after NGX has failed.
static void FeedNgxTrustReport(void (*log)(const char *, ...), const char *tag)
{
    wchar_t core[MAX_PATH] = {};
    HKEY k = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore", 0,
                      KEY_READ | KEY_WOW64_64KEY, &k) == ERROR_SUCCESS)
    {
        DWORD cb = sizeof(core), type = 0;
        RegQueryValueExW(k, L"FullPath", nullptr, &type, reinterpret_cast<BYTE *>(core), &cb);
        RegCloseKey(k);
    }
    log("[%s] ===== why NGX would not load the driver's NGX core here%s =====", tag,
        g_ngx_core_refused_unsigned ? " (NGX's log above: \"failed to load NGXCore: 0\" = its NVIDIA signature check said no)" : "");
    const bool trusted = core[0] != L'\0' && FeedNgxTrustProbe(log, tag, core);
    FeedNgxHookScan(log, tag);
    FeedNgxListForeignModules(log, tag);
    const bool in_host = strcmp(tag, "host") == 0;   // already the clean process: no helper to suggest
    if (g_ngx_core_refused_unsigned && trusted && in_host)
        log("[%s] verdict: Windows verifies the driver's _nvngx.dll as NVIDIA-signed from inside this helper, yet NGX's own "
            "copy of that check refused it. The hooked functions and the modules listed above are where to look.", tag);
    else if (g_ngx_core_refused_unsigned && in_host)
        log("[%s] verdict: the driver's _nvngx.dll does not pass the signature check even in this helper (see the trust "
            "probe lines): reinstall the NVIDIA driver (clean install).", tag);
    else if (g_ngx_core_refused_unsigned && trusted)
        log("[%s] verdict: Windows verifies the driver's _nvngx.dll as NVIDIA-signed from inside this process, yet NGX's own "
            "copy of that check refused it. Something in this process changes what NGX sees -- the hooked functions and the "
            "modules listed above are where to look. The 64-bit helper mode runs NGX in host64, a process with none of them.", tag);
    else if (g_ngx_core_refused_unsigned)
        log("[%s] verdict: the driver's _nvngx.dll does not pass the signature check from inside this process (see the "
            "trust probe lines). If host64\\dlss5-feed-host64.exe --test passes on the same PC, it is this process: the "
            "64-bit helper mode runs NGX there instead.", tag);
    log("[%s] ===== end =====", tag);
}
