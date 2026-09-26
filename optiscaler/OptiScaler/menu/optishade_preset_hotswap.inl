// OptiShade additions, GPL-3.0-or-later. Two saved looks; no automatic preset overwrite.
static void DrawHotSwapKeybind();
static std::filesystem::path swapMain,swapAlternate;
static bool swapLoaded=false;
static optishade::hotswap::PressGate swapPress;
static ULONGLONG swapNextAllowed=0;
static bool SameSwapPreset(const std::filesystem::path& a,const std::filesystem::path& b);
static std::filesystem::path swapPending;
static int swapPendingNumber=0;
static uint64_t swapPendingApplied=0,swapPendingRejected=0;
static ULONGLONG swapPendingDeadline=0;
static void ConfirmHotSwap(){
 if(swapPending.empty())return;
 auto module=GetModuleHandleW(L"ReShade64.dll");auto read=module?(osfx::Read)GetProcAddress(module,"OptiShadeEffectsRead"):nullptr;
 static osfx::Snapshot status{};
 if(read&&read(&status,sizeof(status))){
  if(status.rejected>swapPendingRejected){swapPending.clear();return;}
  if(!status.loading&&status.applied>swapPendingApplied&&SameSwapPreset(std::filesystem::u8path(status.preset),swapPending)){
   ImGuiToast toast{ImGuiToastType::Info,2000};
   toast.setTitle("Hotswap: preset %d",swapPendingNumber);
   ImGui::InsertNotification(toast);swapPending.clear();return;
  }
 }
 if(GetTickCount64()>swapPendingDeadline)swapPending.clear();
}
static std::filesystem::path SwapSettingsPath(){return Util::DllPath().parent_path()/L"OptiShadeData"/L"PresetHotSwap.ini";}
static void LoadSwapPair(){
 if(swapLoaded)return;swapLoaded=true;wchar_t value[1024]{};auto file=SwapSettingsPath();
 GetPrivateProfileStringW(L"Presets",L"Main",L"",value,1024,file.c_str());swapMain=value;
 GetPrivateProfileStringW(L"Presets",L"Hotswap",L"",value,1024,file.c_str());swapAlternate=value;
}
static bool SaveSwapPair(){
 auto file=SwapSettingsPath();auto temp=file;temp+=L".tmp";std::error_code ec;std::filesystem::create_directories(file.parent_path(),ec);
 std::ofstream out(temp,std::ios::binary|std::ios::trunc);const wchar_t bom=0xfeff;
 const std::wstring data=L"[Presets]\r\nMain="+swapMain.wstring()+L"\r\nHotswap="+swapAlternate.wstring()+L"\r\n";
 out.write(reinterpret_cast<const char*>(&bom),sizeof(bom));out.write(reinterpret_cast<const char*>(data.data()),data.size()*sizeof(wchar_t));out.flush();bool written=out.good();out.close();
 if(ec||!written||!MoveFileExW(temp.c_str(),file.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)){
  strcpy_s(feedback,"Could not save the hotswap selection. Check folder permissions.");return false;
 }return true;
}
static void RememberMainPreset(const char* path){LoadSwapPair();swapMain=std::filesystem::u8path(path);SaveSwapPair();}
static bool SameSwapPreset(const std::filesystem::path& a,const std::filesystem::path& b){return optishade::hotswap::same_preset(a,b,Util::DllPath().parent_path());}
static bool SwapKeyConflict(int key){
 auto c=Config::Instance();return key>0&&(key==c->ShortcutKey.value_or_default()||key==c->FpsShortcutKey.value_or_default()||key==c->FpsCycleShortcutKey.value_or_default()||key==c->FGShortcutKey.value_or_default()||key==c->DlssNrToggleKey.value_or_default());
}
static void TryHotSwap(){
 LoadSwapPair();auto module=GetModuleHandleW(L"ReShade64.dll");auto read=module?(osfx::Read)GetProcAddress(module,"OptiShadeEffectsRead"):nullptr;
 if(!read||!read(&fx,sizeof(fx))||fx.loading){strcpy_s(feedback,"Image effects are loading. Try the preset swap when ready.");return;}
 if(fx.dirty){strcpy_s(feedback,"Preset swap skipped: save or revert your unsaved image-effects changes first.");return;}
 auto current=std::filesystem::u8path(fx.preset);if(swapMain.empty())swapMain=current;
 if(swapMain.empty()||swapAlternate.empty()||SameSwapPreset(swapMain,swapAlternate)){strcpy_s(feedback,"Choose two different presets: Preset 1 and Preset 2.");return;}
 auto next=optishade::hotswap::next_preset(current,swapMain,swapAlternate,Util::DllPath().parent_path());std::error_code ec;
 if(!std::filesystem::is_regular_file(next,ec)||ec){strcpy_s(feedback,"The selected preset is missing. Choose it again in Image effects.");return;}
 if(GetTickCount64()<swapNextAllowed||!swapPending.empty())return;
 auto path=next.u8string();if(path.size()>=sizeof(osfx::Command{}.path)){strcpy_s(feedback,"The preset path is too long.");return;}
 osfx::Command c{};c.kind=osfx::HotSwapPreset;strncpy_s(c.path,(const char*)path.c_str(),_TRUNCATE);
 if(Send(c)){swapPending=next;swapPendingNumber=SameSwapPreset(next,swapMain)?1:2;swapPendingApplied=fx.applied;swapPendingRejected=fx.rejected;swapPendingDeadline=GetTickCount64()+120000;swapNextAllowed=GetTickCount64()+1000;LOG_INFO("OptiShade preset hotswap requested: {}",next.filename().string());}
}
static void PollHotSwap(bool pressed,bool released,bool allowed){
 ConfirmHotSwap();
 if(swapPress.update(pressed,released,allowed))TryHotSwap();
}
static void DrawHotSwap(){
 LoadSwapPair();if(swapMain.empty()&&fx.preset[0]){swapMain=std::filesystem::u8path(fx.preset);SaveSwapPair();}
 auto label=swapAlternate.empty()?std::string("Choose a preset"):swapAlternate.filename().string();
 DrawHotSwapKeybind();
 ImGui::TextUnformatted("Preset 2");ImGui::SameLine();ImGui::SetNextItemWidth(300);
 if(ImGui::BeginCombo("##Hotswap preset",label.c_str())){
  std::error_code ec;auto root=Util::DllPath().parent_path()/L"OptiShadeData"/L"Presets";
  for(std::filesystem::recursive_directory_iterator i(root,ec),end;i!=end&&!ec;i.increment(ec)){
   if(_wcsicmp(i->path().extension().c_str(),L".ini")||!i->is_regular_file(ec)||SameSwapPreset(i->path(),swapMain))continue;
   auto name=i->path().lexically_relative(root).string();if(ImGui::Selectable(name.c_str(),SameSwapPreset(i->path(),swapAlternate))){swapAlternate=i->path();SaveSwapPair();}
  }ImGui::EndCombo();
 }
 ImGui::Text("Active look: %s",std::filesystem::u8path(fx.preset).filename().string().c_str());
 const bool invalid=swapMain.empty()||swapAlternate.empty()||SameSwapPreset(swapMain,swapAlternate)||fx.dirty;
 ImGui::BeginDisabled(invalid);if(ImGui::Button("Switch preset"))TryHotSwap();ImGui::EndDisabled();
 ImGui::TextDisabled("One key switches between your two looks. Different shaders may briefly reload.");
 if(fx.dirty)ImGui::TextDisabled("Save or revert unsaved edits before swapping.");
 if(SwapKeyConflict(Config::Instance()->PresetHotSwapKey.value_or_default()))ImGui::TextColored(ImVec4(1,.4f,.3f,1),"Hotswap key conflicts with another OptiShade shortcut. Choose another key.");
}
