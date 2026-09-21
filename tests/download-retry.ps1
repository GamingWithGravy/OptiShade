$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/effects.ps1"
$fixture=Join-Path $env:TEMP ('OptiShade-download-test-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'Game';$pack=Join-Path $fixture 'pack'
New-Item -ItemType Directory -Path "$game/OptiShadeData/Shaders/Packages/00","$pack/repo/Shaders" -Force|Out-Null
Set-Content "$game/OptiShadeData/Shaders/Packages/00/Default.fx" 'offline shader'
Set-Content "$pack/repo/Shaders/Extra.fx" 'downloaded shader'
Set-Content "$pack/repo/Shaders/Common.fxh" 'include'
Compress-Archive -Path "$pack/repo" -DestinationPath "$fixture/fixture.zip"
@'
[00]
PackageName=Default
DownloadUrl=https://github.com/test/default/archive/main.zip
[01]
PackageName=Extra
DownloadUrl=https://github.com/test/extra/archive/main.zip
'@|Set-Content "$fixture/catalogue.ini"
@(@{Name='Default';Source='https://github.com/test/default/archive/main.zip';Effects=1;Status='Installed'})|ConvertTo-Json|Set-Content "$game/OptiShadeData/Effects-install.json"
$script:calls=0;$script:fail=$true
function DownloadShaderArchive($Uri,$Destination){$script:calls++;if($Uri.AbsoluteUri -match '/default/'){throw 'Bundled effects must not download'};if($script:fail){throw 'Simulated network outage'};Copy-Item -LiteralPath "$fixture/fixture.zip" -Destination $Destination}
$failed=$false;try{InstallAllEffects $game "$fixture/catalogue.ini" {}}catch{$failed=$true}
if(-not $failed -or -not(Test-Path "$game/OptiShadeData/Shaders/Packages/00/Default.fx")){throw 'Offline fallback failed'}
'PASS: bundled default FX survive a failed additional download'
$script:fail=$false;$null=InstallAllEffects $game "$fixture/catalogue.ini" {}
if($script:calls -ne 2 -or -not(Test-Path "$game/OptiShadeData/Shaders/Packages/01/Extra.fx")){throw 'Retry failed'}
'PASS: retry skips successful packs and installs only unfinished packs'
$null=InstallAllEffects $game "$fixture/catalogue.ini" {}
if($script:calls -ne 2){throw 'Repeat installation downloaded completed FX'}
'PASS: repeat installation makes no shader downloads'
$receipt=Get-Content "$game/OptiShadeData/Effects-install.json" -Raw|ConvertFrom-Json
if(-not @($receipt|Where-Object Name -eq 'Extra')[0].Files.Count){throw 'Missing file inventory'}
# Simulate losing one installed dependency after a successful download.
$dependency="$game/OptiShadeData/Shaders/Packages/01/Common.fxh"
Remove-Item -LiteralPath $dependency
$receipt|ConvertTo-Json -Depth 5|Set-Content "$game/OptiShadeData/Effects-install.json"
Set-Content "$game/OptiShadeData/Shaders/Packages/01/Extra.fx" 'user edited shader'
$null=InstallAllEffects $game "$fixture/catalogue.ini" {}
if($script:calls -ne 3 -or -not(Test-Path -LiteralPath $dependency)){throw 'Missing dependency was not restored'}
if((Get-Content "$game/OptiShadeData/Shaders/Packages/01/Extra.fx") -ne 'user edited shader'){throw 'Existing shader was overwritten'}
'PASS: missing dependency retries its package and keeps user shader edits'
