// In-game file browser. Directory contents are refreshed only on navigation.
static std::string BrowserText(const std::filesystem::path& path){auto s=path.u8string();return std::string((const char*)s.c_str());}
static bool ImportLook(const std::filesystem::path& source,const std::filesystem::path& root){
 if(fx.dirty){strcpy_s(feedback,"Save or revert your current changes before importing a preset.");return false;}
 std::error_code ec;auto ext=source.extension().wstring();for(auto& ch:ext)ch=(wchar_t)towlower(ch);
 if((ext!=L".ini"&&ext!=L".fx")||!std::filesystem::is_regular_file(source,ec)){strcpy_s(feedback,"Choose an INI preset or FX shader.");return false;}
 auto folder=root/(ext==L".ini"?L"Presets":L"Shaders");std::filesystem::create_directories(folder,ec);
 if(ec){strcpy_s(feedback,"Could not open the game's preset folder.");return false;}
 auto dest=folder/source.filename();dest.replace_extension(ext);
 if(!std::filesystem::equivalent(source,dest,ec)){
  ec.clear();unsigned suffix=2;
  while(std::filesystem::exists(dest,ec)&&!ec&&suffix<10000)dest=folder/(source.stem().wstring()+L" ("+std::to_wstring(suffix++)+L")"+ext);
  auto encoded=BrowserText(dest);if(ec||encoded.size()>=sizeof(osfx::Command{}.path)){strcpy_s(feedback,"Choose a shorter file name or another folder.");return false;}
  if(!std::filesystem::copy_file(source,dest,std::filesystem::copy_options::none,ec)){strcpy_s(feedback,"Could not copy this file. Existing presets were kept.");return false;}
 }
 auto encoded=BrowserText(dest);if(encoded.size()>=1024){strcpy_s(feedback,"This path is too long.");return false;}
 osfx::Command c{};c.kind=ext==L".ini"?osfx::Preset:osfx::Reload;strcpy_s(c.path,encoded.c_str());return Send(c);
}
static void DrawPresetBrowser(const std::filesystem::path& root){
 static char folderText[1024]="",filter[128]="";
 static std::filesystem::path folder,selected;
 static std::vector<std::filesystem::path> entries;
 static bool refresh=false;static std::string issue;
 if(ImGui::Button("Browse presets...")){
  wchar_t home[32768]{};GetEnvironmentVariableW(L"USERPROFILE",home,32768);folder=std::filesystem::path(home)/L"Downloads";
  std::error_code ec;if(!std::filesystem::is_directory(folder,ec))folder=root/L"Presets";
  refresh=true;selected.clear();filter[0]=0;ImGui::OpenPopup("Import a look");
 }
 ImGui::SetNextWindowSize(ImVec2(700,540),ImGuiCond_Appearing);
 if(ImGui::BeginPopupModal("Import a look",nullptr,ImGuiWindowFlags_NoCollapse)){
  ImGui::TextWrapped("Choose a downloaded INI preset. OptiShade copies it into your game's presets folder and loads its effects. Your downloaded file stays where it is.");
  auto go=[&](const std::filesystem::path& path){folder=path;refresh=true;selected.clear();};
  if(ImGui::Button("Downloads")){wchar_t home[32768]{};GetEnvironmentVariableW(L"USERPROFILE",home,32768);go(std::filesystem::path(home)/L"Downloads");}
  ImGui::SameLine();if(ImGui::Button("Game presets"))go(root/L"Presets");
  ImGui::SameLine();if(ImGui::Button("Up")&&folder.has_parent_path())go(folder.parent_path());
  ImGui::SameLine();if(ImGui::Button("Refresh"))refresh=true;
  if(refresh){
   entries.clear();issue.clear();auto text=BrowserText(folder);strncpy_s(folderText,text.c_str(),_TRUNCATE);
   std::error_code ec;for(std::filesystem::directory_iterator it(folder,ec),end;it!=end&&!ec;it.increment(ec)){
    auto ext=it->path().extension().wstring();for(auto& ch:ext)ch=(wchar_t)towlower(ch);
    std::error_code typeError;if(it->is_directory(typeError)||ext==L".ini")entries.push_back(it->path());
    if(entries.size()>=3000){issue="This folder is very large. Open a smaller folder to see more files.";break;}
   }
   if(ec)issue="Could not read this folder. Check the location and access permissions.";
   std::sort(entries.begin(),entries.end());refresh=false;
  }
  ImGui::SetNextItemWidth(-80);ImGui::InputText("##folder",folderText,sizeof(folderText));ImGui::SameLine();if(ImGui::Button("Go"))go(std::filesystem::u8path(folderText));
  ImGui::InputTextWithHint("##findpreset","Find a preset...",filter,sizeof(filter));
  ImGui::BeginChild("Preset files",ImVec2(0,260),true);
  for(const auto& entry:entries){
   auto name=BrowserText(entry.filename());std::string match=name,query=filter;
   for(auto& ch:match)ch=(char)tolower((unsigned char)ch);for(auto& ch:query)ch=(char)tolower((unsigned char)ch);
   if(match.find(query)==std::string::npos)continue;
   std::error_code ec;bool dir=std::filesystem::is_directory(entry,ec);auto label=(dir?"[Folder] ":"")+name;
   if(ImGui::Selectable(label.c_str(),entry==selected)){if(dir)go(entry);else selected=entry;}
  }
  ImGui::EndChild();
  if(!issue.empty())ImGui::TextWrapped("%s",issue.c_str());
  ImGui::TextWrapped("Missing shaders are not downloaded here. Install the effects pack first. Existing presets are never overwritten.");
  ImGui::BeginDisabled(selected.empty()||fx.dirty||fx.loading);
  if(ImGui::Button("Copy and load")){if(ImportLook(selected,root))ImGui::CloseCurrentPopup();}
  ImGui::EndDisabled();ImGui::SameLine();if(ImGui::Button("Cancel"))ImGui::CloseCurrentPopup();
  if(fx.dirty)ImGui::TextColored(ImVec4(1,.3f,.4f,1),"Save or revert your unsaved changes first.");
  if(feedback[0])ImGui::TextWrapped("%s",feedback);ImGui::EndPopup();
 }
}
