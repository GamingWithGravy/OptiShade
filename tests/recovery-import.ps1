$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/recovery.ps1"
function AssertClosed([string]$Game){}
function Assert($value,$text){if(-not $value){throw "FAIL: $text"};"PASS: $text"}
$fixture=Join-Path $env:TEMP ('OptiShade-recovery-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'Game';$store=Join-Path $fixture 'Store';$payload=Join-Path $fixture 'Payload'
New-Item -ItemType Directory -Path $game,$payload,(Join-Path $game 'OptiShadeData/Shaders') -Force|Out-Null
Set-Content (Join-Path $game 'FlightSimulator2024.exe') 'fixture'
Set-Content (Join-Path $game 'OptiScaler.ini') '[Menu]'
Add-Type -AssemblyName System.IO.Compression.FileSystem
function MakeZip($file,$entries){$zip=[IO.Compression.ZipFile]::Open($file,'Create');try{foreach($name in $entries){$e=$zip.CreateEntry($name);$w=[IO.StreamWriter]::new($e.Open());$w.Write('fixture');$w.Dispose()}}finally{$zip.Dispose()}}
$zip=Join-Path $fixture 'valid.zip';MakeZip $zip @('pack/Shaders/Test.fx','pack/Shaders/include/Common.fxh','pack/Textures/Test.png','pack/Look.ini','ignored.dll')
$count=ImportEffectsZip $zip $game
Assert ($count -eq 4) 'ZIP imports FX, includes, textures and INI; excludes DLLs'
Assert (@(Get-ChildItem $game -Filter Common.fxh -Recurse).Count -eq 1) 'Shader include structure retained'
$before=@(Get-ChildItem $game -Recurse -File).Count
try{ImportEffectsZip $zip $game;throw 'Unexpected import'}catch{Assert ($_.Exception.Message -like '*already installed*') 'Duplicate FX rejected'}
$bad=Join-Path $fixture 'unsafe.zip';MakeZip $bad @('okay.ini','../outside.ini')
try{ImportEffectsZip $bad $game;throw 'Unexpected import'}catch{Assert ($_.Exception.Message -like '*Unsafe archive*') 'Traversal rejected before extraction'}
Assert (@(Get-ChildItem $game -Recurse -File).Count -eq $before) 'Rejected archives leave files unchanged'
Set-Content (Join-Path $payload 'OptiScaler.ini') '[DlssNr]'
Set-Content (Join-Path $payload 'ReShade.ini') "[GENERAL]`nPresetPath=old.ini"
Set-Content (Join-Path $game 'OptiScaler.ini') 'user settings'
Set-Content (Join-Path $game 'ReShade.ini') 'user look selection'
$mp=ManifestPath $store $game;New-Item -ItemType Directory -Path (Split-Path $mp) -Force|Out-Null
WriteState @{Game=$game;Status='Installed';Files=@();OwnedDirectories=@('OptiShadeData')} $mp
$backup=ResetOptiShadeSettings $game $payload $store
Assert ((Get-Content (Join-Path $backup 'OptiScaler.ini')) -eq 'user settings') 'Reset backs up previous settings'
Assert ((Get-Content (Join-Path $game 'ReShade.ini') -Raw) -match 'OptiShade recovery.ini') 'Reset selects an empty recovery preset'
$log=Join-Path $game 'OptiShadeData/Performance.log';Set-Content $log 'log'
$lock=[IO.File]::Open($log,'Open','ReadWrite','None')
try{try{RestoreFusion $mp;throw 'Unexpected restore'}catch{Assert ($_.Exception.Message -like '*has not changed any files*') 'Locked log blocks restore before mutation'}}finally{$lock.Dispose()}
Assert ((Get-Content $mp -Raw|ConvertFrom-Json).Status -eq 'Installed') 'Locked restore keeps installation state'
RestoreFusion $mp
Assert ((Get-Content $mp -Raw|ConvertFrom-Json).Status -eq 'Restored') 'Restore succeeds once log is released'
"Fixture: $fixture"
