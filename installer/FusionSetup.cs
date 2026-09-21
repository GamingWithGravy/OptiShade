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
   var initial=InitialSessionState.CreateDefault();
   initial.ExecutionPolicy=Microsoft.PowerShell.ExecutionPolicy.Bypass;
   using(var runspace=RunspaceFactory.CreateRunspace(initial)) {
    runspace.ApartmentState=ApartmentState.STA;runspace.ThreadOptions=PSThreadOptions.UseCurrentThread;runspace.Open();
    using(var shell=PowerShell.Create()) {
     shell.Runspace=runspace;
     bool updating=args.Length>1 && args[1]=="--apply-update";
     shell.AddCommand(Path.Combine(root,updating?"update-install.ps1":"manager.ps1")).AddParameter("Payload",Path.Combine(root,"PayloadFusion")).AddParameter("Installer",args.Length>0?args[0]:Application.ExecutablePath);
     shell.Invoke();
     // Expected discovery misses can populate the error stream even when handled.
     // Only a failed invocation means setup or the unattended update failed.
     if(shell.InvocationStateInfo.State==PSInvocationState.Failed)throw new Exception(shell.InvocationStateInfo.Reason!=null?shell.InvocationStateInfo.Reason.Message:String.Join(Environment.NewLine,shell.Streams.Error));
    }
   }
  } catch(Exception e){if(args.Length>1 && args[1]=="--apply-update"){Directory.CreateDirectory(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiShade"));File.WriteAllText(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OptiShade","Update-error.txt"),e.Message);}else{MessageBox.Show(e.Message,"OptiShade setup",MessageBoxButtons.OK,MessageBoxIcon.Error);}Environment.ExitCode=1;}
 }
}
