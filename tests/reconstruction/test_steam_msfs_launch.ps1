$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile("$root/Beta/installer/library.ps1",[ref]$t,[ref]$e)
if($e.Count){throw ($e|Out-String)}
$n=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'GetOptiShadeSteamLaunchUri'},$true);Invoke-Expression $n.Extent.Text
$dir=Join-Path $env:TEMP ('OptiShade-steam-fixture-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $dir 'steamapps/common/MSFS2024';[void][IO.Directory]::CreateDirectory($game)
$exe=Join-Path $game 'FlightSimulator2024.exe';$manifest=Join-Path $dir 'steamapps/appmanifest_2537590.acf'
[IO.File]::WriteAllText($manifest,'"AppState" { "appid" "2537590" "installdir" "MSFS2024" }')
if((GetOptiShadeSteamLaunchUri $exe) -ne 'steam://rungameid/2537590'){throw 'Valid matching Steam installation not resolved'}
if(GetOptiShadeSteamLaunchUri (Join-Path $game 'X-Plane.exe')){throw 'Vulkan route changed'}
[IO.File]::WriteAllText($manifest,'"AppState" { "appid" "2537591" "installdir" "MSFS2024" }')
if(GetOptiShadeSteamLaunchUri $exe){throw 'Mismatched app ID accepted'}
[IO.File]::WriteAllText($manifest,'"AppState" { "appid" "2537590" "installdir" "MSFS2024 other" }')
if(GetOptiShadeSteamLaunchUri $exe){throw 'Other game accepted'}
[IO.File]::WriteAllText($manifest,'"AppState" { "appid" "2537590" "installdir" "MSFS2024" }')
$xr=Join-Path $game 'OptiShadeData/OpenXR';[void][IO.Directory]::CreateDirectory($xr);[IO.File]::WriteAllText((Join-Path $xr 'OptiShade_XR.json'),'{}')
if(GetOptiShadeSteamLaunchUri $exe){throw 'Process-scoped OpenXR route changed'}
'PASS Steam matching manifest, different game, mismatched ID, Vulkan and OpenXR route preservation.'
