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
     shell.AddCommand(Path.Combine(root,"manager.ps1")).AddParameter("Payload",Path.Combine(root,"PayloadFusion")).AddParameter("Installer",args.Length>0?args[0]:Application.ExecutablePath);
     shell.Invoke();
     if(shell.HadErrors)throw new Exception(String.Join(Environment.NewLine,shell.Streams.Error));
    }
   }
  } catch(Exception e){MessageBox.Show(e.Message,"OptiShade setup",MessageBoxButtons.OK,MessageBoxIcon.Error);Environment.ExitCode=1;}
 }
}
