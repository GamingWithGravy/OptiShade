namespace OptiShadeNeuralDependencies {
struct Status {
 HANDLE process=nullptr;
 bool started=false,ready=false;
 ULONGLONG nextPoll=0;
 FILETIME began{};
 std::string message="Checking the GPU-matched neural model...";
 ~Status(){if(process)CloseHandle(process);}
};
static std::wstring Quote(const std::wstring& value){
 std::wstring out=L"\"";unsigned slash=0;
 for(auto c:value){if(c==L'\\'){++slash;continue;}out.append(c==L'\"'?slash*2+1:slash,L'\\');slash=0;out+=c;}
 out.append(slash*2,L'\\');return out+L'\"';
}
static Status& Poll(const std::string& gpu){
 auto& s=optishade::route::Owned<Status,20>();
 const auto root=Util::DllPath().parent_path();
 if(!s.started&&!gpu.empty()){
  s.started=true;GetSystemTimeAsFileTime(&s.began);
  auto script=root/L"OptiShadeData/Tools/neural-dependency.ps1";
  std::error_code ec;
  if(!std::filesystem::is_regular_file(script,ec)){s.message="Close the simulator and Repair OptiShade in the manager to restore the dependency helper.";return s;}
  const int length=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,gpu.data(),(int)gpu.size(),nullptr,0);
  std::wstring name(length,L'\0');if(length)MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,gpu.data(),(int)gpu.size(),name.data(),length);
  wchar_t system[MAX_PATH]{};GetSystemDirectoryW(system,MAX_PATH);
  auto exe=std::filesystem::path(system)/L"WindowsPowerShell/v1.0/powershell.exe";
  auto args=Quote(exe.wstring())+L" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "+Quote(script.wstring())+L" -Game "+Quote(root.wstring())+L" -GpuName "+Quote(name)+L" -ParentProcessId "+std::to_wstring(GetCurrentProcessId());
  STARTUPINFOW si{};si.cb=sizeof(si);PROCESS_INFORMATION pi{};
  if(!CreateProcessW(exe.c_str(),args.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,root.c_str(),&si,&pi)){s.message="Dependency helper could not start. Repair OptiShade in the manager and check application restrictions.";return s;}
  CloseHandle(pi.hThread);s.process=pi.hProcess;
 }
 const auto now=GetTickCount64();if(now<s.nextPoll)return s;s.nextPoll=now+1000;
 auto file=root/L"OptiShadeData/Neural-dependency-status.txt";WIN32_FILE_ATTRIBUTE_DATA info{};
 if(GetFileAttributesExW(file.c_str(),GetFileExInfoStandard,&info)&&!(info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)&&info.nFileSizeHigh==0&&info.nFileSizeLow<8192&&CompareFileTime(&info.ftLastWriteTime,&s.began)>=0){
  std::ifstream input(file,std::ios::binary);std::string state,message;std::getline(input,state);std::getline(input,message);
  if(!message.empty()){s.ready=state=="ready";s.message=message;}
 }
 if(s.process&&WaitForSingleObject(s.process,0)==WAIT_OBJECT_0){
  DWORD code=1;GetExitCodeProcess(s.process,&code);CloseHandle(s.process);s.process=nullptr;
  if(code!=0)s.message="Dependency helper failed. Open the manager and retry model preparation.";
 }
 return s;
}
}
