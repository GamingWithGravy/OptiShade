param([string]$Payload,[string]$Installer,[switch]$ValidateOnly)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/ownership.ps1"
# Check every extracted payload file before changing any installation.
$catalog=ReadOptiShadeJson (Join-Path $Payload 'files.json') 'Payload catalogue JSON' -Shape Array
if(-not $catalog.Count){throw 'The staged installer has an empty payload catalogue.'}
foreach($entry in $catalog){if((HashFile (OwnedPath $Payload $entry.Path)) -ne $entry.Hash){throw "Staged payload is missing or damaged: $($entry.Path)"}}
$store=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
$records=@();$recordRoot=Join-Path $store 'Games'
if(Test-Path -LiteralPath $recordRoot){$records=@(Get-ChildItem -LiteralPath $recordRoot -Filter manifest.json -Recurse -File -ErrorAction Stop)}
# Preflight every installation before changing any of them.
$targets=@()
$diskNeeded=@{}
$payloadBytes=0L;foreach($entry in $catalog){$payloadBytes+=(Get-Item -LiteralPath (OwnedPath $Payload $entry.Path)).Length}
foreach($record in $records){
 $m=ReadOptiShadeState $record.FullName
 if($m.Status -ne 'Installed'){continue}
 if(-not(Test-Path -LiteralPath (Join-Path $m.Game 'X-Plane.exe')) -and -not(Test-Path -LiteralPath (Join-Path $m.Game 'FlightSimulator2024.exe')) -and -not(Test-Path -LiteralPath (Join-Path $m.Game 'FlightSimulator.exe'))){throw "Recorded game is unavailable or unsupported: $($m.Game). Reconnect it or review its installation record before updating. No game files were changed."}
 AssertClosed $m.Game
 $drive=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($m.Game));$diskNeeded[$drive]+=2*$payloadBytes+64MB
 $proxy=@($m.Files|Where-Object SourcePath -eq 'winmm.dll'|Select-Object -First 1).Path
 if(-not $proxy){throw 'An installation has no recorded loader. Automatic update stopped.'}
 $conflicts=@(GetFusionUpdateConflicts $m)
 if($m.OptionalMfg){
  $provider=@($catalog|Where-Object Path -match '^OptiShadeData[\\/]MFG[\\/]RTXMFG\.dll$')
  $owned=@($m.Files|Where-Object Path -eq 'version.dll')
  if($provider.Count -ne 1 -or $owned.Count -ne 1 -or $owned[0].Mutable -or $owned[0].SourcePath -eq 'winmm.dll'){throw 'Recorded MFG provider needs review before updating any installation.'}
 }
 CleanModBackupReferences $m (Split-Path $record.FullName)
 foreach($f in $m.Files){if($f.Backup -and (HashFile (OwnedPath (Split-Path $record.FullName) $f.Backup)) -ne $f.PreviousHash){throw 'An original backup is missing. Automatic update stopped.'}}
 $targets+=@{Manifest=$m;Proxy=$proxy;Conflicts=$conflicts}
}
foreach($drive in $diskNeeded.Keys){if(([IO.DriveInfo]::new($drive)).AvailableFreeSpace -lt $diskNeeded[$drive]){throw "Not enough disk space on $drive for the game update and rollback files. Free $([math]::Ceiling($diskNeeded[$drive]/1MB)) MB and retry. No game files were changed."}}
if($ValidateOnly){"Validated $($catalog.Count) payload files and $($targets.Count) recorded installation(s).";return}
foreach($target in $targets){
 $m=$target.Manifest
 $mp=InstallFusion $m.Game $Payload $store $Installer $target.Proxy $target.Conflicts -ReplaceExisting $true -PreserveConfiguration $true
 $updated=ReadOptiShadeState $mp
 foreach($key in @('LaunchExe','Downloads','OptionalDlss','FxPresetRelative')){if($m.PSObject.Properties[$key]){$updated|Add-Member -NotePropertyName $key -NotePropertyValue $m.$key -Force}}
 WriteState $updated $mp
}
"Updated $($targets.Count) supported game installation(s). Presets and configuration preserved."
