$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
$fixture=Join-Path $env:TEMP ('OptiShade-replace-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'Game';$payload=Join-Path $fixture 'Payload';$store=Join-Path $fixture 'OptiShade'
New-Item -ItemType Directory -Path $game,$payload -Force|Out-Null
$installer=Join-Path $fixture 'installer.exe';Set-Content $installer 'fixture'
Set-Content (Join-Path $payload 'winmm.dll') 'new loader'
@(@{Path='winmm.dll';Hash=(HashFile (Join-Path $payload 'winmm.dll'))})|ConvertTo-Json|Set-Content (Join-Path $payload 'files.json')
$names=@('dxgi.dll','renodx-dlss5.addon64','dlss5-feed.addon64','dlss5-lab-overlay-example.addon64')
$original=@{}
foreach($name in $names){Set-Content (Join-Path $game $name) ('original '+$name);$original[$name]=HashFile (Join-Path $game $name)}
Set-Content (Join-Path $game 'unrelated.addon64') 'keep';Set-Content (Join-Path $game 'ReShadePreset.ini') 'user preset'
function Assert($ok,$label){if(-not $ok){throw "FAIL: $label"};"PASS: $label"}
$conflicts=@(FindFusionConflicts $game)
Assert ($conflicts.Count -eq 4) 'Known external addons plus unidentified loader listed'
$blocked=$false;try{InstallFusion $game $payload $store $installer 'dxgi.dll'}catch{$blocked=$true}
Assert $blocked 'Replacement needs explicit listed-file consent'
foreach($name in $names){Assert ((HashFile (Join-Path $game $name)) -eq $original[$name]) "Decline preserves $name"}
$stale=@($conflicts|ForEach-Object{[pscustomobject]@{Path=$_.Path;Hash='stale'}})
$blocked=$false;try{InstallFusion $game $payload $store $installer 'dxgi.dll' $stale}catch{$blocked=$true}
Assert $blocked 'Changed files invalidate approval'
$mp=InstallFusion $game $payload $store $installer 'dxgi.dll' $conflicts
Assert ((HashFile (Join-Path $game 'dxgi.dll')) -eq (HashFile (Join-Path $payload 'winmm.dll'))) 'Approved proxy overwritten after backup'
foreach($name in $names|Where-Object {$_ -like '*.addon64'}){Assert (-not(Test-Path (Join-Path $game $name))) "Conflicting add-on disabled: $name"}
Assert (Test-Path (Join-Path $game 'unrelated.addon64')) 'Unrelated add-on left untouched'
Assert ((Get-Content (Join-Path $game 'ReShadePreset.ini')) -eq 'user preset') 'User preset left untouched'
RestoreFusion $mp
foreach($name in $names){Assert ((HashFile (Join-Path $game $name)) -eq $original[$name]) "Restore recovers $name byte for byte"}
$mp=InstallFusion $game $payload $store $installer 'dxgi.dll' @(FindFusionConflicts $game)
UninstallFusion $store $installer
foreach($name in $names){Assert ((HashFile (Join-Path $game $name)) -eq $original[$name]) "Uninstall recovers $name byte for byte"}
"Fixture: $fixture"
