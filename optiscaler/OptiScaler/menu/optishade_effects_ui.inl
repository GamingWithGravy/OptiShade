// OptiShade additions, GPL-3.0-or-later.
#include "../../../shared/EffectsBridge.h"
#include <cctype>
#include <fstream>
#include <set>
#include <unordered_set>
#include "optishade_update_notice.inl"
namespace OptiShadeUI {
static std::string MenuKeyLabel(int vk){
 char name[64]{};UINT scan=MapVirtualKeyA(vk,MAPVK_VK_TO_VSC);if(vk>=VK_PRIOR&&vk<=VK_DELETE)scan|=0x100;
 if(GetKeyNameTextA((LONG)(scan<<16),name,sizeof(name)))return name;return std::to_string(vk);
}
static osfx::Snapshot fx{};
static char feedback[256]="";
static uint64_t seenSave=0;
static std::map<std::string,uint64_t> preparing;
static bool EffectSwitch(const char* id,bool on){
 ImGui::PushID(id);auto pos=ImGui::GetCursorScreenPos();float height=ImGui::GetFrameHeight(),width=height*1.85f;
 bool clicked=ImGui::InvisibleButton("switch",ImVec2(width,height));auto* draw=ImGui::GetWindowDrawList();
 draw->AddRectFilled(pos,ImVec2(pos.x+width,pos.y+height),on?ImGui::GetColorU32(ImGuiCol_CheckMark):IM_COL32(159,51,69,255),height*.5f);
 draw->AddCircleFilled(ImVec2(pos.x+(on?width-height*.5f:height*.5f),pos.y+height*.5f),height*.36f,IM_COL32(246,238,255,255));
 ImGui::PopID();return clicked;
}
static bool Send(osfx::Command command){
 auto module=GetModuleHandleW(L"ReShade64.dll");auto send=module?(osfx::Send)GetProcAddress(module,"OptiShadeEffectsSend"):nullptr;
 command.version=osfx::Version;command.generation=fx.generation;
 bool queued=send&&send(&command,sizeof(command));strcpy_s(feedback,queued?"Applying your change...":"Image effects are not ready yet. Try again after loading.");return queued;
}
#include "optishade_preset_browser.inl"
static bool startupDone=false;
static bool NeedsStartupFrame(){return !startupDone||OptiShadeUpdates::NeedsFrame();}
static bool DrawStartup(bool menuRequested){
 OptiShadeUpdates::Draw(menuRequested);
 if(startupDone)return true;
 static double started=-1,readyAt=-1;if(started<0)started=ImGui::GetTime();
 if((readyAt>=0&&ImGui::GetTime()-readyAt>3)||ImGui::GetTime()-started>13){startupDone=true;return true;}
 auto module=GetModuleHandleW(L"ReShade64.dll");auto read=module?(osfx::Read)GetProcAddress(module,"OptiShadeEffectsRead"):nullptr;
 bool connected=read&&read(&fx,sizeof(fx));bool ready=connected&&!fx.loading;double elapsed=ImGui::GetTime()-started;
 if(ready&&readyAt<0)readyAt=ImGui::GetTime();bool timeout=elapsed>10;
 if(menuRequested&&(readyAt>=0||timeout)){startupDone=true;return true;}
 if((readyAt<0||ImGui::GetTime()-readyAt<3)&&elapsed<13){
  ImGui::SetNextWindowPos(ImVec2(24,24),ImGuiCond_Always);ImGui::SetNextWindowBgAlpha(.94f);
  ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding,14.f);ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(20,16));
  if(ImGui::Begin("OptiShade startup",nullptr,ImGuiWindowFlags_NoDecoration|ImGuiWindowFlags_AlwaysAutoResize|ImGuiWindowFlags_NoInputs|ImGuiWindowFlags_NoSavedSettings|ImGuiWindowFlags_NoFocusOnAppearing|ImGuiWindowFlags_NoNav)){
   ImGui::TextColored(ImGui::GetStyleColorVec4(ImGuiCol_CheckMark),"optishade");ImGui::TextDisabled("powered by fusion engine");ImGui::Separator();
   ImGui::TextUnformatted("Fusion Engine connected");
   ImGui::TextUnformatted(ready?"Ready":connected?"Preparing effects...":timeout?"Waiting for image effects":"Connecting image effects...");
   ImGui::Text("Menu: %s / Ctrl+Shift+%s",MenuKeyLabel(Config::Instance()->ShortcutKey.value_or_default()).c_str(),MenuKeyLabel(Config::Instance()->BackupShortcutKey.value_or_default()).c_str());
   // A moving segment means work is in progress; only a ready runtime fills the bar.
   ImGui::Dummy(ImVec2(0,5));
   auto bar=ImGui::GetCursorScreenPos();const float width=300.f,height=6.f;
   auto* draw=ImGui::GetWindowDrawList();
   draw->AddRectFilled(bar,ImVec2(bar.x+width,bar.y+height),IM_COL32(51,34,70,255),3.f);
   if(ready)draw->AddRectFilled(bar,ImVec2(bar.x+width,bar.y+height),ImGui::GetColorU32(ImGuiCol_CheckMark),3.f);
   else if(!timeout){
    const float segment=width*.28f,offset=(float)fmod(elapsed*.65,1.0)*(width+segment)-segment;
    draw->PushClipRect(bar,ImVec2(bar.x+width,bar.y+height),true);
    draw->AddRectFilled(ImVec2(bar.x+offset,bar.y),ImVec2(bar.x+offset+segment,bar.y+height),ImGui::GetColorU32(ImGuiCol_CheckMark),3.f);
    draw->PopClipRect();
   }
   ImGui::Dummy(ImVec2(width,height));
  }ImGui::End();ImGui::PopStyleVar(2);
 }
 return readyAt>=0||timeout;
}
static void DrawEffects(){
 PollZipImport();
 auto module=GetModuleHandleW(L"ReShade64.dll");auto read=module?(osfx::Read)GetProcAddress(module,"OptiShadeEffectsRead"):nullptr;
 bool connected=read&&read(&fx,sizeof(fx));
 if(!connected){ImGui::TextColored({1,.7f,.3f,1},"Waiting for image effects to become available.");return;}
 for(auto it=preparing.begin();it!=preparing.end();){
  bool found=false;
  if(!fx.loading){for(uint32_t i=0;i<fx.techniques;i++){auto& t=fx.technique[i];if(it->first==t.effect&&t.enabled)found=true;}}
  if(found){it=preparing.erase(it);}
  else if(!fx.loading&&fx.frames>it->second+1800){strcpy_s(feedback,"This shader did not become ready. Check the effects log for missing files or compile errors.");it=preparing.erase(it);}
  else ++it;
 }

 ImGui::BeginDisabled(fx.loading!=0||zipProcess!=nullptr);
 bool enabled=fx.enabled!=0;if(ImGui::Checkbox("Image effects",&enabled)){osfx::Command c{};c.kind=osfx::Effects;c.enabled=enabled;Send(c);}
 ImGui::SameLine();if(ImGui::Button("Recompile installed FX")){osfx::Command c{};c.kind=osfx::Reload;Send(c);}if(ImGui::IsItemHovered())ImGui::SetTooltip("Reload shader code already installed in the game. This does not import or download files.");

 auto root=Util::DllPath().parent_path()/L"OptiShadeData";
 std::error_code error;
 if(fx.saveSerial!=seenSave){seenSave=fx.saveSerial;strcpy_s(feedback,fx.saveOK?"Preset saved. This look will load next time.":"Could not save. Check the folder, permissions, and use a new name for Save as.");}
 static char presetName[128]="My custom look",presetFolder[1024]="";static bool replaceCurrent=false;
 ImGui::SameLine();if(ImGui::Button("Save preset...")){auto current=std::filesystem::u8path(fx.preset);auto folder=(root/L"Presets").u8string();auto name=current.stem().u8string();strncpy_s(presetFolder,(const char*)folder.c_str(),_TRUNCATE);if(!name.empty())strncpy_s(presetName,(const char*)name.c_str(),_TRUNCATE);replaceCurrent=false;ImGui::OpenPopup("Save your look");}
 if(ImGui::BeginPopupModal("Save your look",nullptr,ImGuiWindowFlags_AlwaysAutoResize)){
  ImGui::TextWrapped("Save your chosen effects and their current settings as an INI preset.");
  ImGui::SetNextItemWidth(480);ImGui::InputText("Name",presetName,sizeof(presetName),ImGuiInputTextFlags_AutoSelectAll);
  ImGui::SetNextItemWidth(480);ImGui::InputText("Folder",presetFolder,sizeof(presetFolder));
  ImGui::TextDisabled("Rename to save a new look. Restore keeps presets in the game presets folder.");
  auto proposed=std::filesystem::u8path(presetFolder)/std::filesystem::u8path(presetName);
  if(proposed.extension()!=L".ini")proposed+=L".ini";
  std::error_code warningError;
  if(std::filesystem::exists(proposed,warningError)){
   bool isCurrent=std::filesystem::equivalent(proposed,std::filesystem::u8path(fx.preset),warningError);
   ImGui::TextColored(ImVec4(1.f,.3f,.4f,1.f),"A preset with this name already exists.");
   ImGui::TextWrapped(isCurrent?"Saving over it replaces the saved effects and settings. Give this look a new name to keep both versions.":"This is another saved look. Choose a different name; OptiShade will not overwrite it.");
   if(isCurrent)ImGui::Checkbox("I understand - replace my current saved preset",&replaceCurrent);
   else replaceCurrent=false;
  }else replaceCurrent=false;
  if(ImGui::Button("Use game presets folder")){auto folder=(root/L"Presets").u8string();strncpy_s(presetFolder,(const char*)folder.c_str(),_TRUNCATE);}
  if(ImGui::Button("Save preset")){
   std::string name=presetName;
   bool valid=!name.empty()&&name.find_first_of("<>:\"/\\|?*")==std::string::npos&&name.back()!='.'&&name.back()!=' ';
   for(auto ch:name)if((unsigned char)ch<32)valid=false;
   auto folder=std::filesystem::u8path(presetFolder);auto dest=folder/std::filesystem::u8path(name);
   if(dest.extension()!=L".ini")dest+=L".ini";
   auto encoded=dest.u8string();
   if(!valid||!folder.is_absolute()||!std::filesystem::is_directory(folder,error))strcpy_s(feedback,"Choose a name and an existing full folder path.");
   else if(encoded.size()>=1024)strcpy_s(feedback,"That folder path is too long. Choose a shorter one.");
   else{bool exists=std::filesystem::exists(dest,error);bool current=exists&&std::filesystem::equivalent(dest,std::filesystem::u8path(fx.preset),error);
    if(exists&&(!current||!replaceCurrent))strcpy_s(feedback,"Choose a new name, or allow replacing the current preset. Other existing presets are protected.");
    else{osfx::Command c{};c.kind=exists?osfx::Save:osfx::SaveAs;strcpy_s(c.path,(const char*)encoded.c_str());if(Send(c))ImGui::CloseCurrentPopup();}
   }
  }
  ImGui::SameLine();if(ImGui::Button("Cancel"))ImGui::CloseCurrentPopup();
  if(feedback[0])ImGui::TextWrapped("%s",feedback);
  ImGui::EndPopup();
 }

 DrawDependencyPrompt();
 DrawPresetBrowser(root);
 if(zipProcess)ImGui::TextWrapped("Installing files in the background... You can keep flying; reopen Image effects to see the result.");
 ImGui::TextWrapped("Import INI / Install FX adds files. Saved looks below load an installed preset.");
 static char nextPreset[1024]="";static bool askSwitch=false,waitingSwitch=false;static uint64_t switchSaveSerial=0;
 ImGui::TextUnformatted("Saved look");ImGui::SameLine();ImGui::SetNextItemWidth(300);
 if(ImGui::BeginCombo("##Look presets",std::filesystem::path(fx.preset).filename().string().c_str())){
  for(std::filesystem::recursive_directory_iterator i(root/L"Presets",error),end;i!=end&&!error;i.increment(error)){
   if(i->path().extension()!=L".ini")continue;auto label=i->path().lexically_relative(root/L"Presets").string();if(ImGui::Selectable(label.c_str())){auto path=i->path().u8string();if(fx.dirty){strncpy_s(nextPreset,(const char*)path.c_str(),_TRUNCATE);askSwitch=true;}else{osfx::Command c{};c.kind=osfx::Preset;strncpy_s(c.path,(const char*)path.c_str(),_TRUNCATE);Send(c);}}
  }ImGui::EndCombo();
 }
 if(askSwitch){ImGui::OpenPopup("Unsaved preset changes");askSwitch=false;}
 if(ImGui::BeginPopupModal("Unsaved preset changes",nullptr,ImGuiWindowFlags_AlwaysAutoResize)){
  ImGui::TextColored(ImVec4(1.f,.3f,.4f,1.f),"Your current preset has unsaved changes.");
  ImGui::TextUnformatted("Save them, discard them, or keep editing.");
  if(waitingSwitch&&fx.saveSerial>switchSaveSerial){waitingSwitch=false;if(fx.saveOK){osfx::Command c{};c.kind=osfx::Preset;strcpy_s(c.path,nextPreset);Send(c);preparing.clear();ImGui::CloseCurrentPopup();}}
  ImGui::BeginDisabled(waitingSwitch);
  if(ImGui::Button("Save and switch")){osfx::Command c{};c.kind=osfx::Save;switchSaveSerial=fx.saveSerial;waitingSwitch=Send(c);}
  ImGui::SameLine();if(ImGui::Button("Discard and switch")){osfx::Command c{};c.kind=osfx::Preset;strcpy_s(c.path,nextPreset);Send(c);preparing.clear();ImGui::CloseCurrentPopup();}
  ImGui::SameLine();if(ImGui::Button("Keep editing"))ImGui::CloseCurrentPopup();ImGui::EndDisabled();
  if(feedback[0])ImGui::TextWrapped("%s",feedback);ImGui::EndPopup();
 }
 if(fx.dirty){ImGui::TextColored(ImVec4(1.f,.3f,.4f,1.f),"Unsaved changes - your INI has not been overwritten.");ImGui::SameLine();}
 ImGui::BeginDisabled(!fx.dirty);if(ImGui::Button("Revert changes")){osfx::Command c{};c.kind=osfx::Discard;if(Send(c))preparing.clear();}ImGui::EndDisabled();
 if(ImGui::CollapsingHeader("Advanced: import using a full file path")){
 static char importPath[1024]="";ImGui::InputTextWithHint("##import","Full path to an .fx shader, .ini preset or .zip package",importPath,sizeof(importPath));ImGui::SameLine();
 if(ImGui::Button("Import")){
  if(fx.dirty){strcpy_s(feedback,"Save or discard your preset changes before importing another file.");}
  else{
  ImportLook(std::filesystem::u8path(importPath),root);
 }
 }
 ImGui::TextDisabled("Extra files supplied with a shader go in the Shaders or Textures folder inside OptiShadeData.");
 }
 if(feedback[0])ImGui::TextWrapped("%s",feedback);
 ImGui::Separator();
 static std::vector<std::filesystem::path> library;static bool indexed=false;
 if(importedShader){indexed=false;importedShader=false;}
 bool libraryChanged=!indexed;
 if(!indexed){library.clear();for(std::filesystem::recursive_directory_iterator it(root/L"Shaders",error),end;it!=end&&!error;it.increment(error))if(it->is_regular_file(error)&&it->path().extension()==L".fx")library.push_back(it->path());std::sort(library.begin(),library.end());indexed=true;}
 ImGui::Text("%zu installed shaders | %s",library.size(),fx.loading?"Preparing...":fx.compileOK?"Ready":"Some shaders could not load");ImGui::SameLine();if(ImGui::Button("Rescan installed FX list"))indexed=false;if(ImGui::IsItemHovered())ImGui::SetTooltip("Find files already in OptiShadeData/Shaders. Does not install files or change your look.");
 ImGui::SameLine();const bool moveActiveFirst=ImGui::Button("Active first");
 std::unordered_set<std::string> activeEffects,loadedEffects;for(uint32_t i=0;i<fx.techniques;i++){loadedEffects.insert(fx.technique[i].effect);if(fx.technique[i].enabled)activeEffects.insert(fx.technique[i].effect);}
 static std::vector<std::filesystem::path> ordered;
 if(libraryChanged||ordered.size()!=library.size()){
  ordered=library;std::stable_sort(ordered.begin(),ordered.end(),[](const auto& a,const auto& b){return a.filename().string()<b.filename().string();});
 }
 // Reorder only on this explicit request; changing an effect never moves rows.
 if(moveActiveFirst)std::stable_partition(ordered.begin(),ordered.end(),[&](const auto& path){return activeEffects.count(path.filename().string())!=0;});
 static char search[128]="";static std::string selectedEffect;
 float width=ImGui::GetContentRegionAvail().x;
 if(ImGui::BeginChild("Effect list",ImVec2(width*.45f,0),true)){
  ImGui::SetNextItemWidth(-1);ImGui::InputTextWithHint("##librarysearch","Find an effect...",search,sizeof(search));
  if(ImGui::BeginChild("FX rows",ImVec2(0,0),false)){
  std::vector<size_t> visible;for(size_t i=0;i<ordered.size();++i){auto name=ordered[i].filename().string();if(!search[0]||std::search(name.begin(),name.end(),search,search+strlen(search),[](unsigned char a,unsigned char b){return std::tolower(a)==std::tolower(b);})!=name.end())visible.push_back(i);}
  ImGuiListClipper clipper;clipper.Begin((int)visible.size(),ImGui::GetFrameHeight()+ImGui::GetStyle().ItemSpacing.y);
  while(clipper.Step())for(int row=clipper.DisplayStart;row<clipper.DisplayEnd;++row){const auto& path=ordered[visible[row]];auto filename=path.filename().string();
   bool loaded=loadedEffects.count(filename)!=0,on=activeEffects.count(filename)!=0;
   bool waiting=preparing.count(filename)!=0;ImGui::PushID(path.string().c_str());ImGui::BeginDisabled(waiting);
   if(EffectSwitch("library",on)){
    if(loaded){for(uint32_t i=0;i<fx.techniques;i++){auto& t=fx.technique[i];if(filename!=t.effect)continue;osfx::Command c{};c.kind=osfx::Technique;c.enabled=!on;strcpy_s(c.effect,t.effect);strcpy_s(c.name,t.name);Send(c);}}
    else{osfx::Command c{};c.kind=osfx::Load;c.enabled=1;strncpy_s(c.effect,filename.c_str(),_TRUNCATE);if(Send(c)){preparing[filename]=fx.frames;strcpy_s(feedback,"Preparing your effect. It will switch on when it is ready.");}}
    if(!on){selectedEffect=filename;osfx::Command c{};c.kind=osfx::Inspect;strncpy_s(c.effect,filename.c_str(),_TRUNCATE);Send(c);}
   }
   ImGui::EndDisabled();ImGui::SameLine();
   if(ImGui::Selectable(filename.c_str(),selectedEffect==filename,0,ImVec2(0,ImGui::GetFrameHeight()))){
    selectedEffect=filename;
    if(!loaded&&!waiting){osfx::Command c{};c.kind=osfx::Load;c.enabled=0;strncpy_s(c.effect,filename.c_str(),_TRUNCATE);Send(c);}
    osfx::Command c{};c.kind=osfx::Inspect;strncpy_s(c.effect,filename.c_str(),_TRUNCATE);Send(c);
   }
   if(ImGui::IsItemHovered()){if(waiting)ImGui::SetTooltip("Preparing...");else if(on&&!fx.enabled)ImGui::SetTooltip("Paused by Image effects switch");}
   ImGui::PopID();
  }
  }ImGui::EndChild();
 }ImGui::EndChild();ImGui::SameLine();
 if(ImGui::BeginChild("Effect settings",ImVec2(0,0),true)){
  if(selectedEffect.empty())ImGui::TextWrapped("Choose an effect on the left to see its settings. Selecting a name does not turn the effect on.");
  else{
   ImGui::TextWrapped("%s",selectedEffect.c_str());ImGui::Separator();bool ready=false;
   for(uint32_t i=0;i<fx.techniques;i++)if(selectedEffect==fx.technique[i].effect){ready=true;break;}
   if(!ready)ImGui::TextWrapped("Preparing settings. If they do not appear, this shader may need extra files or may not be compatible.");
   unsigned settings=0;
   for(uint32_t j=0;j<fx.uniforms;j++){
    auto& u=fx.uniform[j];if(selectedEffect!=u.effect)continue;settings++;ImGui::PushID((int)j);bool changed=false;
    if(u.type==3&&u.count==1){bool value=u.value[0]!=0;if(ImGui::Checkbox(u.label[0]?u.label:u.name,&value)){u.value[0]=value?1.f:0.f;changed=true;}}
    else{ImGui::TextWrapped("%s",u.label[0]?u.label:u.name);for(uint32_t k=0;k<u.count;k++){ImGui::PushID((int)k);ImGui::SetNextItemWidth(-1);float value=u.value[k];bool edited=false;
     if(u.hasRange){if(u.type==0)edited=ImGui::SliderFloat("##value",&value,u.minimum,u.maximum,"%.3f");else{int integer=(int)value;edited=ImGui::SliderInt("##value",&integer,(int)u.minimum,(int)u.maximum);value=(float)integer;}}
     else edited=ImGui::DragFloat("##value",&value,u.type==0?.01f:1.f,0,0,u.type==0?"%.3f":"%.0f");
     if(edited){u.value[k]=value;changed=true;}ImGui::PopID();}}
    if(changed){osfx::Command c{};c.kind=osfx::Uniform;c.count=u.count;strcpy_s(c.effect,u.effect);strcpy_s(c.name,u.name);std::copy_n(u.value,16,c.value);Send(c);}ImGui::PopID();
   }
   if(ready&&!settings)ImGui::TextWrapped("This effect has no adjustable settings in this panel.");
   if(fx.truncated)ImGui::TextWrapped("This panel reached its display limit. The full preset still loads in the effects engine.");
  }
 }ImGui::EndChild();ImGui::EndDisabled();
}
}
