$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/mfg.ps1"
function AssertClosed($Game){}
function SavePreRestoreEvidence($Game,$Folder){}
function Assert($ok,$message){if(-not $ok){throw $message};"PASS: $message"}
$root=Join-Path $env:TEMP ('OptiShade-mfg-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $root 'Game';$payload=Join-Path $root 'Payload';$store=Join-Path $root 'Store'
New-Item -ItemType Directory -Path $game,"$payload/OptiShadeData/MFG" -Force|Out-Null
Set-Content "$payload/winmm.dll" 'fixture loader'
Set-Content "$payload/OptiScaler.ini" "[Menu]`nShortcutKey=45`n[FrameGen]`nExternal=false`n[DLSSG]`nAdaMfgUnlock=true"
Copy-Item "$PSScriptRoot/../installer/OptionalMFG/RTXMFG.dll" "$payload/OptiShadeData/MFG/RTXMFG.dll"
@(Get-ChildItem $payload -File -Recurse|ForEach-Object {@{Path=$_.FullName.Substring($payload.Length+1);Hash=(HashFile $_.FullName)}})|ConvertTo-Json|Set-Content "$payload/files.json"
$mp=InstallFusion $game $payload $store "$root/Manager.exe"
$before=Get-Content "$game/OptiScaler.ini" -Raw
try{InstallOptionalMfg $mp $payload @('RTX 5090');throw 'accepted unsupported GPU'}catch{if($_ -like '*accepted unsupported*'){throw}}
Assert (-not(Test-Path "$game/version.dll")) 'Unsupported GPU leaves game untouched'
Set-Content "$game/version.dll" 'other loader'
try{InstallOptionalMfg $mp $payload @('RTX 4060');throw 'overwrote occupied proxy'}catch{if($_ -like '*overwrote occupied*'){throw}}
Assert ((Get-Content "$game/version.dll") -eq 'other loader') 'Existing proxy preserved'
Remove-Item -LiteralPath "$game/version.dll"
InstallOptionalMfg $mp $payload @('NVIDIA GeForce RTX 4070 Ti')
$m=Get-Content $mp -Raw|ConvertFrom-Json
Assert ($m.OptionalMfg -and (HashFile "$game/version.dll") -eq (HashFile "$payload/OptiShadeData/MFG/RTXMFG.dll")) 'Verified module installed and tracked'
$ini=Get-Content "$game/OptiScaler.ini" -Raw
Assert ($ini -match 'External=true' -and $ini -match 'AdaMfgUnlock=false' -and $ini -match 'AmpereMfgUnlock=false' -and $ini -match 'ShortcutKey=45') 'Exclusive FG ownership; menu settings retained'
$mp=InstallFusion $game $payload $store "$root/NewManager.exe" 'winmm.dll' @(FindFusionConflicts $game) -ReplaceExisting $true -PreserveConfiguration $true
$m=Get-Content $mp -Raw|ConvertFrom-Json
Assert ($m.OptionalMfg -and (Test-Path "$game/version.dll") -and (Get-Content "$game/OptiScaler.ini" -Raw) -match 'External=true') 'Repair/update retains optional loader and FG configuration'
RestoreFusion $mp
Assert (-not(Test-Path "$game/version.dll")) 'Restore removes owned optional MFG loader'
