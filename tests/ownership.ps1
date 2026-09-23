$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
function AssertClosed($Game){} # Isolated temporary fixtures, not the running simulator.
$fixture=Join-Path $env:TEMP ('OptiShade-lifecycle-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'Game';$payload=Join-Path $fixture 'Payload';$store=Join-Path $fixture 'OptiShade';$installer=Join-Path $fixture 'OriginalInstaller.exe'
function Assert($ok,$text){if(-not $ok){throw $text};Write-Output "PASS: $text"}
New-Item -ItemType Directory -Path $game,(Join-Path $payload 'OptiShadeData/Shaders'),(Join-Path $payload 'OptiShadeData/Engine') -Force|Out-Null
Set-Content $installer 'original installer'
$protected=@('UserCfg.opt','Controls/Joystick.xml','Settings/graphics.ini','Saves/flight.sav')
foreach($relative in $protected){$path=Join-Path $game $relative;New-Item -ItemType Directory -Path (Split-Path $path) -Force|Out-Null;Set-Content -LiteralPath $path 'game-owned data'}
function AssertGameData($stage){foreach($relative in $protected){Assert ((HashFile (Join-Path $game $relative)) -eq $protectedHashes[$relative]) "$stage preserves $relative byte for byte"}}
Set-Content (Join-Path $game 'ReShade.ini') 'original configuration'
Set-Content (Join-Path $payload 'winmm.dll') 'test binary'
Set-Content (Join-Path $payload 'ReShade.ini') 'installed configuration'
Set-Content (Join-Path $payload 'OptiShadeData/Shaders/Test.fx') 'test shader'
Set-Content (Join-Path $payload 'OptiShadeData/Engine/backend.dll') 'test backend'
$catalog=@(Get-ChildItem $payload -Recurse -File|ForEach-Object {@{Path=$_.FullName.Substring($payload.Length+1);Hash=(HashFile $_.FullName)}})
$catalog|ConvertTo-Json|Set-Content (Join-Path $payload 'files.json')
$original=HashFile (Join-Path $game 'ReShade.ini')
$mp=InstallFusion $game $payload $store $installer -ReplaceMods @(FindFusionConflicts $game)
Assert (Test-Path (Join-Path $game 'winmm.dll')) 'Install writes the recorded files'
Set-Content (Join-Path $game 'ReShade.ini') 'user changed setting'
Set-Content (Join-Path $game 'OptiShadeData/imported.ini') 'imported preset'
# Simulate changing controls/settings and saving progress while OptiShade is installed.
$protectedHashes=@{}
foreach($relative in $protected){$path=Join-Path $game $relative;Set-Content -LiteralPath $path ('latest game data: '+$relative);$protectedHashes[$relative]=HashFile $path}
RestoreFusion $mp
AssertGameData 'Restore'
Assert ((HashFile (Join-Path $game 'ReShade.ini')) -eq $original) 'Restore recovers original configuration byte for byte'
Assert (-not(Test-Path (Join-Path $game 'winmm.dll'))) 'Restore removes the proxy'
Assert (-not(Test-Path (Join-Path $game 'OptiShadeData'))) 'Restore removes generated files and imports'
Assert (-not(Test-Path (Join-Path $game 'OptiShadeData/Engine'))) 'Restore removes backend folder'
$mp=InstallFusion $game $payload $store $installer -ReplaceMods @(FindFusionConflicts $game)
Set-Content (Join-Path $game 'winmm.dll') 'another program replaced this file'
$blocked=$false;try{RestoreFusion $mp}catch{$blocked=$true}
Assert $blocked 'Changed DLL blocks restore'
Assert (Test-Path (Join-Path $game 'OptiShadeData')) 'Failed preflight leaves installation intact'
Copy-Item (Join-Path $payload 'winmm.dll') (Join-Path $game 'winmm.dll') -Force
$blocked=$false;try{OwnedPath $game '../outside.txt'}catch{$blocked=$true}
Assert $blocked 'Paths outside the game are rejected'
UninstallFusion $store $installer
AssertGameData 'Uninstall'
Assert (-not(Test-Path $store)) 'Uninstall removes the complete application store'
Assert (Test-Path $installer) 'Uninstall preserves the original installer'
Assert ((HashFile (Join-Path $game 'ReShade.ini')) -eq $original) 'Uninstall also restores the game'
$mp=InstallFusion $game $payload $store $installer -Proxy 'dxgi.dll' -ReplaceMods @(FindFusionConflicts $game)
Assert ((Test-Path (Join-Path $game 'dxgi.dll')) -and -not(Test-Path (Join-Path $game 'winmm.dll'))) 'Alternate installation method records the actual proxy name'
RestoreFusion $mp
Assert (-not(Test-Path (Join-Path $game 'dxgi.dll'))) 'Restore removes the alternate proxy'
$session=Join-Path $store 'Sessions/setup-fixture';New-Item -ItemType Directory $session -Force|Out-Null
Set-Content (Join-Path $session 'FusionSetup.exe') 'running helper fixture'
$held=[IO.File]::Open((Join-Path $session 'FusionSetup.exe'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try{UninstallFusion $store $installer $session;Assert (Test-Path (Join-Path $session 'FusionSetup.exe')) 'Self-uninstall preserves the active helper until exit';Assert (-not(Test-Path (Join-Path $store 'Games'))) 'Self-uninstall clears recorded game state'}finally{$held.Dispose()}
$existing=Join-Path $game 'dxgi.dll'
Copy-Item "$PSScriptRoot/../reshade/bin/x64/Release/ReShade64.dll" $existing
$before=HashFile $existing;$conflicts=@(FindFusionConflicts $game)
Assert (@($conflicts|Where-Object {$_.Path -eq 'dxgi.dll' -and $_.Recognised}).Count -eq 1) 'Detect existing ReShade using file identity'
$blocked=$false;try{InstallFusion $game $payload $store $installer|Out-Null}catch{$blocked=$true}
Assert ($blocked -and (HashFile $existing) -eq $before) 'Existing mod remains untouched without consent'
$mp=InstallFusion $game $payload $store $installer -Proxy 'winmm.dll' -ReplaceMods $conflicts
Assert (-not(Test-Path $existing)) 'Approved existing mod is disabled after verified backup'
RestoreFusion $mp
Assert ((HashFile $existing) -eq $before) 'Restore recovers the other mod byte for byte'
# Keep the tiny fixture as inspectable test evidence. No real game is touched.
$presetGame=Join-Path $fixture 'PresetGame';New-Item -ItemType Directory $presetGame -Force|Out-Null
$mp=InstallFusion $presetGame $payload $store $installer
$presets=Join-Path $presetGame 'OptiShadeData/Presets';New-Item -ItemType Directory $presets -Force|Out-Null
$custom=Join-Path $presets 'My custom look.ini';Set-Content $custom 'custom saved settings';$customHash=HashFile $custom
RestoreFusion $mp
Assert ((HashFile $custom) -eq $customHash) 'Restore keeps custom INI presets in place'
$mp=InstallFusion $presetGame $payload $store $installer
Assert ((HashFile $custom) -eq $customHash) 'Reinstall accepts preserved presets without changing them'
UninstallFusion $store $installer -KeepPresets $true
Assert ((HashFile $custom) -eq $customHash) 'Uninstall Yes keeps custom INI presets in place'
$mp=InstallFusion $presetGame $payload $store $installer
UninstallFusion $store $installer -KeepPresets $false
Assert (-not(Test-Path $custom)) 'Uninstall No removes managed presets'
Assert (-not(Test-Path (Join-Path $presetGame 'OptiShadeData'))) 'Uninstall No leaves no managed data folder'
$mp=InstallFusion $presetGame $payload $store $installer
New-Item -ItemType Directory $presets -Force|Out-Null;Set-Content $custom 'keep until uninstall'
RestoreFusion $mp
UninstallFusion $store $installer -KeepPresets $false
Assert (-not(Test-Path $custom)) 'Uninstall No also removes presets kept by an earlier Restore'
Write-Output "Fixture: $fixture"
