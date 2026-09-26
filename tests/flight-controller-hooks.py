"""Generate a native regression harness from the actual input-hook functions.

Fake original APIs return non-neutral flight controls and error codes. No game,
physical input injection, or GPU is needed. Build generated CPP with MSVC.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
src = root / 'optiscaler/OptiScaler/menu/input'

def extract(file, name):
    text = (src / file).read_text()
    start = re.search(r'^.*\b' + name + r'\([^;]*?\)\s*\{', text, re.M).start()
    begin = text.index('{', start)
    depth = 1
    end = begin + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

names = ['ShouldBlockDirectInputKeyboardLocked', 'ShouldBlockDirectInputMouseLocked',
         'ShouldBlockDirectInputOtherLocked', 'ShouldBlockDirectInputDeviceLocked', 'IsReservedDirectInputKeyLocked',
         'hkDirectInputGetDeviceState', 'hkDirectInputGetDeviceData']
functions = extract('input_system.cpp', 'IsReservedMenuKeyLocked') + '\n' + '\n'.join(extract('input_system_directinput.cpp', n) for n in names)
functions += '\n' + '\n'.join(extract('input_system_xinput.cpp', n) for n in
    ['ShouldBlockXInputLocked', 'hkXInputGetState', 'hkXInputGetStateEx'])
functions += '\n' + extract('input_system_raw.cpp', 'HandleRawInputLocked')
counters = sorted(set(re.findall(r'_state\.(\w+(?:Count))', functions)))
prefix = r'''
#include <Windows.h>
#include <dinput.h>
#include <Xinput.h>
#include <mutex>
#include <cstring>
#include <cassert>
#include <cstdio>
#include <vector>
#define OPTIINPUT_LOG_VERBOSE(...) ((void)0)
struct State { std::mutex Mutex; bool Initialized=true, Focused=true, BlockKeyboard=true, BlockMouse=true;
'''
prefix += ''.join('unsigned ' + c + '=0;\n' for c in counters) + '} _state;\n'
prefix += r'''
bool preserve=true, visible=true;
int bypassHookDepth=0;
struct Option { int value=VK_INSERT; int value_or_default(){return value;} };
struct Config { Option ShortcutKey; static Config* Instance(){static Config config;return &config;} };
bool PreserveFlightControllerInput(){return preserve;}
bool ShouldApplyBlockingPolicyLocked(){return visible;}
bool ShouldBlockKeyboardInputLocked(){return visible && _state.BlockKeyboard;}
bool ShouldBlockMouseInputLocked(){return visible && _state.BlockMouse;}
struct ScopedHookBypass {};
enum class DirectInputDeviceKind {Keyboard,Mouse,Other};
DirectInputDeviceKind kind=DirectInputDeviceKind::Other;
DirectInputDeviceKind GetDirectInputDeviceKindLocked(void*){return kind;}
HRESULT deviceResult=DI_OK;
unsigned stateCalls=0, dataCalls=0;
DWORD eventScan=0;
HRESULT WINAPI DeviceState(void*,DWORD size,void* data){++stateCalls;if(SUCCEEDED(deviceResult))std::memset(data,0x5a,size);return deviceResult;}
HRESULT WINAPI DeviceData(void*,DWORD,LPDIDEVICEOBJECTDATA data,LPDWORD count,DWORD){++dataCalls;if(SUCCEEDED(deviceResult)&&data&&*count){data[0].dwOfs=eventScan;data[0].dwData=0x80;*count=1;}return deviceResult;}
auto o_DirectInputDeviceGetDeviceState=&DeviceState;
auto o_DirectInputDeviceGetDeviceData=&DeviceData;
DWORD xresult=ERROR_SUCCESS;
DWORD WINAPI XState(DWORD,XINPUT_STATE* s){if(s&&xresult==ERROR_SUCCESS){*s={};s->dwPacketNumber=17;s->Gamepad.sThumbLX=12345;s->Gamepad.bRightTrigger=187;s->Gamepad.wButtons=XINPUT_GAMEPAD_A;}return xresult;}
auto o_XInputGetState=&XState;
auto o_XInputGetStateEx=&XState;
enum class RawSanitizeAction {Pass,SanitizeAll};
struct Decision {RawSanitizeAction Action;};
RawSanitizeAction rawAction=RawSanitizeAction::SanitizeAll;
Decision GetRawInputSanitizeDecisionLocked(HRAWINPUT,const RAWINPUT&){return {rawAction};}
unsigned rawUpdates=0;
void UpdateStateFromRawInputLocked(const RAWINPUT&){++rawUpdates;}
RAWINPUT rawPacket{};
UINT WINAPI RawData(HRAWINPUT,UINT,LPVOID data,PUINT size,UINT){
  *size=sizeof(rawPacket);if(!data)return 0;memcpy(data,&rawPacket,sizeof(rawPacket));return sizeof(rawPacket);
}
auto o_GetRawInputData=&RawData;
'''
suffix = r'''
int main(){
  BYTE data[272]; DIDEVICEOBJECTDATA event{}; DWORD count;
  // Repeated open/close must not fabricate neutral flight axes or switch edges.
  for(int i=0;i<10;i++){
    visible=(i%2)==0; memset(data,0,sizeof(data));
    assert(hkDirectInputGetDeviceState(nullptr,sizeof(data),data)==DI_OK);
    for(BYTE b:data)assert(b==0x5a);
    count=1;assert(hkDirectInputGetDeviceData(nullptr,sizeof(event),&event,&count,0)==DI_OK);
    assert(count==1&&event.dwData==0x80);
    XINPUT_STATE x{};assert(hkXInputGetState(0,&x)==ERROR_SUCCESS);
    assert(x.dwPacketNumber==17&&x.Gamepad.sThumbLX==12345&&x.Gamepad.bRightTrigger==187&&x.Gamepad.wButtons==XINPUT_GAMEPAD_A);
    assert(hkXInputGetStateEx(0,&x)==ERROR_SUCCESS&&x.Gamepad.sThumbLX==12345);
  }
  assert(stateCalls==10&&dataCalls==10);
  visible=true;deviceResult=DIERR_INPUTLOST;
  assert(hkDirectInputGetDeviceState(nullptr,sizeof(data),data)==DIERR_INPUTLOST);
  count=1;assert(hkDirectInputGetDeviceData(nullptr,sizeof(event),&event,&count,0)==DIERR_INPUTLOST);
  xresult=ERROR_DEVICE_NOT_CONNECTED;XINPUT_STATE x{};
  assert(hkXInputGetState(0,&x)==ERROR_DEVICE_NOT_CONNECTED);
  // Controller WM_INPUT must reach the game while its keyboard/mouse menu is open.
  rawPacket.header.dwType=RIM_TYPEHID;
  assert(HandleRawInputLocked(reinterpret_cast<HRAWINPUT>(1)));
  rawPacket.header.dwType=RIM_TYPEKEYBOARD;
  assert(!HandleRawInputLocked(reinterpret_cast<HRAWINPUT>(1)));
  rawAction=RawSanitizeAction::Pass;
  assert(HandleRawInputLocked(reinterpret_cast<HRAWINPUT>(1)));
  rawPacket.header.dwType=RIM_TYPEMOUSE;
  assert(!HandleRawInputLocked(reinterpret_cast<HRAWINPUT>(1)));
  assert(rawUpdates==4);
  // Keyboard and mouse capture are unchanged.
  deviceResult=DI_OK;
  for(auto k:{DirectInputDeviceKind::Keyboard,DirectInputDeviceKind::Mouse}){
    kind=k;memset(data,0x5a,sizeof(data));
    assert(hkDirectInputGetDeviceState(nullptr,sizeof(data),data)==DI_OK);
    for(BYTE b:data)assert(b==0);
  }
  // Reserve a rebound shortcut even with the overlay closed, including extended keys.
  kind=DirectInputDeviceKind::Keyboard;visible=false;
  for(int key:{int(VK_INSERT),int(VK_HOME),int(VK_F7),int('E')}){
    Config::Instance()->ShortcutKey.value=key;
    const UINT sc=MapVirtualKeyW(key,MAPVK_VK_TO_VSC_EX);
    const DWORD di=(sc&0x7f)|((sc&0xff00)?0x80:0);
    assert(IsReservedMenuKeyLocked(key));
    assert(hkDirectInputGetDeviceState(nullptr,256,data)==DI_OK);
    assert(data[di]==0 && data[DIK_A]==0x5a);
    eventScan=di;count=1;
    assert(hkDirectInputGetDeviceData(nullptr,sizeof(event),&event,&count,0)==DI_OK && count==0);
    eventScan=DIK_A;count=1;
    assert(hkDirectInputGetDeviceData(nullptr,sizeof(event),&event,&count,DIGDD_PEEK)==DI_OK && count==1);
    _state.Focused=false;assert(!IsReservedMenuKeyLocked(key));_state.Focused=true;
    bypassHookDepth=1;assert(!IsReservedMenuKeyLocked(key));bypassHookDepth=0;
    preserve=false;assert(!IsReservedMenuKeyLocked(key));preserve=true;
  }
  Config::Instance()->ShortcutKey.value=VK_F7;
  assert(!IsReservedMenuKeyLocked('E')); // previous binding no longer reserved
  deviceResult=DIERR_INPUTLOST;
  assert(hkDirectInputGetDeviceState(nullptr,256,data)==DIERR_INPUTLOST);
  deviceResult=DI_OK;visible=true;
  // Non-MSFS behavior remains unchanged.
  preserve=false;kind=DirectInputDeviceKind::Other;memset(data,0x5a,sizeof(data));
  assert(hkDirectInputGetDeviceState(nullptr,sizeof(data),data)==DI_OK);
  for(BYTE b:data)assert(b==0);
  puts("PASS: repeated menu transitions preserve controller axes/buttons/events; API errors preserved; keyboard/mouse and other-game policy unchanged");
}
'''
out = root/'test-run/flight-controller-hooks.cpp'
out.parent.mkdir(exist_ok=True)
out.write_text(prefix + functions + suffix)
print(out)
