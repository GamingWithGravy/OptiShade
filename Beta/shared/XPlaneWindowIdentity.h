#pragma once
#include <Windows.h>
#include <cwchar>
namespace optishade::window {
// Caption identity only: never invoke a simulator/plugin window procedure while
// the rendering route owns its presentation mutex. GetWindowText sends WM_GETTEXT
// synchronously to windows in this process and can form a UI/render lock cycle.
inline bool IsXPlaneMainWindow(HWND hwnd) noexcept {
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (!IsWindow(hwnd) || pid != GetCurrentProcessId() || GetAncestor(hwnd, GA_ROOT) != hwnd ||
        GetWindow(hwnd, GW_OWNER) || (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW)) return false;
    using ReadCaption = int (WINAPI*)(HWND, LPWSTR, int);
    static const auto read = reinterpret_cast<ReadCaption>(
        GetProcAddress(GetModuleHandleW(L"user32.dll"), "InternalGetWindowText"));
    // Do not fall back to a synchronous message if the OS lacks this entry point.
    wchar_t title[256]{};
    if (!read || read(hwnd, title, 256) <= 0) return false;
    return wcsncmp(title, L"X-System", 8) == 0 || wcsncmp(title, L"X-Plane", 7) == 0;
}
}
