$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'Beta/installer/operation-progress-store.ps1')
$folder=Join-Path $env:TEMP ('optishade-progress-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folder)
$path=Join-Path $folder 'operation.json'
try{
 WriteOptiShadeOperationProgressState $path @{Title='Test';Detail='Starting';Completed=0;Total=250;Status='Running'}
 $job=Start-Job -ArgumentList $PSScriptRoot,$path -ScriptBlock {
  param($testRoot,$statePath)
  $repo=Split-Path (Split-Path $testRoot -Parent) -Parent
  . (Join-Path $repo 'Beta/installer/operation-progress-store.ps1')
  for($i=1;$i -le 250;$i++){
   WriteOptiShadeOperationProgressState $statePath @{Title='Test';Detail="Step $i";Completed=$i;Total=250;Status='Running'}
   Start-Sleep -Milliseconds 2
  }
  WriteOptiShadeOperationProgressState $statePath @{Title='Test';Detail='Finished';Completed=250;Total=250;Status='Completed'}
 }
 $readFailures=0;$reads=0
 while($job.State -in @('NotStarted','Running')){
  try{
   $state=ReadOptiShadeOperationProgressState $path|ConvertFrom-Json
   if($state.Title -ne 'Test' -or $state.Status -notin @('Running','Completed') -or [int]$state.Completed -lt 0 -or [int]$state.Completed -gt 250){throw 'Progress state was partial or invalid.'}
   $reads++
  }catch{$readFailures++;Write-Output ("Read failure: "+$_.Exception.Message)}
  Start-Sleep -Milliseconds 2
 }
 $jobOutput=Receive-Job $job -ErrorAction Stop
 Remove-Job $job -Force
 if($job.State -ne 'Completed'){throw ('Concurrent progress writer failed: '+($jobOutput -join '; '))}
 $final=ReadOptiShadeOperationProgressState $path|ConvertFrom-Json
 if($final.Status -ne 'Completed' -or [int]$final.Completed -ne 250){throw 'Final operation state was not published.'}
 if($readFailures -ne 0){throw "Observed $readFailures partial or locked reads during $reads concurrent reads."}
 if(@(Get-ChildItem -LiteralPath $folder -Filter '*.tmp').Count){throw 'Progress writer left temporary files behind.'}
 Write-Output "Atomic progress state survived $reads concurrent reads with no sharing violations."
}finally{Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue}
