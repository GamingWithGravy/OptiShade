$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/compatibility.ps1"
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('optishade-launch-identity-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
[IO.File]::WriteAllText((Join-Path $fixture 'FlightSimulator2024.exe'),'protected PE contents not needed')
$helper=Join-Path $fixture 'gamelaunchhelper.exe'
if((GetOptiShadeMethodRendererApi 'auto' 'winmm.dll' @() -Executable $helper) -ne 'DirectX'){throw 'Xbox MSFS helper mislabelled Vulkan'}
if((GetOptiShadeMethodRendererApi 'auto' 'winmm.dll' @() -Executable (Join-Path $fixture 'FlightSimulator2024.exe')) -ne 'DirectX'){throw 'MSFS renderer mislabelled Vulkan'}
if((GetOptiShadeMethodRendererApi 'auto' 'winmm.dll' @('Vulkan') -Executable (Join-Path $fixture 'X-Plane.exe')) -ne 'Vulkan'){throw 'X-Plane Vulkan route regressed'}
if((GetOptiShadeMethodRendererApi 'auto' 'dxgi.dll' @('DX9')) -ne 'DirectX'){throw 'DX9 translation route regressed'}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Beta/installer/manager.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'StartManagerAutoSession'},$true)
Invoke-Expression $node.Extent.Text
$message=''
try {StartManagerAutoSession ([pscustomobject]@{Status='Installing';Game=$fixture}) -ObserveOnly}catch{$message=$_.Exception.Message}
if($message -notmatch "recorded status='Installing'" -or -not $message.Contains($fixture)){throw 'Rejected receipt did not report its actual status and game'}
'PASS: MSFS helper/renderer, Vulkan and translation routes, manager syntax, actionable receipt rejection.'
Write-Output ('Fixture retained: '+$fixture)
