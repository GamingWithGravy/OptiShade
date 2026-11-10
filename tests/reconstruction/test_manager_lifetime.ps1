param([string]$Root=(Join-Path $PSScriptRoot '../..'))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,WindowsBase,System.Windows.Forms
$helper=[IO.Path]::GetFullPath((Join-Path $Root 'Beta/installer/manager-lifetime.ps1'))
function Check($Value,[string]$Message){if(-not $Value){throw $Message};Write-Output ('PASS: '+$Message)}
Add-Type -ReferencedAssemblies @([PowerShell].Assembly.Location,[Windows.Threading.Dispatcher].Assembly.Location) -TypeDefinition @'
using System;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Threading;
public static class OptiShadeManagerLifetimeFixture {
 public static string Run(string helper) {
  var previous=Runspace.DefaultRunspace;
  string error="";
  using(var runspace=RunspaceFactory.CreateRunspace()) {
   runspace.ApartmentState=ApartmentState.STA;runspace.ThreadOptions=PSThreadOptions.UseCurrentThread;runspace.Open();Runspace.DefaultRunspace=runspace;
   try {
    using(var shell=PowerShell.Create()) {
     shell.Runspace=runspace;
     shell.AddScript(@"param($helper)
. $helper
InitializeOptiShadeManagerLifetime
try {
 $timer=[Windows.Threading.DispatcherTimer]::new()
 $timer.Interval=[TimeSpan]::FromMilliseconds(1)
 RegisterOptiShadeManagerTimer $timer { throw 'orphan timer callback ran' }
 $timer.Start()
 $worker=NewOptiShadeManagerWorker
 [void]$worker.AddScript('Start-Sleep -Seconds 60')
 $null=$worker.BeginInvoke()
 throw 'original-manager-fixture-failure'
} finally { StopOptiShadeManagerLifetime }").AddArgument(helper);
     try { shell.Invoke(); } catch(Exception e) { error=e.Message; }
     if(shell.InvocationStateInfo.Reason!=null)error=shell.InvocationStateInfo.Reason.Message;
    }
   } finally {Runspace.DefaultRunspace=previous;}
  }
  // Reproduce the native host's error-dialog dispatcher pumping after its
  // PowerShell runspace has already been disposed, without opening a window.
  var frame=new DispatcherFrame();var stop=new DispatcherTimer();
  stop.Interval=TimeSpan.FromMilliseconds(80);
  EventHandler stopHandler=null;stopHandler=delegate(object sender,EventArgs e){stop.Stop();stop.Tick-=stopHandler;frame.Continue=false;};
  stop.Tick+=stopHandler;stop.Start();Dispatcher.PushFrame(frame);
  return error;
 }
}
'@
$watch=[Diagnostics.Stopwatch]::StartNew()
$failure=[OptiShadeManagerLifetimeFixture]::Run($helper)
Check ($failure -match 'original-manager-fixture-failure') 'original failure survives runspace disposal and subsequent dispatcher pumping; no orphan callback crash'
Check ($watch.Elapsed.TotalSeconds -lt 10) 'manager teardown does not block on a running background scan'
. $helper
InitializeOptiShadeManagerLifetime
$timer=[Windows.Threading.DispatcherTimer]::new();RegisterOptiShadeManagerTimer $timer {}
Check ($script:managerTimers.Count -eq 1) 'timer delegate registered for lifetime cleanup'
UnregisterOptiShadeManagerTimer $timer
Check ($script:managerTimers.Count -eq 0) 'completed polling timer releases its delegate rather than accumulating'
StopOptiShadeManagerLifetime;StopOptiShadeManagerLifetime
Check ($script:managerTimers.Count -eq 0 -and $script:managerWorkers.Count -eq 0) 'cleanup is idempotent'
$manager=[IO.File]::ReadAllText((Join-Path $Root 'Beta/installer/manager.ps1'))
Check ($manager -match '(?s)InitializeOptiShadeManagerLifetime\s+try\{' -and $manager -match '(?s)\[void\]\$form\.ShowDialog\(\)\s*\}finally\{.*StopOptiShadeManagerLifetime.*AntiCheatSessionAccepted.*\}\s*$') 'full manager initialization, ShowDialog and startup-consent cleanup are within the outer cleanup boundary'
Check ($manager -notmatch '\.Add_Tick\(') 'every manager DispatcherTimer is registered for teardown'
# Compile the actual native host source and exercise preserved script diagnostics
# without invoking Main or showing a MessageBox.
$hostSource=[IO.File]::ReadAllText((Join-Path $Root 'Beta/installer/FusionSetup.cs'))
Add-Type -TypeDefinition $hostSource -ReferencedAssemblies @([PowerShell].Assembly.Location,[Windows.Forms.Form].Assembly.Location)
$shell=[PowerShell]::Create()
try{
 $null=$shell.AddScript("throw 'original-host-fixture-error'")
 try{$null=$shell.Invoke()}catch{}
 $flags=[Reflection.BindingFlags]'Static,NonPublic'
 $hostType=@([AppDomain]::CurrentDomain.GetAssemblies()|ForEach-Object {$_.GetType('FusionSetup',$false)}|Where-Object {$_})[0]
 $detail=$hostType.GetMethod('DescribeFailure',$flags).Invoke($null,@($shell,$shell.InvocationStateInfo.Reason))
 Check ($detail -match 'original-host-fixture-error' -and $detail -match '<ScriptBlock>') 'host preserves original PowerShell error and script stack before disposing its runspace'
}finally{$shell.Dispose()}
