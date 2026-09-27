// Run the same bounded importer as the launcher without blocking a Present.
static HANDLE zipProcess=nullptr;
static std::filesystem::path zipResult;
static std::filesystem::path zipError;
static std::filesystem::path dependencyPreset,dependencyRoot,loadAfterImport;
static std::vector<std::string> missingShaders;
static bool askDependencies=false,dependencyDiscardApproved=false;
static void PollZipImport(){
 if(!zipProcess||WaitForSingleObject(zipProcess,0)!=WAIT_OBJECT_0)return;
 DWORD code=1;GetExitCodeProcess(zipProcess,&code);CloseHandle(zipProcess);zipProcess=nullptr;
 std::ifstream file(zipResult,std::ios::binary);std::string result((std::istreambuf_iterator<char>(file)),{});file.close();
 std::error_code ec;std::filesystem::remove(zipResult,ec);
 if(result.empty()){
  std::ifstream errors(zipError,std::ios::binary);char buffer[2049]{};errors.read(buffer,2048);result.assign(buffer,(size_t)errors.gcount());
  if(result.empty())result="Import helper exited without a result (exit code "+std::to_string(code)+"). Check folder access or PowerShell application restrictions. Current look unchanged.";
 }
 std::filesystem::remove(zipError,ec);
 if(code!=0 || result.rfind("OK:",0)!=0){std::ofstream diagnostic(zipResult.parent_path()/L"Import-last-error.txt",std::ios::binary|std::ios::trunc);diagnostic<<"Import worker exit code: "<<code<<"\n"<<result.substr(0,8192);}
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
 if(zipProcess||(dependencies&&fx.dirty&&!discardApproved)||fx.loading){strcpy_s(feedback,"Wait for the current operation and save or revert your look before importing.");return false;}
 std::error_code ec;auto worker=root/L"Tools/import-effects.ps1";
 if(!std::filesystem::is_regular_file(worker,ec)){strcpy_s(feedback,"Import helper is missing. Close the simulator and Repair with the manager matching your installed version.");return false;}
 if(!std::filesystem::is_regular_file(archive,ec)){strcpy_s(feedback,"Choose an existing ZIP file.");return false;}
 wchar_t system[MAX_PATH]{};GetSystemDirectoryW(system,MAX_PATH);
 auto exe=std::filesystem::path(system)/L"WindowsPowerShell/v1.0/powershell.exe";
 auto leaf=L"Import-result-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64())+L".txt";
 zipResult=root/leaf;
 auto quote=[](const std::filesystem::path& p){return L"\""+p.wstring()+L"\"";};
 // -File arguments are literal data, never an interpolated PowerShell command.
 std::wstring args=quote(exe)+L" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "+quote(worker)+(dependencies?L" -Preset ":L" -Archive ")+quote(archive)+L" -Game "+quote(root.parent_path())+L" -Result \""+leaf+L"\"";
 // Capture startup errors too: execution-policy/application-control failures happen before the script can write a result.
 wchar_t temp[MAX_PATH]{},log[MAX_PATH]{};
 if(!GetTempPathW(MAX_PATH,temp)||!GetTempFileNameW(temp,L"OSI",0,log)){strcpy_s(feedback,"Cannot create an import log in your Windows temporary folder. Check its write permissions.");return false;}
 zipError=log;
 SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES),nullptr,TRUE};
 HANDLE output=CreateFileW(log,GENERIC_WRITE,FILE_SHARE_READ,&security,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
 HANDLE input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&security,OPEN_EXISTING,0,nullptr);
 SIZE_T bytes=0;InitializeProcThreadAttributeList(nullptr,1,0,&bytes);
 std::vector<unsigned char> attributes(bytes);STARTUPINFOEXW si{};si.StartupInfo.cb=sizeof(si);
 si.lpAttributeList=reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
 const bool initialized=InitializeProcThreadAttributeList(si.lpAttributeList,1,0,&bytes)!=FALSE;
 HANDLE handles[]{output,input};
 bool ready=initialized&&output!=INVALID_HANDLE_VALUE&&input!=INVALID_HANDLE_VALUE&&UpdateProcThreadAttribute(si.lpAttributeList,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,handles,sizeof(handles),nullptr,nullptr);
 si.StartupInfo.dwFlags=STARTF_USESTDHANDLES;si.StartupInfo.hStdOutput=output;si.StartupInfo.hStdError=output;si.StartupInfo.hStdInput=input;
 PROCESS_INFORMATION pi{};
 bool started=ready&&CreateProcessW(exe.c_str(),args.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW|EXTENDED_STARTUPINFO_PRESENT,nullptr,nullptr,&si.StartupInfo,&pi);
 DWORD failure=GetLastError();
 if(initialized)DeleteProcThreadAttributeList(si.lpAttributeList);
 if(output!=INVALID_HANDLE_VALUE)CloseHandle(output);if(input!=INVALID_HANDLE_VALUE)CloseHandle(input);
 if(!started){std::filesystem::remove(zipError,ec);sprintf_s(feedback,"Import helper could not start (Windows error %lu). Current look unchanged. Check folder access or application-control restrictions.",failure);return false;}
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
