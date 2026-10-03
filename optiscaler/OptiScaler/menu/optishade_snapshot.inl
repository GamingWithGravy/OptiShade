// OptiShade additions, GPL-3.0-or-later.
static void DrawSnapshotKeybind();
static uint64_t snapshotRequestId=0;
static bool snapshotWaiting=false;
static bool SnapshotConflict(int key){
 return key>0&&(SwapKeyConflict(key)||key==Config::Instance()->PresetHotSwapKey.value_or_default());
}
static void SnapshotNotice(bool ok,const char* message){
 ImGuiToast toast{ok?ImGuiToastType::Info:ImGuiToastType::Error,4000};
 toast.setTitle(ok?"SnapShot saved":"SnapShot not saved");toast.setContent("%s",message);ImGui::InsertNotification(toast);
}
static void PollSnapshot(bool pressed,bool allowed){
 auto module=GetModuleHandleW(L"ReShade64.dll");
 auto read=module?(optishade::capture::Read)GetProcAddress(module,"OptiShadeSnapshotRead"):nullptr;
 auto request=module?(optishade::capture::Request)GetProcAddress(module,"OptiShadeSnapshotRequest"):nullptr;
 optishade::capture::Status status{};
 if(snapshotWaiting){
  if(!read){snapshotWaiting=false;SnapshotNotice(false,"The capture runtime disconnected.");}
  else if(read(&status,sizeof(status))&&status.request==snapshotRequestId&&optishade::capture::Lifecycle::terminal(status.stage)){
   snapshotWaiting=false;
   const char* message=status.detail;
   if(status.stage==optishade::capture::Stage::TimedOut)message="Capture timed out and was cancelled. No late picture will be saved.";
   else if(status.stage==optishade::capture::Stage::Cancelled)message="Capture cancelled because the game view changed.";
   SnapshotNotice(status.stage==optishade::capture::Stage::Saved,message);
  }
 }
 if(!pressed||!allowed||snapshotWaiting)return;
 snapshotRequestId=request?request():0;
 if(snapshotRequestId)snapshotWaiting=true;
 else SnapshotNotice(false,"Capture is busy or the game view is not ready yet.");
}
