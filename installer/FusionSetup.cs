using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;
class FusionSetup {
 [STAThread] static void Main(string[] args) {
  try {
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
    using(var shell=PowerShell.Create()) {
     shell.Runspace=runspace;
     bool updating=args.Length>1 && (args[1]=="--apply-update" || args[1]=="--check-update");
     bool worker=args.Length>1 && args[0]=="--update-worker";
     if(worker) shell.AddCommand(Path.Combine(root,"update-worker.ps1")).AddParameter("Config",args[1]);
     else shell.AddCommand(Path.Combine(root,updating?"update-install.ps1":"manager.ps1")).AddParameter("Payload",Path.Combine(root,"PayloadFusion")).AddParameter("Installer",args.Length>0?args[0]:Application.ExecutablePath);
     if(updating && args[1]=="--check-update")shell.AddParameter("ValidateOnly",true);
     shell.Invoke();
     // Expected discovery misses can populate the error stream even when handled.
     // Only a failed invocation means setup or the unattended update failed.
     if(shell.InvocationStateInfo.State==PSInvocationState.Failed)throw new Exception(shell.InvocationStateInfo.Reason!=null?shell.InvocationStateInfo.Reason.Message:String.Join(Environment.NewLine,shell.Streams.Error));
    }
   }
  } catch(Exception e){if(args.Length>1 && (args[1]=="--apply-update" || args[1]=="--check-update")){string store=Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA")??Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiShade");Directory.CreateDirectory(store);File.WriteAllText(Path.Combine(store,"Update-error.txt"),e.ToString());}else{MessageBox.Show(e.Message,"OptiShade setup",MessageBoxButtons.OK,MessageBoxIcon.Error);}Environment.ExitCode=1;}
 }
}
