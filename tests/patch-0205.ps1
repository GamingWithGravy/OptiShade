$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/menu-settings.ps1"
. "$PSScriptRoot/../installer/import-effects.ps1"
. "$PSScriptRoot/../installer/library.ps1"
. "$PSScriptRoot/../installer/compatibility.ps1"
function AssertClosed($Game){}
function Check($ok,$message){if(-not $ok){throw "FAIL: $message"};"PASS: $message"}
function Reject([scriptblock]$Action,$message){$failed=$false;try{&$Action}catch{$failed=$true};Check $failed $message}
$fixture=Join-Path $env:TEMP ('OptiShade-0205-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'Game';$payload=Join-Path $fixture 'Payload';$store=Join-Path $fixture 'Store'
New-Item -ItemType Directory -Path "$game/OptiShadeData/Shaders","$payload/OptiShadeData/Shaders","$payload/OptiShadeData/Presets" -Force|Out-Null
Set-Content "$game/FlightSimulator2024.exe" 'fixture'
Set-Content "$game/OptiScaler.ini" "[Menu]`r`nShortcutKey=36`r`nOther=keep`r`n[DlssNr]`r`nEnabled=false"
SetMenuSettings $game 45 75
$keys=GetMenuSettings $game
Check ($keys.ShortcutKey -eq 45 -and $keys.BackupShortcutKey -eq 75) 'Launcher saves primary and Ctrl+Shift backup key'
Check ((Get-Content "$game/OptiScaler.ini" -Raw) -match 'Other=keep') 'Key settings preserve unrelated configuration'
Reject {SetMenuSettings $game 75 75} 'Overlapping bindings rejected'
Reject {SetMenuSettings $game 35 79} 'Menu key cannot also toggle frame generation'
Reject {SetMenuSettings $game 0 79} 'Invalid key cannot disable primary menu'
Set-Content "$payload/winmm.dll" 'loader';Set-Content "$payload/OptiScaler.ini" "[Menu]`nShortcutKey=45"
Set-Content "$payload/OptiShadeData/Shaders/Test.fx" 'shader';Set-Content "$payload/OptiShadeData/Presets/My look.ini" 'Techniques='
@(Get-ChildItem $payload -Recurse -File|ForEach-Object {@{Path=$_.FullName.Substring($payload.Length+1);Hash=(HashFile $_.FullName)}})|ConvertTo-Json|Set-Content "$payload/files.json"
$mp=InstallFusion $game $payload $store "$fixture/setup.exe" 'winmm.dll' @(FindFusionConflicts $game) -ReplaceExisting $true -PreserveConfiguration $true -IncludeEffects $false
Check (-not(Test-Path "$game/OptiShadeData/Shaders/Test.fx")) 'Upscaling-only install omits shader payload'
$mp=InstallFusion $game $payload $store "$fixture/setup.exe" 'winmm.dll' @(FindFusionConflicts $game) -ReplaceExisting $true -PreserveConfiguration $true
Check (-not(Test-Path "$game/OptiShadeData/Shaders/Test.fx")) 'Repair/update retain shader opt-out'
Check ((GetMenuSettings $game).BackupShortcutKey -eq 75) 'Repair/update retain launcher shortcuts'
# Model an interrupted install with its durable ownership receipt still present.
$interrupted=Get-Content $mp -Raw|ConvertFrom-Json;$interrupted.Status='Installing';WriteState $interrupted $mp
$mp=InstallFusion $game $payload $store "$fixture/setup.exe" 'winmm.dll' @(FindFusionConflicts $game) -ReplaceExisting $true -PreserveConfiguration $true
Check ((Get-Content $mp -Raw|ConvertFrom-Json).Status -eq 'Installed') 'Interrupted installation repairs using the existing receipt'
Check ((GetMenuSettings $game).BackupShortcutKey -eq 75) 'Interrupted repair preserves shortcut configuration'
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Zip($path,$entries){$zip=[IO.Compression.ZipFile]::Open($path,'Create');try{foreach($name in $entries.Keys){$entry=$zip.CreateEntry($name);$w=[IO.StreamWriter]::new($entry.Open());$w.Write($entries[$name]);$w.Dispose()}}finally{$zip.Dispose()}}
$valid="$fixture/valid.zip";Zip $valid @{'pack/Shaders/Custom.fx'='shader';'pack/Shaders/inc/header.fxh'='include';'pack/Textures/lookup.png'='texture';'pack/Look.ini'='Techniques=Colour@Custom.fx';'unsafe.exe'='ignored'}
Check ((ImportEffectsArchive $valid $game) -eq 4) 'ZIP installs shader, include, texture and preset only'
Check (@(Get-ChildItem "$game/OptiShadeData/Presets" -Filter '*.ini' -Recurse).Count -eq 2) 'ZIP preset is discoverable recursively'
Reject {ImportEffectsArchive $valid $game} 'Duplicate shader import keeps existing files'
foreach($name in @('../outside.ini','C:/outside.ini','a/CON.ini','a/file.ini:stream','a/./look.ini')){
 $bad="$fixture/$([guid]::NewGuid().ToString('N')).zip";Zip $bad @{$name='bad';'good.ini'='Techniques='};Reject {ImportEffectsArchive $bad $game} "Reject unsafe ZIP path $name"
}
$ini="$fixture/required.ini";Set-Content $ini "Techniques=Colour@Custom.fx,Sharp@LumaSharpen.fx`n[Unknown.fx]`nValue=1"
$missing=@(GetMissingPresetShaders $ini $game)
Check ($missing.Count -eq 2 -and 'Custom.fx' -notin $missing) 'INI dependencies compare against installed FX'
$catalogue="$PSScriptRoot/../installer/EffectPackages.ini"
$packages=GetPresetPackages @('LumaSharpen.fx') $catalogue
Check ($packages.Count -eq 1 -and $packages['01'].Shaders[0] -eq 'LumaSharpen.fx') 'Missing FX resolves to exact catalogue package'
Reject {GetPresetPackages @('Unknown.fx') $catalogue} 'Unknown FX never guesses a download'
$duplicate="$fixture/duplicates.ini";Set-Content $duplicate "[a]`nEffectFiles=Same.fx`n[b]`nEffectFiles=Same.fx"
Reject {GetPresetPackages @('Same.fx') $duplicate} 'Ambiguous FX never guesses a package'
$amd=[pscustomobject]@{Known=$true;Nvidia=$false;Names='AMD Radeon RX 7900 XTX'}
AssertMsfsNvidiaTarget "$game/FlightSimulator2024.exe" $amd
$plan=GetFusionCompatibility $game "$game/FlightSimulator2024.exe" $amd 'Steam'
Check (-not $plan.DownloadNvidia -and $plan.PossibleInput) 'AMD can install applicable features without NVIDIA downloads'
Check ((GetNeuralRuntimeStatus $game $amd).State -eq 'Unsupported on this hardware') 'AMD never claims NVIDIA Neural Rendering availability'
"Fixture: $fixture"
