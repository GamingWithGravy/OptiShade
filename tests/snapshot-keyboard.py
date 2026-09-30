"""Exercise production input setters and Keybind::Render using real ImGui."""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[1]
out=root/'test-run';out.mkdir(exist_ok=True)
def extract(path,name):
 text=(root/path).read_text(encoding='utf-8-sig')
 match=re.search(r'^.*\b'+name+r'\([^;]*?\)\s*\{',text,re.M)
 start=match.start();begin=text.index('{',start);depth=1;end=begin+1
 while depth:
  depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
menu=(root/'optiscaler/OptiScaler/menu/menu_common.cpp').read_text(encoding='utf-8-sig')
start=menu.index('class Keybind\n');end=menu.index('\n};',start)+3
keybind=menu[start:end]
src=r"""
#define NOMINMAX
#include <Windows.h>
#include <array>
#include <cassert>
#include <cstdio>
#include <mutex>
#include <map>
#include <string>
#include "../optiscaler/OptiScaler/include/imgui/imgui.h"
#include "../optiscaler/OptiScaler/include/imgui/imgui_internal.h"
#include "../optiscaler/OptiScaler/menu/input/print_screen_key.h"
namespace OptiInput {
struct ButtonState {bool Down=false,Pressed=false,Released=false,BlockedDown=false;DWORD LastMessageTime=0;};
struct State {std::array<ButtonState,256> Keys{};PrintScreenKey PrintScreen;int LastPressedKey=0;std::recursive_mutex Mutex;} _state;
void SyncAggregateModifierStateLocked(){}
"""
base='optiscaler/OptiScaler/menu/input/'
for fn in ['SetKeyDown','SetKeyUp','SetKeyUpStateOnly']:src+=extract(base+'input_system_messages.cpp',fn)+'\n'
for fn in ['IsKeyPressed','GetLastPressedKey']:src+=extract(base+'input_system.cpp',fn)+'\n'
src+=r"""
void Clear(){for(auto& k:_state.Keys){k.Pressed=false;k.Released=false;}_state.LastPressedKey=0;}
void Reset(){_state.Keys={};_state.PrintScreen={};_state.LastPressedKey=0;}
}
constexpr int UnboundKey=-1;bool capturingKey=false;int lastKey=0;
template<class T>struct CustomOptional{T value=0;T value_or_default()const{return value;}void reset(){value=0;}void operator=(T v){value=v;}};
std::string wstring_to_string(const wchar_t* s){std::string result;while(*s)result.push_back(static_cast<char>(*s++));return result;}
static std::map<ImGuiID,ImRect> rectangles;static std::map<std::string,ImRect> items;
void ImGuiTestEngineHook_ItemAdd(ImGuiContext*,ImGuiID id,const ImRect& r,const ImGuiLastItemData*){rectangles[id]=r;}
void ImGuiTestEngineHook_ItemInfo(ImGuiContext*,ImGuiID id,const char* label,ImGuiItemStatusFlags){if(rectangles.count(id))items[label]=rectangles[id];}
void ImGuiTestEngineHook_Log(ImGuiContext*,const char*,...){}
const char* ImGuiTestEngine_FindItemDebugLabel(ImGuiContext*,ImGuiID){return "fixture";}
"""+keybind+r"""
CustomOptional<int> binding;Keybind button("SnapShot",731);
std::string Frame(){
 auto& io=ImGui::GetIO();io.DeltaTime=1.f/60;items.clear();rectangles.clear();
 ImGui::NewFrame();ImGui::SetNextWindowPos({0,0});ImGui::SetNextWindowSize({700,300});
 ImGui::Begin("Key fixture",nullptr,ImGuiWindowFlags_NoSavedSettings);
 GImGui->LogBuffer.clear();ImGui::LogToBuffer();button.Render(binding);
 std::string text=GImGui->LogBuffer.c_str();ImGui::LogFinish();ImGui::End();ImGui::Render();
 for(auto* texture:ImGui::GetPlatformIO().Textures){texture->SetTexID(1);texture->SetStatus(ImTextureStatus_OK);}return text;
}
void BeginCapture(){
 Frame();Frame();assert(items.count("SnapShot"));auto c=items.at("SnapShot").GetCenter();auto& io=ImGui::GetIO();
 io.AddMousePosEvent(c.x,c.y);Frame();io.AddMouseButtonEvent(0,true);Frame();io.AddMouseButtonEvent(0,false);Frame();
 assert(capturingKey);
}
void Consume(int key){lastKey=OptiInput::GetLastPressedKey();assert(lastKey==key);Frame();assert(binding.value==key&&!capturingKey);}
int main(){
 using namespace OptiInput;
 ImGui::CreateContext();auto& io=ImGui::GetIO();io.IniFilename=nullptr;io.DisplaySize={700,300};io.BackendFlags|=ImGuiBackendFlags_RendererHasTextures;GImGui->TestEngineHookItems=true;io.LogFilename=nullptr;
 // Actual Keybind button -> production LastPressedKey -> saved value and label.
 for(int key=VK_NUMPAD0;key<=VK_NUMPAD9;++key){Reset();BeginCapture();SetKeyDown(key,100+key,false);Consume(key);assert(IsKeyPressed(key));SetKeyUp(key,300+key);assert(Frame().find("NumPad "+std::to_string(key-VK_NUMPAD0))!=std::string::npos);}
 Reset();BeginCapture();SetKeyUp(VK_SNAPSHOT,1000);Consume(VK_SNAPSHOT);assert(IsKeyPressed(VK_SNAPSHOT));assert(Frame().find("Print Screen")!=std::string::npos);
 assert(Keybind::KeyNameFromVirtualKeyCode(0)=="Unbound"&&Keybind::KeyNameFromVirtualKeyCode((USHORT)-1)=="Unbound");
 // Duplicate WndProc/queue observation may happen in the next render frame.
 Clear();SetKeyUp(VK_SNAPSHOT,1000);assert(!IsKeyPressed(VK_SNAPSHOT)&&!GetLastPressedKey());
 // Distinct key-up-only presses stay usable even one millisecond apart.
 SetKeyUp(VK_SNAPSHOT,1001);assert(IsKeyPressed(VK_SNAPSHOT));Clear();SetKeyUp(VK_SNAPSHOT,1002);assert(IsKeyPressed(VK_SNAPSHOT));
 Clear();SetKeyUp(VK_SNAPSHOT,1000);assert(!IsKeyPressed(VK_SNAPSHOT));
 Reset();SetKeyUp(VK_SNAPSHOT,0xfffffffeu);Clear();SetKeyUp(VK_SNAPSHOT,1);assert(IsKeyPressed(VK_SNAPSHOT));Clear();SetKeyUp(VK_SNAPSHOT,0xfffffffeu);assert(!IsKeyPressed(VK_SNAPSHOT));
 Reset();SetKeyDown(VK_SNAPSHOT,2000,true);assert(IsKeyPressed(VK_SNAPSHOT));Clear();assert(SetKeyUp(VK_SNAPSHOT,2050));assert(!IsKeyPressed(VK_SNAPSHOT));
 // Raw make/break before equivalent WM up: one press across frames.
 Reset();SetKeyDown(VK_SNAPSHOT,3000,false);Clear();SetKeyUpStateOnly(VK_SNAPSHOT,3050);SetKeyUp(VK_SNAPSHOT,3050);assert(!IsKeyPressed(VK_SNAPSHOT));
 Clear();SetKeyUp(VK_SNAPSHOT,3050);SetKeyDown(VK_SNAPSHOT,3000,false);assert(!IsKeyPressed(VK_SNAPSHOT));
 // Switching to WM-only up-only delivery does not retain raw ownership.
 SetKeyUp(VK_SNAPSHOT,3051);assert(IsKeyPressed(VK_SNAPSHOT));
 // Polling release cannot erase the original down evidence.
 Reset();SetKeyDown(VK_SNAPSHOT,4000,false);Clear();SetKeyUpStateOnly(VK_SNAPSHOT,4051);SetKeyUp(VK_SNAPSHOT,4050);assert(!IsKeyPressed(VK_SNAPSHOT));
 // A later up-only WM press must not inherit polling-only down evidence.
 Reset();SetKeyDown(VK_SNAPSHOT,4100,false);Clear();SetKeyUpStateOnly(VK_SNAPSHOT,4150);Clear();SetKeyUp(VK_SNAPSHOT,4200);assert(IsKeyPressed(VK_SNAPSHOT));
 // Raw-only down/up next press remains available; ordinary keys unchanged.
 Reset();SetKeyDown(VK_SNAPSHOT,5000,false);SetKeyUpStateOnly(VK_SNAPSHOT,5050);Clear();SetKeyDown(VK_SNAPSHOT,5000,false);assert(!IsKeyPressed(VK_SNAPSHOT));SetKeyDown(VK_SNAPSHOT,5100,false);assert(IsKeyPressed(VK_SNAPSHOT));
 Reset();SetKeyUp('A',6000);assert(!IsKeyPressed('A'));SetKeyDown('A',6001,false);assert(IsKeyPressed('A'));
 // Older WM/raw releases must not clear a newer press or synthesize again.
 Reset();SetKeyUp(VK_SNAPSHOT,6000);Clear();SetKeyDown(VK_SNAPSHOT,6100,true);Clear();SetKeyUp(VK_SNAPSHOT,6000);assert(_state.Keys[VK_SNAPSHOT].Down&&_state.Keys[VK_SNAPSHOT].BlockedDown);SetKeyUp(VK_SNAPSHOT,6150);assert(!IsKeyPressed(VK_SNAPSHOT));
 Reset();SetKeyDown(VK_SNAPSHOT,6200,false);SetKeyUpStateOnly(VK_SNAPSHOT,6250);Clear();SetKeyDown(VK_SNAPSHOT,6300,false);Clear();SetKeyUpStateOnly(VK_SNAPSHOT,6250);assert(_state.Keys[VK_SNAPSHOT].Down);SetKeyUp(VK_SNAPSHOT,6350);assert(!IsKeyPressed(VK_SNAPSHOT));
 // Focus reset permits the next Print Screen, independent of prior sources.
 Reset();SetKeyUp(VK_SNAPSHOT,7000);assert(IsKeyPressed(VK_SNAPSHOT));
 ImGui::DestroyContext();puts("PASS: production Keybind click/capture/labels for Print Screen and all ten NumPad digits; up-only, normal, raw/WM/queue dedup, polling, rapid presses and source changes.");
}
"""
(out/'snapshot-keyboard.cpp').write_text(src)
print('Generated production Snapshot keyboard and real ImGui fixture')
