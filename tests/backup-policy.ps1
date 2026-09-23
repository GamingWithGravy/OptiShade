$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/ownership.ps1"
function AssertClosed($Game){}
$f=Join-Path $env:TEMP ('OptiShade-backup-policy-'+[guid]::NewGuid().ToString('N'))
$g=Join-Path $f 'Game';$p=Join-Path $f 'Payload';$store=Join-Path $f 'Store'
New-Item -ItemType Directory -Path $g,$p -Force|Out-Null
Set-Content "$p/winmm.dll" 'new-loader';Set-Content "$g/ReShade64.dll" 'old-reshade';Set-Content "$g/nvngx_dlssnr.dll" 'old-model';Set-Content "$g/dxgi.dll" 'genuine-original'
@(@{Path='winmm.dll';Hash=(HashFile "$p/winmm.dll")})|ConvertTo-Json|Set-Content "$p/files.json"
$mp=InstallFusion $g $p $store "$f/setup.exe" 'dxgi.dll' @(FindFusionConflicts $g)
$m=Get-Content $mp -Raw|ConvertFrom-Json
if(@($m.Files|Where-Object Backup).Count -ne 3){throw 'Original graphics files were not all backed up'}
if(Test-Path "$g/ReShade64.dll"){throw 'Conflicting ReShade retained'}
if(Test-Path "$g/nvngx_dlssnr.dll"){throw 'Conflicting NR retained'}
# Simulate contaminated legacy receipt, including an obsolete app engine file.
$folder=Split-Path $mp;Set-Content "$folder/Backups/legacy-mod" 'old-reshade'
$m.Files+=@{Path='ReShade.ini';SourcePath='';Hash='';PreviousHash=(HashFile "$folder/Backups/legacy-mod");Backup='Backups/legacy-mod';Mutable=$true}
WriteState $m $mp
$mp=InstallFusion $g $p $store "$f/setup.exe" 'dxgi.dll' @(FindFusionConflicts $g) -ReplaceExisting $true
if(-not(Test-Path "$folder/Backups/legacy-mod")){throw 'Verified legacy backup discarded'}
if(@(Get-ChildItem "$folder/Backups" -File -Recurse).Count -ne 4){throw 'Original backup chain was not preserved'}
RestoreFusion $mp
if((Get-Content "$g/dxgi.dll") -ne 'genuine-original'){throw 'Original loader not restored'}
foreach($mod in @('ReShade64.dll','ReShade.ini','nvngx_dlssnr.dll')){if(-not(Test-Path "$g/$mod")){throw "Original mod not restored: $mod"}}
'PASS: clean original backup survives upgrades; third-party originals and verified legacy backups are restored'
