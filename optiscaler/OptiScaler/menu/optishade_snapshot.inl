// OptiShade additions, GPL-3.0-or-later.
static void DrawSnapshotKeybind();
static uint64_t snapshotSeen=0;
static bool snapshotWaiting=false;
static ULONGLONG snapshotDeadline=0;
static bool SnapshotConflict(int key){
 return key>0&&(SwapKeyConflict(key)||key==Config::Instance()->PresetHotSwapKey.value_or_default());
}
static void SnapshotNotice(bool ok,const char* message){
 ImGuiToast toast{ok?ImGuiToastType::Info:ImGuiToastType::Error,4000};
 toast.setTitle(ok?"SnapShot saved":"SnapShot not saved");toast.setContent("%s",message);ImGui::InsertNotification(toast);
}
static void PollSnapshot(bool pressed,bool allowed){
 auto module=GetModuleHandleW(L"ReShade64.dll");auto read=module?(osfx::Read)GetProcAddress(module,"OptiShadeEffectsRead"):nullptr;
 static osfx::Snapshot status{};
 if(snapshotWaiting){
  if(read&&read(&status,sizeof(status))&&status.snapshotSerial!=snapshotSeen){
   snapshotSeen=status.snapshotSerial;snapshotWaiting=false;SnapshotNotice(status.snapshotOK!=0,status.snapshotPath);
  }else if(GetTickCount64()>snapshotDeadline){snapshotWaiting=false;SnapshotNotice(false,"Capture timed out. Check the effects log before trying again.");}
 }
 if(!pressed||!allowed||snapshotWaiting)return;
 if(!read||!read(&fx,sizeof(fx))){SnapshotNotice(false,"Image effects capture is not connected yet.");return;}
 osfx::Command c{};c.kind=osfx::TakeSnapshot;
 snapshotSeen=fx.snapshotSerial;
 if(Send(c)){snapshotWaiting=true;snapshotDeadline=GetTickCount64()+60000;}
 else SnapshotNotice(false,"The capture request could not be sent.");
}
