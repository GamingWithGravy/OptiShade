$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/library.ps1"
$fixture=Join-Path $env:TEMP ('OptiShade-discovery-'+[guid]::NewGuid().ToString('N'))
$binary="$PSScriptRoot/../installer/FusionSetup.exe"
function AssertTarget($folder,$launcher,$expected,$label){
 $found=@(FindFusionExecutable $folder $launcher)
 if($found.Count -ne 1 -or $found[0].Path -ne (Join-Path $folder $expected)){throw "FAIL: $label"}
 "PASS: $label"
}
$xbox=Join-Path $fixture 'CustomLocation/Content';$steam=Join-Path $fixture 'Steam/MSFS';$generic=Join-Path $fixture 'OtherGame'
New-Item -ItemType Directory -Path $xbox,$steam,(Join-Path $generic 'Binaries/Win64') -Force|Out-Null
foreach($folder in @($xbox,$steam)){foreach($name in @('FlightSimulator2024.exe','gamelaunchhelper.exe')){Copy-Item $binary (Join-Path $folder $name)}}
Set-Content (Join-Path $xbox 'MicrosoftGame.Config') '<Game/>'
AssertTarget $xbox 'Xbox' 'gamelaunchhelper.exe' 'Xbox MSFS selects helper without a file picker'
AssertTarget $xbox '' 'gamelaunchhelper.exe' 'Manually selected Xbox folder is detected from game metadata'
AssertTarget (Split-Path $xbox) 'Xbox' 'Content/gamelaunchhelper.exe' 'Xbox parent folder resolves Content automatically'
AssertTarget $steam 'Steam' 'FlightSimulator2024.exe' 'Steam MSFS selects the main EXE even with a helper present'
Copy-Item $binary (Join-Path $generic 'Binaries/Win64/OtherGame-Win64-Shipping.exe')
$rejected=$false;try{FindFusionExecutable $generic}catch{$rejected=$true};if(-not $rejected){throw 'Non-MSFS target accepted'}; 'PASS: Other games remain unavailable in this MSFS-only patch'
"Fixture: $fixture"

foreach($inputPath in @(('  "'+$steam+'"  '),(Join-Path $steam 'FlightSimulator2024.exe'))){
 if((ResolveFusionInstallFolder $inputPath) -ne $steam){throw 'Pasted/EXE path did not resolve'}
}
foreach($bad in @('', '   ', 'relative\game', 'C:game', 'C:\bad"path', 'C:\game*')){
 $rejected=$false;try{ResolveFusionInstallFolder $bad|Out-Null}catch{$rejected=$true}
 if(-not $rejected){throw "Invalid path accepted: $bad"}
}
# Isolated catalogues: a malformed registration must not hide a valid custom Store location.
function Get-PSDrive { @() }
function Get-ItemProperty { [pscustomobject]@{SteamPath='invalid"path';InstallPath='invalid"path'} }
function Get-AppxPackage {
 param($Name,$ErrorAction)
 @([pscustomobject]@{Name=$Name;InstallLocation='invalid"path'},[pscustomobject]@{Name=$Name;InstallLocation=$xbox})
}
$detected=@(FindFusionGames (Join-Path $fixture 'Store')|Where-Object Folder -eq $xbox)
if($detected.Count -ne 1 -or $detected[0].Launcher -ne 'Xbox'){throw 'Custom Store installation discovery failed'}
'PASS: pasted paths, invalid entries and custom Store installation discovery'
