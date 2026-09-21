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
AssertTarget $generic '' 'Binaries/Win64/OtherGame-Win64-Shipping.exe' 'Other games resolve their nested main EXE'
"Fixture: $fixture"
