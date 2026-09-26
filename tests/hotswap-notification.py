"""Test the production toast confirmation against simulated effects-bridge snapshots."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
source = (root/'optiscaler/OptiScaler/menu/optishade_preset_hotswap.inl').read_text()
function = source[source.index('static void ConfirmHotSwap()'):source.index('static std::filesystem::path SwapSettingsPath()')]
prefix = r'''
#include <Windows.h>
#include <filesystem>
#include <cassert>
#include <cstdio>
#include <cstdarg>
#include <string>
#include "../shared/EffectsBridge.h"
#include "../shared/PresetPathIdentity.h"
static std::filesystem::path swapPending;
static int swapPendingNumber=0;
static uint64_t swapPendingApplied=10,swapPendingRejected=3;
static ULONGLONG swapPendingDeadline=120000,now=100;
bool SameSwapPreset(const std::filesystem::path&a,const std::filesystem::path&b){return optishade::hotswap::same_preset(a,b,std::filesystem::current_path());}
enum class ImGuiToastType {Info};
struct ImGuiToast {char title[128]{};ImGuiToast(ImGuiToastType,int){}void setTitle(const char* format,...){va_list args;va_start(args,format);vsnprintf(title,sizeof(title),format,args);va_end(args);}};
namespace ImGui {int count=0;std::string last;void InsertNotification(const ImGuiToast& t){++count;last=t.title;}}
osfx::Snapshot status{};bool connected=true;
bool Read(osfx::Snapshot*out,uint32_t){*out=status;return connected;}
HMODULE Module(const wchar_t*){return reinterpret_cast<HMODULE>(1);}
FARPROC Proc(HMODULE,const char*){return reinterpret_cast<FARPROC>(&Read);}
#define GetModuleHandleW Module
#define GetProcAddress Proc
#define GetTickCount64() now
'''
suffix = r'''
int main(){
 for(int number:{2,1,2,1}){
  swapPendingNumber=number;swapPending="chosen.ini";
  memset(&status,0,sizeof(status));status.applied=10;status.rejected=3;strcpy_s(status.preset,"chosen.ini");
  int before=ImGui::count;ConfirmHotSwap();assert(ImGui::count==before); // merely queued
  status.applied=11;status.loading=true;ConfirmHotSwap();assert(ImGui::count==before);
  status.loading=false;strcpy_s(status.preset,"previous.ini");ConfirmHotSwap();assert(ImGui::count==before);
  strcpy_s(status.preset,"chosen.ini");ConfirmHotSwap();
  assert(ImGui::count==before+1&&ImGui::last=="Hotswap: preset "+std::to_string(number));
  assert(swapPending.empty());ConfirmHotSwap();assert(ImGui::count==before+1);
 }
 swapPending="chosen.ini";status.rejected=4;ConfirmHotSwap();assert(swapPending.empty()&&ImGui::count==4);
 swapPending="chosen.ini";connected=false;now=120001;ConfirmHotSwap();assert(swapPending.empty()&&ImGui::count==4);
 puts("PASS: preset 1/2 toasts only after completed matching swaps; none on queued/loading/wrong-preset/rejected/timed-out swaps; no duplicates");
}
'''
out=root/'test-run/hotswap-notification.cpp'
out.parent.mkdir(exist_ok=True)
out.write_text(prefix+function+suffix)
print(out)
