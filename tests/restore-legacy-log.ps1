$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
function AssertClosed($Game){}
function SavePreRestoreEvidence($Game,$Folder){}
function Check($ok,$message){if(-not $ok){throw $message};"PASS: $message"}
$fixture=Join-Path $env:TEMP ('OptiShade-legacy-log-'+[guid]::NewGuid().ToString('N'))
function GetShaderRecoveryRoot { Join-Path $fixture 'Recovery' }
function MakeInstall([string]$name,[switch]$Original){
 $game=Join-Path $fixture $name;$payload=Join-Path $fixture ($name+'-Payload');$store=Join-Path $fixture 'Store'
 New-Item -ItemType Directory -Path $game,$payload -Force|Out-Null
 Set-Content "$payload/winmm.dll" 'owned loader fixture'
 Set-Content "$payload/ReShade.log" '12:00:00:001 [ 42] | INFO  | Initializing ReShade version fixture'
 if($Original){Set-Content "$game/ReShade.log" 'original pre-install log'}
 @(Get-ChildItem $payload -File|ForEach-Object {@{Path=$_.Name;Hash=(HashFile $_.FullName)}})|ConvertTo-Json|Set-Content "$payload/files.json"
 $mp=InstallFusion $game $payload $store "$fixture/Manager.exe"
 $m=Get-Content $mp -Raw|ConvertFrom-Json;$m.Version='P0.21.3'
 $entry=@($m.Files|Where-Object Path -eq 'ReShade.log')[0];$entry.Mutable=$false;WriteState $m $mp
 Add-Content "$game/ReShade.log" '12:00:01:001 [ 42] | INFO  | Runtime output changed normally'
 return @{Game=$game;Payload=$payload;Manifest=$mp;Record=$m}
}
function MustRefuse($case,[string]$message){
 $before=HashFile "$($case.Game)/winmm.dll";$log=HashFile "$($case.Game)/ReShade.log"
 $blocked=$false;try{RestoreFusion $case.Manifest}catch{$blocked=$true}
 Check $blocked $message
 Check ((HashFile "$($case.Game)/winmm.dll") -eq $before -and (HashFile "$($case.Game)/ReShade.log") -eq $log) 'Failed restore preflight keeps game bytes unchanged'
}
$case=MakeInstall 'Known' -Original;$changed=HashFile "$($case.Game)/ReShade.log"
$record=$case.Record;$entry=@($record.Files|Where-Object Path -eq 'ReShade.log')[0];$backup=OwnedPath (Split-Path $case.Manifest) $entry.Backup;$original=HashFile $backup
RestoreFusion $case.Manifest
$after=Get-Content $case.Manifest -Raw|ConvertFrom-Json
Check ($after.Status -eq 'Restored' -and (HashFile "$($case.Game)/ReShade.log") -eq $original) 'Known legacy log restores the verified original'
Check ((HashFile (Join-Path $after.RecoveredLogs 'ReShade.log')) -eq $changed -and (HashFile $backup) -eq $original) 'Complete current log and original backup are both preserved'
RestoreFusion $case.Manifest
Check ((HashFile (Join-Path $after.RecoveredLogs 'ReShade.log')) -eq $changed) 'Repeat restore retains recovery evidence'
$case=MakeInstall 'Displaced' -Original;$m=$case.Record;$log=@($m.Files|Where-Object Path -eq 'ReShade.log')[0];$log.Hash='';$log.SourcePath='';WriteState $m $case.Manifest
RestoreFusion $case.Manifest
Check ((Get-Content $case.Manifest -Raw|ConvertFrom-Json).Status -eq 'Restored') 'Verified displaced-root-log receipt is also recoverable'
$case=MakeInstall 'UnknownVersion';$case.Record.Version='foreign receipt';WriteState $case.Record $case.Manifest;MustRefuse $case 'Unknown receipt version remains a conflict'
$case=MakeInstall 'UnknownContents';Set-Content "$($case.Game)/ReShade.log" 'MZ arbitrary changed content';MustRefuse $case 'Unrecognisable changed log content remains a conflict'
$case=MakeInstall 'ChangedDll';Set-Content "$($case.Game)/winmm.dll" 'changed binary';MustRefuse $case 'Mutable log exception never relaxes DLL verification'
$case=MakeInstall 'FailedBackup' -Original;$entry=@($case.Record.Files|Where-Object Path -eq 'ReShade.log')[0];Set-Content (OwnedPath (Split-Path $case.Manifest) $entry.Backup) 'damaged';MustRefuse $case 'Failed original backup verification still blocks restore'
$case=MakeInstall 'UnknownShape';$entry=@($case.Record.Files|Where-Object Path -eq 'ReShade.log')[0];$entry.SourcePath='another.log';WriteState $case.Record $case.Manifest;MustRefuse $case 'Unknown log receipt shape remains a conflict'
$case=MakeInstall 'LinkedLog';$target=Join-Path $fixture 'Unrelated.log';Set-Content $target 'unrelated'
Remove-Item -LiteralPath "$($case.Game)/ReShade.log"
try{
 New-Item -ItemType SymbolicLink -Path "$($case.Game)/ReShade.log" -Target $target -ErrorAction Stop|Out-Null
 MustRefuse $case 'Linked root log remains blocked'
}catch{if($_.Exception.Message -match 'privilege|Administrator'){Write-Output 'SKIP: symlink creation unavailable'}else{throw}}
