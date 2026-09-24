// Run the same bounded importer as the launcher without blocking a Present.
static HANDLE zipProcess=nullptr;
static std::filesystem::path zipResult;
static std::filesystem::path dependencyPreset,dependencyRoot,loadAfterImport;
static std::vector<std::string> missingShaders;
static bool askDependencies=false,dependencyDiscardApproved=false;
static void PollZipImport(){
 if(!zipProcess||WaitForSingleObject(zipProcess,0)!=WAIT_OBJECT_0)return;
 DWORD code=1;GetExitCodeProcess(zipProcess,&code);CloseHandle(zipProcess);zipProcess=nullptr;
 std::ifstream file(zipResult,std::ios::binary);std::string result((std::istreambuf_iterator<char>(file)),{});file.close();
 std::error_code ec;std::filesystem::remove(zipResult,ec);
 if(code==0&&result.rfind("OK:",0)==0){osfx::Command c{};c.kind=osfx::Reload;bool queued=Send(c);importedShader=true;
  if(queued){
   if(!loadAfterImport.empty()){osfx::Command preset{};preset.kind=osfx::Preset;auto text=loadAfterImport.u8string();strncpy_s(preset.path,(const char*)text.c_str(),_TRUNCATE);Send(preset);}
   strncpy_s(feedback,result.c_str(),_TRUNCATE);
  }
  else strcpy_s(feedback,"ZIP installed in OptiShadeData. Recompile installed FX when effects are ready, then choose the imported Saved look.");
 }else strncpy_s(feedback,result.empty()?"Import could not complete. Check folder permissions and PowerShell availability, then retry. Existing files were kept.":result.c_str(),_TRUNCATE);
 loadAfterImport.clear();
}
static bool StartZipImport(const std::filesystem::path& archive,const std::filesystem::path& root,bool dependencies=false,bool discardApproved=false){
 if(zipProcess||(fx.dirty&&!discardApproved)||fx.loading){strcpy_s(feedback,"Wait for the current operation and save or revert your look before importing.");return false;}
 std::error_code ec;auto worker=root/L"Tools/import-effects.ps1";
 if(!std::filesystem::is_regular_file(worker,ec)){strcpy_s(feedback,"ZIP helper is missing. Close MSFS and Repair with the 0.20.9 manager.");return false;}
 if(!std::filesystem::is_regular_file(archive,ec)){strcpy_s(feedback,"Choose an existing ZIP file.");return false;}
 wchar_t system[MAX_PATH]{};GetSystemDirectoryW(system,MAX_PATH);
 auto exe=std::filesystem::path(system)/L"WindowsPowerShell/v1.0/powershell.exe";
 auto leaf=L"Import-result-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64())+L".txt";
 zipResult=root/leaf;
 auto quote=[](const std::filesystem::path& p){return L"\""+p.wstring()+L"\"";};
 // -File arguments are literal data, never an interpolated PowerShell command.
 std::wstring args=quote(exe)+L" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "+quote(worker)+(dependencies?L" -Preset ":L" -Archive ")+quote(archive)+L" -Game "+quote(root.parent_path())+L" -Result \""+leaf+L"\"";
 STARTUPINFOW si{};si.cb=sizeof(si);PROCESS_INFORMATION pi{};
 if(!CreateProcessW(exe.c_str(),args.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&si,&pi)){strcpy_s(feedback,"Could not start ZIP import. Use the launcher ZIP importer or check PowerShell permissions.");return false;}
 CloseHandle(pi.hThread);zipProcess=pi.hProcess;
 if(dependencies)loadAfterImport=archive;
 strcpy_s(feedback,dependencies?"Downloading missing FX from the catalogue. The current look stays active until installation succeeds...":"Extracting ZIP in the background. Existing files and your current look are kept...");return true;
}
static bool RequestPresetLoad(const std::filesystem::path& preset,const std::filesystem::path& root,bool discardApproved=false){
 std::error_code ec;
 if(std::filesystem::file_size(preset,ec)>4*1024*1024||ec){strcpy_s(feedback,"Could not read preset, or preset exceeds 4 MB.");return false;}
 std::ifstream input(preset,std::ios::binary);std::string text((std::istreambuf_iterator<char>(input)),{});
 std::set<std::string> installed,required;
 auto lower=[](std::string s){for(auto& c:s)c=(char)tolower((unsigned char)c);return s;};
 for(std::filesystem::recursive_directory_iterator it(root/L"Shaders",ec),end;it!=end&&!ec;it.increment(ec))if(it->is_regular_file(ec))installed.insert(lower(it->path().filename().string()));
 // Only explicit shader filenames can be mapped reliably. Never infer a package from a technique name.
 const std::regex shader("(?:@|\\[)([^@,;\\[\\]\\r\\n/\\\\]+\\.fx)(?=,|\\]|\\s*(?:\\r?\\n|$))",std::regex::icase);
 for(std::sregex_iterator it(text.begin(),text.end(),shader),end;it!=end;++it)required.insert((*it)[1].str());
 missingShaders.clear();for(const auto& name:required)if(!installed.count(lower(name)))missingShaders.push_back(name);
 if(!missingShaders.empty()){dependencyPreset=preset;dependencyRoot=root;dependencyDiscardApproved=discardApproved;askDependencies=true;return true;}
 osfx::Command c{};c.kind=osfx::Preset;auto path=preset.u8string();strncpy_s(c.path,(const char*)path.c_str(),_TRUNCATE);return Send(c);
}
static void DrawDependencyPrompt(){
 if(askDependencies){ImGui::OpenPopup("Missing FX files");askDependencies=false;}
 const auto area=ImGui::GetMainViewport()->WorkSize;
 ImGui::SetNextWindowSize(ImVec2((std::min)(700.f,area.x-24),(std::min)(450.f,area.y-24)),ImGuiCond_Appearing);
 if(ImGui::BeginPopupModal("Missing FX files",nullptr,ImGuiWindowFlags_NoCollapse)){
  ImGui::TextWrapped("This INI has missing FX files. Would you like to install and load them now?");
  ImGui::BeginChild("Missing shader list",ImVec2(0,100),true);
  for(const auto& name:missingShaders)ImGui::BulletText("%s",name.c_str());
  ImGui::EndChild();
  ImGui::TextWrapped("OptiShade will download matching packages from its catalogue, install the required FX with includes and textures, then load this look. Existing files are kept. Unknown or ambiguous shaders need the author's ZIP. Compilation and depth-dependent effects can still require adjustment.");
  if(ImGui::Button("Install missing FX and load INI")){if(StartZipImport(dependencyPreset,dependencyRoot,true,dependencyDiscardApproved))ImGui::CloseCurrentPopup();}
  if(ImGui::Button("Keep current look"))ImGui::CloseCurrentPopup();
  if(feedback[0])ImGui::TextWrapped("%s",feedback);
  ImGui::EndPopup();
 }
}
