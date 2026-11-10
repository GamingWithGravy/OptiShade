// Copyright (c) 2026 gravy / GamingWithGravy. All Rights Reserved.
// OptiShade Proprietary Material: standalone manager host source only.
// See LICENSES/OPTISHADE-PROPRIETARY.txt and OPTISHADE_LICENSING.md.
// Hosted scripts and third-party components retain their own licences.
// Earlier GPL grants and applicable platform permissions remain intact.
// No further copying, modification, redistribution or incorporation into
// another project is permitted except under the applicable licence or law.
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;
class FusionSetup {
 static void AppendErrorRecord(System.Text.StringBuilder detail,ErrorRecord record) {
  if(record==null)return;
  detail.AppendLine().AppendLine(record.ToString());
  if(record.InvocationInfo!=null)detail.AppendLine(record.InvocationInfo.PositionMessage);
  detail.AppendLine(record.ScriptStackTrace);
 }
 static string DescribeFailure(PowerShell shell,Exception error) {
  var detail=new System.Text.StringBuilder(error==null?"OptiShade manager failed.":error.ToString());
  // Capture while the original runspace/error records still exist. A later
  // error-dialog message pump must not replace the originating failure.
  var runtimeError=error as RuntimeException;
  if(runtimeError!=null)AppendErrorRecord(detail,runtimeError.ErrorRecord);
  foreach(var record in shell.Streams.Error)AppendErrorRecord(detail,record);
  return detail.ToString();
 }
 static void SaveFailure(string name,Exception error) {
  try {
   string store=Environment.GetEnvironmentVariable("OPTISHADE_STORE")??Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA")??Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiShade");
   Directory.CreateDirectory(store);File.WriteAllText(Path.Combine(store,name),DateTime.UtcNow.ToString("o")+Environment.NewLine+error.ToString());
  }catch { /* Error reporting must preserve the original failure. */ }
 }
 [STAThread] static void Main(string[] args) {
  try {
   // Hosted Windows PowerShell inherits this process's .NET path policy.
   // Set before any Path/File calls; do not change machine-wide registry policy.
   AppContext.SetSwitch("Switch.System.IO.UseLegacyPathHandling", false);
   AppContext.SetSwitch("Switch.System.IO.BlockLongPaths", false);
   string root=AppDomain.CurrentDomain.BaseDirectory;
   // A parent running PowerShell 7 can omit Windows PowerShell's built-in
   // module path. This host uses Windows PowerShell 5.1 and needs its modules.
   string modules=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell","v1.0","Modules");
   string modulePath=Environment.GetEnvironmentVariable("PSModulePath")??"";
   Environment.SetEnvironmentVariable("PSModulePath",modules+Path.PathSeparator+modulePath);
   var initial=InitialSessionState.CreateDefault();
   initial.ExecutionPolicy=Microsoft.PowerShell.ExecutionPolicy.Bypass;
   using(var runspace=RunspaceFactory.CreateRunspace(initial)) {
    runspace.ApartmentState=ApartmentState.STA;runspace.ThreadOptions=PSThreadOptions.UseCurrentThread;runspace.Open();
    var previousDefault=Runspace.DefaultRunspace;
    Runspace.DefaultRunspace=runspace;
    try {
    using(var shell=PowerShell.Create()) {
     shell.Runspace=runspace;
     bool updating=args.Length>1 && (args[1]=="--apply-update" || args[1]=="--check-update");
     bool worker=args.Length>1 && args[0]=="--update-worker";
     bool operationProgress=args.Length>2 && args[1]=="--operation-progress";
     bool installerUi=args.Length>1 && args[0]=="--installer-ui";
     if(installerUi) shell.AddCommand(Path.Combine(root,"installer-ui.ps1")).AddParameter("Config",args[1]);
     else if(args.Length>1 && args[0]=="--diagnostic-worker") shell.AddCommand(Path.Combine(root,"diagnostic-worker.ps1")).AddParameter("Request",args[1]);
     else if(worker) shell.AddCommand(Path.Combine(root,"update-worker.ps1")).AddParameter("Config",args[1]);
     else if(operationProgress) shell.AddCommand(Path.Combine(root,"operation-progress.ps1")).AddParameter("Config",args[2]);
     else {
      shell.AddCommand(Path.Combine(root,updating?"update-install.ps1":"manager.ps1"))
       .AddParameter("Payload",Path.Combine(root,"PayloadFusion"))
       .AddParameter("Installer",args.Length>0?args[0]:Application.ExecutablePath);
      if(!updating)shell.AddParameter("UninstallMode",args.Length>1 && args[1]=="--uninstall-app");
     }
     if(!updating && !worker && !operationProgress && !installerUi && args.Length>1 && args[1]=="--tray")shell.AddParameter("StartInTray",true);
     if(updating && args[1]=="--check-update")shell.AddParameter("ValidateOnly",true);
     try { shell.Invoke(); }
     catch(Exception error) { throw new Exception(DescribeFailure(shell,error),error); }
     // Expected discovery misses can populate the error stream even when handled.
     // Only a failed invocation means setup or the unattended update failed.
     if(shell.InvocationStateInfo.State==PSInvocationState.Failed)throw new Exception(DescribeFailure(shell,shell.InvocationStateInfo.Reason));
    }
    } finally { Runspace.DefaultRunspace=previousDefault; }
   }
  } catch(Exception e){if(args.Length>1 && (args[0]=="--diagnostic-worker" || args[0]=="--installer-ui")){Environment.ExitCode=1;return;}if(args.Length>1 && args[1]=="--operation-progress"){Environment.ExitCode=1;return;}if(args.Length>1 && (args[1]=="--apply-update" || args[1]=="--check-update")){SaveFailure("Update-error.txt",e);}else{SaveFailure("Manager-error.txt",e);MessageBox.Show(e.Message,"OptiShade setup",MessageBoxButtons.OK,MessageBoxIcon.Error);}Environment.ExitCode=1;}
 }
}
