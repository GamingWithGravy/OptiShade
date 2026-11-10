#include "MenuSettingsDraft.h"
#include <SimpleIni.h>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <chrono>
static unsigned checks=0;
#define CHECK(x) do{++checks;if(!(x))throw std::runtime_error(std::string(#x)+" @"+std::to_string(__LINE__));}while(0)
struct Settings {
    std::optional<int> ShortcutKey=45,BackupShortcutKey=79,FpsShortcutKey=33,FpsCycleShortcutKey=34,
        FGShortcutKey=35,DlssNrToggleKey=36,PresetHotSwapKey=0,SnapshotKey=0;
    std::optional<bool> MenuPhysicalNavigationKey=false;
    std::optional<float> MenuScale,MenuAccentColorR=.62f,MenuAccentColorG=.32f,MenuAccentColorB=1.f,MenuBGColorA=.99f;
    int unrelatedNrStrength=10;bool unrelatedFgEnabled=true;
};
int main(){try{
 using namespace optishade::menu_settings;
 Settings c;Draft<Settings> draft;draft.Begin(c);CHECK(!draft.Dirty(c));
 c.ShortcutKey=112;draft.Begin(c);CHECK(draft.Dirty(c)); // Keybind alone enables Save.
 c.unrelatedNrStrength=88;c.unrelatedFgEnabled=false;
 draft.Discard(c);CHECK(c.ShortcutKey==45&&!draft.Dirty(c));CHECK(c.unrelatedNrStrength==88&&!c.unrelatedFgEnabled);
 c.SnapshotKey=-1;c.MenuScale=1.5f;c.MenuBGColorA=.7f;c.MenuAccentColorR=.2f;
 CHECK(!draft.Commit(c,[]{return false;}));CHECK(draft.Dirty(c));CHECK(draft.feedback.find("Could not save")!=std::string::npos);
 const auto file=std::filesystem::temp_directory_path()/ ("optishade-menu-settings-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())+".ini");
 CSimpleIniA ini;ini.SetUnicode();ini.SetValue("DlssNr","Strength","10");ini.SetValue("FrameGen","External","true");ini.SetValue("Unrelated","Owner","preserved");
 CHECK(ini.SaveFile(file.string().c_str())>=0);
 CHECK(draft.Commit(c,[&]{CSimpleIniA saved;saved.SetUnicode();if(saved.LoadFile(file.string().c_str())<0)return false;Write(saved,c);return saved.SaveFile(file.string().c_str())>=0;}));
 CHECK(!draft.Dirty(c));CSimpleIniA loaded;CHECK(loaded.LoadFile(file.string().c_str())>=0);
 CHECK(loaded.GetLongValue("Menu","SnapshotKey",123)==-1);CHECK(loaded.GetDoubleValue("Menu","Scale")==1.5);
 CHECK(loaded.GetDoubleValue("Menu","BGColorA")>.69&&loaded.GetDoubleValue("Menu","BGColorA")<.71);
 CHECK(std::string(loaded.GetValue("DlssNr","Strength",""))=="10");CHECK(std::string(loaded.GetValue("FrameGen","External",""))=="true");
 CHECK(std::string(loaded.GetValue("Unrelated","Owner",""))=="preserved");
 c.ShortcutKey.reset();c.MenuScale.reset();CHECK(draft.Dirty(c));Write(loaded,c);CHECK(loaded.SaveFile(file.string().c_str())>=0);
 CSimpleIniA reopened;CHECK(reopened.LoadFile(file.string().c_str())>=0);CHECK(std::string(reopened.GetValue("Menu","ShortcutKey",""))=="auto");CHECK(std::string(reopened.GetValue("Menu","Scale",""))=="auto");
 draft.Discard(c);CHECK(c.ShortcutKey==45&&c.MenuScale==1.5f);CHECK(!draft.Dirty(c));
 // Saving a shortcut cannot silently alter a pending renderer/FG choice.
 CHECK(c.unrelatedNrStrength==88&&!c.unrelatedFgEnabled);
 std::filesystem::remove(file);
 std::cout<<checks<<" menu settings draft/persistence assertions passed\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
