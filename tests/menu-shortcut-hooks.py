"""Exercise production keyboard hooks with fake game input; no input is injected."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
src = root / 'optiscaler/OptiScaler/menu/input'

def extract(file, name):
    text = (src / file).read_text()
    start = re.search(r'^.*\b' + name + r'\([^;]*?\)\s*\{', text, re.M).start()
    begin = text.index('{', start)
    depth, end = 1, begin + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

functions = '\n'.join(extract(file, name) for file, name in [
    ('input_system.cpp', 'IsReservedMenuKeyLocked'),
    ('input_system.cpp', 'ShouldBlockVirtualKey'),
    ('input_system_messages.cpp', 'hkGetKeyboardState'),
    ('input_system_raw.cpp', 'NormalizeRawKeyboardVirtualKey'),
    ('input_system_raw.cpp', 'GetRawKeyboardSanitizeActionLocked'),
    ('input_system_windows_hooks.cpp', 'ShouldBlockWindowsKeyboardHookCallbackLocked'),
])
# Run the real window-message keyboard cases, without faking unrelated mouse/window APIs.
messages = (src/'input_system_messages.cpp').read_text()
cases = messages[messages.index('    case WM_KEYDOWN:', messages.index('bool HandleWindowMessage')):]
cases = cases[:cases.index('    case WM_UNICHAR:')]
functions += '\nbool KeyboardMessage(UINT msg, WPARAM wParam, LPARAM lParam){bool shouldBlock=false;switch(msg){\n' + cases + '\n}return shouldBlock;}\n'
prefix = r'''
#include <Windows.h>
#include <mutex>
#include <vector>
#include <cassert>
#include <cstdio>
#include <cstring>
#define OPTIINPUT_LOG_VERBOSE(...) ((void)0)
struct Key {bool Down=false, Blocked=false;};
struct State {
 std::mutex Mutex; bool Initialized=true,Focused=true,MenuVisible=false,BlockKeyboard=false,BlockMouse=false;
 Key Keys[256]; bool RawKeyboardBlockedDown[256]{},WindowsHookKeyboardBlockedDown[256]{};
 unsigned GetKeyboardStateFilteredCount=0;std::vector<wchar_t> TextInput;
} _state;
int bypassHookDepth=0;bool preserve=true;
struct Option {int value=VK_INSERT;int value_or_default(){return value;}};
struct Config {Option ShortcutKey;static Config* Instance(){static Config c;return &c;}};
bool PreserveFlightControllerInput(){return preserve;}
bool ShouldApplyBlockingPolicyLocked(){return bypassHookDepth==0&&_state.MenuVisible;}
bool ShouldBlockKeyboardInputLocked(){return ShouldApplyBlockingPolicyLocked()&&_state.BlockKeyboard;}
bool ShouldBlockMouseInputLocked(){return ShouldApplyBlockingPolicyLocked()&&_state.BlockMouse;}
bool IsMouseVirtualKey(int vk){return vk==VK_LBUTTON||vk==VK_RBUTTON||vk==VK_MBUTTON||vk==VK_XBUTTON1||vk==VK_XBUTTON2;}
BOOL keyboardResult=TRUE;
BOOL WINAPI KeyboardState(PBYTE state){if(keyboardResult)memset(state,0x80,256);return keyboardResult;}
auto o_GetKeyboardState=&KeyboardState;
enum class RawSanitizeAction {Pass,SanitizeAll};
struct WindowsHookSlot {int HookType=WH_KEYBOARD_LL;};
int NormalizeModifierVirtualKey(int vk,LPARAM){return vk;}
void SetKeyDown(int vk,DWORD,bool blocked){_state.Keys[vk].Down=true;_state.Keys[vk].Blocked=blocked;}
bool SetKeyUp(int vk,DWORD){auto old=_state.Keys[vk].Blocked;_state.Keys[vk]={};return old;}
'''
suffix = r'''
int main(){
 for(int key:{int(VK_INSERT),int(VK_HOME),int(VK_F7),int('E')}){
  Config::Instance()->ShortcutKey.value=key;
  for(bool open:{false,true,false,true,false}){
   _state.MenuVisible=open;_state.BlockKeyboard=open;
   assert(KeyboardMessage(WM_KEYDOWN,key,0));
   assert(_state.Keys[key].Down); // overlay still receives the press
   assert(KeyboardMessage(WM_KEYUP,key,0));assert(!_state.Keys[key].Down);
   assert(ShouldBlockVirtualKey(key));
   BYTE state[256];assert(hkGetKeyboardState(state));assert(state[key]==0);
   assert(state['A']==(open?0:0x80));
   RAWKEYBOARD raw{};raw.VKey=key;
   assert(GetRawKeyboardSanitizeActionLocked(raw)==RawSanitizeAction::SanitizeAll);
   raw.Flags=RI_KEY_BREAK;
   assert(GetRawKeyboardSanitizeActionLocked(raw)==RawSanitizeAction::SanitizeAll);
   WindowsHookSlot slot;KBDLLHOOKSTRUCT event{};event.vkCode=key;
   assert(ShouldBlockWindowsKeyboardHookCallbackLocked(slot,0,0,reinterpret_cast<LPARAM>(&event)));
   event.flags=LLKHF_UP;
   assert(ShouldBlockWindowsKeyboardHookCallbackLocked(slot,0,0,reinterpret_cast<LPARAM>(&event)));
   assert(!ShouldBlockWindowsKeyboardHookCallbackLocked(slot,-1,0,reinterpret_cast<LPARAM>(&event)));
  }
  _state.Focused=false;assert(!IsReservedMenuKeyLocked(key));_state.Focused=true;
  bypassHookDepth=1;assert(!ShouldBlockVirtualKey(key));bypassHookDepth=0;
 }
 Config::Instance()->ShortcutKey.value='E';
 const LPARAM scan=LPARAM(MapVirtualKeyW('E',MAPVK_VK_TO_VSC))<<16;
 assert(KeyboardMessage(WM_CHAR,'e',scan));
 assert(!KeyboardMessage(WM_KEYDOWN,'A',0));
 _state.MenuVisible=true;_state.BlockKeyboard=true;
 assert(!KeyboardMessage(WM_KEYUP,'A',0)); // owed release survives menu opening
 _state.MenuVisible=false;_state.BlockKeyboard=false;
 Config::Instance()->ShortcutKey.value=VK_F7;
 assert(!ShouldBlockVirtualKey('E'));
 BYTE data[256];memset(data,0x55,256);keyboardResult=FALSE;
 assert(!hkGetKeyboardState(data)&&data[VK_F7]==0x55);
 preserve=false;assert(!IsReservedMenuKeyLocked(VK_F7));
 puts("PASS: custom/rebound menu key down/up, polling, raw input, hooks and text are reserved; overlay sees input; unrelated held-key release and errors preserved");
}
'''
out = root/'test-run/menu-shortcut-hooks.cpp'
out.parent.mkdir(exist_ok=True)
out.write_text(prefix + functions + suffix)
print(out)
