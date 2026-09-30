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
$blocked=$false;try{AssertOptiShadeDownloadChannel 'beta' $store}catch{$blocked=$true}
if(-not $blocked){throw 'Beta download allowed without opt-in'}
AssertOptiShadeDownloadChannel 'stable' $store
[IO.File]::WriteAllText((Join-Path $store 'beta-updates.txt'),'opted in')
AssertOptiShadeDownloadChannel 'beta' $store
'PASS: beta download requires explicit opt-in; stable remains available'
# Manager EXEs remain mapped while the old launcher cleans up extracted files.
Set-Content $old 'closing beta manager';$closingHash=(Get-FileHash $old).Hash
$ready=Join-Path $root 'lock-ready'
$job=Start-Job -ArgumentList $old,$ready -ScriptBlock {
 param($file,$ready)
 $handle=[IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 try{[IO.File]::WriteAllText($ready,'ready');Start-Sleep -Seconds 4}finally{$handle.Dispose()}
}
try{
 $clock=[Diagnostics.Stopwatch]::StartNew()
 while(-not(Test-Path $ready)){if($clock.Elapsed.TotalSeconds -gt 15){throw 'Lock fixture failed'};Start-Sleep -Milliseconds 50}
 $script:pumps=0
 $notice=CompleteOptiShadeManagerUpdate $old $closingHash $new $newHash $store stable {$script:pumps++}
 if($notice -or (Test-Path $old) -or $script:pumps -eq 0){throw 'Delayed previous-manager shutdown left the beta EXE behind'}
 'PASS: locked beta EXE is removed after delayed shutdown; progress callback remains active'
}finally{Wait-Job $job -Timeout 10|Out-Null;Remove-Job $job -Force}

# A matching file reached through a junction is not an owned deletion target.
$physical=Join-Path $root 'Physical';$linked=Join-Path $root 'Linked'
[void][IO.Directory]::CreateDirectory($physical)
$protected=Join-Path $physical 'Protected.exe';Set-Content -LiteralPath $protected 'keep linked target'
$protectedHash=(Get-FileHash -LiteralPath $protected).Hash
New-Item -ItemType Junction -Path $linked -Target $physical|Out-Null
$notice=CompleteOptiShadeManagerUpdate (Join-Path $linked 'Protected.exe') $protectedHash $new $newHash $store stable
if(-not $notice -or (Get-FileHash -LiteralPath $protected).Hash -ne $protectedHash){throw 'Linked previous-manager ancestor was not protected'}
'PASS: linked ancestor preserves a matching previous EXE'
