$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/library.ps1"
function AssertClosed([string]$Game){} # Fixtures contain text files, never a running simulator.
function Assert($ok,$label){if(-not $ok){throw "FAIL: $label"};"PASS: $label"}
$fixture=Join-Path $env:TEMP ('OptiShade-update-test-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'Game';$payload=Join-Path $fixture 'Payload';$store=Join-Path $fixture 'OptiShade';$installer=Join-Path $fixture 'installer.exe'
New-Item -ItemType Directory -Path $game,(Join-Path $payload 'OptiShadeData/Shaders') -Force|Out-Null
Set-Content $installer 'installer'
Set-Content (Join-Path $game 'dxgi.dll') 'original graphics loader'
Set-Content (Join-Path $game 'ReShade.ini') 'original config'
$original=HashFile (Join-Path $game 'dxgi.dll')
function Payload([string]$version){
 Set-Content (Join-Path $payload 'winmm.dll') $version
 Set-Content (Join-Path $payload 'ReShade.ini') 'default config'
 Set-Content (Join-Path $payload 'OptiShadeData/Shaders/test.fx') $version
 @(Get-ChildItem $payload -Recurse -File|Where-Object Name -ne 'files.json'|ForEach-Object {@{Path=$_.FullName.Substring($payload.Length+1);Hash=(HashFile $_.FullName)}})|ConvertTo-Json|Set-Content (Join-Path $payload 'files.json')
}
Payload 'v1'
$mp=InstallFusion $game $payload $store $installer 'dxgi.dll' @(FindFusionConflicts $game)
Assert ((GetFusionInstallState $store $game) -eq 'Installed') 'Exact Content path reads installed state'
$m=Get-Content $mp -Raw|ConvertFrom-Json;$m|Add-Member Downloads 'Pending';WriteState $m $mp
Assert ((GetFusionInstallState $store $game) -eq 'Installed - downloads pending') 'Partial downloads are still installed'
New-Item -ItemType Directory -Path (Join-Path $game 'OptiShadeData/Presets') -Force|Out-Null
Set-Content (Join-Path $game 'OptiShadeData/Presets/Mine.ini') 'my look'
Set-Content (Join-Path $game 'ReShade.ini') 'user config'
Payload 'v2'
$mp=InstallFusion $game $payload $store $installer 'dxgi.dll' @(FindFusionConflicts $game) -ReplaceExisting $true -PreserveConfiguration $true
Assert ((Get-Content (Join-Path $game 'dxgi.dll')) -eq 'v2') 'Upgrade updates the loader'
Assert ((Get-Content (Join-Path $game 'ReShade.ini')) -eq 'user config') 'Automatic update preserves configuration'
Assert ((Get-Content (Join-Path $game 'OptiShadeData/Presets/Mine.ini')) -eq 'my look') 'Upgrade preserves saved looks'
$beforeManifest=HashFile $mp;$beforeLoader=HashFile (Join-Path $game 'dxgi.dll')
Payload 'v3'
$script:injectFailure=$true
function Copy-Item {
 param([string]$LiteralPath,[string]$Destination,[switch]$Force)
 if($script:injectFailure -and $Destination -eq (Join-Path $game 'OptiShadeData/Shaders/test.fx')){$script:injectFailure=$false;throw 'Simulated disk write failure'}
 Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}
$failed=$false;try{InstallFusion $game $payload $store $installer 'dxgi.dll' @(FindFusionConflicts $game) -ReplaceExisting $true -PreserveConfiguration $true}catch{$failed=$true}
Remove-Item Function:/Copy-Item
Assert $failed 'Interrupted update is reported'
Assert ((HashFile (Join-Path $game 'dxgi.dll')) -eq $beforeLoader) 'Interrupted update rolls loader back'
Assert ((Get-Content (Join-Path $game 'OptiShadeData/Shaders/test.fx')) -eq 'v2') 'Interrupted update rolls shader back'
# JSON whitespace can change on recovery, so inspect its recorded version/hash.
$restoredManifest=Get-Content $mp -Raw|ConvertFrom-Json
Assert ((@($restoredManifest.Files|Where-Object Path -eq 'dxgi.dll')[0].Hash) -eq $beforeLoader) 'Interrupted update restores ownership record'
RestoreFusion $mp
Assert ((HashFile (Join-Path $game 'dxgi.dll')) -eq $original) 'Restore after upgrade recovers original pre-v1 loader'
Assert (-not(Test-Path (Join-Path $game 'ReShade.ini'))) 'Mod configuration is not resurrected by Restore'
Assert ((GetFusionInstallState $store $game) -eq 'Not installed (restored)') 'Restore refreshes selector state'
$orphan=Join-Path $fixture 'Orphan';New-Item -ItemType Directory -Path (Join-Path $orphan 'OptiShadeData/Shaders') -Force|Out-Null
Set-Content (Join-Path $orphan 'OptiShadeData/Shaders/test.fx') 'untracked user shader'
$mp=InstallFusion $orphan $payload $store $installer 'winmm.dll' @() -ReplaceExisting $true
RestoreFusion $mp
Assert (-not(Test-Path (Join-Path $orphan 'OptiShadeData/Shaders/test.fx'))) 'Orphaned app files are not restored as originals'
Set-Content (Join-Path $game 'FlightSimulator2024.exe') 'fixture, not executable'
$mp=InstallFusion $game $payload $store $installer 'dxgi.dll' @(FindFusionConflicts $game) -ReplaceExisting $true
Set-Content (Join-Path $game 'ReShade.ini') 'keep update config'
$m=Get-Content $mp -Raw|ConvertFrom-Json;$m|Add-Member LaunchExe (Join-Path $game 'FlightSimulator2024.exe');WriteState $m $mp
Payload 'v4'
$savedLocalAppData=$env:LOCALAPPDATA
try{
 $env:LOCALAPPDATA=$fixture
 function Get-Process {} # Simulate a closed game; only this fixture's store is visible.
 & "$PSScriptRoot/../installer/update-install.ps1" -Payload $payload -Installer $installer
}finally{$env:LOCALAPPDATA=$savedLocalAppData;Remove-Item Function:/Get-Process}
Assert ((Get-Content (Join-Path $game 'dxgi.dll')) -eq 'v4') 'Real update helper updates tracked MSFS installation'
Assert ((Get-Content (Join-Path $game 'ReShade.ini')) -eq 'keep update config') 'Real update helper keeps configuration'
'Fixture: '+$fixture
