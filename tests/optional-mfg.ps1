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

# A replaced third-party loader must be restored after installing optional MFG.
Set-Content "$game/version.dll" 'original third-party loader'
$originalHash=HashFile "$game/version.dll"
$mp=InstallFusion $game $payload $store "$root/Manager.exe" 'winmm.dll' @(FindFusionConflicts $game)
InstallOptionalMfg $mp $payload @('RTX 4060')
$m=Get-Content $mp -Raw|ConvertFrom-Json
Assert (@($m.Files|Where-Object Path -eq 'version.dll').Count -eq 1) 'MFG reuses displaced-loader ownership record'
RestoreFusion $mp
Assert ((HashFile "$game/version.dll") -eq $originalHash) 'Restore preserves original third-party loader'

# Simulate the duplicate ledger emitted by previously released installers.
$mp=InstallFusion $game $payload $store "$root/Manager.exe" 'winmm.dll' @(FindFusionConflicts $game)
$m=Get-Content $mp -Raw|ConvertFrom-Json
$m.Files=@($m.Files)+[pscustomobject]@{Path='version.dll';SourcePath='';Hash=(HashFile "$payload/OptiShadeData/MFG/RTXMFG.dll");PreviousHash='';Backup='';Mutable=$false;Retained=$true}
$m|Add-Member OptionalMfg $true -Force
Copy-Item "$payload/OptiShadeData/MFG/RTXMFG.dll" "$game/version.dll"
WriteState $m $mp
Set-Content "$game/version.dll" 'unrecognised changed loader'
try{RestoreFusion $mp;throw 'accepted changed loader'}catch{if($_ -like '*accepted changed loader*'){throw}}
Assert ((Get-Content "$game/version.dll") -eq 'unrecognised changed loader') 'Legacy recovery still refuses a changed loader'
Copy-Item "$payload/OptiShadeData/MFG/RTXMFG.dll" "$game/version.dll" -Force
RestoreFusion $mp
Assert ((HashFile "$game/version.dll") -eq $originalHash) 'Legacy duplicate MFG records recover original loader'
