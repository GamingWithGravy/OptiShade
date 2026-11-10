$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/components.ps1"
. "$root/Beta/installer/neural-download.ps1"
. "$root/Beta/installer/mfg.ps1"
. "$root/Beta/installer/auto-compatibility.ps1"
function OwnedPath([string]$Root,[string]$Relative){
 $base=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
 $target=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
 if(-not $target.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture escaped its root.'}
 $check=$target;while($check){if(Test-Path -LiteralPath $check){if((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked fixture refused.'}};$next=Split-Path $check -Parent;if($next -eq $check){break};$check=$next};$target
}
function AssertClosed([string]$Game){if(-not(Test-Path -LiteralPath (Join-Path $Game 'fixture-only')) -or (Test-Path -LiteralPath (Join-Path $Game 'fixture-running'))){throw 'Fixture game is not closed.'}}
function AssertAntiCheatMutation([string]$Game,[string]$Exe,[string]$Action){AssertClosed $Game}
# Controlled external boundaries only. The production PE reader, planner,
# component installation, ownership adoption, NR receipt and transactions run.
function GetOptiShadeNeuralModelCatalog {[pscustomobject]@{Id='fixture-model';Variant='auto';Families=@(40);ModelHash=(HashFile $script:fixtureModel);Signed=$false;Family='Fixture Ada'}}
function GetVerifiedNeuralCache($Selection,[scriptblock]$Progress){$script:modelDownloads++;return $script:fixtureModel}
function InstallNvidia([string]$Game,[scriptblock]$Progress){AssertClosed $Game;$script:nvidiaPreparations++}
$count=0;$script:modelDownloads=0;$script:nvidiaPreparations=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:count++}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-auto-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
function WriteFixtureExe([string]$Path){
 $bytes=New-Object byte[] 1024;$stream=[IO.MemoryStream]::new($bytes,$true);$writer=[IO.BinaryWriter]::new($stream)
 try{$writer.Write([uint16]0x5a4d);$stream.Position=0x3c;$writer.Write([uint32]0x80);$stream.Position=0x80;$writer.Write([uint32]0x4550);$writer.Write([uint16]0x8664);$writer.Write([uint16]1);$stream.Position=0x94;$writer.Write([uint16]240);$writer.Write([uint16]2);$writer.Write([uint16]0x20b);$stream.Position=0x98+60;$writer.Write([uint32]512);$stream.Position=0x98+240+8;$writer.Write([uint32]512);$writer.Write([uint32]0x1000);$writer.Write([uint32]512);$writer.Write([uint32]512)}finally{$writer.Dispose()};[IO.File]::WriteAllBytes($Path,$bytes)
}
try{
 $game=Join-Path $fixture 'game';$payload=Join-Path $fixture 'payload';[void][IO.Directory]::CreateDirectory($game);[void][IO.Directory]::CreateDirectory($payload)
 $exe=Join-Path $game 'ForzaHorizon4.exe';WriteFixtureExe $exe;[IO.File]::WriteAllText((Join-Path $game 'fixture-only'),'fixture');[IO.File]::WriteAllText((Join-Path $game 'OptiScaler.ini'),'[DlssNR]')
 $catalogue=@();foreach($relative in @('OptiShadeData/Shaders/Fixture.fx','OptiShadeData/Engine/libxess.dll','OptiShadeData/Engine/amd_fidelityfx_loader_dx12.dll','OptiShadeData/Engine/amd_fidelityfx_framegeneration_dx12.dll','OptiShadeData/Engine/nvngx_dlss.dll')){
  $file=Join-Path $payload $relative;[void][IO.Directory]::CreateDirectory((Split-Path $file));[IO.File]::WriteAllText($file,'CPU fixture bytes '+$relative)
  $catalogue+=[pscustomobject]@{Path=$relative;Hash=(HashFile $file)}
 }
 WriteState @($catalogue) (Join-Path $payload 'files.json');$script:fixtureModel=Join-Path $fixture 'fixture-model';[IO.File]::WriteAllText($script:fixtureModel,'fake model; never loaded')
 $manifest=Join-Path $fixture 'manifest.json';WriteState ([pscustomobject]@{Game=$game;Status='Installed';IncludeEffects=$false;OptionalDlss=$false;Version=(GetBundledOptiShadeVersion);LaunchExe=$exe;Architecture='x64';RouteDLL='OptiShadeGeneric.dll';Components=@();Files=@()}) $manifest
 $gpu=[pscustomobject]@{Known=$true;Complete=$true;Names='NVIDIA RTX fixture';Adapters=@([pscustomobject]@{Name='NVIDIA RTX fixture';Luid='42';VendorId=0x10DE;DeviceId=0x2684;SubSystemId=1;Software=$false;ComputeCapabilityKnown=$true;ComputeMajor=8;ComputeMinor=9;Family=40;DriverVersion='nvcuda-file:32.0.15.8000'})}

 $script:allFxDownloads=0
 function InstallAllEffects { $script:allFxDownloads++;throw 'Unexpected all-effects download.' }
 $initial=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {param($text,$completed,$total)}
 $m=ReadOptiShadeState $manifest
 Check ($m.Downloads -ceq 'Complete' -and $m.AllFxInstalled -eq $false -and $script:allFxDownloads -eq 0) 'Successful bundled Auto preparation retained a stale pending-download label or requested all FX.'

 # A completed explicit mutation at the outer progress yield cannot be replayed
 # by a stale plan or overwritten by its later preparation-status save.
 $script:raceManifest=$manifest;$script:removedDuringAuto=$false;$beforeDownloads=$script:modelDownloads
 $failed=$false
 try{InvokeOptiShadeAutoPreparation $manifest $payload $gpu {
  param($text,$completed,$total)
  if(-not $script:removedDuringAuto -and $text -ceq 'Auto: preparing nr...'){$script:removedDuringAuto=$true;RemoveOptiShadeAddon $script:raceManifest 'Neural'}
 }}catch{$failed=$_.Exception.Message -like '*preferences changed*'}
 $m=ReadOptiShadeState $manifest
 Check ($failed -and $script:removedDuringAuto -and 'Neural' -notin $m.Components -and 'Neural' -cin @(GetOptiShadeAutoComponentExclusions $m)) 'A stale Auto plan replayed a completed reentrant component removal.'
 Check ($script:modelDownloads -eq $beforeDownloads -and -not(Test-Path -LiteralPath (Join-Path $game 'nvngx_dlssnr.dll'))) 'Stale preparation acquired or reinstalled the removed model.'
 $beforeReceipt=HashFile $manifest;$failed=$false
 try{InstallOptiShadeAddon $manifest $payload 'Neural' $gpu {}}catch{$failed=$_.Exception.Message -like '*explicitly removed*'}
 Check ($failed -and (HashFile $manifest) -ceq $beforeReceipt) 'A direct nonexplicit component install ignored the current canonical exclusion.'
 InstallOptiShadeAddon $manifest $payload 'Neural' $gpu {} -ExplicitSelection
 [void](InvokeOptiShadeAutoPreparation $manifest $payload $gpu {})
 $script:changedDuringAuto=$false;$script:callbackPayload=$payload;$script:callbackGpu=$gpu
 $failed=$false
 try{InvokeOptiShadeAutoPreparation $manifest $payload $gpu {
  param($text,$completed,$total)
  if(-not $script:changedDuringAuto -and $text -ceq 'Auto: preparing nr...'){
   $script:changedDuringAuto=$true;$nextDesired=CopyOptiShadeAutoDesired;$nextDesired.nr='off'
   [void](InvokeOptiShadeAutoPreparation $script:raceManifest $script:callbackPayload $script:callbackGpu {} $nextDesired)
  }
 }}catch{$failed=$_.Exception.Message -like '*preferences changed*'}
 $m=ReadOptiShadeState $manifest
 Check ($failed -and $m.AutoCompatibility.Desired.nr -ceq 'off' -and $m.AutoCompatibility.Features.nr.State -ceq 'off') 'An earlier preparation save replaced the newer production Auto NR Off request.'
 [void](InvokeOptiShadeAutoPreparation $manifest $payload $gpu {} (CopyOptiShadeAutoDesired))

 # Execute the retained historical removal branch and keep its published receipt
 # shape (no exclusion field). The pre-audit remover was also reproduced against
 # its exact captured source; no planner fingerprint is rewritten in this test.
 foreach($id in @('Neural','Effects')){
  RemoveOptiShadeAddon $manifest $id -PreserveAutoPreference
  $old=ReadOptiShadeState $manifest;$old.PSObject.Properties.Remove('AutoComponentExclusions');WriteState $old $manifest
  $beforeDownloads=$script:modelDownloads
  $legacyPrepared=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {}
  $m=ReadOptiShadeState $manifest
  Check ($id -cin @(GetOptiShadeAutoComponentExclusions $m) -and $id -notin $m.Components -and $script:modelDownloads -eq $beforeDownloads) ('Updated Auto lost the evidenced prior-format '+$id+' removal.')
  InstallOptiShadeAddon $manifest $payload $id $gpu {} -ExplicitSelection -SkipAllFx
  [void](InvokeOptiShadeAutoPreparation $manifest $payload $gpu {})
 }
 RemoveOptiShadeAddon $manifest 'Providers' -PreserveAutoPreference
 $old=ReadOptiShadeState $manifest;$old.PSObject.Properties.Remove('AutoComponentExclusions');WriteState $old $manifest
 $unknown=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {}
 $m=ReadOptiShadeState $manifest
 Check ($unknown.Features.upscaling.State -ceq 'needs_review' -and $unknown.Features.frameGeneration.State -ceq 'off' -and 'Providers' -notin $m.Components -and 'Providers' -cnotin @(GetOptiShadeAutoComponentExclusions $m)) 'Ambiguous prior Providers intent was silently re-enabled or invented as an explicit removal; retired OptiShade frame generation must remain off.'
 Check ($m.Downloads -ceq 'Pending' -and (GetOptiShadeAutoDesiredForManifest $m $m.AutoCompatibility.Desired).frameGeneration -ceq 'off') 'Ambiguous preparation became ready for Play before its component choice was resolved.'
 $disabled=CopyOptiShadeAutoDesired;$disabled.enabled=$false
 $off=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {} $disabled
 Check ($off.Features.upscaling.State -ceq 'off' -and $off.Features.upscaling.ReasonCode -ceq 'legacy_component_intent_unknown') 'Auto Off discarded unresolved older component evidence.'
 $again=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {} (CopyOptiShadeAutoDesired)
 Check ($again.Features.upscaling.State -ceq 'needs_review' -and 'Providers' -notin (ReadOptiShadeState $manifest).Components) 'Auto-on after Off silently resolved ambiguous older Providers intent.'
 $featureOff=CopyOptiShadeAutoDesired;$featureOff.upscaling='off';$featureOff.frameGeneration='off'
 [void](InvokeOptiShadeAutoPreparation $manifest $payload $gpu {} $featureOff)
 $again=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {} (CopyOptiShadeAutoDesired)
 Check ($again.Features.upscaling.State -ceq 'needs_review' -and $again.Features.frameGeneration.State -ceq 'off' -and 'Providers' -notin (ReadOptiShadeState $manifest).Components) 'Feature Off/on lost the unresolved older upscaling choice or re-enabled retired OptiShade frame generation.'
 InstallOptiShadeAddon $manifest $payload 'Providers' $gpu {} -ExplicitSelection
 $again=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {}
 Check ($again.Features.upscaling.State -ceq 'prepared' -and -not $again.Features.upscaling.ReasonCode) 'Explicit Providers installation failed to resolve its older ambiguity.'
 # Missing bytes while Components still owns the feature are repair work, not
 # evidence of a user removal. This tests real payload reinstallation.
 $missing=Join-Path $game 'OptiShadeData/Engine/nvngx_dlss.dll';Remove-Item -LiteralPath $missing
 $script:innerInstallBlocked=$false;$script:innerAncestorBlocked=$false;$script:innerIndependentAllowed=$false;$script:independentCallbackStore=Join-Path $fixture 'callback-independent-store'
 $again=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {
  param($text,$completed,$total)
  if($text -ceq 'Installing OptiShadeData/Engine/nvngx_dlss.dll'){
   try{RemoveOptiShadeAddon $script:raceManifest 'Neural'}catch{$script:innerInstallBlocked=$_.Exception.Message -like '*reporting progress for an active preparation transaction*'}
   $other=EnterOptiShadeMutation -StateRoot $script:independentCallbackStore
   try{
    InvokeOptiShadeMutationProgress (Join-Path $script:independentCallbackStore 'manifest.json') {
     try{$ancestor=EnterOptiShadeMutation -ManifestPath $script:raceManifest;ExitOptiShadeMutation $ancestor}catch{$script:innerAncestorBlocked=$_.Exception.Message -like '*reporting progress for an active preparation transaction*'}
     $independent=EnterOptiShadeMutation -StateRoot (Join-Path $script:independentCallbackStore 'third-store')
     try{$script:innerIndependentAllowed=$true}finally{ExitOptiShadeMutation $independent}
    } 'Nested independent provider progress'
   }finally{ExitOptiShadeMutation $other}
  }
 }
 Check ($again.Features.nr.State -ceq 'prepared' -and (Test-Path -LiteralPath $missing) -and 'Neural' -cnotin @(GetOptiShadeAutoComponentExclusions (ReadOptiShadeState $manifest))) 'An owned missing file was mistaken for historical explicit removal.'
 Check $script:innerInstallBlocked 'An inner addon progress callback admitted a same-store removal inside its active rollback transaction.'
 Check ($script:innerAncestorBlocked -and $script:innerIndependentAllowed) 'An independent nested callback lost its ancestor-store guard or blocked a third unrelated store.'
 Remove-Item -LiteralPath $missing;$beforeModel=HashFile (Join-Path $game 'nvngx_dlssnr.dll')
 $partial=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {param($text,$completed,$total) if($text -ceq 'Installing OptiShadeData/Engine/nvngx_dlss.dll'){throw 'fixture inner progress failure'}}
 Check ($partial.Features.nr.State -ceq 'failed' -and -not(Test-Path -LiteralPath $missing) -and (HashFile (Join-Path $game 'nvngx_dlssnr.dll')) -ceq $beforeModel) 'A failing inner progress callback lost addon rollback boundaries.'
 # This real installation requires ordinary nested calls after the callback
 # throws. Its success also verifies thread-local callback cleanup in finally.
 InstallOptiShadeAddon $manifest $payload 'Neural' $gpu {} -ExplicitSelection
 $again=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {} -RetryFailed
 Check ($again.Features.nr.State -ceq 'prepared') 'The callback failure left the current thread/store permanently blocked.'
 # Exercise the same guard through the model-cache seam used by production
 # downloads. Ensure/Import and removal remain the actual production routines.
 Remove-Item -LiteralPath (Join-Path $game 'nvngx_dlssnr.dll');$script:innerCacheBlocked=$false
 $script:realIntentCache=${function:GetVerifiedNeuralCache}
 function GetVerifiedNeuralCache($Selection,[scriptblock]$Progress){& $Progress 'Downloading verified fixture model...';return & $script:realIntentCache $Selection $Progress}
 try{
  $again=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {
   param($text,$completed,$total)
   if($text -ceq 'Downloading verified fixture model...'){try{RemoveOptiShadeAddon $script:raceManifest 'Neural'}catch{$script:innerCacheBlocked=$_.Exception.Message -like '*reporting progress for an active preparation transaction*'}}
  }
 }finally{Set-Item Function:GetVerifiedNeuralCache $script:realIntentCache}
 Check ($script:innerCacheBlocked -and $again.Features.nr.State -ceq 'prepared' -and 'Neural' -cin (ReadOptiShadeState $manifest).Components) 'Inner model-download progress admitted a removal that a later model import could overwrite.' 
 # Removal and exclusion must roll back together when the receipt commit fails,
 # including the existing NR settings mutation and model bytes.
 $beforeReceipt=HashFile $manifest;$beforeModel=HashFile (Join-Path $game 'nvngx_dlssnr.dll');$beforeIni=HashFile (Join-Path $game 'OptiScaler.ini')
 $script:realIntentWrite=${function:WriteState};$script:failRemovalReceipt=$manifest
 function WriteState($Value,[string]$Path){
  if($Path -ceq $script:failRemovalReceipt -and $Value.Status -ceq 'Installed' -and 'Neural' -notin @($Value.Components)){$script:failRemovalReceipt='';throw 'fixture removal receipt commit failed'}
  & $script:realIntentWrite $Value $Path
 }
 try{$failed=$false;try{RemoveOptiShadeAddon $manifest 'Neural'}catch{$failed=$_.Exception.Message -like '*fixture removal receipt commit failed*'}}finally{Set-Item Function:WriteState $script:realIntentWrite}
 Check ($failed -and (HashFile $manifest) -ceq $beforeReceipt -and (HashFile (Join-Path $game 'nvngx_dlssnr.dll')) -ceq $beforeModel -and (HashFile (Join-Path $game 'OptiScaler.ini')) -ceq $beforeIni) 'Failed component removal committed an exclusion or lost its original files/settings.'

 $preset=Join-Path $game 'OptiShadeData/Presets/My look.ini';[void][IO.Directory]::CreateDirectory((Split-Path $preset));[IO.File]::WriteAllText($preset,'my saved look')
 $beforeDownloads=$script:modelDownloads
 foreach($id in @('Neural','Effects','Providers')){
  RemoveOptiShadeAddon $manifest $id
  $removed=ReadOptiShadeState $manifest
  Check ($id -notin $removed.Components -and $id -cin @(GetOptiShadeAutoComponentExclusions $removed)) ('Explicit '+$id+' removal did not commit its canonical Auto exclusion.')
  $again=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {param($text,$completed,$total)}
  $m=ReadOptiShadeState $manifest
  Check ($id -notin $m.Components) ('Next Auto preparation reinstalled explicitly removed '+$id+'.')
 }
 $m=ReadOptiShadeState $manifest;$effective=GetOptiShadeAutoDesiredForManifest $m $m.AutoCompatibility.Desired
 Check ($m.AutoCompatibility.Enabled -and $effective.nr -ceq 'off' -and $effective.upscaling -ceq 'off' -and $effective.frameGeneration -ceq 'off') ('Component exclusions did not limit their effective runtime features or retired OptiShade FG became active. nr='+$effective.nr+'; upscaling='+$effective.upscaling+'; fg='+$effective.frameGeneration+'; exclusions='+(@((GetOptiShadeAutoComponentIntent $m).Exclusions)-join ',')+'; review='+(@((GetOptiShadeAutoComponentIntent $m).Review)-join ',')+'; route='+$m.FrameGenerationRoute)
 Check ($m.AutoCompatibility.Desired.nr -ceq 'auto' -and $m.AutoCompatibility.Desired.upscaling -ceq 'auto') 'A derived component exclusion overwrote the original per-feature preferences.'
 Check ($script:modelDownloads -eq $beforeDownloads -and $script:allFxDownloads -eq 0 -and [IO.File]::ReadAllText($preset) -ceq 'my saved look') 'Excluded preparation downloaded components or changed the saved preset.'
 $beforeReceipt=HashFile $manifest;$beforeFiles=@(Get-ChildItem -LiteralPath $game -Recurse -File|ForEach-Object FullName|Sort-Object)
 $originalDownload=${function:GetVerifiedNeuralCache};function GetVerifiedNeuralCache {throw 'fixture network unavailable'}
 try{$failed=$false;try{InstallOptiShadeAddon $manifest $payload 'Neural' $gpu {} -ExplicitSelection}catch{$failed=$_.Exception.Message -like '*fixture network unavailable*'};Check $failed 'Explicit reinstall did not reach the controlled failure after payload preparation.'}finally{Set-Item Function:GetVerifiedNeuralCache $originalDownload}
 Check ((HashFile $manifest) -ceq $beforeReceipt -and (@(Get-ChildItem -LiteralPath $game -Recurse -File|ForEach-Object FullName|Sort-Object) -join '|') -ceq ($beforeFiles -join '|')) 'Failed explicit reinstall lost exclusions or left partial game files.'
 InstallOptiShadeAddon $manifest $payload 'Neural' $gpu {} -ExplicitSelection
 $m=ReadOptiShadeState $manifest
 Check ('Neural' -in $m.Components -and 'Neural' -cnotin @(GetOptiShadeAutoComponentExclusions $m) -and 'Effects' -cin @(GetOptiShadeAutoComponentExclusions $m) -and 'Providers' -cin @(GetOptiShadeAutoComponentExclusions $m)) 'Explicit Neural reinstall erased unrelated removal choices or retained its own exclusion.'
 $again=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {param($text,$completed,$total)}
 Check ($again.Features.nr.State -ceq 'prepared' -and $again.Features.imageEffects.State -ceq 'off' -and $again.Features.upscaling.State -ceq 'off' -and $again.Features.frameGeneration.State -ceq 'off') 'Automatic preparation failed to retain independent explicit component choices or re-enabled retired OptiShade frame generation.'
 $userDesired=CopyOptiShadeAutoDesired;$userDesired.nr='off'
 [void](InvokeOptiShadeAutoPreparation $manifest $payload $gpu {} $userDesired)
 InstallOptiShadeAddon $manifest $payload 'Providers' $gpu {} -ExplicitSelection
 $m=ReadOptiShadeState $manifest;$next=GetOptiShadeAutoDesiredForManifest $m $m.AutoCompatibility.Desired
 Check ($next.nr -ceq 'off' -and $next.upscaling -ceq 'auto' -and $next.frameGeneration -ceq 'off' -and 'Effects' -cin @(GetOptiShadeAutoComponentExclusions $m)) 'Explicit Providers reinstall reset unrelated NR Off or Effects removal, or re-enabled retired OptiShade frame generation.'
 $copy=@{};CopyOptiShadeInstallationPreferences $m $copy
 Check ('Effects' -cin @($copy.AutoComponentExclusions) -and $copy.AutoCompatibility.Desired.nr -ceq 'off') 'Core repair preference copy discarded explicit component intent.'
 # Exercise the actual manager Retry adapter without WPF. Only the host view,
 # current hardware query and legacy network routine are fixture boundaries.
 $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Beta/installer/manager.ps1'),[ref]$null,[ref]$errors)
 if($errors.Count){throw $errors[0].Message}
 foreach($name in @('InvokeManagerRetryDownloads','StartManagerAutoSession')){$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true);if(-not $node){throw ('Missing manager function '+$name)};Invoke-Expression $node.Extent.Text}
 function ManifestPath {return $manifest}
 function GetFusionGpu {return $gpu}
 $path=[pscustomobject]@{Text=$game};$status=[pscustomobject]@{Text=''};$autoStatus=[pscustomobject]@{Text=''};$form=[pscustomobject]@{}
 $form|Add-Member ScriptMethod FindName {param($name) return $autoStatus}
 $runtimeTimer=[pscustomobject]@{Started=$false};$runtimeTimer|Add-Member ScriptMethod Start {$this.Started=$true}
 $progress={param($text,$completed=0,$total=0)};$store=$fixture;$script:legacyRetries=0
 function FinishOptionalDownloads {param($Manifest,$Plan) $script:legacyRetries++}
 function CheckGameCompatibility {return [pscustomobject]@{Fixture=$true}}
 function SaveFusionCompatibility {}
 StartManagerAutoSession $m
 Check ($runtimeTimer.Started -and $script:autoIntent.Desired.nr -ceq 'off' -and $script:autoIntent.Desired.frameGeneration -ceq 'off') 'The real Play/session adapter did not send the effective per-component desired state or re-enabled retired OptiShade frame generation.'
 $originalIdentityReader=${function:GetOptiShadeExecutableIdentity}
 function GetOptiShadeExecutableIdentity([string]$File){throw [UnauthorizedAccessException]::new('protected EXE fixture')}
 try{
  StartManagerAutoSession $m -ObserveOnly
  Check ($script:autoIntent.ObserveOnly -and $script:autoIntent.ExecutableHash -eq '' -and $runtimeTimer.Started) 'real manager observe-only path starts monitoring a protected image with unknown hash'
  Check (-not (SaveOptiShadeAutoRenderingHint $manifest $script:autoIntent $null $null)) 'hashless observation never persists a reusable preparation hint'
  $strictBlocked=$false;try{StartManagerAutoSession $m}catch{$strictBlocked=$true}
  Check $strictBlocked 'feature-changing session initialization still requires measured executable identity'
 }finally{Set-Item Function:GetOptiShadeExecutableIdentity $originalIdentityReader}
 $normal=CopyOptiShadeAutoDesired
 [void](InvokeOptiShadeAutoPreparation $manifest $payload $gpu {} $normal)
 $damaged=Join-Path $game 'OptiShadeData/Engine/nvngx_dlss.dll';$good=[IO.File]::ReadAllBytes($damaged);[IO.File]::WriteAllText($damaged,'external edit; must be retained')
 $partial=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {}
 Check ($partial.Features.nr.State -ceq 'failed' -and (ReadOptiShadeState $manifest).Downloads -ceq 'Pending') 'Failed Auto preparation did not project a truthful retry-needed state.'
 InvokeManagerRetryDownloads
 Check ($script:legacyRetries -eq 0 -and $script:allFxDownloads -eq 0 -and [IO.File]::ReadAllText($damaged) -ceq 'external edit; must be retained' -and (ReadOptiShadeState $manifest).Downloads -ceq 'Pending') 'Auto Retry entered old optional/all-FX downloads, removed an exclusion, or overwrote a changed owned file.'
 [IO.File]::WriteAllBytes($damaged,$good);InvokeManagerRetryDownloads
 $m=ReadOptiShadeState $manifest
 Check ($m.Downloads -ceq 'Complete' -and $m.AutoCompatibility.Features.nr.State -ceq 'prepared' -and 'Effects' -notin $m.Components -and $script:legacyRetries -eq 0) 'Auto Retry did not resume the actual planner and clear the stale pending state while preserving exclusions.'
 $savedAuto=$m.AutoCompatibility;$m.PSObject.Properties.Remove('AutoCompatibility');WriteState $m $manifest
 InvokeManagerRetryDownloads
 Check ($script:legacyRetries -eq 1 -and -not (ReadOptiShadeState $manifest).AutoCompatibility) 'A non-Auto legacy Retry silently converted its preparation controller.'
 $m|Add-Member AutoCompatibility $savedAuto -Force;WriteState $m $manifest
 $beforeReceipt=HashFile $manifest;$bad=$m|ConvertTo-Json -Depth 12|ConvertFrom-Json;$bad.AutoComponentExclusions=@('Effects','Effects')
 $failed=$false;try{$null=GetOptiShadeAutoPreparationPlan $bad $payload $gpu}catch{$failed=$true}
 Check ($failed -and (HashFile $manifest) -ceq $beforeReceipt) 'Malformed exclusions were silently accepted or mutated installation state.'
 # Physical adapter names can collide. Choices use measured LUIDs, and an
 # explicit NR selection does not replace the independently observed FG GPU.
 $first=$gpu.Adapters[0];$second=$first|ConvertTo-Json|ConvertFrom-Json;$second.Luid='43'
 $amd=$first|ConvertTo-Json|ConvertFrom-Json;$amd.Name='AMD fixture';$amd.VendorId=0x1002;$amd.Luid='44';$amd.Family=0
 $multi=[pscustomobject]@{Known=$true;Complete=$true;Names='NVIDIA RTX fixture, NVIDIA RTX fixture, AMD fixture';Adapters=@($first,$second,$amd)}
 $choices=@(GetOptiShadeNeuralAdapterChoices $multi)
 Check ($choices.Count -eq 2 -and @($choices.Label|Select-Object -Unique).Count -eq 2) 'Same-name physical GPUs were collapsed or a non-admitted adapter was offered as a neural choice.'
 $m=ReadOptiShadeState $manifest;$m|Add-Member NeuralAdapter (GetOptiShadeAdapterReceipt $first) -Force
 $m.AutoCompatibility|Add-Member RenderingHint ([pscustomobject]@{ExecutableHash=(GetOptiShadeExecutableIdentity $exe).SHA256;Adapter=(GetOptiShadeAdapterReceipt $first)}) -Force
 SetOptiShadeNeuralAdapterSelection $m $multi '43'
 Check ($m.NeuralAdapterSelection -ceq 'explicit' -and (ResolveOptiShadeNeuralAdapter $m $multi).Adapter.Luid -ceq '43') 'A fresh game-GPU choice retained the old canonical neural adapter.'
 $plan=GetOptiShadeAutoPreparationPlan $m $payload $multi
 Check ($plan.Candidate.Adapter.Luid -ceq '43' -and $plan.Gpu.PreferredRenderingLuid -ceq '42' -and (ResolveOptiShadeMfgAdapter $plan.Gpu $m).Adapter.Luid -ceq '42') 'An old rendering hint overrode explicit NR choice, or NR choice replaced FG rendering identity.'
 WriteState $m $manifest
 [void](InvokeOptiShadeAutoPreparation $manifest $payload $multi {})
 $m=ReadOptiShadeState $manifest
 Check ($m.NeuralAdapter.Luid -ceq '43' -and $m.NeuralAdapterSelection -ceq 'explicit' -and $m.AutoCompatibility.RenderingHint.Adapter.Luid -ceq '42') 'Actual model preparation dropped explicit NR identity or changed FG rendering evidence.'
 $before=$m|ConvertTo-Json -Depth 12 -Compress;$failed=$false;try{SetOptiShadeNeuralAdapterSelection $m $multi '999'}catch{$failed=$true}
 Check ($failed -and ($m|ConvertTo-Json -Depth 12 -Compress) -ceq $before) 'A disappeared selected adapter changed the saved preference before validation.'
 $copy=@{};CopyOptiShadeInstallationPreferences $m $copy
 Check ($copy.NeuralAdapterSelection -ceq 'explicit' -and $copy.NeuralAdapter.Luid -ceq '43') 'Core repair lost canonical explicit adapter selection.'

 # A user selection remains the same physical choice when its measured driver
 # refreshes or its LUID rebinds uniquely after reboot. Admit exactly the plan's
 # expected receipt refresh while continuing to reject a newer user selection.
 $driverGpu=$multi|ConvertTo-Json -Depth 6|ConvertFrom-Json;$driverGpu.Adapters[1].DriverVersion='nvcuda-file:32.0.15.9000'
 $refreshed=InvokeOptiShadeAutoPreparation $manifest $payload $driverGpu {}
 $m=ReadOptiShadeState $manifest
 Check ($refreshed.Features.nr.State -ceq 'prepared' -and $m.NeuralAdapter.Luid -ceq '43' -and $m.NeuralAdapter.DriverVersion -ceq 'nvcuda-file:32.0.15.9000' -and $m.NeuralAdapterSelection -ceq 'explicit') 'The planned driver receipt refresh was mistaken for a changed user adapter choice.'
 $rebooted=$driverGpu.Adapters[1]|ConvertTo-Json|ConvertFrom-Json;$rebooted.Luid='143'
 $rebootGpu=[pscustomobject]@{Known=$true;Complete=$true;Names=$rebooted.Name;Adapters=@($rebooted)}
 $refreshed=InvokeOptiShadeAutoPreparation $manifest $payload $rebootGpu {}
 $m=ReadOptiShadeState $manifest
 Check ($refreshed.Features.nr.State -ceq 'prepared' -and $m.NeuralAdapter.Luid -ceq '143' -and $m.NeuralAdapterSelection -ceq 'explicit') 'The exact planned unique physical-device rebind was mistaken for a new user selection.'
 $multi=$driverGpu;SetOptiShadeNeuralAdapterSelection $m $multi '43';WriteState $m $manifest
 [void](InvokeOptiShadeAutoPreparation $manifest $payload $multi {})

 # A measured adapter preference saved at the real Auto progress yield is
 # independently protected from stale preparation and its previous FG hint.
 $script:callbackGpu=$multi;$script:adapterChangedDuringAuto=$false;$beforeDownloads=$script:modelDownloads;$failed=$false
 try{InvokeOptiShadeAutoPreparation $manifest $payload $multi {
  param($text,$completed,$total)
  if(-not $script:adapterChangedDuringAuto -and $text -ceq 'Auto: preparing nr...'){
   $script:adapterChangedDuringAuto=$true;$latest=ReadOptiShadeState $script:raceManifest
   SetOptiShadeNeuralAdapterSelection $latest $script:callbackGpu '42';WriteState $latest $script:raceManifest
  }
 }}catch{$failed=$_.Exception.Message -like '*preferences changed*'}
 $m=ReadOptiShadeState $manifest
 Check ($failed -and $m.NeuralAdapter.Luid -ceq '42' -and $m.NeuralAdapterSelection -ceq 'explicit' -and $script:modelDownloads -eq $beforeDownloads) 'A stale Auto plan overwrote the newer measured adapter choice or acquired its old model.'
 SetOptiShadeNeuralAdapterSelection $m $multi '43';WriteState $m $manifest
 [void](InvokeOptiShadeAutoPreparation $manifest $payload $multi {})
 # Retain a real route journal by changing a target at the production copy
 # boundary. Status must be pending/recovery_required without changing the
 # receipt hashes pinned by that unresolved transaction.
 $script:conflictTarget=Join-Path $game 'OptiShadeData/Neural-runtime.json'
 $script:realIntentRouteCopy=${function:CopyOptiShadeRouteFile}
 function CopyOptiShadeRouteFile([string]$Source,[string]$Destination,[string]$ExpectedHash){
  if($Destination -ceq $script:conflictTarget){$script:conflictTarget='';[IO.File]::WriteAllText($Destination,'independent external edit during transaction');throw 'fixture model receipt conflict'}
  & $script:realIntentRouteCopy $Source $Destination $ExpectedHash
 }
 try{$failed=$false;try{InvokeOptiShadeAutoPreparation $manifest $payload $multi {}}catch{$failed=$true}}finally{Set-Item Function:CopyOptiShadeRouteFile $script:realIntentRouteCopy}
 $m=ReadOptiShadeState $manifest;$recovery=GetOptiShadeRouteRecovery $manifest;$pinnedReceipt=HashFile $manifest
 $display=FormatOptiShadeAutoPreparation $m.AutoCompatibility $manifest
 Check ($failed -and $recovery -and $m.Downloads -ceq 'Pending' -and $display -like '*recovery_required*') 'An interrupted real route transaction retained a stale Complete/ready Auto status.'
 Check ((HashFile $manifest) -ceq $pinnedReceipt -and [IO.File]::ReadAllText((Join-Path $game 'OptiShadeData/Neural-runtime.json')) -ceq 'independent external edit during transaction') 'Recovery-status projection rewrote a pinned receipt or the externally changed target.'
 # Resolve only the fixture's injected conflict to the verified previous bytes,
 # then exercise the existing recovery owner and resume normal preparation.
 $entry=@($recovery.Journal.Files|Where-Object Path -ceq 'OptiShadeData/Neural-runtime.json')[0]
 CopyOptiShadeRouteFile (OwnedPath $recovery.Directory $entry.Before) $entry.Target $entry.BeforeHash
 [void](RecoverOptiShadeRouteTransaction $manifest)
 [void](InvokeOptiShadeAutoPreparation $manifest $payload $multi {} -RetryFailed)
 Check (-not(GetOptiShadeRouteRecovery $manifest) -and (ReadOptiShadeState $manifest).Downloads -ceq 'Complete') 'Resolved recovery did not release the actual transaction owner for Auto retry.'
 $m=ReadOptiShadeState $manifest

 # Exercise the legacy repair entry point which InstallFusion still calls.
 # Auto receipts must not enter its old settings selector; older receipts keep
 # their established explicit portable-route repair behavior.
 $sim=Join-Path $game 'FlightSimulator2024.exe';WriteFixtureExe $sim
 $m.LaunchExe=$sim;$m.RouteDLL='OptiShadeMSFS2024.dll';$m.AutoCompatibility.Desired.frameGeneration='off';WriteState $m $manifest
 SelectPortableFsr2x $manifest $payload
 $ini=Join-Path $game 'OptiScaler.ini';$text=SetMfgIniValue ([IO.File]::ReadAllText($ini)) 'FrameGen' 'Enabled' 'false';[IO.File]::WriteAllText($ini,$text)
 $beforeIni=HashFile $ini;$beforeReceipt=HashFile $manifest;$beforeJournals=@(Get-ChildItem -LiteralPath (Join-Path $fixture 'MfgRollback') -Directory).Count
 [void](EnsureAutomaticMfg $manifest $payload $gpu)
 Check ((HashFile $ini) -ceq $beforeIni -and (HashFile $manifest) -ceq $beforeReceipt -and (GetSm86MfgIniValue ([IO.File]::ReadAllText($ini)) 'FrameGen' 'Enabled') -ceq 'false') 'Core repair''s old selector overwrote Auto FG Off or the retained provider receipt.'
 Check (@(Get-ChildItem -LiteralPath (Join-Path $fixture 'MfgRollback') -Directory).Count -eq $beforeJournals) 'Auto core repair created an unnecessary second provider route transaction.'
 $m=ReadOptiShadeState $manifest;$m.PSObject.Properties.Remove('AutoCompatibility');WriteState $m $manifest
 [void](EnsureAutomaticMfg $manifest $payload $gpu)
 Check ((ReadOptiShadeState $manifest).FrameGenerationRoute -ceq 'portable-fsr2x' -and (GetSm86MfgIniValue ([IO.File]::ReadAllText($ini)) 'FrameGen' 'Enabled') -ceq 'true') 'The retained non-Auto portable repair route lost its existing explicit selection behavior.'
 "Auto component intent: $count assertions passed through production removal, migration, reentrant intent admission, rollback, explicit reinstall, recovery, manager Retry/session adapters and GPU identity selection. Network/GPU/WPF host boundaries are fixtures; no game output is claimed."
}finally{if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
