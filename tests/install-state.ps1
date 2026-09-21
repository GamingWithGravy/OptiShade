$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
. "$PSScriptRoot/../installer/library.ps1"
$root=Join-Path $env:TEMP ('OptiShade-state-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $root 'Xbox/Content'
$store=Join-Path $root 'Store'
New-Item -ItemType Directory -Path $game -Force|Out-Null
Set-Content (Join-Path $game 'FlightSimulator2024.exe') 'fixture'
Set-Content (Join-Path $game 'ReShade64.dll') 'fixture'
if((GetFusionInstallState $store (Split-Path $game)) -ne 'Graphics files detected - not tracked'){throw 'Parent folder did not detect untracked graphics files'}
$mp=ManifestPath $store $game
New-Item -ItemType Directory -Path (Split-Path $mp) -Force|Out-Null
WriteState @{Game=$game;Status='Installed';Files=@(@{Path='winmm.dll';SourcePath='winmm.dll'})} $mp
if((GetFusionInstallState $store $game) -notmatch 'incomplete'){throw 'Missing loader reported installed'}
[IO.File]::WriteAllBytes((Join-Path $game 'winmm.dll'),[byte[]]@())
if((GetFusionInstallState $store $game) -notmatch 'incomplete'){throw 'Empty loader reported installed'}
Set-Content (Join-Path $game 'winmm.dll') 'fixture'
if((GetFusionInstallState $store $game) -ne 'Installed'){throw 'Stored loader not detected'}
'PASS: parent-folder discovery and missing/empty loader states are accurate'
. "$PSScriptRoot/../installer/compatibility.ps1"
. "$PSScriptRoot/../installer/recovery.ps1"
function GetFusionGpu { [pscustomobject]@{Known=$true;Names='NVIDIA GeForce RTX 4090';Drivers=@()} }
Set-Content (Join-Path $game 'private-preset.ini') 'private preset sentinel'
$report=GetOptiShadeSupportReport (Split-Path $game) $store
if($report.GameFolder -ne $game -or $report.NeuralModel.Family -ne 'RTX 20/30/40'){throw 'Incorrect support report target/GPU'}
if(@($report.Files|Where-Object Path -eq 'winmm.dll')[0].SHA256 -ne (HashFile (Join-Path $game 'winmm.dll'))){throw 'Incorrect reported loader hash'}
if(($report|ConvertTo-Json -Depth 8) -match 'private preset sentinel'){throw 'Preset contents included'}
'PASS: support report resolves platform folder, includes loader hash and excludes preset contents'
