# Dispatcher callbacks must be detached before the hosting runspace is disposed,
# including when startup or ShowDialog throws before the window raises Closed.
function InitializeOptiShadeManagerLifetime {
 $script:managerTimers=[Collections.Generic.List[object]]::new()
 $script:managerWorkers=[Collections.Generic.List[object]]::new()
 if(-not ('OptiShadeManagerWorkerCleanup' -as [type])){
  Add-Type -ReferencedAssemblies ([PowerShell].Assembly.Location) -TypeDefinition @'
using System;
using System.Management.Automation;
using System.Threading;
public static class OptiShadeManagerWorkerCleanup {
 public static void Release(PowerShell worker) {
  if(worker==null) return;
  // No PowerShell delegate is queued on a thread without a runspace.
  ThreadPool.QueueUserWorkItem(delegate(object unused) {
   try { worker.Stop(); } catch { }
   try { worker.Dispose(); } catch { }
  });
 }
}
'@
 }
}
function RegisterOptiShadeManagerTimer($Timer,[scriptblock]$Handler){
 $callback=[EventHandler]$Handler
 $script:managerTimers.Add([pscustomobject]@{Timer=$Timer;Handler=$callback})
 $Timer.Add_Tick($callback)
}
function UnregisterOptiShadeManagerTimer($Timer){
 foreach($entry in @($script:managerTimers.ToArray())){
  if([object]::ReferenceEquals($entry.Timer,$Timer)){
   $entry.Timer.Stop();$entry.Timer.Remove_Tick($entry.Handler)
   [void]$script:managerTimers.Remove($entry)
  }
 }
}
function NewOptiShadeManagerWorker {
 $worker=[PowerShell]::Create();$script:managerWorkers.Add($worker);return $worker
}
function RemoveOptiShadeManagerWorker($Worker){
 if($Worker){[void]$script:managerWorkers.Remove($Worker);$Worker.Dispose()}
}
function StopOptiShadeManagerLifetime {
 # Stop/remove all callbacks first. Cleanup must not replace the original error.
 foreach($entry in @($script:managerTimers.ToArray())){
  try{$entry.Timer.Stop();$entry.Timer.Remove_Tick($entry.Handler)}catch{}
 }
 $script:managerTimers.Clear()
 foreach($worker in @($script:managerWorkers.ToArray())){[OptiShadeManagerWorkerCleanup]::Release($worker)}
 $script:managerWorkers.Clear()
}
function InvokeOptiShadePlayPreparation([scriptblock]$Preparation,[scriptblock]$Log={}){
 try{
  & $Preparation
  return [pscustomobject]@{Succeeded=$true;Error=''}
 }catch{
  $message=[string]$_.Exception.Message
  try{if($Log){& $Log $message}}catch{}
  return [pscustomobject]@{Succeeded=$false;Error=$message}
 }
}
