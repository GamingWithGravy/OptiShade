$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/update-lifecycle.ps1"
$root=Join-Path $env:TEMP ('OptiShade-update-lifecycle-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$old=Join-Path $root 'Old.exe';$new=Join-Path $root (GetOptiShadeManagerName '0.21.3-beta.2' 'beta');$store=Join-Path $root 'Store'
Set-Content $old 'old manager';Set-Content $new 'new manager'
$oldHash=(Get-FileHash $old).Hash;$newHash=(Get-FileHash $new).Hash
$notice=CompleteOptiShadeManagerUpdate $old $oldHash $new $newHash $store 'beta'
if($notice -or (Test-Path $old) -or -not(Test-Path "$store/beta-updates.txt")){throw 'Successful beta switch did not replace the previous manager and persist beta'}
Set-Content $old 'changed manager'
$notice=CompleteOptiShadeManagerUpdate $old $oldHash $new $newHash $store 'stable'
if(-not(Test-Path $old) -or -not $notice -or (Test-Path "$store/beta-updates.txt")){throw 'Stable switch must reset beta and preserve a changed old EXE'}
$failed=$false;try{CompleteOptiShadeManagerUpdate $old $oldHash $new ('0'*64) $store 'beta'}catch{$failed=$true}
if(-not $failed -or (Test-Path "$store/beta-updates.txt") -or -not(Test-Path $old)){throw 'Failed verification changed channel or removed old manager'}
'PASS: successful replacement, stable opt-out, changed-file protection and failed verification'
