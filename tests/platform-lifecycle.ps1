$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/library.ps1"
. "$PSScriptRoot/../installer/compatibility.ps1"
function AssertClosed($Game){}
function Assert($ok,$message){if(-not $ok){throw "FAIL: $message"};"PASS: $message"}
$fixture=Join-Path $env:TEMP ('OptiShade-platform-'+[guid]::NewGuid().ToString('N'))
$payload=Join-Path $fixture 'Payload';$store=Join-Path $fixture 'OptiShade';$installer=Join-Path $fixture 'setup.exe'
New-Item -ItemType Directory -Path "$payload/OptiShadeData/Presets" -Force|Out-Null
Set-Content "$payload/winmm.dll" 'our loader'
Set-Content "$payload/ReShade64.dll" 'our effects runtime'
Set-Content "$payload/OptiShadeData/Presets/My look.ini" 'default look'
Set-Content "$payload/nvngx.dll_dlssnr.dll" 'our neural helper'
@(Get-ChildItem $payload -Recurse -File|ForEach-Object {@{Path=$_.FullName.Substring($payload.Length+1);Hash=(HashFile $_.FullName)}})|ConvertTo-Json|Set-Content "$payload/files.json"
$gpu=[pscustomobject]@{Names='NVIDIA GeForce RTX 5080';Known=$true;Nvidia=$true}
$targets=@()
foreach($platform in @('Steam','Xbox')){
 # Steam may be in a user-named XboxGames directory; do not use that name to pick its loader.
 $parent=Join-Path $fixture $(if($platform -eq 'Steam'){'XboxGames/SteamLibrary/steamapps/common/MSFS'}else{'Xbox/MSFS'})
 $game=if($platform -eq 'Xbox'){Join-Path $parent 'Content'}else{$parent}
 New-Item -ItemType Directory -Path $game -Force|Out-Null
 foreach($exe in @('FlightSimulator2024.exe','gamelaunchhelper.exe')){Copy-Item -LiteralPath "$PSScriptRoot/../installer/FusionSetup.exe" -Destination (Join-Path $game $exe)}
 if($platform -eq 'Xbox'){Set-Content "$game/MicrosoftGame.Config" '<Game/>'}
 $resolved=ResolveFusionInstallFolder $parent
 Assert ($resolved -eq $game) "$platform parent resolves to actual executable folder"
 $exe=@(FindFusionExecutable $parent $platform)[0].Path
 $plan=GetFusionCompatibility $parent $exe $gpu $platform
 $expected=if($platform -eq 'Steam'){'dxgi.dll'}else{'winmm.dll'}
 Assert ($plan.Proxy -eq $expected) "$platform selects $expected regardless of parent folder name"
 Set-Content "$game/nvngx_dlss.dll" 'native game NVIDIA file'
 $native=HashFile "$game/nvngx_dlss.dll"
 $mp=InstallFusion $resolved $payload $store $installer $plan.Proxy
 Assert (Test-Path -LiteralPath (Join-Path $game $expected)) "$platform loader installed beside executable"
 Assert ((GetFusionInstallState $store $parent) -eq 'Installed') "$platform status resolves same target as install"
 Set-Content "$game/OptiShadeData/Presets/User.ini" 'saved look'
 $mp=InstallFusion $resolved $payload $store $installer $plan.Proxy @(FindFusionConflicts $game) -ReplaceExisting $true
 RestoreFusion (ManifestPath $store (ResolveFusionInstallFolder $parent))
 Assert (-not(Test-Path -LiteralPath (Join-Path $game $expected))) "$platform repair then restore removes actual loader"
 Assert ((HashFile "$game/nvngx_dlss.dll") -eq $native) "$platform native NVIDIA file preserved"
 Assert (Test-Path "$game/OptiShadeData/Presets/User.ini") "$platform saved preset preserved"
 $mp=InstallFusion $resolved $payload $store $installer $plan.Proxy @(FindFusionConflicts $game) -ReplaceExisting $true
 $targets+=@{Game=$game;Loader=$expected;Native=$native}
}
# Keep a session fixture so uninstall only removes individual, verified contained paths.
$session=Join-Path $store 'Sessions/test';New-Item -ItemType Directory -Path $session -Force|Out-Null
Set-Content "$session/keep.txt" 'active installer session'
UninstallFusion $store $installer $session -KeepPresets $true
foreach($target in $targets){
 Assert (-not(Test-Path (Join-Path $target.Game $target.Loader))) 'Uninstall removes each platform loader'
 Assert (-not(Test-Path (Join-Path $target.Game 'nvngx.dll_dlssnr.dll'))) 'Uninstall removes installed neural helper'
 Assert ((HashFile (Join-Path $target.Game 'nvngx_dlss.dll')) -eq $target.Native) 'Uninstall keeps game-owned NVIDIA runtime'
}
