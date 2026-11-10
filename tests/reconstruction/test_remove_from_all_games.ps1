$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/library.ps1"
# Settings > Remove OptiShade from all games: every recorded game is restored with
# the real restore, and the OptiShade app's own data stays.
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-allgames-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
function GetShaderRecoveryRoot { Join-Path $testRoot 'recovery' }
$script:closed=@()
function AssertClosed([string]$Game){
 if((Test-Path -LiteralPath $Game) -and -not(Test-Path -LiteralPath (Join-Path $Game 'fixture-only.txt'))){throw 'Cleanup attempted a non-fixture game.'}
 $script:closed+=,$Game
 if(Test-Path -LiteralPath (Join-Path $Game 'fixture-running')){throw 'Fixture game is running.'}
}
function Check($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Fixture([string]$Name,[string]$Store){
 $game=Join-Path $testRoot ($Name+'/game');[void][IO.Directory]::CreateDirectory((Join-Path $game 'OptiShadeData/Presets'))
 $receipt=ManifestPath $Store $game;$folder=Split-Path $receipt
 [void][IO.Directory]::CreateDirectory((Join-Path $folder 'Backups'))
 $loader=Join-Path $game 'dxgi.dll';$original=Join-Path $folder 'Backups/original-loader';$preset=Join-Path $game 'OptiShadeData/Presets/my-look.ini'
 [IO.File]::WriteAllText((Join-Path $game 'fixture-only.txt'),'isolated ownership fixture')
 [IO.File]::WriteAllText((Join-Path $game 'Game.exe'),'unchanged game executable fixture')
 [IO.File]::WriteAllText($loader,'OptiShade loader '+$Name);[IO.File]::WriteAllText($original,'original game loader '+$Name);[IO.File]::WriteAllText($preset,'user saved look '+$Name)
 WriteState ([pscustomobject]@{Game=$game;Status='Installed';Version=(GetBundledOptiShadeVersion);OwnedDirectories=@('OptiShadeData');Components=@();Files=@(
  [pscustomobject]@{Path='dxgi.dll';SourcePath='winmm.dll';Hash=(HashFile $loader);PreviousHash=(HashFile $original);Backup='Backups/original-loader';Mutable=$false;Retained=$false},
  [pscustomobject]@{Path='OptiShadeData/Presets/my-look.ini';SourcePath='';Hash=(HashFile $preset);PreviousHash='';Backup='';Mutable=$true;Retained=$false}
 )}) $receipt
 return [pscustomobject]@{Game=$game;Loader=$loader;Preset=$preset;OriginalHash=(HashFile $original)}
}
try{
 foreach($keep in $true,$false){
  $store=Join-Path $testRoot ('store-'+$keep+'/OptiShade');[void][IO.Directory]::CreateDirectory($store)
  $settings=Join-Path $store 'manager-interface.json';[IO.File]::WriteAllText($settings,'{"Theme":"Dark"}')
  $games=@((Fixture ('first-'+$keep) $store),(Fixture ('second-'+$keep) $store))
  $script:closed=@()
  $result=RemoveOptiShadeFromAllGames $store -KeepPresets $keep
  Check ($result.Games -eq 2) ('expected 2 games, got '+$result.Games)
  Check ($script:closed.Count -ge 2 -and (@($script:closed[0],$script:closed[1])|Sort-Object) -join '|' -ceq (@($games.Game)|Sort-Object) -join '|') 'every game must be checked as closed before any game is restored'
  foreach($g in $games){
   Check ((HashFile $g.Loader) -ceq $g.OriginalHash) ('the original loader was not restored in '+$g.Game)
   Check ([IO.File]::ReadAllText((Join-Path $g.Game 'Game.exe')) -ceq 'unchanged game executable fixture') 'the game executable changed'
   Check ((Test-Path -LiteralPath $g.Preset) -eq $keep) ('saved look kept='+(Test-Path -LiteralPath $g.Preset)+' but KeepPresets='+$keep)
  }
  Check (Test-Path -LiteralPath $settings) 'the OptiShade app data was removed; only games should change'
  $again=RemoveOptiShadeFromAllGames $store -KeepPresets $keep
  Check ($again.Games -eq 0) 'already-restored games were restored again'
 }
 'PASS: Remove from all games restores every recorded game, honours Keep saved looks, keeps the app data, and is a no-op the second time'
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
