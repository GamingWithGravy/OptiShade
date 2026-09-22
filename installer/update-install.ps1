param([string]$Payload,[string]$Installer)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/ownership.ps1"
$store=Join-Path $env:LOCALAPPDATA 'OptiShade'
$records=@(Get-ChildItem -LiteralPath (Join-Path $store 'Games') -Filter manifest.json -Recurse -File -ErrorAction SilentlyContinue)
# Preflight every installation before changing any of them.
$targets=@()
foreach($record in $records){
 $m=Get-Content -LiteralPath $record.FullName -Raw|ConvertFrom-Json
 if($m.Status -ne 'Installed'){continue}
 if(-not(Test-Path -LiteralPath (Join-Path $m.Game 'FlightSimulator2024.exe'))){continue}
 AssertClosed $m.Game
 $proxy=@($m.Files|Where-Object SourcePath -eq 'winmm.dll'|Select-Object -First 1).Path
 if(-not $proxy){throw 'An installation has no recorded loader. Automatic update stopped.'}
 $conflicts=@(FindFusionConflicts $m.Game)
 foreach($c in $conflicts){$owned=@($m.Files|Where-Object {$_.Path -eq $c.Path -and ($_.Hash -eq $c.Hash -or ($_.Mutable -and $_.Path -match '\.(ini|log)$'))});if(-not $owned.Count){throw "An untracked or modified graphics loader was found in $($m.Game). Use setup to review conflicts."}}
 CleanModBackupReferences $m (Split-Path $record.FullName)
 foreach($f in $m.Files){if($f.Backup -and (HashFile (OwnedPath (Split-Path $record.FullName) $f.Backup)) -ne $f.PreviousHash){throw 'An original backup is missing. Automatic update stopped.'}}
 $targets+=@{Manifest=$m;Proxy=$proxy;Conflicts=$conflicts}
}
foreach($target in $targets){
 $m=$target.Manifest
 $mp=InstallFusion $m.Game $Payload $store $Installer $target.Proxy $target.Conflicts -ReplaceExisting $true -PreserveConfiguration $true
 $updated=Get-Content -LiteralPath $mp -Raw|ConvertFrom-Json
 foreach($key in @('LaunchExe','Downloads','OptionalDlss')){if($m.PSObject.Properties[$key]){$updated|Add-Member -NotePropertyName $key -NotePropertyValue $m.$key -Force}}
 WriteState $updated $mp
}
"Updated $($targets.Count) Microsoft Flight Simulator 2024 installation(s). Presets and configuration preserved."
