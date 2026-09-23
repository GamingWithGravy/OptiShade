$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/recovery.ps1"
function AssertClosed($Game){}
function Check($ok,$message){if(-not $ok){throw $message};"PASS: $message"}
$fixture=Join-Path $env:TEMP ('OptiShade-own-ini-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'Game';$payload=Join-Path $fixture 'Payload';$store=Join-Path $fixture 'Store'
New-Item -ItemType Directory -Path $game,"$payload/OptiShadeData/Shaders","$payload/OptiShadeData/Presets" -Force|Out-Null
Set-Content "$payload/winmm.dll" 'fixture loader'
Set-Content "$payload/OptiScaler.ini" '[Menu]'
Set-Content "$payload/OptiShadeData/Shaders/Unneeded.fx" 'unneeded'
Set-Content "$payload/OptiShadeData/Presets/My look.ini" 'Techniques='
New-Item -ItemType Directory -Path "$payload/OptiShadeData/Shaders/Custom","$payload/OptiShadeData/Licenses" -Force|Out-Null
Copy-Item "$PSScriptRoot/../installer/FusionCinema/Gravy_FusionCinema.fx" "$payload/OptiShadeData/Shaders/Custom/Gravy_FusionCinema.fx"
Copy-Item "$PSScriptRoot/../installer/FusionCinema/Gravy - Fusion Cinema Custom v1.ini" "$payload/OptiShadeData/Presets/Gravy - Fusion Cinema Custom v1.ini"
Copy-Item "$PSScriptRoot/../installer/FusionCinema/LICENSE" "$payload/OptiShadeData/Licenses/FusionCinema-GPL3.txt"
@(Get-ChildItem $payload -Recurse -File|ForEach-Object {@{Path=$_.FullName.Substring($payload.Length+1);Hash=(HashFile $_.FullName)}})|ConvertTo-Json|Set-Content "$payload/files.json"
$mp=InstallFusion $game $payload $store "$fixture/Manager.exe" -IncludeEffects $false
Check (-not(Test-Path "$game/OptiShadeData/Shaders/Unneeded.fx")) 'INI-only core install excludes unrelated bundled shaders'
Check ((Test-Path "$game/OptiShadeData/Shaders/Custom/Gravy_FusionCinema.fx") -and (Test-Path "$game/OptiShadeData/Presets/Gravy - Fusion Cinema Custom v1.ini") -and (Test-Path "$game/OptiShadeData/Licenses/FusionCinema-GPL3.txt")) 'Own-INI install includes Fusion Cinema shader, preset and licence by default'
Set-Content "$game/OptiShadeData/Presets/Gravy - Fusion Cinema Custom v1.ini" 'user-edited look'
$ini=Join-Path $fixture 'User look.ini';$catalogue=Join-Path $fixture 'Packages.ini'
Set-Content $ini "Techniques=Colour@Needed.fx`n[Needed.fx]`nStrength=0.5"
Set-Content $catalogue "[test]`nEffectFiles=Needed.fx,Unneeded.fx`nDownloadUrl=https://github.com/example/test/archive/main.zip"
$selected=GetPresetPackages @(GetMissingPresetShaders $ini $game) $catalogue
Check ($selected.Count -eq 1 -and $selected['test'].Shaders.Count -eq 1 -and $selected['test'].Shaders[0] -eq 'Needed.fx') 'Dependency plan selects only the referenced FX'
New-Item -ItemType Directory -Path "$game/OptiShadeData/Shaders" -Force|Out-Null
Set-Content "$game/OptiShadeData/Shaders/Needed.fx" 'existing effect'
$relative=SaveOwnPreset $ini $game $catalogue
InstallPresetDependencies (OwnedPath $game $relative) $game $catalogue
Check ((HashFile $ini) -eq (HashFile (OwnedPath $game $relative))) 'Imported preset is preserved exactly'
Check (-not(Test-Path "$game/OptiShadeData/Shaders/Unneeded.fx")) 'Existing dependency satisfies preset without full FX download'
Set-Content $ini 'Techniques=LegacyUnqualified'
$rejected=$false;try{TestOwnPreset $ini $game $catalogue}catch{$rejected=$true}
Check $rejected 'Ambiguous legacy preset fails rather than silently downloading everything'
Set-Content $ini "Techniques=Private@Unavailable.fx"
$rejected=$false;try{TestOwnPreset $ini $game $catalogue}catch{$rejected=$true}
Check $rejected 'Unknown dependency fails before download'
$mp=InstallFusion $game $payload $store "$fixture/Manager.exe" -ReplaceMods @(FindFusionConflicts $game) -ReplaceExisting $true -PreserveConfiguration $true
Check (-not(Test-Path "$game/OptiShadeData/Shaders/Unneeded.fx") -and (Test-Path (OwnedPath $game $relative))) 'Repair retains preset-only choice and imported look'

Check ((Get-Content "$game/OptiShadeData/Presets/Gravy - Fusion Cinema Custom v1.ini" -Raw).Trim() -eq 'user-edited look') 'Repair preserves edited bundled preset'
$fullGame=Join-Path $fixture 'FullGame';New-Item -ItemType Directory -Path $fullGame|Out-Null
$fullManifest=InstallFusion $fullGame $payload $store "$fixture/Manager.exe" -IncludeEffects $true
Check ((Test-Path "$fullGame/OptiShadeData/Shaders/Custom/Gravy_FusionCinema.fx") -and (Test-Path "$fullGame/OptiShadeData/Shaders/Unneeded.fx")) 'Full FX install includes Fusion Cinema alongside the catalogue'