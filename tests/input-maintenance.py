"""Compile production input policies/hooks against deterministic Win32 originals.

No game, device I/O or input injection. The WndProc fixture uses hidden test windows.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
src = root / 'optiscaler/OptiScaler/menu/input'
out = root / 'test-run'
out.mkdir(exist_ok=True)

def extract(file, name):
    text = (src / file).read_text()
    start = re.search(r'^.*\b' + name + r'\([^;]*?\)\s*\{', text, re.M).start()
    begin = text.index('{', start)
    depth, end = 1, begin + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

hid = r'''
#include <Windows.h>
#include <winioctl.h>
#include <hidusage.h>
#include <hidclass.h>
#include <array>
#include <mutex>
#include <string>
#include <algorithm>
#include <cwctype>
#include <cstdint>
#include <cassert>
#include <cstdio>
#ifndef HID_USAGE_GENERIC_MULTI_AXIS_CONTROLLER
#define HID_USAGE_GENERIC_MULTI_AXIS_CONTROLLER 8
#endif
unsigned warningCount=0; ULONGLONG tick=100;
#define LOG_WARN(...) (++warningCount)
#define OPTIINPUT_LOG_VERBOSE(...) ((void)0)
#define GetTickCount64() tick
enum class HidDeviceKind {Other,Keyboard,Mouse,Gamepad};
struct HidHandleSlot {bool InUse=false;HANDLE Handle=nullptr;HidDeviceKind Kind=HidDeviceKind::Other;USHORT UsagePage=0,Usage=0;std::uint64_t Generation=0;};
constexpr size_t MaxTrackedHidHandles=64;
struct State {
 std::recursive_mutex Mutex;
 std::array<HidHandleSlot,MaxTrackedHidHandles> HidHandleSlots{};
 bool HidMouseHandleSeen=false,HidKeyboardHandleSeen=false,HidGamepadHandleSeen=false,HidOtherHandleSeen=false;
 uint64_t HidCreateFileCallCount=0,HidTrackedHandleCount=0,HidNextGeneration=0,HidTrackingOverflowCount=0;
 ULONGLONG HidLastOverflowWarning=0;
 uint64_t HidReadFileCallCount=0,HidReadFileBlockedCount=0,HidReadFilePassedCount=0;
 uint64_t HidDeviceIoControlCallCount=0,HidDeviceIoControlBlockedCount=0,HidDeviceIoControlPassedCount=0;
} _state;
thread_local int bypassHookDepth=0;
struct ScopedHookBypass{ScopedHookBypass(){++bypassHookDepth;}~ScopedHookBypass(){--bypassHookDepth;}};
USHORT usage=HID_USAGE_GENERIC_MOUSE;bool visible=false,closeOk=true,reuseDuringClose=false,readOk=true;
HANDLE returned=reinterpret_cast<HANDLE>(1);
bool TryQueryHidUsage(HANDLE,USHORT*page,USHORT*value){*page=HID_USAGE_PAGE_GENERIC;*value=usage;SetLastError(900);return true;}
bool ShouldBlockMouseInputLocked(){return visible;}
void TrackHidHandleLocked(HANDLE,const std::wstring&);
HANDLE WINAPI OpenW(LPCWSTR,DWORD,DWORD,LPSECURITY_ATTRIBUTES,DWORD,DWORD,HANDLE){SetLastError(123);return returned;}
HANDLE WINAPI OpenA(LPCSTR,DWORD,DWORD,LPSECURITY_ATTRIBUTES,DWORD,DWORD,HANDLE){SetLastError(123);return returned;}
BOOL WINAPI Close(HANDLE h){if(reuseDuringClose){reuseDuringClose=false;TrackHidHandleLocked(h,L"\\\\?\\hid#reconnected");}SetLastError(closeOk?77:ERROR_INVALID_HANDLE);return closeOk;}
BOOL WINAPI Read(HANDLE,LPVOID,DWORD,LPDWORD n,LPOVERLAPPED){if(n)*n=4;SetLastError(readOk?77:ERROR_IO_PENDING);return readOk;}
BOOL WINAPI Control(HANDLE,DWORD,LPVOID,DWORD,LPVOID,DWORD,LPDWORD n,LPOVERLAPPED){if(n)*n=4;SetLastError(readOk?77:ERROR_IO_PENDING);return readOk;}
auto o_CreateFileW=&OpenW;auto o_CreateFileA=&OpenA;auto o_CloseHandle=&Close;auto o_ReadFile=&Read;auto o_DeviceIoControl=&Control;
'''
hid += '\n'.join(extract('input_system_hid.cpp', n) for n in [
    'ToLowerCopy','LooksLikeHidPath','AnsiToWide','HidKindFromUsage','FindHidHandleSlotLocked',
    'AllocateHidHandleSlotLocked','UpdateHidSeenFlagsLocked','TrackHidHandleLocked','ClearHidHandleLocked',
    'IsTrackedHidMouseLocked','ShouldBlockHidMouseReadLocked','ZeroReadBuffer','IsHidInputReportIoctl',
    'hkCreateFileW','hkCreateFileA','hkReadFile','hkDeviceIoControl','hkCloseHandle'])
hid += r'''
void Open(uintptr_t n,bool ansi=false){returned=reinterpret_cast<HANDLE>(n);HANDLE h=ansi?hkCreateFileA("\\\\?\\hid#mouse",0,0,nullptr,0,0,nullptr):hkCreateFileW(L"\\\\?\\hid#mouse",0,0,nullptr,0,0,nullptr);assert(h==returned&&GetLastError()==123);}
int main(){
 assert(AnsiToWide("hid#plain")==L"hid#plain");assert(AnsiToWide(nullptr).empty());
 for(uintptr_t n=1;n<=64;++n)Open(n,n%2);
 assert(_state.HidTrackedHandleCount==64);
 for(uintptr_t n=65;n<10065;++n)Open(n,n%2);
 assert(_state.HidTrackedHandleCount==64&&_state.HidTrackingOverflowCount==10000&&warningCount==1);
 tick+=60000;Open(99999);assert(warningCount==2&&_state.HidTrackingOverflowCount==10001);
 // Overflow never steals a live slot, and untracked reads remain game-owned.
 BYTE data[4]={1,2,3,4};DWORD count=0;visible=true;
 assert(hkReadFile(returned,data,4,&count,nullptr)&&data[0]==1&&count==4);
 HANDLE first=reinterpret_cast<HANDLE>(1);closeOk=false;
 assert(!hkCloseHandle(first)&&GetLastError()==ERROR_INVALID_HANDLE&&FindHidHandleSlotLocked(first));
 closeOk=true;reuseDuringClose=true;auto generation=FindHidHandleSlotLocked(first)->Generation;
 assert(hkCloseHandle(first)&&GetLastError()==77);
 assert(FindHidHandleSlotLocked(first)->Generation!=generation&&_state.HidTrackedHandleCount==64);
 assert(hkCloseHandle(first)&&!FindHidHandleSlotLocked(first)&&_state.HidTrackedHandleCount==63);
 for(int n=0;n<10000;++n){Open(1,n%2);assert(_state.HidTrackedHandleCount==64);assert(hkCloseHandle(first));}
 assert(_state.HidTrackedHandleCount==63);
 {ScopedHookBypass bypass;Open(1);assert(_state.HidTrackedHandleCount==63);}
 returned=INVALID_HANDLE_VALUE;hkCreateFileW(L"hid#bad",0,0,nullptr,0,0,nullptr);assert(_state.HidTrackedHandleCount==63);
 Open(1);visible=false;data[0]=9;assert(hkReadFile(first,data,4,&count,nullptr)&&data[0]==9&&count==4&&GetLastError()==77);
 visible=true;assert(hkReadFile(first,data,4,&count,nullptr)&&data[0]==0&&count==0);
 data[0]=9;readOk=false;OVERLAPPED pending{};assert(!hkReadFile(first,data,4,&count,&pending)&&data[0]==9&&GetLastError()==ERROR_IO_PENDING);
 assert(!hkDeviceIoControl(first,IOCTL_HID_GET_INPUT_REPORT,nullptr,0,data,4,&count,&pending)&&data[0]==9);
 readOk=true;{ScopedHookBypass bypass;assert(hkReadFile(first,data,4,&count,nullptr)&&data[0]==9);}
 usage=HID_USAGE_GENERIC_JOYSTICK;Open(1);assert(hkReadFile(first,data,4,&count,nullptr)&&data[0]==9);
 {ScopedHookBypass bypass;closeOk=false;assert(!hkCloseHandle(first)&&FindHidHandleSlotLocked(first));closeOk=true;assert(hkCloseHandle(first)&&!FindHidHandleSlotLocked(first));}
 puts("PASS HID: W/A, overflow fail-open + bounded warnings, failed close, reuse race, 10000 reconnects, bypass, last-error and pending IO preserved");
}
'''
(out/'input-hid-maintenance.cpp').write_text(hid)

physical = r'''
#include "../optiscaler/OptiScaler/menu/input/menu_physical_key.h"
#include "../optiscaler/OptiScaler/menu/input/print_screen_key.h"
#include <Windows.h>
#include <cassert>
#include <cstdio>
#include <initializer_list>
using namespace OptiInput;
int main(){
 for(int key:{VK_INSERT,VK_HOME,VK_END,VK_DELETE,VK_PRIOR,VK_NEXT}){
  for(auto source:{PhysicalKeySource::Window,PhysicalKeySource::Raw,PhysicalKeySource::DirectInput}){
   MenuPhysicalKey p;p.Configure(key);auto scan=NavigationMakeCode(key);
   // Num Lock off logical navigation, and Num Lock on keypad VK, both pass.
   p.Observe(key,scan,false,false,false,source);assert(!p.Pressed&&!p.Down);
   p.Observe(VK_NUMPAD0,scan,false,false,false,source);assert(!p.Pressed);
   p.Observe(key,scan,true,true,false,source);assert(!p.Pressed);
   p.Observe(key,0,true,false,false,source);assert(!p.Pressed);
   p.Observe(key,scan,true,false,true,source);assert(p.Source==PhysicalKeySource::None);
   p.Observe(key,scan,true,false,false,source);assert(p.Pressed&&p.Down);
   p.EndFrame();for(int n=0;n<100;n++)p.Observe(key,scan,true,false,false,source);
   assert(!p.Pressed&&p.Down);p.Observe(key,scan,true,false,true,source);assert(p.Released&&!p.Down);
   p.EndFrame();
   // A whole delayed duplicate tap from each other API must not retoggle.
   for(auto other:{PhysicalKeySource::Window,PhysicalKeySource::Raw,PhysicalKeySource::DirectInput})if(other!=source){
    p.Observe(key,scan,true,false,false,other);p.Observe(key,scan,true,false,true,other);assert(!p.Pressed&&!p.Released);
   }
   // Short tap retains both edges, then focus lifecycle/rebind clears source.
   p.Observe(key,scan,true,false,false,source);p.Observe(key,scan,true,false,true,source);assert(p.Pressed&&p.Released);
   p={};p.Configure(key);assert(!p.Down&&!p.Pressed&&p.Source==PhysicalKeySource::None);
   p.Configure(VK_F7);assert(NavigationMakeCode(VK_F7)==0&&!p.Down);
  }
 }
 puts("PASS physical menu: dedicated/keypad Insert Home End Delete/Page keys, short taps, repeat, delayed duplicate WM/raw/DI, rebind/focus/reset");
}
'''
(out/'input-physical-maintenance.cpp').write_text(physical)

window = r'''
#include <Windows.h>
#include <mutex>
#include <cassert>
#include <cstdio>
#include <cstdint>
#define LOG_WARN(...) ((void)0)
#define LOG_INFO(...) ((void)0)
#define LOG_DEBUG(...) ((void)0)
#define OPTIINPUT_LOG_VERBOSE(...) ((void)0)
inline constexpr wchar_t OriginalWndProcProperty[]=L"OptiShade.Input.OriginalWndProc.1";
enum class InputMessageSource {WndProc,MessageQueue};
struct State{std::recursive_mutex Mutex;HWND InputHwnd=nullptr;DWORD InputProcessId=0,InputThreadId=0;bool UseWndProcSubclass=true,WndProcSubclassed=false,MenuVisible=false,Focused=true;WNDPROC OriginalWndProc=nullptr;} _state;
LRESULT CALLBACK OptiInputWndProc(HWND,UINT,WPARAM,LPARAM);
bool ValidateInputWindowLocked(){return IsWindow(_state.InputHwnd);}
bool IsTargetWindow(HWND hwnd){return hwnd==_state.InputHwnd;}
bool HandleWindowMessage(HWND,UINT,WPARAM,LPARAM,InputMessageSource){return false;}
void ClearInputWindowLocked(){_state.InputHwnd=nullptr;_state.OriginalWndProc=nullptr;_state.WndProcSubclassed=false;}
'''
window += '\n'.join(extract('input_system_window.cpp', n) for n in [
    'TryGetWindowProc','InstallWindowSubclass','ValidateWindowSubclassLocked','RemoveWindowSubclass'])
window += '\n' + extract('input_system_messages.cpp','OptiInputWndProc')
window += r'''
int firstCount=0,secondCount=0,wrapperCount=0;
constexpr UINT Probe=WM_APP+17;
LRESULT CALLBACK First(HWND h,UINT m,WPARAM w,LPARAM l){if(m==Probe){++firstCount;return 11;}return DefWindowProcW(h,m,w,l);}
LRESULT CALLBACK Second(HWND h,UINT m,WPARAM w,LPARAM l){if(m==Probe){++secondCount;return 22;}return DefWindowProcW(h,m,w,l);}
LRESULT CALLBACK Wrapper(HWND h,UINT m,WPARAM w,LPARAM l){if(m==Probe)++wrapperCount;return OptiInputWndProc(h,m,w,l);}
void Target(HWND h){_state.InputHwnd=h;_state.InputThreadId=GetWindowThreadProcessId(h,&_state.InputProcessId);}
int main(){
 WNDCLASSW wc{};wc.lpfnWndProc=First;wc.hInstance=GetModuleHandleW(nullptr);wc.lpszClassName=L"OptiShadeInputMaintenanceFixture";assert(RegisterClassW(&wc));
 HWND a=CreateWindowW(wc.lpszClassName,L"hidden fixture",0,0,0,1,1,nullptr,nullptr,wc.hInstance,nullptr);assert(a);
 Target(a);assert(InstallWindowSubclass(a));assert(SendMessageW(a,Probe,0,0)==11);
 SetWindowLongPtrW(a,GWLP_WNDPROC,reinterpret_cast<LONG_PTR>(Wrapper));ValidateWindowSubclassLocked();
 assert(!_state.WndProcSubclassed&&_state.OriginalWndProc==First);assert(!InstallWindowSubclass(a));
 assert(SendMessageW(a,Probe,0,0)==11&&wrapperCount==1);
 RemoveWindowSubclass();assert(GetPropW(a,OriginalWndProcProperty));
 HWND b=CreateWindowW(wc.lpszClassName,L"second hidden fixture",0,0,0,1,1,nullptr,nullptr,wc.hInstance,nullptr);assert(b);
 SetWindowLongPtrW(b,GWLP_WNDPROC,reinterpret_cast<LONG_PTR>(Second));Target(b);assert(InstallWindowSubclass(b));
 assert(SendMessageW(a,Probe,0,0)==11&&SendMessageW(b,Probe,0,0)==22);
 // Restored original is the only safe auto-reinstall case.
 SetWindowLongPtrW(b,GWLP_WNDPROC,reinterpret_cast<LONG_PTR>(Second));ValidateWindowSubclassLocked();assert(_state.WndProcSubclassed);
 assert(SendMessageW(b,Probe,0,0)==22);DestroyWindow(a);assert(_state.InputHwnd==b);
 RemoveWindowSubclass();assert(!GetPropW(b,OriginalWndProcProperty));assert(SendMessageW(b,Probe,0,0)==22);
 assert(InstallWindowSubclass(b));DestroyWindow(b);assert(!_state.InputHwnd&&!_state.OriginalWndProc);
 assert(!InstallWindowSubclass(b));UnregisterClassW(wc.lpszClassName,wc.hInstance);
 puts("PASS WndProc: benign wrapper preserved, no recursive reinstall, per-HWND chain across recreation, safe restore, destroyed-window cleanup");
}
'''
(out/'input-window-maintenance.cpp').write_text(window)

focus = r'''
#include <Windows.h>
#include <array>
#include <string>
#include <cassert>
#include <cstdio>
#include "../optiscaler/OptiScaler/menu/input/menu_physical_key.h"
#include "../optiscaler/OptiScaler/menu/input/print_screen_key.h"
using namespace OptiInput;
struct Button {bool Down=false,Pressed=false,Released=false,BlockedDown=false;};
struct State {std::array<Button,256> Keys{};std::array<Button,5> MouseButtons{};MenuPhysicalKey PhysicalMenu;PrintScreenKey PrintScreen;bool Focused=true,MenuVisible=true,BlockMouse=true,BlockKeyboard=true,BlockCursor=true;int LastPressedKey=1;float MouseWheel=1;std::wstring TextInput=L"a";int ExternalPendingMouseDeltaX=3,ExternalPendingMouseDeltaY=4;} _state;
int rawClears=0,cacheClears=0,clipEnds=0,clipBegins=0;
void ResetRawInputBlockStateLocked(){++rawClears;}
void ResetRawInputSanitizeCacheLocked(){++cacheClears;}
void EndCursorClipBlockLocked(){++clipEnds;}
void BeginCursorClipBlockLocked(){++clipBegins;}
'''
focus += '\n'.join(extract('input_system_messages.cpp', n) for n in ['ClearFocusInputStateLocked','ReconcileInputFocusLocked'])
focus += r'''
int main(){
 _state.Keys['A']={true,true,false,true};_state.MouseButtons[0]={true,true,false,true};
 _state.PhysicalMenu.Configure(VK_INSERT);_state.PhysicalMenu.Observe(VK_INSERT,0x52,true,false,false,PhysicalKeySource::Raw);
 ReconcileInputFocusLocked(false);
 assert(!_state.Keys['A'].Down&&!_state.Keys['A'].Pressed&&!_state.Keys['A'].BlockedDown&&!_state.MouseButtons[0].Down);
 assert(!_state.PhysicalMenu.Down&&!_state.PhysicalMenu.Pressed&&_state.PhysicalMenu.Source==PhysicalKeySource::None);
 assert(!_state.Focused&&!_state.BlockMouse&&!_state.BlockKeyboard&&!_state.BlockCursor&&_state.MenuVisible);
 assert(_state.TextInput.empty()&&!_state.LastPressedKey&&!_state.MouseWheel&&!_state.ExternalPendingMouseDeltaX);
 assert(rawClears==1&&cacheClears==1&&clipEnds==1);
 ReconcileInputFocusLocked(false);assert(rawClears==1&&clipEnds==1);
 ReconcileInputFocusLocked(true);assert(_state.Focused&&_state.BlockMouse&&_state.BlockKeyboard&&clipBegins==1);
 _state.MenuVisible=false;ReconcileInputFocusLocked(false);ReconcileInputFocusLocked(true);
 assert(!_state.BlockKeyboard&&!_state.BlockMouse&&clipBegins==1);
 puts("PASS focus: key/button/suppression/physical-owner state released on alt-tab, no repeated cleanup, capture restored only for visible focused UI");
}
'''
(out/'input-focus-maintenance.cpp').write_text(focus)
print('Generated HID, physical shortcut, hidden-window and focus production harnesses')
