// OptiShade additions, GPL-3.0-or-later.
#include "../../../shared/EffectsBridge.h"
#include "../../../shared/EffectNumericUi.h"
#include "../../../shared/EffectReadiness.h"
#include "../../../shared/EffectEditorCache.h"
#include "../../../shared/PresetHotSwapPolicy.h"
#include "../../../shared/PresetPathIdentity.h"
#include "../../../shared/PresetTechniquePolicy.h"
#include <algorithm>
#include <cctype>
#include <climits>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <string>
#include <unordered_set>
#include <vector>
#include "optishade_update_notice.inl"
namespace OptiShadeUI {
static std::string MenuKeyLabel(int vk){
 char name[64]{};UINT scan=MapVirtualKeyA(vk,MAPVK_VK_TO_VSC);if(vk>=VK_PRIOR&&vk<=VK_DELETE)scan|=0x100;
 if(GetKeyNameTextA((LONG)(scan<<16),name,sizeof(name)))return name;return std::to_string(vk);
}
static osfx::Snapshot fx{};
static char feedback[8192]="";
static uint64_t seenSave=0;
static uint64_t nextEditRequest=0,seenEditAckSequence=0,editAckGeneration=0;
static std::map<uint64_t,std::string> pendingUniformEdits;
static std::map<std::string,optishade::fxready::Request> preparing;
static std::vector<std::filesystem::path> fxLibrary;
static bool fxLibraryIndexed=false;
static std::filesystem::path fxLibraryRoot,fxLibraryGameRoot;
static bool EffectSwitch(const char* id,bool on){
 ImGui::PushID(id);auto pos=ImGui::GetCursorScreenPos();float height=ImGui::GetFontSize()*1.2f,width=height*1.85f;
 bool clicked=ImGui::InvisibleButton("switch",ImVec2(width,height),ImGuiButtonFlags_EnableNav);auto* draw=ImGui::GetWindowDrawList();
 draw->AddRectFilled(pos,ImVec2(pos.x+width,pos.y+height),on?ImGui::GetColorU32(ImGuiCol_CheckMark):ImGui::GetColorU32(ImGuiCol_FrameBg),height*.5f);
 draw->AddCircleFilled(ImVec2(pos.x+(on?width-height*.5f:height*.5f),pos.y+height*.5f),height*.36f,IM_COL32(246,238,255,255));
 ImGui::PopID();return clicked;
}
static const char* EffectLoadStatus(bool waiting,bool active,bool requested,bool loaded,bool compileOK){
 if(waiting)return "Compiling effect...";
 if(loaded)return active?"Enabled in this look":"Compiled and loaded; disabled in this look";
 if(requested)return compileOK?"Requested by this look, but not loaded. Check the effects log.":"Requested by this look, but a compile error is reported for one or more FX. Check the effects log.";
 if(!compileOK)return "Not used by this look; the runtime reports an error in one or more FX. Check the effects log.";
 return "Installed, not used by this look. Enable it to load.";
}
enum class FxGlyph { Spark, Sun, Palette, HalfTone, Triangle, Orbits, Dots, Layers, Grid, Wave };
static FxGlyph GlyphForFx(const std::string& filename){
 std::string key=filename;std::transform(key.begin(),key.end(),key.begin(),[](unsigned char c){return static_cast<char>(std::tolower(c));});
 if(key.find("color")!=std::string::npos||key.find("colour")!=std::string::npos||key.find("vibrance")!=std::string::npos||key.find("lut")!=std::string::npos)return FxGlyph::Palette;
 if(key.find("tonemap")!=std::string::npos||key.find("tone")!=std::string::npos||key.find("dither")!=std::string::npos)return FxGlyph::HalfTone;
 if(key.find("sharp")!=std::string::npos||key.find("clarity")!=std::string::npos||key.find("cas")!=std::string::npos)return FxGlyph::Triangle;
 if(key.find("bloom")!=std::string::npos||key.find("light")!=std::string::npos||key.find("glow")!=std::string::npos)return FxGlyph::Sun;
 if(key.find("mxao")!=std::string::npos||key.find("occlusion")!=std::string::npos)return FxGlyph::Dots;
 if(key.find("depth")!=std::string::npos)return FxGlyph::Layers;
 if(key.find("mask")!=std::string::npos||key.find("border")!=std::string::npos)return FxGlyph::Grid;
 if(key.find("deband")!=std::string::npos||key.find("grain")!=std::string::npos)return FxGlyph::Wave;
 if(key.find("ascii")!=std::string::npos||key.find("comic")!=std::string::npos)return FxGlyph::Orbits;
 return FxGlyph::Spark;
}
static void DrawFxGlyph(const std::string& filename,ImVec2 pos,float size,bool selected){
 auto* draw=ImGui::GetWindowDrawList();const ImU32 accent=ImGui::GetColorU32(ImGuiCol_CheckMark),muted=ImGui::GetColorU32(ImGuiCol_TextDisabled);
 const ImU32 ink=selected?accent:muted;const float cx=pos.x+size*.5f,cy=pos.y+size*.5f,r=size*.23f;
 draw->AddRectFilled(pos,ImVec2(pos.x+size,pos.y+size),ImGui::GetColorU32(ImGuiCol_FrameBg),size*.18f);
 const auto glyph=GlyphForFx(filename);
 if(glyph==FxGlyph::Sun){draw->AddCircle(ImVec2(cx,cy),r,ink,20,1.6f);for(int i=0;i<8;i++){float a=6.2831853f*i/8.f;draw->AddLine(ImVec2(cx+std::cos(a)*r*1.45f,cy+std::sin(a)*r*1.45f),ImVec2(cx+std::cos(a)*r*2.05f,cy+std::sin(a)*r*2.05f),ink,1.5f);}}
 else if(glyph==FxGlyph::Palette){draw->AddCircle(ImVec2(cx,cy),r*1.65f,ink,24,1.5f);draw->AddCircleFilled(ImVec2(cx-r*.55f,cy-r*.3f),r*.2f,accent);draw->AddCircleFilled(ImVec2(cx+r*.55f,cy-r*.45f),r*.2f,ink);draw->AddCircleFilled(ImVec2(cx+r*.6f,cy+r*.45f),r*.2f,accent);}
 else if(glyph==FxGlyph::HalfTone){draw->AddCircle(ImVec2(cx,cy),r*1.65f,ink,24,1.5f);draw->AddLine(ImVec2(cx,cy-r*1.6f),ImVec2(cx,cy+r*1.6f),ink,1.5f);draw->AddCircleFilled(ImVec2(cx-r*.65f,cy),r*.9f,ImGui::GetColorU32(ImGuiCol_ButtonActive));}
 else if(glyph==FxGlyph::Triangle){draw->AddLine(ImVec2(cx,cy-r*1.8f),ImVec2(cx+r*1.65f,cy+r*1.35f),ink,1.7f);draw->AddLine(ImVec2(cx+r*1.65f,cy+r*1.35f),ImVec2(cx-r*1.65f,cy+r*1.35f),ink,1.7f);draw->AddLine(ImVec2(cx-r*1.65f,cy+r*1.35f),ImVec2(cx,cy-r*1.8f),ink,1.7f);}
 else if(glyph==FxGlyph::Orbits){draw->AddCircle(ImVec2(cx-r*.55f,cy),r,ink,20,1.4f);draw->AddCircle(ImVec2(cx+r*.55f,cy),r,accent,20,1.4f);draw->AddCircle(ImVec2(cx,cy-r*.55f),r,ink,20,1.4f);}
 else if(glyph==FxGlyph::Dots){for(int i=0;i<12;i++){float a=6.2831853f*i/12.f;draw->AddCircleFilled(ImVec2(cx+std::cos(a)*r*1.55f,cy+std::sin(a)*r*1.55f),size*.035f,ink);}}
 else if(glyph==FxGlyph::Layers){for(int i=0;i<3;i++){float y=cy+(i-1)*size*.18f;draw->AddLine(ImVec2(cx, y-size*.22f),ImVec2(cx+size*.29f,y),ink,1.5f);draw->AddLine(ImVec2(cx+size*.29f,y),ImVec2(cx,y+size*.22f),ink,1.5f);draw->AddLine(ImVec2(cx,y+size*.22f),ImVec2(cx-size*.29f,y),ink,1.5f);draw->AddLine(ImVec2(cx-size*.29f,y),ImVec2(cx,y-size*.22f),ink,1.5f);}}
 else if(glyph==FxGlyph::Grid){draw->AddRect(ImVec2(cx-r*1.7f,cy-r*1.7f),ImVec2(cx+r*1.7f,cy+r*1.7f),ink,2.f,0,1.4f);draw->AddLine(ImVec2(cx,cy-r*1.6f),ImVec2(cx,cy+r*1.6f),ink,1.f);draw->AddLine(ImVec2(cx-r*1.6f,cy),ImVec2(cx+r*1.6f,cy),ink,1.f);}
 else if(glyph==FxGlyph::Wave){ImVec2 points[]={ImVec2(cx-r*1.7f,cy+r*.5f),ImVec2(cx-r*.7f,cy-r*.5f),ImVec2(cx+r*.2f,cy+r*.5f),ImVec2(cx+r*1.5f,cy-r*.65f)};for(unsigned i=0;i<3;i++)draw->AddLine(points[i],points[i+1],i==1?accent:ink,1.7f);}
 else{draw->AddLine(ImVec2(cx,cy-size*.3f),ImVec2(cx,cy+size*.3f),ink,1.7f);draw->AddLine(ImVec2(cx-size*.3f,cy),ImVec2(cx+size*.3f,cy),ink,1.7f);draw->AddLine(ImVec2(cx-size*.2f,cy-size*.2f),ImVec2(cx+size*.2f,cy+size*.2f),accent,1.4f);}
}
static bool FavoriteButton(const char* id,bool favorite){
 ImGui::PushID(id);const float size=ImGui::GetFrameHeight();const auto pos=ImGui::GetCursorScreenPos();const bool clicked=ImGui::InvisibleButton("favorite",ImVec2(size,size));
 auto* draw=ImGui::GetWindowDrawList();const ImU32 col=ImGui::GetColorU32(favorite?ImGuiCol_CheckMark:ImGuiCol_TextDisabled);
 ImVec2 points[10];const ImVec2 center(pos.x+size*.5f,pos.y+size*.5f);
 for(int i=0;i<10;++i){const float angle=-1.5707963f+i*.62831853f,r=size*(i%2?.15f:.36f);points[i]=ImVec2(center.x+std::cos(angle)*r,center.y+std::sin(angle)*r);}
 for(int i=0;i<10;++i){if(favorite)draw->AddTriangleFilled(center,points[i],points[(i+1)%10],col);else draw->AddLine(points[i],points[(i+1)%10],col,1.5f);}
 if(ImGui::IsItemHovered())ImGui::SetTooltip(favorite?"Remove from favourites":"Add to favourites");
 ImGui::PopID();return clicked;
}
static void DrawChevron(ImVec2 pos,float size,ImU32 color,bool down){const float sign=down?1.f:-1.f;auto* d=ImGui::GetWindowDrawList();d->AddLine(ImVec2(pos.x-size*.25f,pos.y-sign*size*.12f),ImVec2(pos.x,pos.y+sign*size*.12f),color,1.6f);d->AddLine(ImVec2(pos.x,pos.y+sign*size*.12f),ImVec2(pos.x+size*.25f,pos.y-sign*size*.12f),color,1.6f);}
static void DrawSearchGlyph(ImVec2 pos,float size,ImU32 color){auto* d=ImGui::GetWindowDrawList();d->AddCircle(ImVec2(pos.x+size*.42f,pos.y+size*.4f),size*.25f,color,20,1.6f);d->AddLine(ImVec2(pos.x+size*.6f,pos.y+size*.6f),ImVec2(pos.x+size*.88f,pos.y+size*.88f),color,1.7f);}
static void DrawFilterGlyph(ImVec2 pos,float size,ImU32 color){auto* d=ImGui::GetWindowDrawList();for(int i=0;i<3;i++){float y=pos.y+size*(.28f+i*.24f),x=pos.x+size*.18f;d->AddLine(ImVec2(x,y),ImVec2(pos.x+size*.82f,y),color,1.4f);float knob=pos.x+size*(i==1?.65f:i==2?.38f:.52f);d->AddCircleFilled(ImVec2(knob,y),size*.075f,color);}}
static void RememberMainPreset(const char* path);
static bool Send(osfx::Command command){
 auto module=GetModuleHandleW(L"ReShade64.dll");auto send=module?(osfx::Send)GetProcAddress(module,"OptiShadeEffectsSend"):nullptr;
 command.version=osfx::Version;command.generation=fx.generation;
 if(command.kind==osfx::Uniform){command.editRequest=++nextEditRequest;if(!command.editRequest)command.editRequest=++nextEditRequest;}
 bool queued=send&&send(&command,sizeof(command));strcpy_s(feedback,queued?"Applying your change...":"Image effects are not ready yet. Try again after loading.");
 if(queued&&command.kind==osfx::Uniform)pendingUniformEdits[command.editRequest]=std::string(command.effect)+" / "+command.name;
 if(queued&&command.kind==osfx::Preset)RememberMainPreset(command.path);return queued;
}
static void ReadUniformEditAcks(){
 if(editAckGeneration!=fx.generation){editAckGeneration=fx.generation;seenEditAckSequence=fx.editAcks.sequence;pendingUniformEdits.clear();return;}
 const uint64_t latest=fx.editAcks.sequence;if(latest<=seenEditAckSequence)return;
 const uint64_t first=latest-seenEditAckSequence>osfx::EditAckCapacity?latest-osfx::EditAckCapacity+1:seenEditAckSequence+1;
 for(uint64_t sequence=first;sequence<=latest;++sequence){
  const auto& ack=fx.editAcks.entries[sequence%osfx::EditAckCapacity];if(ack.sequence!=sequence||!ack.request)continue;
  auto pending=pendingUniformEdits.find(ack.request);if(pending==pendingUniformEdits.end())continue;
  if(ack.result==osfx::EditResultApplied){std::string message="ReShade accepted the live FX value: ";message+=ack.effect;message+=" / ";message+=ack.name;strcpy_s(feedback,message.c_str());}
  else{
   const char* reason=ack.result==osfx::EditResultPerformanceMode?"Performance Mode is on":
    ack.result==osfx::EditResultMissingTarget?"the FX uniform is no longer available":
    ack.result==osfx::EditResultInvalidShape?"the value type or array shape changed":
    ack.result==osfx::EditResultInvalidValue?"the value is invalid":
    ack.result==osfx::EditResultLimit?"OptiShade reached its tracked edit limit":
    ack.result==osfx::EditResultRuntimeChanged?"the active effects runtime changed":
    "the effects runtime rejected the edit";
   std::string message="Could not apply ";message+=ack.effect;message+=" / ";message+=ack.name;message+=" because ";message+=reason;message+=". Check the effects log for details.";strcpy_s(feedback,message.c_str());
  }
  pendingUniformEdits.erase(pending);
 }
 seenEditAckSequence=latest;
}
#include "optishade_preset_hotswap.inl"
#include "optishade_snapshot.inl"
#include "optishade_preset_browser.inl"
static bool startupDone=false;
static bool lookEditorOpen=false;
static bool NeedsStartupFrame(){return !startupDone||OptiShadeUpdates::NeedsFrame();}
static bool DrawStartup(bool menuRequested){
 OptiShadeUpdates::Draw(menuRequested);
 if(startupDone)return true;
 static double started=-1,readyAt=-1;if(started<0)started=ImGui::GetTime();
 if((readyAt>=0&&ImGui::GetTime()-readyAt>3)||ImGui::GetTime()-started>13){startupDone=true;return true;}
 auto module=GetModuleHandleW(L"ReShade64.dll");auto read=module?(osfx::Read)GetProcAddress(module,"OptiShadeEffectsRead"):nullptr;
 bool connected=read&&read(&fx,sizeof(fx));bool ready=connected&&!fx.loading&&fx.compileOK;double elapsed=ImGui::GetTime()-started;
 if(ready&&readyAt<0)readyAt=ImGui::GetTime();bool timeout=elapsed>10;
 if(menuRequested&&(readyAt>=0||timeout)){startupDone=true;return true;}
 if((readyAt<0||ImGui::GetTime()-readyAt<3)&&elapsed<13){
  ImGui::SetNextWindowPos(ImGui::GetMainViewport()->GetCenter(),ImGuiCond_Always,ImVec2(.5f,.5f));
  ImGui::SetNextWindowSize(ImVec2(std::min(520.f,ImGui::GetIO().DisplaySize.x-30.f),0),ImGuiCond_Always);ImGui::SetNextWindowBgAlpha(.94f);
  ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding,14.f);ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding,ImVec2(20,16));
  if(ImGui::Begin("OptiShade startup",nullptr,ImGuiWindowFlags_NoDecoration|ImGuiWindowFlags_AlwaysAutoResize|ImGuiWindowFlags_NoInputs|ImGuiWindowFlags_NoSavedSettings|ImGuiWindowFlags_NoFocusOnAppearing|ImGuiWindowFlags_NoNav)){
   optishade::panel::Brand();ImGui::Spacing();ImGui::TextDisabled("powered by fusion engine");ImGui::Separator();
   ImGui::TextWrapped("%s",ready?"Fusion Engine Connected":connected?(fx.loading?"Compiling shader files and loading your look...":"Checking shader compilation..."):timeout?"Still waiting for the effects runtime":"Connecting the image effects runtime...");
   if(connected&&fx.preset[0])ImGui::TextWrapped("Look: %s",std::filesystem::u8path(fx.preset).filename().string().c_str());
   if(connected&&!fx.loading&&!fx.compileOK)ImGui::TextWrapped("A shader did not compile. Open Image effects for details.");
   ImGui::Text("Menu: %s / Ctrl+Shift+%s",MenuKeyLabel(Config::Instance()->ShortcutKey.value_or_default()).c_str(),MenuKeyLabel(Config::Instance()->BackupShortcutKey.value_or_default()).c_str());
   // A moving segment means work is in progress; only a ready runtime fills the bar.
   ImGui::Dummy(ImVec2(0,5));
   auto bar=ImGui::GetCursorScreenPos();const float width=std::max(20.f,ImGui::GetContentRegionAvail().x),height=6.f;
   auto* draw=ImGui::GetWindowDrawList();
   draw->AddRectFilled(bar,ImVec2(bar.x+width,bar.y+height),IM_COL32(51,34,70,255),3.f);
   if(ready)draw->AddRectFilled(bar,ImVec2(bar.x+width,bar.y+height),ImGui::GetColorU32(ImGuiCol_CheckMark),3.f);
   else if(!timeout){
    const float segment=width*.28f,offset=(float)fmod(elapsed*.65,1.0)*(width+segment)-segment;
    draw->PushClipRect(bar,ImVec2(bar.x+width,bar.y+height),true);
    draw->AddRectFilled(ImVec2(bar.x+offset,bar.y),ImVec2(bar.x+offset+segment,bar.y+height),ImGui::GetColorU32(ImGuiCol_CheckMark),3.f);
    draw->PopClipRect();
   }
   ImGui::Dummy(ImVec2(width,height));optishade::panel::Signature();
  }ImGui::End();ImGui::PopStyleVar(2);
 }
 return readyAt>=0||timeout;
}
static void DrawLookEditor(const std::filesystem::path& root,std::error_code& error){
 static std::string selected,previousSelection;static int view=0;static char search[128]="";
 static bool onlyEnabled=false;
 static std::set<std::string> favourites;static std::filesystem::path favouritesRoot;
 if(favouritesRoot!=root){favouritesRoot=root;favourites.clear();std::ifstream in(root/L"FX-favourites.txt");std::string name;while(favourites.size()<4096&&std::getline(in,name)){if(!name.empty()&&name.back()=='\r')name.pop_back();if(name.size()<256&&name.find_first_of("/\\")==std::string::npos&&name.ends_with(".fx"))favourites.insert(name);}}
 auto saveFavourites=[&]{const auto temp=root/L"FX-favourites.tmp",dest=root/L"FX-favourites.txt";std::ofstream out(temp,std::ios::binary|std::ios::trunc);for(const auto& name:favourites)out<<name<<'\n';out.close();if(!out||!MoveFileExW(temp.c_str(),dest.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))strcpy_s(feedback,"Could not save favourites. Check write access to OptiShadeData.");};
 static optishade::effects_ui::EditorCache cache;
 static uint64_t cacheGeneration=0,baselineSaveSerial=fx.saveSerial;
 static std::map<std::string,std::map<unsigned,std::vector<osfx::UniformInfo>>> savedValues;
 if(importedShader){fxLibraryIndexed=false;importedShader=false;}
 static const auto gameRoot=Util::DllPath().parent_path();
 if(!fxLibraryIndexed||fxLibraryRoot!=root||fxLibraryGameRoot!=gameRoot){
  fxLibrary.clear();
  for(const auto& scanRoot:{root/L"Shaders",gameRoot/L"reshade-shaders"/L"Shaders"}){
   std::error_code scanError;
   for(std::filesystem::recursive_directory_iterator it(scanRoot,scanError),end;it!=end&&!scanError;it.increment(scanError))
    if(it->is_regular_file(scanError)&&!scanError&&_wcsicmp(it->path().extension().c_str(),L".fx")==0)fxLibrary.push_back(it->path());
  }
  std::sort(fxLibrary.begin(),fxLibrary.end());fxLibraryRoot=root;fxLibraryGameRoot=gameRoot;fxLibraryIndexed=true;
 }
 cache.Sync(fx.generation);
 if(cacheGeneration!=fx.generation){cacheGeneration=fx.generation;savedValues.clear();previousSelection.clear();}
 if(fx.saveSerial!=baselineSaveSerial){baselineSaveSerial=fx.saveSerial;if(fx.saveOK){savedValues.clear();for(const auto& item:cache.effects)for(const auto& page:item.second.pages)savedValues[item.first][page.first]=page.second;}}
 if(!fx.loading&&!ImGui::IsAnyItemActive()){
  if(cache.Accept(fx)){auto it=cache.effects.find(selected);if(it!=cache.effects.end()){auto page=it->second.pages.find(fx.uniformPage);if(page!=it->second.pages.end())savedValues[selected].try_emplace(fx.uniformPage,page->second);}}
 }

 std::unordered_set<std::string> activeEffects,loadedEffects,installedEffects;
 for(const auto& item:fxLibrary)installedEffects.insert(item.filename().string());
 static std::unordered_set<std::string> requestedEffects;static std::string parsedPreset;static uint64_t parsedSave=~uint64_t{},nextPresetRead=0;
 for(uint32_t i=0;i<fx.techniques;i++){loadedEffects.insert(fx.technique[i].effect);if(fx.technique[i].enabled)activeEffects.insert(fx.technique[i].effect);}
 if(parsedPreset!=fx.preset||parsedSave!=fx.saveSerial||GetTickCount64()>=nextPresetRead){
  parsedPreset=fx.preset;parsedSave=fx.saveSerial;nextPresetRead=GetTickCount64()+2000;requestedEffects.clear();
  std::ifstream preset(std::filesystem::u8path(fx.preset));std::string line;
  while(std::getline(preset,line))if(const auto key=line.find("Techniques=");key!=std::string::npos){
   auto value=line.substr(key+11);size_t start=0;
   while(start<value.size()){const auto end=value.find(',',start);auto item=value.substr(start,end==std::string::npos?std::string::npos:end-start);const auto at=item.rfind('@');
    if(at!=std::string::npos){auto effect=item.substr(at+1);while(!effect.empty()&&std::isspace(static_cast<unsigned char>(effect.front())))effect.erase(effect.begin());while(!effect.empty()&&std::isspace(static_cast<unsigned char>(effect.back())))effect.pop_back();if(effect.size()>3&&effect.compare(effect.size()-3,3,".fx")==0)requestedEffects.insert(std::move(effect));}
    if(end==std::string::npos)break;start=end+1;
   }
   break;
  }
 }
 std::set<std::string> lookNames(requestedEffects.begin(),requestedEffects.end());lookNames.insert(activeEffects.begin(),activeEffects.end());
 std::vector<std::string> allNames(installedEffects.begin(),installedEffects.end());std::sort(allNames.begin(),allNames.end());
 std::vector<std::string> names;

 optishade::panel::CardHeading("FX LIBRARY","Choose an effect on the left. Changes preview immediately; save when you are happy.",5);
 ImGui::Spacing();
 const float available=ImGui::GetContentRegionAvail().x;
 const float listWidth=std::clamp(available*.30f,280.f,430.f);
 ImGui::BeginChild("Look editor FX list",ImVec2(listWidth,0),ImGuiChildFlags_Borders|ImGuiChildFlags_AlwaysUseWindowPadding);
 const float iconSize=ImGui::GetFrameHeight();auto iconPos=ImGui::GetCursorScreenPos();ImGui::InvisibleButton("##search-glyph",ImVec2(iconSize,iconSize));DrawSearchGlyph(iconPos,iconSize,ImGui::GetColorU32(ImGuiCol_TextDisabled));ImGui::SameLine();
 ImGui::SetNextItemWidth(std::max(32.f,ImGui::GetContentRegionAvail().x-iconSize-ImGui::GetStyle().ItemSpacing.x));ImGui::InputTextWithHint("##look-editor-search","Search FX / files...",search,sizeof(search));ImGui::SameLine();
 if(ImGui::Button("##look-editor-filters",ImVec2(iconSize,iconSize))){ImGui::OpenPopup("FX library filters");}
 if(ImGui::IsItemHovered())ImGui::SetTooltip("Filter the installed effects list");
 auto filterPos=ImGui::GetItemRectMin();DrawFilterGlyph(filterPos,ImGui::GetFrameHeight(),ImGui::GetColorU32(ImGuiCol_Text));
 if(ImGui::BeginPopup("FX library filters")){ImGui::Checkbox("Enabled in this look",&onlyEnabled);ImGui::EndPopup();}
 const std::string labels[]={"This look ("+std::to_string(lookNames.size())+")","All installed ("+std::to_string(allNames.size())+")","Favourites ("+std::to_string(favourites.size())+")"};
 if(ImGui::BeginTabBar("FX views",ImGuiTabBarFlags_FittingPolicyScroll)){for(int tab=0;tab<3;++tab){if(ImGui::BeginTabItem((labels[tab]+"###fx-view-"+std::to_string(tab)).c_str())){view=tab;ImGui::EndTabItem();}}ImGui::EndTabBar();}
 if(view==0)names.assign(lookNames.begin(),lookNames.end());else if(view==1)names=allNames;else names.assign(favourites.begin(),favourites.end());
 names.erase(std::remove_if(names.begin(),names.end(),[&](const auto& name){
  if(search[0]&&std::search(name.begin(),name.end(),search,search+strlen(search),[](unsigned char a,unsigned char b){return std::tolower(a)==std::tolower(b);})==name.end())return true;
  return onlyEnabled&&!activeEffects.count(name)&&!(!loadedEffects.count(name)&&requestedEffects.count(name));
 }),names.end());
 ImGui::TextDisabled("%zu shown",names.size());
 if(selected.empty()&&!names.empty())selected=names.front();
 ImGui::BeginChild("Filtered FX",ImVec2(0,0));
 ImGuiListClipper clipper;clipper.Begin(static_cast<int>(names.size()));
 while(clipper.Step())for(int row=clipper.DisplayStart;row<clipper.DisplayEnd;++row){
  const auto& filename=names[row];
  const bool missing=installedEffects.count(filename)==0;
  const bool loaded=loadedEffects.count(filename)!=0,waiting=preparing.count(filename)!=0;
  const bool on=activeEffects.count(filename)!=0||(!loaded&&requestedEffects.count(filename)!=0);
  ImGui::PushID(filename.c_str());ImGui::BeginDisabled(waiting||missing||fx.loading||zipProcess!=nullptr);
  if(EffectSwitch("toggle",on)){
   if(loaded){for(uint32_t i=0;i<fx.techniques;i++){const auto& t=fx.technique[i];if(filename!=t.effect)continue;osfx::Command c{};c.kind=osfx::Technique;c.enabled=!on;strcpy_s(c.effect,t.effect);strcpy_s(c.name,t.name);Send(c);}}
   else{osfx::Command c{};c.kind=osfx::Load;c.enabled=1;strncpy_s(c.effect,filename.c_str(),_TRUNCATE);if(Send(c))preparing[filename]={GetTickCount64(),fx.generation};}
  }
  ImGui::EndDisabled();ImGui::SameLine();
  const auto glyphPos=ImGui::GetCursorScreenPos();const float glyphSize=ImGui::GetFrameHeight()*1.55f;ImGui::Dummy(ImVec2(glyphSize,glyphSize));DrawFxGlyph(filename,glyphPos,glyphSize,selected==filename);ImGui::SameLine();
  auto displayName=filename;const auto extension=displayName.rfind(".fx");if(extension!=std::string::npos&&extension+3==displayName.size())displayName.resize(extension);
  ImGui::BeginGroup();if(ImGui::Selectable(displayName.c_str(),selected==filename,ImGuiSelectableFlags_None,ImVec2(std::max(40.f,ImGui::GetContentRegionAvail().x-ImGui::GetFrameHeight()*2.f),ImGui::GetFrameHeight()))){selected=filename;}
  ImGui::TextDisabled("%s",filename.c_str());ImGui::EndGroup();ImGui::SameLine();
  if(FavoriteButton("favourite",favourites.count(filename)!=0)){if(favourites.count(filename))favourites.erase(filename);else favourites.insert(filename);saveFavourites();}
  if(missing){ImGui::SameLine();ImGui::TextColored(ImVec4(1.f,.28f,.38f,1.f),"!");if(ImGui::IsItemHovered())ImGui::SetTooltip("FX file is missing from the installed shader library.");}
  if(waiting){ImGui::SameLine();ImGui::TextDisabled("…");}
  ImGui::PopID();ImGui::Separator();
 }
 if(names.empty())ImGui::TextWrapped(search[0]||onlyEnabled?"No matching effects. Clear search or filters to see more.":view==2?"Star an effect to keep it here. Favourites do not enable or load shaders.":view==0?"No effects in this look. Browse All FX to add one.":"No installed FX files were found.");
 ImGui::EndChild();
  ImGui::EndChild();
  if(selected!=previousSelection){if(!previousSelection.empty())cache.SetOpen(previousSelection,false);previousSelection=selected;if(!selected.empty())cache.SetOpen(selected,true);}
  ImGui::SameLine();
 ImGui::BeginChild("Look editor selected effect",ImVec2(0,0),ImGuiChildFlags_Borders|ImGuiChildFlags_AlwaysUseWindowPadding);
 if(selected.empty())ImGui::TextWrapped("Select an FX file to see its settings.");
 else{
  ImGui::PushID(selected.c_str());
  const bool loaded=loadedEffects.count(selected)!=0,on=activeEffects.count(selected)!=0||(!loaded&&requestedEffects.count(selected)!=0),waiting=preparing.count(selected)!=0;
  auto& effect=cache.effects[selected];
  auto detailGlyph=ImGui::GetCursorScreenPos();DrawFxGlyph(selected,detailGlyph,ImGui::GetFrameHeight()*2.1f,true);ImGui::Dummy(ImVec2(ImGui::GetFrameHeight()*2.1f,ImGui::GetFrameHeight()*2.1f));ImGui::SameLine();
  ImGui::BeginGroup();ImGui::Text("%s",selected.c_str());
  if(!effect.description.empty())ImGui::TextWrapped("%s",effect.description.c_str());
  else ImGui::TextDisabled("Shader settings and activation for this effect.");
   ImGui::TextDisabled("You can edit settings while this FX is enabled; changes apply live.");
    ImGui::TextDisabled("%s",EffectLoadStatus(waiting,activeEffects.count(selected)!=0,requestedEffects.count(selected)!=0,loaded,fx.compileOK!=0));ImGui::EndGroup();ImGui::SameLine();
  if(FavoriteButton("detail-favourite",favourites.count(selected)!=0)){if(favourites.count(selected))favourites.erase(selected);else favourites.insert(selected);saveFavourites();}
  ImGui::SameLine();if(ImGui::SmallButton("?"))ImGui::SetTooltip("Shader controls come from this FX file. Numeric settings can be adjusted with the slider or an exact typed value.");
  ImGui::Separator();
  auto path=std::find_if(fxLibrary.begin(),fxLibrary.end(),[&](const auto& p){return p.filename().string()==selected;});
  const bool selectedMissing=path==fxLibrary.end();
  if(!fx.performanceMode&&!fx.loading&&zipProcess==nullptr&&!loaded&&!waiting&&!selectedMissing&&ImGui::Button("Load shader settings")){osfx::Command c{};c.kind=osfx::Load;strncpy_s(c.effect,selected.c_str(),_TRUNCATE);if(Send(c))preparing[selected]={GetTickCount64(),fx.generation};}
  if(fx.performanceMode)ImGui::TextWrapped("Turn off Performance Mode on Image effects to load and edit shader settings.");
  else if(!effect.known)ImGui::TextWrapped(waiting?"Preparing effect...":loaded?"Loading shader settings...":"Browse without changing the image. Load shader settings or enable this effect when ready.");
  else if(effect.total==0)ImGui::TextWrapped("This FX file exposes no editable shader values.");
  else{
   const unsigned pageCount=std::max(1u,(effect.total+osfx::MaxUniforms-1)/osfx::MaxUniforms);
   ImGui::BeginDisabled(fx.loading||zipProcess!=nullptr||fx.performanceMode);
   for(unsigned page=0;page<pageCount;++page){
    ImGui::Spacing();ImGui::SeparatorText((selected+" - settings page "+std::to_string(page+1)+" of "+std::to_string(pageCount)).c_str());
    auto found=effect.pages.find(page);if(found==effect.pages.end()){ImGui::TextDisabled("Loading this settings page...");continue;}
    savedValues[selected].try_emplace(page,found->second);
    for(auto& u:found->second){
     ImGui::PushID(u.effect);ImGui::PushID(u.name);ImGui::PushID(static_cast<int>(u.arrayIndex));
     const char* label=u.label[0]?u.label:u.name;ImGui::TextWrapped("%s",label);
     if(u.arrayCount>1){ImGui::SameLine();ImGui::TextDisabled("[%u]",u.arrayIndex+1);}
     if(u.tooltip[0]&&ImGui::IsItemHovered())ImGui::SetTooltip("%s",u.tooltip);
     for(uint32_t k=0;k<u.count;k++){
      ImGui::PushID(static_cast<int>(k));if(u.count>1){ImGui::AlignTextToFramePadding();ImGui::Text("%u",k+1);ImGui::SameLine();}
      bool changed=false;
      if((u.uiKind==osfx::UiCombo||u.uiKind==osfx::UiList||u.uiKind==osfx::UiRadio)&&(u.type==1||u.type==2)&&u.count==1&&u.itemsSize){
       std::vector<std::string> choices;size_t offset=0,limit=std::min<size_t>(u.itemsSize,sizeof(u.items));
       while(offset<limit){size_t end=offset;while(end<limit&&u.items[end])++end;if(end>offset)choices.emplace_back(u.items+offset,end-offset);offset=end+1;}
       int current=u.type==1?u.signedValue[k]:static_cast<int>(std::min<uint32_t>(u.unsignedValue[k],INT_MAX));
       const char* preview=current>=0&&static_cast<size_t>(current)<choices.size()?choices[current].c_str():"Choose...";
       if(u.uiKind==osfx::UiRadio){for(size_t i=0;i<choices.size();++i){if(i)ImGui::SameLine();if(ImGui::RadioButton(choices[i].c_str(),current==static_cast<int>(i))){current=static_cast<int>(i);changed=true;}}}
       else if(ImGui::BeginCombo("##choice",preview)){for(size_t i=0;i<choices.size();++i)if(ImGui::Selectable(choices[i].c_str(),current==static_cast<int>(i))){current=static_cast<int>(i);changed=true;}ImGui::EndCombo();}
       if(changed){if(u.type==1)u.signedValue[k]=current;else u.unsignedValue[k]=static_cast<uint32_t>(current);}
      }else if(u.type==3){bool value=u.value[k]!=0;if(u.uiKind==osfx::UiCombo){const char* options[]={"Off","On"};int current=value?1:0;if(ImGui::Combo("##boolean",&current,options,2)){u.value[k]=current?1.f:0.f;changed=true;}}else if(ImGui::Checkbox("##enabled",&value)){u.value[k]=value?1.f:0.f;changed=true;}}
      else if(u.type==1)changed|=optishade::effects_ui::Integer("value",u.signedValue[k],u.hasRange!=0,u.minimum,u.maximum);
      else if(u.type==2)changed|=optishade::effects_ui::Integer("value",u.unsignedValue[k],u.hasRange!=0,u.minimum,u.maximum);
      else changed|=optishade::effects_ui::Numeric("value",u.value[k],false,u.hasRange!=0,u.minimum,u.maximum);
      if(changed){osfx::Command c{};c.kind=osfx::Uniform;c.count=u.count;c.arrayIndex=u.arrayIndex;c.type=u.type;strcpy_s(c.effect,u.effect);strcpy_s(c.name,u.name);std::copy_n(u.value,16,c.value);std::copy_n(u.signedValue,16,c.signedValue);std::copy_n(u.unsignedValue,16,c.unsignedValue);Send(c);}
      ImGui::PopID();
     }
     ImGui::Separator();ImGui::PopID();ImGui::PopID();ImGui::PopID();
    }
   }
   ImGui::EndDisabled();
   if(cache.exhausted)ImGui::TextWrapped("The settings cache is full. Close this editor and reopen it to inspect another effect.");
   ImGui::BeginDisabled(savedValues[selected].empty()||fx.performanceMode||fx.loading||zipProcess!=nullptr);
   if(ImGui::Button("Reset to saved")){
    for(const auto& page:savedValues[selected])for(const auto& original:page.second){
     osfx::Command c{};c.kind=osfx::Uniform;c.count=original.count;c.arrayIndex=original.arrayIndex;c.type=original.type;strcpy_s(c.effect,original.effect);strcpy_s(c.name,original.name);std::copy_n(original.value,16,c.value);std::copy_n(original.signedValue,16,c.signedValue);std::copy_n(original.unsignedValue,16,c.unsignedValue);Send(c);
    }
    cache.effects[selected].pages=savedValues[selected];strcpy_s(feedback,"This effect's values were restored to the saved look values.");
   }
   ImGui::EndDisabled();if(fx.performanceMode)ImGui::TextDisabled("Turn off Performance Mode on the Image effects page before editing values.");
  }
  if(path!=fxLibrary.end()){
   ImGui::Spacing();ImGui::SeparatorText("File information");
   ImGui::Text("Filename: %s",path->filename().string().c_str());ImGui::TextUnformatted("Type: ReShade effect (.fx)");
  ImGui::TextWrapped("Status: %s",EffectLoadStatus(waiting,activeEffects.count(selected)!=0,requestedEffects.count(selected)!=0,loaded,fx.compileOK!=0));ImGui::TextWrapped("Location: %s",path->string().c_str());
  }else{ImGui::TextColored(ImVec4(1.f,.28f,.38f,1.f),"This effect is referenced by the look but its FX file is missing.");ImGui::TextWrapped("Restore the shader file to OptiShadeData/Shaders, then rescan installed FX from Image effects.");}
  ImGui::PopID();
 }
 ImGui::EndChild();
 if(fx.performanceMode)ImGui::TextWrapped("Performance Mode is on. Values are read-only until it is disabled on the Image effects page.");
 if(!fx.loading&&zipProcess==nullptr&&!fx.performanceMode&&!ImGui::IsAnyItemActive()){
  osfx::Command c{};if(cache.Next(GetTickCount64(),c)){auto module=GetModuleHandleW(L"ReShade64.dll");auto send=module?(osfx::Send)GetProcAddress(module,"OptiShadeEffectsSend"):nullptr;c.version=osfx::Version;c.generation=fx.generation;if(!send||!send(&c,sizeof(c)))cache.CancelRequest();}
 }
 if(feedback[0])ImGui::TextWrapped("%s",feedback);
}
static void DrawEffects(bool editor=false){
 PollZipImport();
 auto module=GetModuleHandleW(L"ReShade64.dll");auto read=module?(osfx::Read)GetProcAddress(module,"OptiShadeEffectsRead"):nullptr;
 bool connected=read&&read(&fx,sizeof(fx));

 for(auto it=preparing.begin();it!=preparing.end();){
  bool found=false;
  if(!fx.loading){for(uint32_t i=0;i<fx.techniques;i++){auto& t=fx.technique[i];if(it->first==t.effect&&t.enabled)found=true;}}
  const auto result=optishade::fxready::poll(it->second,GetTickCount64(),fx.generation,connected,fx.loading!=0,found);
  if(result==optishade::fxready::Result::Waiting){++it;continue;}
  if(result==optishade::fxready::Result::Active)strcpy_s(feedback,"Effect compiled and activated.");
  else if(result==optishade::fxready::Result::RuntimeLost)strcpy_s(feedback,"The effects runtime stopped responding. Retry when the game finishes loading.");
  else if(result==optishade::fxready::Result::Cancelled)strcpy_s(feedback,"The effects runtime changed. Please select the effect again.");
  else strcpy_s(feedback,fx.loading?"Effect compilation has exceeded two minutes. Check the effects log before retrying.":"This effect did not activate. Check for missing files or shader compile errors, then retry.");
  it=preparing.erase(it);
 }

 if(!connected){ImGui::TextWrapped("Image effects are not responding yet. The game may still be loading.");if(feedback[0])ImGui::TextWrapped("%s",feedback);return;}
 if(fx.saveSerial!=seenSave){seenSave=fx.saveSerial;strcpy_s(feedback,fx.saveOK?"Preset saved. This look will load next time.":"Could not save. Check the folder, permissions, and use a new name for Save as.");}
 ReadUniformEditAcks();
 auto root=Util::DllPath().parent_path()/L"OptiShadeData";
 std::error_code error;
 if(editor){DrawLookEditor(root,error);return;}
 ImGui::BeginDisabled(fx.loading!=0||zipProcess!=nullptr);
 const auto panelPosition=ImGui::GetWindowPos(),panelSize=ImGui::GetWindowSize();
 if(!editor) optishade::panel::Card("Saved look card",[&]{
 optishade::panel::CardHeading("SAVED LOOK","",2);
 bool enabled=fx.enabled!=0;if(EffectSwitch("Image effects enabled",enabled)){osfx::Command c{};c.kind=osfx::Effects;c.enabled=!enabled;Send(c);}
 ImGui::SameLine();ImGui::BeginGroup();ImGui::TextUnformatted("Image effects enabled");ImGui::TextDisabled("Applies your saved look and active shaders.");ImGui::EndGroup();ImGui::Spacing();ImGui::Separator();

 static char presetName[128]="My custom look",presetFolder[1024]="";static bool replaceCurrent=false;static bool openSave=false;
 if(openSave){ImGui::OpenPopup("Save your look");openSave=false;}

 ImGui::SetNextWindowPos(panelPosition,ImGuiCond_Always);
 ImGui::SetNextWindowSize(panelSize,ImGuiCond_Always);
 if(ImGui::BeginPopupModal("Save your look",nullptr,ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoResize)){
  ImGui::TextWrapped("Save your chosen effects and their current settings as an INI preset.");
  ImGui::SetNextItemWidth(std::max(100.f,ImGui::GetContentRegionAvail().x-60.f));ImGui::InputText("Name",presetName,sizeof(presetName),ImGuiInputTextFlags_AutoSelectAll);
  ImGui::SetNextItemWidth(std::max(100.f,ImGui::GetContentRegionAvail().x-60.f));ImGui::InputText("Folder",presetFolder,sizeof(presetFolder));
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
 static char nextPreset[1024]="";static bool askSwitch=false,waitingSwitch=false;static uint64_t switchSaveSerial=0;
 LoadSwapPair();ImGui::AlignTextToFramePadding();ImGui::TextUnformatted("Preset");ImGui::SameLine(ImGui::GetWindowWidth()*.37f);ImGui::SetNextItemWidth(-1);
 if(ImGui::BeginCombo("##Look presets",(swapMain.empty()?std::filesystem::u8path(fx.preset):swapMain).filename().string().c_str())){
  for(std::filesystem::recursive_directory_iterator i(root/L"Presets",error),end;i!=end&&!error;i.increment(error)){
   if(i->path().extension()!=L".ini"||SameSwapPreset(i->path(),swapAlternate))continue;auto label=i->path().filename().string()+"##"+i->path().string();if(ImGui::Selectable(label.c_str())){auto path=i->path().u8string();if(fx.dirty){strncpy_s(nextPreset,(const char*)path.c_str(),_TRUNCATE);askSwitch=true;}else{RequestPresetLoad(i->path(),root);}}
  }ImGui::EndCombo();
 }

 if(!editor){
  ImGui::TextWrapped("Choose your saved look here. Open the editor to browse shaders and tune every setting.");
  if(ImGui::Button("Open look editor",ImVec2(-1,ImGui::GetFrameHeight()*1.5f)))lookEditorOpen=true;
  if(fx.dirty)ImGui::TextWrapped("Your look has unsaved changes. Save to keep them.");
 }
 ImGui::TextDisabled("Your image effects preset is separate from neural rendering.");
 ImGui::Spacing();ImGui::BeginDisabled(fx.performanceMode!=0);if(ImGui::Button("Save a copy",ImVec2(ImGui::GetContentRegionAvail().x*.48f,ImGui::GetFrameHeight()*1.3f))){auto current=std::filesystem::u8path(fx.preset);auto folder=(root/L"Presets").u8string();auto name=current.stem().u8string();strncpy_s(presetFolder,(const char*)folder.c_str(),_TRUNCATE);if(!name.empty())strncpy_s(presetName,(const char*)name.c_str(),_TRUNCATE);replaceCurrent=false;openSave=true;}
 ImGui::EndDisabled();if(ImGui::IsItemHovered())ImGui::SetTooltip("Save a copy... or explicitly replace your current preset.");
 ImGui::SameLine();ImGui::BeginDisabled(!fx.dirty);if(ImGui::Button("Revert changes",ImVec2(-1,ImGui::GetFrameHeight()*1.3f))){osfx::Command c{};c.kind=osfx::Discard;if(Send(c))preparing.clear();}ImGui::EndDisabled();
 DrawPresetBrowser(root);
 auto deliveryText=[](const char* label,const osfx::Delivery& d){
  const char* state="not connected";
  switch(d.state){case 1:state="preset pending";break;case 2:state="preset loading";break;case 3:state="preset failed or missing techniques";break;case 4:state="preset submitted to renderer (confirm output)";break;case 5:state="effects bypassed";break;case 6:state="separate profile retained";break;case 7:state="not currently presenting";break;}
  ImGui::TextWrapped("%s: %s",label,state);
 };
 if(ImGui::CollapsingHeader("Preset output details")){deliveryText("Desktop",fx.desktop);deliveryText("Headset",fx.headset);}
 if(fx.headset.generation){
  const bool linked=fx.headset.state!=6;
  ImGui::BeginDisabled(fx.dirty!=0);
  if(EffectSwitch("Link headset look to desktop",linked)){osfx::Command c{};c.kind=osfx::LinkVR;c.enabled=!linked;Send(c);}
  ImGui::SameLine();ImGui::TextUnformatted("Link headset look to desktop");
  ImGui::EndDisabled();
  if(fx.dirty)ImGui::TextWrapped("Save or discard your changes before changing headset linking.");
 }


 if(!fx.loading){
  using optishade::preset::State;
  switch(static_cast<State>(fx.presetState)){
  case State::Applied:ImGui::TextWrapped("Saved look fully applied: %u requested techniques active.",fx.presetApplied);break;
  case State::Partial:ImGui::TextWrapped("Saved look partially applied: %u of %u requested techniques active.",fx.presetApplied,fx.presetRequested);break;
  case State::Failed:ImGui::TextWrapped("Saved look failed validation: no complete compiled technique match. Your preset file is unchanged.");break;
  case State::Edited:ImGui::TextWrapped("Current look has unsaved changes; save to validate it against the preset.");break;
  case State::Disabled:ImGui::TextWrapped("Image effects are off. The saved look is not currently applied.");break;
  default:ImGui::TextWrapped("Saved look validation is not available yet.");break;
  }
  if(fx.presetMissing)ImGui::TextWrapped("Missing techniques: %s",fx.presetReport);
  if(!fx.compileOK)ImGui::TextWrapped("Some FX failed to compile. Check the effects log for the shader error; installed files alone do not mean the look loaded.");
  if(fx.presetMissing)ImGui::TextWrapped("Check the preset author's ZIP and installation instructions for the matching FX variant. OptiShade does not rename techniques or change your source preset.");
 }
 if(zipProcess)ImGui::TextWrapped("Installing files in the background... You can keep flying; reopen Image effects to see the result.");


 if(askSwitch){ImGui::OpenPopup("Unsaved preset changes");askSwitch=false;}
 ImGui::SetNextWindowPos(panelPosition,ImGuiCond_Always);
 ImGui::SetNextWindowSize(panelSize,ImGuiCond_Always);
 if(ImGui::BeginPopupModal("Unsaved preset changes",nullptr,ImGuiWindowFlags_NoMove|ImGuiWindowFlags_NoResize)){
  ImGui::TextColored(ImVec4(1.f,.3f,.4f,1.f),"Your current preset has unsaved changes.");
  ImGui::TextUnformatted("Save them, discard them, or keep editing.");
  if(waitingSwitch&&fx.saveSerial>switchSaveSerial){waitingSwitch=false;if(fx.saveOK){RequestPresetLoad(std::filesystem::u8path(nextPreset),root,true);preparing.clear();ImGui::CloseCurrentPopup();}}
  ImGui::BeginDisabled(waitingSwitch);
  if(ImGui::Button("Save and switch")){osfx::Command c{};c.kind=osfx::Save;switchSaveSerial=fx.saveSerial;waitingSwitch=Send(c);}
  ImGui::SameLine();if(ImGui::Button("Discard and switch")){RequestPresetLoad(std::filesystem::u8path(nextPreset),root,true);preparing.clear();ImGui::CloseCurrentPopup();}
  ImGui::SameLine();if(ImGui::Button("Keep editing"))ImGui::CloseCurrentPopup();ImGui::EndDisabled();
  if(feedback[0])ImGui::TextWrapped("%s",feedback);ImGui::EndPopup();
 }
 if(fx.dirty){ImGui::TextColored(ImVec4(1.f,.3f,.4f,1.f),"Unsaved changes - your INI has not been overwritten.");ImGui::SameLine();}

 if(ImGui::CollapsingHeader("Preset tools: import using a full file path")){
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
 });
 if(!editor){
 if(optishade::panel::Group("Preset switching",optishade::panel::Section::PresetSwitch,"Your two saved looks and their shortcut")){
  ImGui::TextWrapped("Preset 1: %s",(swapMain.empty()?std::filesystem::u8path(fx.preset):swapMain).filename().string().c_str());
  ImGui::TextWrapped("Choose Preset 1 with Saved look above. Unsaved edits remain protected.");
  DrawHotSwap();
 }
 if(optishade::panel::Group("Preset tools & advanced shader options",optishade::panel::Section::EffectsTools,"Import/export, package management and maintenance tools")){
 bool performanceMode=fx.performanceMode!=0;
 ImGui::BeginDisabled(fx.dirty!=0&&!performanceMode);if(ImGui::Checkbox("Performance Mode (image effects)",&performanceMode)){osfx::Command c{};c.kind=osfx::PerformanceMode;c.enabled=performanceMode;Send(c);}ImGui::EndDisabled();
 if(fx.dirty)ImGui::TextDisabled("Save or revert your look before changing Performance Mode.");
 else ImGui::TextDisabled("Optimizes saved shader settings. Turn off to edit shader values. Gains vary by effect.");
 if(ImGui::Button("Recompile installed FX")){osfx::Command c{};c.kind=osfx::Reload;Send(c);}if(ImGui::IsItemHovered())ImGui::SetTooltip("Reload shader code already installed in the game. This does not import or download files.");
 if(ImGui::Button("Rescan installed FX list"))fxLibraryIndexed=false;
 }
 }
 ImGui::EndDisabled();
}
}
