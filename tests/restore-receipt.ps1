$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
function AssertClosed($Game){}
$fixture=Join-Path $env:TEMP ('OptiShade-receipt-restore-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $fixture 'Game';$payload=Join-Path $fixture 'Payload';$store=Join-Path $fixture 'Store'
New-Item -ItemType Directory -Path $game,"$payload/OptiShadeData" -Force|Out-Null
Set-Content "$payload/winmm.dll" 'loader'
Set-Content "$payload/OptiShadeData/Effects-install.json" '[]'
@(Get-ChildItem $payload -Recurse -File|ForEach-Object {@{Path=$_.FullName.Substring($payload.Length+1);Hash=(HashFile $_.FullName)}})|ConvertTo-Json|Set-Content "$payload/files.json"
$mp=InstallFusion $game $payload $store "$fixture/setup.exe"
$m=Get-Content $mp -Raw|ConvertFrom-Json
$receipt=@($m.Files|Where-Object Path -like '*Effects-install.json')[0]
if(-not $receipt.Mutable){throw 'New receipt must be mutable'}
'PASS: new installations mark the FX receipt mutable'
# Reproduce the user's old manifest, then the installer's legitimate receipt update.
$receipt.Mutable=$false;WriteState $m $mp
Set-Content "$game/OptiShadeData/Effects-install.json" '[{"Status":"Installed"}]'
Set-Content "$game/winmm.dll" 'unexpected binary change'
try{RestoreFusion $mp;throw 'Unexpected restore'}catch{if($_.Exception.Message -notlike '*file changed after installation: winmm.dll*'){throw}}
'PASS: modified binaries still block Restore'
Copy-Item -LiteralPath "$payload/winmm.dll" -Destination "$game/winmm.dll" -Force
Copy-Item -LiteralPath "$payload/winmm.dll" -Destination "$game/dxgi.dll" -Force
Set-Content "$game/version.dll" 'unrelated loader'
RestoreFusion $mp
if((Get-Content $mp -Raw|ConvertFrom-Json).Status -ne 'Restored'){throw 'Legacy receipt blocked Restore'}
'PASS: legacy manifest with changed FX receipt restores successfully'
if(Test-Path "$game/dxgi.dll"){throw 'Duplicate OptiShade loader remained'}
if((Get-Content "$game/version.dll") -ne 'unrelated loader'){throw 'Unrelated loader changed'}
'PASS: duplicate known loader removed; unrelated proxy kept'
Copy-Item -LiteralPath "$payload/winmm.dll" -Destination "$game/dxgi.dll" -Force
RestoreFusion $mp
if(Test-Path "$game/dxgi.dll"){throw 'Restored status skipped leftover loader'}
'PASS: already-restored installations recheck remaining known loaders'
$saved=Join-Path (Split-Path $mp) 'PreRestoreDiagnostics.json'
if(-not(Test-Path -LiteralPath $saved)){throw 'Restore did not preserve diagnostics'}
$e=Get-Content -LiteralPath $saved -Raw|ConvertFrom-Json
if($e.Context -notmatch 'before Restore' -or -not $e.Captured){throw 'Snapshot lacks historical context'}
if(-not($e.Files|Where-Object {$_.Path -eq 'winmm.dll' -and $_.Bytes -gt 0})){throw 'Snapshot missed installed loader before removal'}
$before=[IO.File]::ReadAllText($saved)
RestoreFusion $mp
if([IO.File]::ReadAllText($saved) -ne $before){throw 'Repeat restore overwrote useful evidence'}
'PASS: pre-restore installed evidence survives cleanup and repeated Restore'
