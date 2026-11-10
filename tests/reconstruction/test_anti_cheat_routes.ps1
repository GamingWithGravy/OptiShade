param([string]$Installer=(Join-Path $PSScriptRoot '../../Beta/installer'))
$ErrorActionPreference='Stop'
foreach($file in @('ownership','components','mfg','sm86-mfg','nvidia','neural-download','effects','import-effects','recovery','auto-compatibility')){
 $scriptPath=Join-Path $Installer ($file+'.ps1')
 . $scriptPath
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-ConsentRoutes-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $temp 'game';[void][IO.Directory]::CreateDirectory((Join-Path $game 'EasyAntiCheat'))
$oldStore=$env:OPTISHADE_STORE;$env:OPTISHADE_STORE=Join-Path $temp 'state'
$record=ManifestPath $env:OPTISHADE_STORE $game;[void][IO.Directory]::CreateDirectory((Split-Path $record -Parent));$exe=Join-Path $game 'game.exe'
[IO.File]::WriteAllText($exe,'fixture executable')
@{Game=$game;Status='Installed';LaunchExe=$exe;Files=@()}|ConvertTo-Json|Set-Content -LiteralPath $record
$original=[IO.File]::ReadAllText($record)
$script:AntiCheatDecision=$null;$script:AntiCheatOperation=$null
$coreStore=Join-Path $temp 'core-store'
$routes=[ordered]@{
 'Core install/repair'={InstallFusion $game 'missing-payload' $coreStore 'fixture.exe' -Executable $exe}
 'NR import'={ImportNrRuntime $record 'missing-model'}
 'Addon payload'={InstallAddonPayload $record 'missing-payload' 'Neural'}
 'Addon dispatch'={InstallOptiShadeAddon $record 'missing-payload' 'Neural' $null $null}
 'OptiMFG component'={InstallOptiShadeAddon $record 'missing-payload' 'OptiMfg' $null $null}
 'MFG dispatch'={InstallOptionalMfg $record 'missing-payload' @('NVIDIA GeForce RTX 4090')}
 'Legacy MFG'={InstallLegacyMfg $record 'missing-payload' @('NVIDIA GeForce RTX 4090')}
 'Source MFG'={InstallSourceMfg $record 'missing-payload' @('NVIDIA GeForce RTX 4090')}
 'SM86 MFG'={InstallSm86Mfg $record @('NVIDIA GeForce RTX 3090') $null}
 'NVIDIA runtime'={InstallNvidia $game}
 'Neural download'={EnsureNeuralRuntime $record $null}
 'All effects'={InstallAllEffects $game 'missing-catalogue'}
 'Imported effects'={ImportEffectsArchive 'missing-archive' $game}
 'Preset dependencies'={InstallPresetDependencies 'missing-preset' $game 'missing-catalogue'}
 'Cinema effects'={InstallFusionCinema $game}
 'Auto preparation'={InvokeOptiShadeAutoPreparation $record 'missing-payload' $null}
}
try{
 foreach($route in $routes.GetEnumerator()){
  $message='';try{& $route.Value}catch{$message=$_.Exception.Message}
  if($route.Key -eq 'MFG dispatch'){if($message -ne 'The legacy OptiShade MFG installer is retired. Install OptiMFG instead.'){throw ('Retired dispatcher must refuse: '+$message)}}elseif($message -notlike '*UserConsentRequired*'){throw ($route.Key+' did not defer to consent: '+$message)}
  if([IO.File]::ReadAllText($record) -ne $original -or @((Get-ChildItem -LiteralPath $game -File -Recurse|Where-Object FullName -ne $exe)).Count -ne 0){throw ($route.Key+' mutated fixture before consent')}
  Write-Output ('PASS: '+$route.Key+' defers before writes')
 }
}finally{
 $env:OPTISHADE_STORE=$oldStore
 # Retain this small isolated fixture for review; no real game was used.
 Write-Output ('Fixture: '+$temp)
}
