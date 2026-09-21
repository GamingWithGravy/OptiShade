// In-game file browser. Directory contents are refreshed only on navigation.
static std::string BrowserText(const std::filesystem::path& path){auto s=path.u8string();return std::string((const char*)s.c_str());}
static bool importedShader=false;
static bool ImportLook(const std::filesystem::path& source,const std::filesystem::path& root){
 if(fx.dirty){strcpy_s(feedback,"Save or revert your current changes before importing a preset.");return false;}
 std::error_code ec;auto ext=source.extension().wstring();for(auto& ch:ext)ch=(wchar_t)towlower(ch);
 if((ext!=L".ini"&&ext!=L".fx")||!std::filesystem::is_regular_file(source,ec)){strcpy_s(feedback,"Choose an INI preset or FX shader.");return false;}
 if(ext==L".fx"){
  for(std::filesystem::recursive_directory_iterator it(root/L"Shaders",ec),end;it!=end&&!ec;it.increment(ec)){
   auto name=it->path().filename().wstring(),wanted=source.filename().wstring();for(auto& c:name)c=(wchar_t)towlower(c);for(auto& c:wanted)c=(wchar_t)towlower(c);
   if(name!=wanted)continue;
   std::error_code same;if(std::filesystem::equivalent(source,it->path(),same)){osfx::Command c{};c.kind=osfx::Reload;importedShader=true;return Send(c);}
   strcpy_s(feedback,"An FX file with this name is already installed. Back it up before replacing it outside the game; duplicate shader names are not imported.");return false;
  }ec.clear();
 }
 auto folder=root/(ext==L".ini"?L"Presets":L"Shaders/Custom");std::filesystem::create_directories(folder,ec);
 if(ec){strcpy_s(feedback,"Could not open the game's preset folder.");return false;}
 auto dest=folder/source.filename();dest.replace_extension(ext);
 if(!std::filesystem::equivalent(source,dest,ec)){
  ec.clear();unsigned suffix=2;
  if(ext==L".fx"&&std::filesystem::exists(dest,ec)){strcpy_s(feedback,"An FX file with this name is already installed. Keep it, or back it up and replace it in Shaders/Custom outside the game.");return false;}
  while(std::filesystem::exists(dest,ec)&&!ec&&suffix<10000)dest=folder/(source.stem().wstring()+L" ("+std::to_wstring(suffix++)+L")"+ext);
  auto encoded=BrowserText(dest);if(ec||encoded.size()>=sizeof(osfx::Command{}.path)){strcpy_s(feedback,"Choose a shorter file name or another folder.");return false;}
  if(!std::filesystem::copy_file(source,dest,std::filesystem::copy_options::none,ec)){strcpy_s(feedback,"Could not copy this file. Existing presets were kept.");return false;}
 }
 auto encoded=BrowserText(dest);if(encoded.size()>=1024){strcpy_s(feedback,"This path is too long.");return false;}
 osfx::Command c{};c.kind=ext==L".ini"?osfx::Preset:osfx::Reload;strcpy_s(c.path,encoded.c_str());bool queued=Send(c);if(ext==L".fx")importedShader=true;return queued;
}
static void DrawPresetBrowser(const std::filesystem::path& root){
 static char folderText[1024]="",filter[128]="";
 static std::filesystem::path folder,selected;
 static std::vector<std::filesystem::path> entries;
 static bool refresh=false,shaders=false;static std::string issue;
 bool openIni=ImGui::Button("Import INI...");ImGui::SameLine();bool openFx=ImGui::Button("Install FX...");
 if(openIni||openFx){
  shaders=openFx;
  wchar_t home[32768]{};GetEnvironmentVariableW(L"USERPROFILE",home,32768);folder=std::filesystem::path(home)/L"Downloads";
  std::error_code ec;if(!std::filesystem::is_directory(folder,ec))folder=root/L"Presets";
  refresh=true;selected.clear();filter[0]=0;ImGui::OpenPopup("Browse files to install");
 }
 ImGui::SetNextWindowSize(ImVec2(700,540),ImGuiCond_Appearing);
 if(ImGui::BeginPopupModal("Browse files to install",nullptr,ImGuiWindowFlags_NoCollapse)){
  ImGui::TextWrapped(shaders?"Install an FX shader: copy it into Shaders/Custom, then recompile installed effects. Enable it in the effect list when ready.":"Import an INI look: copy it into Presets and load it. Required shaders must already be installed. The original file is kept.");
  auto go=[&](const std::filesystem::path& path){std::error_code ec;if(!path.is_absolute()||!std::filesystem::is_directory(path,ec)){issue="Enter an existing full folder path, for example D:\\My presets.";return;}folder=path;refresh=true;selected.clear();};
  if(ImGui::Button("Downloads")){wchar_t home[32768]{};GetEnvironmentVariableW(L"USERPROFILE",home,32768);go(std::filesystem::path(home)/L"Downloads");}
  ImGui::SameLine();if(ImGui::Button("Desktop")){wchar_t home[32768]{};GetEnvironmentVariableW(L"USERPROFILE",home,32768);go(std::filesystem::path(home)/L"Desktop");}
  ImGui::SameLine();if(ImGui::Button("Documents")){wchar_t home[32768]{};GetEnvironmentVariableW(L"USERPROFILE",home,32768);go(std::filesystem::path(home)/L"Documents");}
  ImGui::SameLine();if(ImGui::Button("Installed files"))go(root/(shaders?L"Shaders":L"Presets"));
  ImGui::SameLine();if(ImGui::Button("Up")&&folder.has_parent_path())go(folder.parent_path());
  ImGui::SameLine();if(ImGui::Button("Refresh"))refresh=true;
  ImGui::TextUnformatted("Drive:");ImGui::SameLine();
  DWORD drives=GetLogicalDrives();for(int n=0;n<26;n++)if(drives&(1u<<n)){char label[]={char('A'+n),':',0};if(ImGui::Button(label))go(std::filesystem::path(std::string(label)+"\\"));ImGui::SameLine();}ImGui::NewLine();
  if(refresh){
   entries.clear();issue.clear();auto text=BrowserText(folder);strncpy_s(folderText,text.c_str(),_TRUNCATE);
   std::error_code ec;for(std::filesystem::directory_iterator it(folder,ec),end;it!=end&&!ec;it.increment(ec)){
    auto ext=it->path().extension().wstring();for(auto& ch:ext)ch=(wchar_t)towlower(ch);
    std::error_code typeError;if(it->is_directory(typeError)||ext==(shaders?L".fx":L".ini"))entries.push_back(it->path());
    if(entries.size()>=3000){issue="This folder is very large. Open a smaller folder to see more files.";break;}
   }
   if(ec)issue="Could not read this folder. Check the location and access permissions.";
   std::sort(entries.begin(),entries.end());refresh=false;
  }
  ImGui::TextUnformatted("Folder path (paste a folder, then press Enter or Go)");
  ImGui::SetNextItemWidth(-80);bool enter=ImGui::InputText("##folder",folderText,sizeof(folderText),ImGuiInputTextFlags_EnterReturnsTrue);ImGui::SameLine();bool navigate=ImGui::Button("Go");if(enter||navigate)go(std::filesystem::u8path(folderText));
  ImGui::InputTextWithHint("##findpreset",shaders?"Find an FX file...":"Find an INI preset...",filter,sizeof(filter));
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
  ImGui::TextWrapped(shaders?"This installs one .fx file. Copy any supplied include files and textures with their original folder structure into OptiShadeData/Shaders/Custom and OptiShadeData/Textures. Existing FX files are not overwritten.":"Existing presets are kept; an imported duplicate gets a new name. This does not download missing effects.");
  ImGui::BeginDisabled(selected.empty()||fx.dirty||fx.loading);
  if(ImGui::Button(shaders?"Copy FX and recompile":"Copy INI and load look")){if(ImportLook(selected,root))ImGui::CloseCurrentPopup();}
  ImGui::EndDisabled();ImGui::SameLine();if(ImGui::Button("Cancel"))ImGui::CloseCurrentPopup();
  if(fx.dirty)ImGui::TextColored(ImVec4(1,.3f,.4f,1),"Save or revert your unsaved changes first.");
  if(feedback[0])ImGui::TextWrapped("%s",feedback);ImGui::EndPopup();
 }
}
