$ErrorActionPreference='Stop'
. "$PSScriptRoot/ownership.ps1"

$root=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-LoaderMigrationTest-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $root 'Game';$state=Join-Path $root 'State'
[void][IO.Directory]::CreateDirectory($game);[void][IO.Directory]::CreateDirectory((Join-Path $state 'Backups'))
try{
    $installed='OptiShade proxy bytes';$original='Original game loader bytes'
    $loader=Join-Path $game 'winmm.dll';$backup=Join-Path $state 'Backups/original-winmm'
    [IO.File]::WriteAllText($loader,$installed);[IO.File]::WriteAllText($backup,$original)
    $manifest=[pscustomobject]@{Game=$game;Files=@([pscustomobject]@{Path='winmm.dll';SourcePath='winmm.dll';Hash=(HashFile $loader);PreviousHash=(HashFile $backup);Backup='Backups/original-winmm'})}

    $plan=@(GetOptiShadeLoaderMigrationPlan $manifest $game $state 'dxgi.dll')
    if($plan.Count -ne 1 -or -not $plan[0].RestoreNeeded -or $plan[0].Path -ne 'winmm.dll'){throw 'A changed installation method did not plan to restore the verified prior loader.'}
    if((GetOptiShadeLoaderMigrationPlan $manifest $game $state 'winmm.dll').Count){throw 'The selected loader was incorrectly marked for retirement.'}

    [IO.File]::WriteAllText($loader,$original)
    $alreadyRestored=@(GetOptiShadeLoaderMigrationPlan $manifest $game $state 'dxgi.dll')
    if($alreadyRestored.Count -ne 1 -or $alreadyRestored[0].RestoreNeeded){throw 'An already restored original loader was not safely recognized.'}

    [IO.File]::WriteAllText($loader,'A different third-party loader')
    $modifiedRejected=$false
    try{$null=GetOptiShadeLoaderMigrationPlan $manifest $game $state 'dxgi.dll'}catch{$modifiedRejected=$true}
    if(-not $modifiedRejected){throw 'A modified loader was accepted for migration.'}

    $manifest.Files+=@([pscustomobject]@{Path='winmm.dll';SourcePath='winmm.dll';Hash='different';PreviousHash=(HashFile $backup);Backup='Backups/original-winmm'})
    $duplicateRejected=$false
    try{$null=GetOptiShadeLoaderMigrationPlan $manifest $game $state 'dxgi.dll'}catch{$duplicateRejected=$true}
    if(-not $duplicateRejected){throw 'Conflicting duplicate loader receipt entries were accepted.'}

    Write-Output 'Loader migration ownership tests passed.'
}finally{
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
