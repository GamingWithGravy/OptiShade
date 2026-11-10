param([string]$CrashFixture='',[ValidateSet('legacy','source','remove')][string]$CrashAction='legacy')
$ErrorActionPreference='Stop'
. "$PSScriptRoot/fixtures/windows_pe.ps1"
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'Beta/installer/ownership.ps1')
. (Join-Path $root 'Beta/installer/mfg.ps1')
. (Join-Path $root 'Beta/installer/components.ps1')
$script:fixtureMfgImportReader=${function:GetOptiShadeExecutableIdentity}
function GetOptiShadeExecutableIdentity([string]$File){
 $identity=& $script:fixtureMfgImportReader $File
 if($script:fixtureMfgImports){$identity.Imports=@($script:fixtureMfgImports)}
 return $identity
}
$script:testRoot=if($CrashFixture){Split-Path $CrashFixture}else{Join-Path ([IO.Path]::GetTempPath()) ('optishade-mfg-selection-'+[guid]::NewGuid().ToString('N'))}
$fixturePreviousLocalAppData=$env:LOCALAPPDATA;$env:LOCALAPPDATA=$script:testRoot
$script:legacyFixtureBytes='fixture legacy only; never loaded';$script:sourceFixtureBytes='fixture source only; never loaded'
$script:expectedHash='E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'
function AssertClosed([string]$Game){if(-not(Test-Path -LiteralPath (Join-Path $Game 'fixture-only.txt'))){throw 'Not an isolated MFG fixture.'}}
function OwnedPath([string]$Root,[string]$Relative){
 $base=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar;$target=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
 if(-not $target.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture path escaped its root.'}
 $check=$target;while($check){if((Test-Path -LiteralPath $check) -and ((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked fixture refused.'};$next=Split-Path $check -Parent;if($next -eq $check){break};$check=$next};return $target
}
function HashFile([string]$Path){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return ''}
 # These two exact data byte sequences stand in for production release pins.
 # Their identity follows verified journal copies, never an assumed filename.
 $content=[IO.File]::ReadAllText($Path)
 if($content -ceq $script:legacyFixtureBytes){return $script:expectedHash}
 if($content -ceq $script:sourceFixtureBytes){return $script:SourceMfgSha256.ToUpperInvariant()}
 return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}
$script:AntiCheatOperation=@{Name='provider fixture';Accepted=@{}}
# This lifecycle fixture assumes the launcher-wide agreement has already
# been accepted. Refusal paths are tested independently by anti-cheat tests.
$script:AntiCheatSessionAccepted=$true
$script:fixtureGpu=[pscustomobject]@{Complete=$true;Adapters=@([pscustomobject]@{Name='NVIDIA GeForce RTX 4090';Luid='40';VendorId=0x10DE;DeviceId=0x2684;SubSystemId=1;Software=$false;ComputeCapabilityKnown=$true;ComputeMajor=8;ComputeMinor=9;Family=40;DriverVersion='fixture'})}
$script:mfgEvidenceLogs=[Collections.Generic.List[string]]::new()
function WriteInstallerLog([string]$Message){$script:mfgEvidenceLogs.Add($Message)}
function InvokeFixtureAction($f,[string]$Action){
 $script:AntiCheatOperation.Accepted[('installation|'+[IO.Path]::GetFullPath($f.Game).TrimEnd('\').ToLowerInvariant())]=$true
 switch($Action){'legacy'{InstallLegacyMfg $f.Manifest $f.Payload $script:fixtureGpu};'source'{InstallSourceMfg $f.Manifest $f.Payload $script:fixtureGpu};'remove'{RemoveOptiShadeAddon $f.Manifest 'Mfg'}}
}
if($CrashFixture){
 $script:fixtureMfgImports=@('d3d12.dll')
 $f=[pscustomobject]@{Game=(Join-Path $CrashFixture 'game');Manifest=(Join-Path $CrashFixture 'manifest.json');Payload=(Join-Path $CrashFixture 'payload')}
 $realWrite=${function:WriteState};$script:crashReceipt=$f.Manifest
 function WriteState($Value,[string]$Path){if($Path -eq $script:crashReceipt){[Environment]::Exit(92)};& $realWrite $Value $Path}
 InvokeFixtureAction $f $CrashAction
 throw 'Provider crash injection did not reach receipt commit.'
}
[void][IO.Directory]::CreateDirectory($script:testRoot);$script:assertions=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:assertions++}
$providerGuidance=GetOptiShadeMfgPreparationMessage 'unsupported_game'
Check ($providerGuidance -notmatch 'unsupported_game' -and $providerGuidance -match 'OptiShade can prepare MFG' -and $providerGuidance -match 'activation requires a compatible live DLSS Frame Generation provider' -and $providerGuidance -match 'game/provider compatibility limitation, not an OptiShade installation failure' -and $providerGuidance -match 'If you expected the game to support MFG, or are unsure' -and $providerGuidance -match 'send diagnostics to the Discord channel') 'MFG preparation guidance must separate installation from live activation, identify the current game/provider blocker, and offer diagnostics when support is expected or unclear.'
$managerSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../Beta/installer/manager.ps1'))
Check ($managerSource.Contains('if($x86Only -and $id -in @(''Cockpit'',''Providers''))') -and -not $managerSource.Contains('if($x86Only -and $id -in @(''Mfg'',''Cockpit'',''Providers''))') -and $managerSource.Contains('if($x86Only -and $id -eq ''Mfg'')') -and $managerSource.Contains('provider needs 64-bit game') -and $managerSource.Contains('No provider files are installed for a 32-bit renderer')) 'The Components page must keep MFG selectable independently of compatibility classification and clearly state when 32-bit architecture prevents provider installation.'
Check ($managerSource.Contains('$selector.IsEnabled=if($id -eq ''Mfg'')') -and $managerSource.Contains('negative install-time compatibility result disable its card')) 'A stale compatibility scan must not disable the MFG component selector.'
Check ($managerSource.Contains('MFG is selected for an in-game compatibility check. Setup could not establish the live provider in advance') -and $managerSource.Contains('$mfgDecision -eq ''deferred'' -or $componentResult -match ''in-game''')) 'A deferred MSFS/game-provider result must report the staged MFG selection instead of leaving a stale setup-time warning.'
$ambiguousGuidance=GetOptiShadeMfgPreparationMessage 'ambiguous_adapter'
Check ($ambiguousGuidance -match 'which NVIDIA adapter is rendering' -and $ambiguousGuidance -match 'No provider files were changed') 'Ambiguous-adapter provider diagnostics must explain the rendering-GPU issue without changing files.'
$integratedGuidance=GetOptiShadeMfgPreparationMessage 'unsupported_hardware'
Check ($integratedGuidance -match 'not an NVIDIA RTX GPU' -and $integratedGuidance -match 'High performance' -and $integratedGuidance -match 'No provider files were changed') 'A selected AMD/Intel renderer did not receive safe, actionable MFG guidance.'
$integrated= [pscustomobject]@{Name='AMD Radeon(TM) Graphics';Luid='99';VendorId=0x1002;DeviceId=0x164E;SubSystemId=1;Software=$false;ComputeCapabilityKnown=$false;ComputeMajor=0;ComputeMinor=0;Family=0;DriverVersion='fixture'}
$hybridGpu=[pscustomobject]@{Complete=$true;Adapters=@($script:fixtureGpu.Adapters[0],$integrated)}
$mfgCandidate=ResolveOptiShadeMfgAdapter $hybridGpu
Check ($mfgCandidate.State -eq 'candidate' -and [string]$mfgCandidate.Adapter.Luid -ceq '40' -and [uint32]$mfgCandidate.Adapter.VendorId -eq 0x10DE) 'Integrated AMD graphics displaced the measured NVIDIA MFG preparation candidate.'
$amdRendering=[pscustomobject]@{Complete=$true;Adapters=@($script:fixtureGpu.Adapters[0],$integrated);PreferredRenderingLuid='99'}
$mfgRenderer=ResolveOptiShadeMfgAdapter $amdRendering
Check ($mfgRenderer.State -ne 'candidate') 'A live AMD rendering LUID was mapped to an NVIDIA MFG provider candidate.'
function Fixture([string]$Name){
 $folder=Join-Path $script:testRoot $Name;$game=Join-Path $folder 'game';$payload=Join-Path $folder 'payload'
 [void][IO.Directory]::CreateDirectory($game);[void][IO.Directory]::CreateDirectory((Join-Path $payload 'OptiShadeData/MFG'))
 WriteOptiShadeFixtureExecutable (Join-Path $game 'FlightSimulator2024.exe');[IO.File]::WriteAllText((Join-Path $game 'fixture-only.txt'),'fixture')
 [IO.File]::WriteAllText((Join-Path $game 'OptiScaler.ini'),"[FrameGen]`r`nExternal=false`r`n[DLSSG]`r`nAdaMfgUnlock=false`r`nAmpereMfgUnlock=false`r`n")
 [IO.File]::WriteAllText((Join-Path $payload 'OptiShadeData/MFG/RTXMFG.dll'),$script:legacyFixtureBytes)
 [IO.File]::WriteAllText((Join-Path $payload 'OptiShadeData/MFG/OptiShadeMFG.dll'),$script:sourceFixtureBytes)
 WriteState ([pscustomobject]@{abi=131072;sha256=$script:SourceMfgSha256;families=@(40)}) (Join-Path $payload 'OptiShadeData/MFG/source-build.json')
 $manifest=Join-Path $folder 'manifest.json'
 WriteState ([pscustomobject]@{Status='Installed';Game=$game;LaunchExe=(Join-Path $game 'FlightSimulator2024.exe');Architecture='x64';RouteDLL='OptiShadeMSFS2024.dll';Components=@('Effects','Providers');Files=@();OptionalMfg=$false;SourceMfg=$false}) $manifest
 return [pscustomobject]@{Folder=$folder;Game=$game;Manifest=$manifest;Payload=$payload}
}
function CaptureFixture($f){
 $gameHashes=@{};foreach($file in @(Get-ChildItem -LiteralPath $f.Game -Recurse -File)){$gameHashes[$file.FullName]=HashFile $file.FullName}
 return [pscustomobject]@{Receipt=(HashFile $f.Manifest);Files=$gameHashes}
}
function CheckRestored($f,$before){
 Check ((HashFile $f.Manifest) -ceq $before.Receipt) 'Complete provider receipt was not restored.'
 $after=@(Get-ChildItem -LiteralPath $f.Game -Recurse -File);Check ($after.Count -eq $before.Files.Count) 'Interrupted provider left extra or missing game files.'
 foreach($file in $after){Check ($before.Files.ContainsKey($file.FullName) -and (HashFile $file.FullName) -ceq $before.Files[$file.FullName]) ('Provider recovery did not restore '+$file.Name)}
 Check (-not(Test-Path -LiteralPath (Join-Path $f.Folder 'MfgRouteTransaction.json'))) 'Recovered provider left an active journal.'
}
try{
 $target=Fixture 'selected-import';$manifest=ReadOptiShadeState $target.Manifest;$generic=Join-Path $target.Game 'Generic.exe';WriteOptiShadeFixtureExecutable $generic;$manifest.LaunchExe=$generic;$manifest.RouteDLL='OptiShade.dll'
 $actualReader=${function:GetOptiShadeExecutableIdentity};$script:readImportTarget=''
 function GetOptiShadeExecutableIdentity([string]$File){$script:readImportTarget=$File;$value=& $actualReader $File;$value.Imports=@('dinput8.dll');return $value}
 try{$loader=SelectOptionalMfgLoader $manifest;Check ($script:readImportTarget -ceq $generic -and $loader.Name -ceq 'dinput8.dll') 'MFG proxy selection borrowed a sibling simulator EXE instead of the selected renderer.'}finally{Set-Item Function:GetOptiShadeExecutableIdentity $actualReader}
 $script:fixtureMfgImports=@('d3d12.dll')
 # The manual component action must stage a valid provider for a generic x64
 # game before it has exposed any live DLSS-G capability. This exercises the
 # production preparation transaction rather than claiming runtime output.
 $generic=Fixture 'generic-preinstall';$genericExe=Join-Path $generic.Game 'GenericGame.exe';WriteOptiShadeFixtureExecutable $genericExe
 $genericRecord=ReadOptiShadeState $generic.Manifest;$genericRecord.LaunchExe=$genericExe;$genericRecord.RouteDLL='OptiShadeGeneric.dll';WriteState $genericRecord $generic.Manifest
 function GetOptiShadeUpdateChannel { return 'beta' }
 Check (-not(TestOptiShadeMfgPreparationGame (ReadOptiShadeState $generic.Manifest) $script:fixtureGpu)) 'The generic pre-install fixture unexpectedly had live DLSS-G capability.'
 InstallOptionalMfg $generic.Manifest $generic.Payload $script:fixtureGpu
 $genericInstalled=ReadOptiShadeState $generic.Manifest
 Check ($genericInstalled.SourceMfg -and -not $genericInstalled.OptionalMfg -and 'Mfg' -in @($genericInstalled.Components)) 'The generic manual MFG action did not stage its provider before live DLSS-G was observed.'
 $successEvidence=@($script:mfgEvidenceLogs|Where-Object {$_ -match 'MFG install evidence: outcome=prepared; providerDecision=source'})
 Check ($successEvidence.Count -eq 1 -and $successEvidence[0] -match 'OptiShadeMFG\.dll:matches-receipt:' -and $successEvidence[0] -match 'receiptSource=True') 'Successful MFG preparation did not log the selected provider, receipt, and on-disk provider hash relationship.'
 Check ($successEvidence[0] -notmatch [regex]::Escape($generic.Game)) 'MFG diagnostic evidence leaked the absolute game path.'
  # RTX 50 uses the live game provider. The selectable component must succeed
  # without demanding a duplicate provider DLL; runtime capability is checked
  # after the game exposes its own Streamline state.
  $native=Fixture 'native-mfg-selection';$nativeGpu=[pscustomobject]@{Complete=$true;Adapters=@([pscustomobject]@{Name='NVIDIA GeForce RTX 5090';Luid='50';VendorId=0x10DE;DeviceId=1;SubSystemId=1;Software=$false;ComputeCapabilityKnown=$true;ComputeMajor=12;ComputeMinor=0;Family=50;DriverVersion='fixture'})}
  $nativeBefore=CaptureFixture $native
  $nativeResult=InstallOptiShadeAddon $native.Manifest $native.Payload 'Mfg' $nativeGpu {}
  $nativeInstalled=ReadOptiShadeState $native.Manifest
  Check ($nativeResult -match 'checked in-game' -and $nativeInstalled.NativeMfg -and 'Mfg' -in @($nativeInstalled.Components) -and $nativeInstalled.ProviderPolicy.Evidence -ceq 'native_provider_checked_in_game') 'Native MFG selection was blocked or did not record its in-game activation check.'
  Check (-not $nativeInstalled.SourceMfg -and -not $nativeInstalled.OptionalMfg -and -not $nativeInstalled.Sm86Mfg -and -not(Test-Path (Join-Path $native.Game 'OptiShadeData/MFG/OptiShadeMFG.dll')) -and -not(Test-Path (Join-Path $native.Game 'version.dll'))) 'Native MFG selection installed a duplicate provider or guessed game loader.'
  $nativeAfter=CaptureFixture $native
  Check ($nativeBefore.Files.Count -eq $nativeAfter.Files.Count) 'Native MFG selection changed game files instead of recording the native route.'
  foreach($file in $nativeAfter.Files.Keys){Check ($nativeBefore.Files[$file] -ceq $nativeAfter.Files[$file]) 'Native MFG selection modified an existing game file.'}
  RemoveOptiShadeAddon $native.Manifest 'Mfg'
  Check ('Mfg' -notin @(GetOptiShadeAddonSelection (ReadOptiShadeState $native.Manifest)) -and -not(Test-Path (Join-Path $native.Game 'version.dll'))) 'Removing the native MFG selection changed the game provider or left a selected component.'
  # An unknown or unsupported x64 route stages only the pinned provider payload
  # as inert data; it must not inject a guessed proxy or activation descriptor.
  $deferred=Fixture 'deferred-mfg-selection';$deferredBefore=CaptureFixture $deferred;$decisionReader=${function:GetOptiShadeInstallProviderDecision}
  function GetOptiShadeInstallProviderDecision {return 'unsupported_hardware'}
  try{$deferredResult=InstallOptiShadeAddon $deferred.Manifest $deferred.Payload 'Mfg' $null {param($Message)} -ExplicitSelection}finally{Set-Item Function:GetOptiShadeInstallProviderDecision $decisionReader}
  $deferredInstalled=ReadOptiShadeState $deferred.Manifest
  Check ('Mfg' -in @($deferredInstalled.Components) -and $deferredInstalled.DeferredMfg -and $deferredInstalled.PreparedMfg -and $deferredInstalled.ProviderPolicy.Evidence -ceq 'prepared_waiting_for_supported_loader') 'Unknown/unsupported install-time discovery did not stage the inactive MFG payload.'
  Check ($deferredResult -match 'prepared inactive' -and -not $deferredInstalled.SourceMfg -and -not $deferredInstalled.OptionalMfg -and -not $deferredInstalled.Sm86Mfg) 'Deferred MFG preparation claimed an active provider without route proof.'
  Check ((HashFile (Join-Path $deferred.Game 'OptiShadeData/MFG/OptiShadeMFG.dll')) -ceq $script:SourceMfgSha256.ToUpperInvariant() -and -not(Test-Path (Join-Path $deferred.Game 'OptiShadeData/MFG/source-backend.json')) -and -not(Test-Path (Join-Path $deferred.Game 'version.dll'))) 'Deferred MFG preparation did not stage only the verified inactive payload.'
  $deferredAfter=CaptureFixture $deferred
  Check ($deferredBefore.Files.Count + 1 -eq $deferredAfter.Files.Count) 'Deferred MFG selection did not add exactly the staged payload.'
  RemoveOptiShadeAddon $deferred.Manifest 'Providers'
  $afterProviderRemoval=ReadOptiShadeState $deferred.Manifest
  Check ('Mfg' -in @($afterProviderRemoval.Components) -and $afterProviderRemoval.DeferredMfg -and $afterProviderRemoval.PreparedMfg -and 'Providers' -notin @($afterProviderRemoval.Components)) 'A prepared MFG selection incorrectly blocked removal of unrelated FSR/XeSS provider files.'
  $decisionReader=${function:GetOptiShadeInstallProviderDecision};function GetOptiShadeInstallProviderDecision {return 'native'}
  try{[void](InstallOptiShadeAddon $deferred.Manifest $deferred.Payload 'Mfg' $script:fixtureGpu {} -ExplicitSelection)}finally{Set-Item Function:GetOptiShadeInstallProviderDecision $decisionReader}
  $nativeAfterStage=ReadOptiShadeState $deferred.Manifest
  Check ($nativeAfterStage.NativeMfg -and -not $nativeAfterStage.PreparedMfg -and -not $nativeAfterStage.DeferredMfg -and -not(Test-Path (Join-Path $deferred.Game 'OptiShadeData/MFG/OptiShadeMFG.dll'))) 'Switching a prepared route to native MFG left the inactive payload behind.'
  $decisionReader=${function:GetOptiShadeInstallProviderDecision};function GetOptiShadeInstallProviderDecision {return 'unsupported_hardware'}
  $foreignPath=Join-Path $deferred.Game 'OptiShadeData/MFG/OptiShadeMFG.dll';[IO.File]::WriteAllText($foreignPath,'foreign MFG payload')
  try{[void](InstallOptiShadeAddon $deferred.Manifest $deferred.Payload 'Mfg' $null {} -ExplicitSelection)}finally{Set-Item Function:GetOptiShadeInstallProviderDecision $decisionReader}
  Check (([IO.File]::ReadAllText($foreignPath) -ceq 'foreign MFG payload') -and -not (ReadOptiShadeState $deferred.Manifest).PreparedMfg) 'Inactive staging overwrote a foreign MFG payload.'
  Remove-Item -LiteralPath $foreignPath -Force
  RemoveOptiShadeAddon $deferred.Manifest 'Mfg'
  Check ('Mfg' -notin @(GetOptiShadeAddonSelection (ReadOptiShadeState $deferred.Manifest)) -and -not (ReadOptiShadeState $deferred.Manifest).DeferredMfg -and -not (ReadOptiShadeState $deferred.Manifest).PreparedMfg -and -not(Test-Path (Join-Path $deferred.Game 'OptiShadeData/MFG/OptiShadeMFG.dll'))) 'Removing the prepared MFG selection did not remove its owned payload and state.'
  $x86=Fixture 'x86-deferred-mfg-selection';$x86Before=CaptureFixture $x86;$x86Manifest=ReadOptiShadeState $x86.Manifest;$x86Manifest.Architecture='x86';WriteState $x86Manifest $x86.Manifest
  $x86Result=InstallOptiShadeAddon $x86.Manifest $x86.Payload 'Mfg' $null {} -ExplicitSelection;$x86Installed=ReadOptiShadeState $x86.Manifest
  Check ($x86Result -match 'payload was not staged' -and 'Mfg' -in @($x86Installed.Components) -and $x86Installed.DeferredMfg -and -not $x86Installed.PreparedMfg -and $x86Installed.ProviderPolicy.Evidence -ceq 'runtime_check_in_game') 'The x86 MFG test selection was blocked instead of being recorded as deferred.'
  $x86After=CaptureFixture $x86;Check ($x86Before.Files.Count -eq $x86After.Files.Count) 'The x86 deferred selection changed game files.'
  foreach($file in $x86After.Files.Keys){Check ($x86Before.Files[$file] -ceq $x86After.Files[$file]) 'The x86 deferred selection changed an existing game file.'}
  RemoveOptiShadeAddon $x86.Manifest 'Mfg';Check ('Mfg' -notin @(GetOptiShadeAddonSelection (ReadOptiShadeState $x86.Manifest))) 'Removing the x86 deferred MFG selection did not clear the test component.'
 $preflight=Fixture 'preflight-deferred';$preflightBefore=CaptureFixture $preflight;$decisionReader=${function:GetOptiShadeInstallProviderDecision}
 function GetOptiShadeInstallProviderDecision {return 'unknown_adapter'}
 try{$preflightResult=InstallOptionalMfg $preflight.Manifest $preflight.Payload $script:fixtureGpu}catch{throw ('MFG must defer an unknown install-time GPU instead of failing selection: '+$_.Exception.Message)}finally{Set-Item Function:GetOptiShadeInstallProviderDecision $decisionReader}
 $preflightState=ReadOptiShadeState $preflight.Manifest;$preflightAfter=CaptureFixture $preflight
 Check ($preflightResult -match 'in-game' -and $preflightState.DeferredMfg -and 'Mfg' -in @($preflightState.Components) -and $preflightState.ProviderPolicy.Evidence -ceq 'prepared_waiting_for_supported_loader') ('Direct MFG preparation did not preserve the selection when install-time adapter discovery failed: '+$preflightResult+'; deferred='+$preflightState.DeferredMfg+'; components='+(@($preflightState.Components)-join ',')+'; evidence='+$preflightState.ProviderPolicy.Evidence)
 Check ($preflightState.PreparedMfg -and $preflightBefore.Files.Count + 1 -eq $preflightAfter.Files.Count -and -not(Test-Path (Join-Path $preflight.Game 'version.dll')) -and -not(Test-Path (Join-Path $preflight.Game 'OptiShadeData/MFG/source-backend.json'))) 'Unknown-adapter MFG preparation did not stage only an inactive payload.'
 $directNative=Fixture 'direct-native-route';$directNativeBefore=CaptureFixture $directNative
 function GetOptiShadeInstallProviderDecision {return 'native'}
 try{$directNativeResult=InstallOptionalMfg $directNative.Manifest $directNative.Payload $script:fixtureGpu}catch{throw ('Direct MFG preparation rejected the game-native route: '+$_.Exception.Message)}finally{Set-Item Function:GetOptiShadeInstallProviderDecision $decisionReader}
 $directNativeState=ReadOptiShadeState $directNative.Manifest;$directNativeAfter=CaptureFixture $directNative
 Check ($directNativeResult -match 'checked in-game' -and $directNativeState.NativeMfg -and 'Mfg' -in @($directNativeState.Components) -and $directNativeState.ProviderPolicy.Evidence -ceq 'native_provider_checked_in_game') 'Direct MFG preparation did not record the native in-game route.'
 Check ($directNativeBefore.Files.Count -eq $directNativeAfter.Files.Count) 'Native MFG selection changed game files.'
 foreach($file in $directNativeAfter.Files.Keys){Check ($directNativeBefore.Files[$file] -ceq $directNativeAfter.Files[$file]) 'Native MFG selection modified an existing game file.'}
 $providerFailure=Fixture 'provider-preparation-failure-deferred';$failureBefore=CaptureFixture $providerFailure;$decisionReader=${function:GetOptiShadeInstallProviderDecision};$sourceInstaller=${function:InstallSourceMfg}
 function GetOptiShadeInstallProviderDecision {return 'source'}
 function InstallSourceMfg {throw 'Synthetic provider setup failure after a safe rollback.'}
 try{$providerFailureResult=InstallOptionalMfg $providerFailure.Manifest $providerFailure.Payload $script:fixtureGpu}catch{throw ('A safely rolled-back provider setup failure must preserve MFG for an in-game check: '+$_.Exception.Message)}finally{Set-Item Function:GetOptiShadeInstallProviderDecision $decisionReader;Set-Item Function:InstallSourceMfg $sourceInstaller}
 $providerFailureState=ReadOptiShadeState $providerFailure.Manifest;$failureAfter=CaptureFixture $providerFailure
 Check ($providerFailureResult -match 'prepared inactive' -and 'Mfg' -in @($providerFailureState.Components) -and $providerFailureState.DeferredMfg -and $providerFailureState.PreparedMfg -and $providerFailureState.ProviderPolicy.Evidence -ceq 'prepared_waiting_for_supported_loader') 'A safe provider setup failure did not stage the inactive payload for runtime qualification.'
 Check ($failureBefore.Files.Count + 1 -eq $failureAfter.Files.Count -and -not(Test-Path (Join-Path $providerFailure.Game 'version.dll')) -and -not(Test-Path (Join-Path $providerFailure.Game 'OptiShadeData/MFG/source-backend.json'))) 'A safely deferred provider setup added an activation route or more than the inert payload.'
 $auto=Fixture 'automatic-preflight-failure';$decisionReader=${function:GetOptiShadeInstallProviderDecision};$script:mfgEvidenceLogs.Clear()
 function GetOptiShadeInstallProviderDecision {throw 'Synthetic automatic MFG policy failure.'}
 try{[void](EnsureAutomaticMfg $auto.Manifest $auto.Payload $script:fixtureGpu)}finally{Set-Item Function:GetOptiShadeInstallProviderDecision $decisionReader}
 Check (@($script:mfgEvidenceLogs|Where-Object {$_ -match 'MFG install evidence: outcome=failed; providerDecision=not-evaluated' -and $_ -match 'Synthetic automatic MFG policy failure'}).Count -eq 1) 'Automatic MFG policy failure was not recorded in Installer.log.'
 $autoLock=Fixture 'automatic-lock-failure';$mutationReader=${function:EnterOptiShadeMutation};$script:mfgEvidenceLogs.Clear()
 function EnterOptiShadeMutation {throw 'Synthetic automatic MFG store lock failure.'}
 try{try{[void](EnsureAutomaticMfg $autoLock.Manifest $autoLock.Payload $script:fixtureGpu);throw 'Automatic MFG lock failure fixture unexpectedly succeeded.'}catch{Check ($_.Exception.Message -match 'Synthetic automatic MFG store lock failure')}}finally{Set-Item Function:EnterOptiShadeMutation $mutationReader}
 Check (@($script:mfgEvidenceLogs|Where-Object {$_ -match 'MFG install evidence: outcome=failed; providerDecision=not-evaluated' -and $_ -match 'Synthetic automatic MFG store lock failure'}).Count -eq 1) 'Automatic MFG lock acquisition failure was not recorded in Installer.log.'
 $script:mfgEvidenceLogs.Clear();$fixtureError=[InvalidOperationException]::new('Injected MFG fixture failure at '+$generic.Game+'.')
 WriteOptiShadeMfgAttemptEvidence $generic.Manifest 'source' 'failed' $fixtureError
 Check (@($script:mfgEvidenceLogs|Where-Object {$_ -match 'outcome=failed; providerDecision=source' -and $_ -match 'errorType=System.InvalidOperationException' -and $_ -match 'Injected MFG fixture failure' -and $_ -match '<LOCAL_PATH>' -and $_ -notmatch [regex]::Escape($generic.Game)}).Count -eq 1) 'MFG failure evidence omitted its provider decision, sanitized path or actionable exception details.'
 Check ((HashFile (Join-Path $generic.Game 'OptiShadeData/MFG/OptiShadeMFG.dll')) -ceq $script:SourceMfgSha256.ToUpperInvariant()) 'The generic pre-install transaction did not verify the owned source provider.'
 Check (-not(Test-Path -LiteralPath (Join-Path $generic.Game 'version.dll'))) 'Generic pre-install guessed version.dll instead of hosting MFG under the selected renderer.'
 $legacy=Fixture 'legacy-install';InvokeFixtureAction $legacy 'legacy';$m=ReadOptiShadeState $legacy.Manifest
 Check ($m.OptionalMfg -and 'Mfg' -in @($m.Components) -and 'Mfg' -in @(GetOptiShadeAddonSelection $m)) 'Legacy install omitted the explicit MFG selection.'
 Check ('Effects' -in $m.Components -and 'Providers' -in $m.Components) 'Legacy install discarded other selections.'
 Check ((HashFile (Join-Path $legacy.Game 'd3d12.dll')) -ceq $script:expectedHash -and -not(Test-Path (Join-Path $legacy.Game 'version.dll'))) 'Legacy fixture did not place its evidence-selected loader without adding version.dll.'
 [IO.File]::AppendAllText((Join-Path $legacy.Game 'OptiScaler.ini'),"`r`n; user choice")
 $userIni=HashFile (Join-Path $legacy.Game 'OptiScaler.ini');$receipt=HashFile $legacy.Manifest;InvokeFixtureAction $legacy 'legacy'
 Check ((HashFile $legacy.Manifest) -ceq $receipt -and (HashFile (Join-Path $legacy.Game 'OptiScaler.ini')) -ceq $userIni) 'Repeated legacy preparation changed user settings or its receipt.'
 Remove-Item -LiteralPath (Join-Path $legacy.Game 'd3d12.dll');InvokeFixtureAction $legacy 'legacy'
 Check ((HashFile (Join-Path $legacy.Game 'd3d12.dll')) -ceq $script:expectedHash -and (HashFile (Join-Path $legacy.Game 'OptiScaler.ini')) -ceq $userIni) 'Missing owned legacy repair did not preserve later settings.'
 $source=Fixture 'source-install';InvokeFixtureAction $source 'source';$m=ReadOptiShadeState $source.Manifest
 Check ($m.SourceMfg -and -not $m.OptionalMfg -and 'Mfg' -in $m.Components) 'Source preparation did not record MFG selection.'
 $sourceRelative='OptiShadeData/MFG/OptiShadeMFG.dll';$activationRelative='OptiShadeData/MFG/source-backend.json'
 Check ((HashFile (Join-Path $source.Game $sourceRelative)) -ceq $script:SourceMfgSha256.ToUpperInvariant()) 'Source provider bytes were not verified.'
 $rollback=[string]$m.SourceMfgRollback;$originalIni=HashFile (Join-Path $rollback 'OptiScaler.ini')
 Remove-Item -LiteralPath (Join-Path $source.Game $sourceRelative);InvokeFixtureAction $source 'source';$m=ReadOptiShadeState $source.Manifest
 Check ($m.SourceMfgRollback -ceq $rollback -and (HashFile (Join-Path $rollback 'OptiScaler.ini')) -ceq $originalIni) 'Source repair replaced the original pre-source settings backup.'
 $chain=Join-Path $source.Folder 'original-source';[IO.File]::WriteAllText($chain,'pre-OptiShade original bytes');$record=@($m.Files|Where-Object Path -eq $sourceRelative)[0];$record.Backup='original-source';$record.PreviousHash=HashFile $chain;WriteState $m $source.Manifest
 InvokeFixtureAction $source 'source';$m=ReadOptiShadeState $source.Manifest
 Check (@($m.Files|Where-Object {$_.Path -eq $sourceRelative -and $_.Backup -eq 'original-source' -and $_.PreviousHash -ceq (HashFile $chain)}).Count -eq 1) 'Source repair discarded an original backup chain.'
 InvokeFixtureAction $source 'remove';$m=ReadOptiShadeState $source.Manifest
 Check (-not $m.SourceMfg -and 'Mfg' -notin $m.Components -and (HashFile (Join-Path $source.Game $sourceRelative)) -ceq (HashFile $chain)) 'Source removal failed to restore the original file and clear selection.'
 $migration=Fixture 'legacy-to-source';InvokeFixtureAction $migration 'legacy';InvokeFixtureAction $migration 'source';$m=ReadOptiShadeState $migration.Manifest
 Check ($m.SourceMfg -and -not $m.OptionalMfg -and -not(Test-Path -LiteralPath (Join-Path $migration.Game 'd3d12.dll')) -and -not(Test-Path -LiteralPath (Join-Path $migration.Game 'version.dll'))) 'Source migration retained a second legacy provider.'
 $foreign=Fixture 'foreign-source';$foreignPath=Join-Path $foreign.Game $sourceRelative;[void][IO.Directory]::CreateDirectory((Split-Path $foreignPath));[IO.File]::WriteAllText($foreignPath,'foreign source file')
 $before=CaptureFixture $foreign;$blocked=$false;try{InvokeFixtureAction $foreign 'source'}catch{$blocked=$_.Exception.Message -like '*unowned or changed*'}
 Check $blocked 'An unowned source provider was not rejected.';CheckRestored $foreign $before
 foreach($action in @('legacy','source','remove')){
  $f=Fixture ('fault-'+$action);if($action -eq 'remove'){InvokeFixtureAction $f 'source'};$before=CaptureFixture $f
  $realWrite=${function:WriteState};$script:failReceipt=$f.Manifest
  function WriteState($Value,[string]$Path){if($Path -eq $script:failReceipt){throw 'Injected provider receipt failure.'};& $realWrite $Value $Path}
  $failed=$false;try{InvokeFixtureAction $f $action}catch{$failed=$_.Exception.Message -like '*Injected provider receipt failure*'}finally{Set-Item Function:WriteState $realWrite}
  Check $failed ('Provider fault did not reach receipt commit: '+$action);CheckRestored $f $before
  $f=Fixture ('crash-'+$action);if($action -eq 'remove'){InvokeFixtureAction $f 'source'};$before=CaptureFixture $f
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Process -Id $PID).Path;$start.UseShellExecute=$false;$start.Arguments='-NoLogo -NoProfile -File "'+$PSCommandPath+'" -CrashFixture "'+$f.Folder+'" -CrashAction '+$action
  $child=[Diagnostics.Process]::Start($start);try{$child.WaitForExit();Check ($child.ExitCode -eq 92) ('Provider process did not stop at commit: '+$action)}finally{$child.Dispose()}
  Check (Test-Path -LiteralPath (Join-Path $f.Folder 'MfgRouteTransaction.json')) ('Provider crash did not retain a recovery pointer: '+$action)
  Check (RecoverOptiShadeRouteTransaction $f.Manifest) ('Provider restart recovery did not run: '+$action);CheckRestored $f $before
 }
 "MFG preparation/removal: $script:assertions assertions passed with actual receipts, journals, atomic file changes and child-process interruption. Two synthetic payload byte sequences stand in for release pins; no GPU/game ran."
}finally{
 $script:AntiCheatOperation=$null;$script:AntiCheatSessionAccepted=$false;$env:LOCALAPPDATA=$fixturePreviousLocalAppData
 if(Test-Path -LiteralPath $script:testRoot -PathType Container){Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
