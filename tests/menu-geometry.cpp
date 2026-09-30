#define NOMINMAX
#include "../shared/MenuGeometryIni.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <iterator>
#include <limits>
#include <set>

using namespace optishade::menu_geometry;
static std::string Read(const std::filesystem::path& p) { std::ifstream f(p, std::ios::binary); return {std::istreambuf_iterator<char>(f), {}}; }
int main()
{
    assert(!Parse("")); assert(!Parse("1 2 3")); assert(!Parse("nan 0 900 600 1920 1080 1"));
    assert(!Parse("0 0 -900 600 1920 1080 1")); assert(!Parse("0 0 900 600 1920 1080 8"));
    assert(!Parse("0 0 900 600 1920 1080 1 trailing")); assert(!ValidContext("../escape"));
    const Geometry user {{240, 160, 1120, 760}, {1920, 1080}, 1};
    assert(Same(Parse(Serialize(user))->rect, user.rect));
    State state; state.Load(user); Rect r;
    assert(state.Prepare({1920,1080},1,r)); assert(Same(r,user.rect));
    assert(!state.Prepare({1920,1080},1,r)); // No per-frame forced layout.
    assert(state.Prepare({1024,720},1,r));
    assert(r.x >= 15 && r.y >= 15 && r.x+r.width <= 1009 && r.y+r.height <= 705);
    state.Observe(r,false,100); // Fullscreen/window resize is not a user menu edit.
    assert(!state.Due(2000,false,true));
    assert(state.Prepare({1920,1080},1,r)); assert(Same(r,user.rect));
    assert(state.Prepare({3840,2160},2,r));
    assert(r.width==2240 && r.height==1520 && r.x==480 && r.y==320);
    state.Observe(r,false,200); // Scale change cannot overwrite preferred geometry.
    assert(state.Prepare({1920,1080},1,r)); assert(Same(r,user.rect));
    assert(state.Prepare({2560,1440},1,r)); assert(Same(r,user.rect)); // Maximized viewport.
    const Rect deliberate {310,220,1200,800};
    state.Observe(deliberate,true,5000);
    assert(!state.Due(5700,false)); assert(!state.Due(6000,true)); assert(state.Due(5750,false));
    state.Saved(5750,false); assert(!state.Due(6000,false,true)); assert(state.Due(10750,false));
    state.Saved(10750,true); assert(!state.Due(11000,false,true));
    state.Observe({330,240,1250,810},true,11001); assert(state.Due(11002,false,true)); // Close flush.
    State restart; restart.Load(Parse(Serialize(*state.Preferred())));
    assert(restart.Prepare({2560,1440},1,r)); assert(Same(r,state.Preferred()->rect));
    auto offscreen=user;offscreen.rect.x=9000;offscreen.rect.y=-300;
    auto fitted=Fit(offscreen,{1920,1080},1);
    assert(fitted.x+fitted.width<=1905 && fitted.y>=15);
    assert(!state.Prepare({0,0},1,r)); assert(!state.Prepare({1920,1080},std::numeric_limits<float>::quiet_NaN(),r));
    const auto tiny=Fit(user,{20,20},1); assert(tiny.width==10 && tiny.height==10 && tiny.x==5 && tiny.y==5);

    Contexts contexts; std::set<uintptr_t> live {1,2,3,4};
    auto isLive=[&](uintptr_t handle){return live.count(handle)!=0;};
    assert(contexts.Select("overlay-desktop",1,isLive)=="overlay-desktop.0");
    assert(contexts.Select("overlay-mirror",2,isLive)=="overlay-mirror.0");
    assert(contexts.Select("overlay-desktop",3,isLive)=="overlay-desktop.1");
    assert(contexts.Select("direct-desktop",4,isLive)=="direct-desktop.0");
    assert(contexts.Select("overlay-desktop",1,isLive)=="overlay-desktop.0");
    live.erase(1);live.insert(5);
    assert(contexts.Select("overlay-desktop",5,isLive)=="overlay-desktop.0"); // HWND recreation.
    for(uintptr_t i=6;i<=17;++i){live.insert(i);assert(!contexts.Select("secondary",i,isLive).empty());}
    live.insert(18);assert(contexts.Select("secondary",18,isLive).empty()); // Bound, no live eviction.

    const auto fixture=std::filesystem::path("test-run") / ("geometry-"+std::to_string(GetCurrentProcessId()));
    std::filesystem::create_directories(fixture);
    const auto path=fixture/"OptiScaler.ini";
    const std::string original="[Menu]\nScale=1.25\nShortcutKey=0x2d\n[DlssNr]\nEnabled=false\n[Custom]\nUser=untouched\n";
    assert(optishade::AtomicConfigWrite(path,original));
    CSimpleIniA memory; assert(memory.LoadFile(path.c_str())>=0);
    memory.SetValue("DlssNr","Enabled","true"); // Deliberate unsaved live setting.
    assert(!LoadIni(memory,"overlay-1.0")); // Old-schema migration starts at normal default.
    assert(SaveIni(memory,path,"overlay-1.0",user));
    CSimpleIniA disk;assert(disk.LoadFile(path.c_str())>=0);
    assert(std::string(disk.GetValue("DlssNr","Enabled"))=="false");
    assert(std::string(memory.GetValue("DlssNr","Enabled"))=="true");
    assert(std::string(disk.GetValue("Menu","Scale"))=="1.25");
    assert(std::string(disk.GetValue("Menu","ShortcutKey"))=="0x2d");
    assert(std::string(disk.GetValue("Custom","User"))=="untouched");
    assert(Same(LoadIni(disk,"overlay-1.0")->rect,user.rect));
    const Geometry mirror {{25,25,700,500},{1280,720},1};
    assert(SaveIni(memory,path,"overlay-2.0",mirror));
    assert(Same(LoadIni(memory,"overlay-1.0")->rect,user.rect));
    assert(Same(LoadIni(memory,"overlay-2.0")->rect,mirror.rect));
    assert(SaveIni(memory,path,"overlay-1.1",mirror)); // Simultaneous secondary window.
    const auto before=Read(path);
    assert(SetFileAttributesW(path.c_str(),FILE_ATTRIBUTE_READONLY));
    assert(!SaveIni(memory,path,"overlay-1.0",mirror)); assert(Read(path)==before);
    assert(SetFileAttributesW(path.c_str(),FILE_ATTRIBUTE_NORMAL));
    HANDLE locked=CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,0,nullptr);
    assert(locked!=INVALID_HANDLE_VALUE);
    assert(!SaveIni(memory,path,"overlay-1.0",mirror)); assert(Read(path)==before);CloseHandle(locked);
    for(const auto& entry:std::filesystem::directory_iterator(fixture)) assert(entry.path()==path); // Failed writes leave no tmp files.
    assert(optishade::AtomicConfigWrite(path,"[MenuGeometry]\nSchema=2\nOther=preserve\n"));
    const auto future=Read(path);assert(!SaveIni(memory,path,"overlay-1.0",user));assert(Read(path)==future);
    assert(optishade::AtomicConfigWrite(path,"[MenuGeometry]\nSchema=1\noverlay-1.0=invalid\n"));
    CSimpleIniA malformed;assert(malformed.LoadFile(path.c_str())>=0); assert(!LoadIni(malformed,"overlay-1.0"));
    assert(SaveIni(memory,path,"overlay-1.0",user)); // Replace malformed current-schema entry on real edit.
    for(int i=1;i<16;++i) assert(SaveIni(memory,path,"view."+std::to_string(i),user));
    assert(!SaveIni(memory,path,"view.overflow",user));
    assert(SaveIni(memory,path,"overlay-1.0",mirror)); // Existing entries remain editable at cap.
    std::filesystem::remove(path);std::filesystem::remove(fixture);
    std::cout << "PASS: geometry schema, malformed/offscreen/restart, view/scale restoration, debounce/retry, independent surfaces, bounded entries, atomic failure and unrelated-setting preservation\n";
}
