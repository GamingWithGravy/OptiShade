# One manager Auto controller. Preparation is durable ownership evidence only;
# each new Play/Auto-session action must bind a live OS process before control.
. "$PSScriptRoot/qualified-plans.ps1"
function CopyOptiShadeAutoDesired($Desired=$null,[bool]$DefaultEnabled=$true){
 if(-not $Desired){return [pscustomobject][ordered]@{enabled=$DefaultEnabled;nr='auto';upscaling='auto';frameGeneration='off'}}
 if($Desired.enabled -isnot [bool]){throw 'Auto enabled intent must be boolean.'}
 $copy=[ordered]@{enabled=[bool]$Desired.enabled}
 foreach($name in @('nr','upscaling','frameGeneration')){if([string]$Desired.$name -cnotin @('auto','off')){throw ('Invalid Auto preference: '+$name)};$copy[$name]=[string]$Desired.$name}
 # OptiShade's MFG implementation is retired. Ignore any older saved Auto
 # request so launch/repair cannot reinstall or reactivate its former route.
 $copy.frameGeneration='off'
 return [pscustomobject]$copy
}
function GetOptiShadeAutoComponentIntent($Manifest){
 $excluded=@(GetOptiShadeAutoComponentExclusions $Manifest);$review=@()
 # Older Auto receipts recorded successful preparation, then the component
 # remover updated Components and the old explicit boolean without invalidating
 # Auto. Infer only that narrow completed-removal shape, never missing files.
 $legacy=-not $Manifest.PSObject.Properties['AutoComponentExclusions']
 $previous=$Manifest.AutoCompatibility
 if($previous -and $previous.Schema -eq 1 -and $previous.Evidence -ceq 'installation_only' -and $Manifest.PSObject.Properties['Components']){
  foreach($entry in @(@{Id='Effects';Features=@('imageEffects');Flag='IncludeEffects'},@{Id='Neural';Features=@('nr');Flag='OptionalDlss'},@{Id='Providers';Features=@('upscaling','frameGeneration');Flag=''})){
   $id=[string]$entry.Id
   if($id -cin $excluded -or $id -cin @($Manifest.Components)){continue}
   $prepared=$false;$unresolved=$false
   foreach($name in $entry.Features){
    $feature=$previous.Features.$name
    if($feature -and $feature.Requested -ceq 'auto' -and $feature.State -cin @('prepared','prepared_waiting_for_inputs','waiting_for_runtime')){$prepared=$true}
    if($feature -and $feature.ReasonCode -ceq 'legacy_component_intent_unknown'){$unresolved=$true}
   }
   if(-not $unresolved -and (-not $legacy -or -not $prepared)){continue}
   $flag=if($entry.Flag){$Manifest.PSObject.Properties[[string]$entry.Flag]}else{$null}
   if($legacy -and $prepared -and $flag -and $flag.Value -is [bool] -and -not $flag.Value){$excluded+=,$id}
   else{$review+=,$id}
  }
 }
 return [pscustomobject]@{Exclusions=@($excluded|Sort-Object -Unique);Review=@($review|Sort-Object -Unique)}
}
function GetOptiShadeAutoDesiredForManifest($Manifest,$Desired=$null){
 $desired=CopyOptiShadeAutoDesired $Desired
 $intent=GetOptiShadeAutoComponentIntent $Manifest;$inactive=@($intent.Exclusions)+@($intent.Review)
 if('Neural' -cin $inactive){$desired.nr='off'}
 # FSR/XeSS is an upscaling component. Keep its intent independent of the
 # retired frame-generation feature.
 if('Providers' -cin $intent.Exclusions){$desired.upscaling='off'}
 if('Providers' -cin $intent.Review){$desired.upscaling='off';$desired.frameGeneration='off'}
 return $desired
}
function GetOptiShadeAutoHash([string]$Value){
 $sha=[Security.Cryptography.SHA256]::Create();try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-','')}finally{$sha.Dispose()}
}
function GetOptiShadeAutoPreparationGpu($Manifest,$Gpu,$Identity){
 # A previously verified rendering LUID is a preparation hint for the same
 # executable build and current driver/device. It is never live enable intent.
 $hint=if($Manifest.AutoCompatibility){$Manifest.AutoCompatibility.RenderingHint}else{$null}
 if($hint -and [string]$hint.ExecutableHash -ceq [string]$Identity.SHA256){
  $candidate=ResolveOptiShadeAdapterCandidate $Gpu '' ([string]$hint.Adapter.Luid)
  if($candidate.State -eq 'candidate' -and [uint32]$candidate.Adapter.VendorId -eq [uint32]$hint.Adapter.VendorId -and [uint32]$candidate.Adapter.DeviceId -eq [uint32]$hint.Adapter.DeviceId -and [uint32]$candidate.Adapter.SubSystemId -eq [uint32]$hint.Adapter.SubSystemId -and [string]$candidate.Adapter.DriverVersion -ceq [string]$hint.Adapter.DriverVersion){
   return [pscustomobject]@{Adapters=@($Gpu.Adapters);Names=[string]$Gpu.Names;Known=[bool]$Gpu.Known;Complete=$Gpu.Complete;PreferredRenderingLuid=[string]$candidate.Adapter.Luid}
  }
 }
 return $Gpu
}
function GetOptiShadeAutoPreparationPlan($Manifest,[string]$Payload,$Gpu,$Desired=$null){
 if($Manifest.Status -ne 'Installed'){throw 'Complete the core installation before Auto preparation.'}
 # Xbox/MS Store can deny reads of the encrypted rendering EXE even though its
 # recorded content helper remains readable and launchable. Auto only stages
 # owned components; when the existing x64 install record permits it, retain
 # unknown renderer/API and hash evidence instead of aborting on OpenRead.
 $identity=GetOptiShadeRenderingExecutable $Manifest -AllowRecordedUnknown
 $preferences=CopyOptiShadeAutoDesired $Desired
 $desired=GetOptiShadeAutoDesiredForManifest $Manifest $preferences
 $componentIntent=GetOptiShadeAutoComponentIntent $Manifest;$excluded=@($componentIntent.Exclusions)
 $inventoryGpu=$Gpu
 $gpu=GetOptiShadeAutoPreparationGpu $Manifest $Gpu $identity
 # An explicit NR preparation choice is independent of the observed rendering
 # device used for FG. A previous session hint cannot silently undo that choice.
 $neuralGpu=if($Manifest.NeuralAdapterSelection -ceq 'explicit'){
  [pscustomobject]@{Adapters=@($inventoryGpu.Adapters);Names=[string]$inventoryGpu.Names;Known=[bool]$inventoryGpu.Known;Complete=$inventoryGpu.Complete}
 }else{$gpu}
 $candidate=ResolveOptiShadeNeuralAdapter $Manifest $neuralGpu
 $catalogue=ReadOptiShadeJson (Join-Path $Payload 'files.json') 'Auto payload catalogue' -Shape Array
 if(-not @($catalogue).Count){throw 'Auto needs the verified payload catalogue from this manager.'}
 $providerDecision='retired'
 $xp12=$Manifest.RouteDLL -eq 'OptiShadeXPlane12.dll'
 $nrApiKnownUnsupported=$identity.ApiCandidates.Count -gt 0 -and @($identity.ApiCandidates|Where-Object {$_ -in @('DX11','DX12','Vulkan')}).Count -eq 0
 $nrApiEvidence=@($identity.ApiCandidates) -join ', ';if(-not $nrApiEvidence){$nrApiEvidence='no static or delay-load API imports recorded'}
 $nrUnsupportedReason='Static executable imports: '+$nrApiEvidence+'. This x64 API is not admitted for live Neural Rendering. Component files may still be prepared; runtime activation remains blocked.'
 $feature={param($Requested,$State,$Reason,$Route) [pscustomobject]@{Requested=$Requested;State=$State;Reason=$Reason;Route=$Route;Evidence='installation_only'}}
 $features=[ordered]@{}
 $features.imageEffects=if(-not $desired.enabled -or 'Effects' -cin $excluded){& $feature 'off' 'off' 'Image effects remain removed or Auto is Off. Explicit component installation can restore them.' ''}else{& $feature 'auto' 'candidate' 'Prepare the bundled image-effects component; output remains unverified.' 'effects'}
 $features.upscaling=if(-not $desired.enabled -or $desired.upscaling -eq 'off'){& $feature 'off' 'off' 'Explicit Auto upscaling Off is retained.' ''}elseif($identity.Architecture -eq 'x86' -or $xp12){& $feature 'auto' 'unsupported' 'This route has no admitted automatic upscaling provider; existing game settings are retained.' ''}else{& $feature 'auto' 'candidate' 'Pinned provider dependencies can be prepared; a live game upscaling input is still required.' 'game_integrated'}
 $features.nr=if(-not $desired.enabled -or $desired.nr -eq 'off'){& $feature 'off' 'off' 'Explicit Auto NR Off is retained.' ''}elseif($candidate.State -eq 'unsupported_hardware'){& $feature 'auto' 'unsupported' $candidate.Reason ''}elseif($xp12){& $feature 'auto' 'deferred' 'XP12 qualification is pending. Its existing graphics and guide choices are retained.' 'xp12_vulkan'}elseif($candidate.State -ne 'candidate'){& $feature 'auto' 'waiting_for_rendering_adapter' $candidate.Reason ''}elseif($identity.Architecture -eq 'x86' -and $identity.ApiCandidates -contains 'DX9' -and (-not(TestOptiShadeLegacyD3D9Wrapper $Manifest.Game) -or (GetOptiShadeInstalledLoaderPath $Manifest) -ne 'dxgi.dll')){& $feature 'auto' 'needs_wrapper' 'Native D3D9 needs a configured external D3D9-to-D3D11 wrapper and DXGI attachment before Legacy NR preparation.' 'legacy_nr'}elseif($identity.Architecture -eq 'x86'){& $feature 'auto' 'candidate' 'Prepare the measured model and x64 worker. The actual legacy API/device/guides are qualified in session; Vulkan still needs its existing compatible 32-bit layer.' 'legacy_nr'}elseif($nrApiKnownUnsupported){& $feature 'auto' 'unsupported' $nrUnsupportedReason ''}else{& $feature 'auto' 'candidate' 'Prepare the pinned model and owned identity; a new session Auto action and live input validation still gate NR.' 'nr'}
 $features.frameGeneration=& $feature 'off' 'off' 'Frame generation is not currently provided by OptiShade.' ''
 foreach($entry in @(@{Id='Effects';Features=@('imageEffects')},@{Id='Neural';Features=@('nr')},@{Id='Providers';Features=@('upscaling','frameGeneration')})){
  if($entry.Id -cnotin @($componentIntent.Review)){continue}
  foreach($name in $entry.Features){
   if($preferences.enabled -and ($name -eq 'imageEffects' -or $preferences.$name -cne 'off')){
    $features[$name]=& $feature 'auto' 'needs_review' 'An older Auto receipt records prepared dependencies but no longer owns this component. Its removal intent is unclear. Review or explicitly reinstall the component.' ''
   }
   # Off temporarily suppresses preparation; it does not resolve an older
   # component ambiguity. Keep the marker until explicit install/removal.
   $features[$name]|Add-Member ReasonCode 'legacy_component_intent_unknown' -Force
  }
 }
 $staticRanking=GetOptiShadeAutoStaticRanking $Manifest $Payload $gpu $identity @($catalogue) $desired $providerDecision
 $inventory=@($Gpu.Adapters|Sort-Object Luid|ForEach-Object {[ordered]@{luid=[string]$_.Luid;vendor=[uint32]$_.VendorId;device=[uint32]$_.DeviceId;subsystem=[uint32]$_.SubSystemId;major=[int]$_.ComputeMajor;minor=[int]$_.ComputeMinor;known=[bool]$_.ComputeCapabilityKnown;driver=[string]$_.DriverVersion}})
 $context=[ordered]@{schema=1;exe=$identity.SHA256;architecture=$identity.Architecture;version=(GetBundledOptiShadeVersion);payload=(HashFile (Join-Path $Payload 'files.json'));providerPolicy=(HashFile (Join-Path $PSScriptRoot 'provider-policy.json'));modelPolicy=(HashFile (Join-Path $PSScriptRoot 'neural-model-policy.json'));inventory=$inventory;desired=$desired;componentExclusions=$excluded;componentReview=@($componentIntent.Review);neuralVariant=$(if($Manifest.NeuralRuntimeVariant){[string]$Manifest.NeuralRuntimeVariant}else{'auto'});candidate=$(if($candidate.Adapter){[string]$candidate.Adapter.Luid}else{''});neuralSelection=[string]$Manifest.NeuralAdapterSelection;renderingHint=[string]$gpu.PreferredRenderingLuid;route=[string]$Manifest.FrameGenerationRoute;providerDecision=$providerDecision;staticQualification=$staticRanking.Fingerprint}
 return [pscustomobject]@{Schema=1;Desired=$desired;Preferences=$preferences;Identity=$identity;Gpu=$gpu;NeuralGpu=$neuralGpu;Candidate=$candidate;Features=[pscustomobject]$features;ComponentIntent=$componentIntent;Catalogue=@($catalogue);Fingerprint=(GetOptiShadeAutoHash ($context|ConvertTo-Json -Depth 12 -Compress));ProviderDecision=$providerDecision;StaticRanking=$staticRanking}
}
function TestOptiShadeAutoComponentVerified($Manifest,[object[]]$Catalogue,[string]$Id){
 if($Id -notin @(GetOptiShadeAddonSelection $Manifest)){return $false}
 $required=@(GetOptiShadeAddonPayloadEntries $Catalogue $Manifest $Id)
 if(-not $required.Count){return $false}
 foreach($item in $required){
  $entries=@($Manifest.Files|Where-Object {([string]$_.Path).Replace('\','/') -ieq ([string]$item.Path).Replace('\','/')})
  $file=OwnedPath $Manifest.Game $item.Path
  if($entries.Count -ne 1 -or -not(Test-Path -LiteralPath $file -PathType Leaf)){return $false}
  if(-not(TestOptiShadeMutableFile $item.Path) -and (HashFile $file) -cne [string]$entries[0].Hash){return $false}
 }
 return $true
}
function TestOptiShadeAutoMfgVerified($Manifest,[string]$Route){
 if($Route -eq 'sm86'){return TestSm86MfgReceipt $Manifest}
 if($Route -eq 'legacy'){
  if(-not $Manifest.OptionalMfg -or $Manifest.SourceMfg -or $Manifest.Sm86Mfg){return $false}
  $loader=GetOptiShadeMfgLoaderName $Manifest
  $entries=@($Manifest.Files|Where-Object {([string]$_.Path).Replace('\','/') -ieq $loader})
  return ($entries.Count -eq 1 -and -not $entries[0].Mutable -and [string]$entries[0].Hash -ceq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040' -and (HashFile (OwnedPath $Manifest.Game $loader)) -ceq [string]$entries[0].Hash)
 }
 if($Route -eq 'source'){
  if(-not $Manifest.SourceMfg -or $Manifest.OptionalMfg -or $Manifest.Sm86Mfg){return $false}
  foreach($path in @('OptiShadeData/MFG/OptiShadeMFG.dll','OptiShadeData/MFG/source-backend.json')){
   $entries=@($Manifest.Files|Where-Object {([string]$_.Path).Replace('\','/') -ieq $path})
   if($entries.Count -ne 1 -or $entries[0].Mutable -or (HashFile (OwnedPath $Manifest.Game $path)) -cne [string]$entries[0].Hash){return $false}
  }
  return ((HashFile (OwnedPath $Manifest.Game 'OptiShadeData/MFG/OptiShadeMFG.dll')).ToLowerInvariant() -ceq $script:SourceMfgSha256)
 }
 return $false
}
function RecordOptiShadeAutoMfgSelection([string]$ManifestPath,[string]$Route){
 if($Route -notin @('native','native_probe')){throw 'Only native or deferred MFG selections can be recorded without provider installation.'}
 $manifest=ReadOptiShadeState $ManifestPath
 $manifest|Add-Member -NotePropertyName Components -NotePropertyValue @(@(GetOptiShadeAddonSelection $manifest)+'Mfg'|Select-Object -Unique) -Force
 if($Route -ceq 'native'){
  $manifest|Add-Member -NotePropertyName NativeMfg -NotePropertyValue $true -Force
  $manifest.PSObject.Properties.Remove('DeferredMfg')
  $manifest|Add-Member -NotePropertyName ProviderPolicy -NotePropertyValue ([pscustomobject]@{Schema=1;Channel=(GetOptiShadeMfgPolicyChannel);Requested='native';RecordedSource=$false;RecordedLegacy=$false;RecordedSm86=$false;Evidence='auto_native_provider_checked_in_game'}) -Force
  $manifest|Add-Member -NotePropertyName AutomaticMfgStatus -NotePropertyValue 'MFG component selected for the native game route. Live provider capability and activation are checked in-game; no separate provider DLL was installed.' -Force
 }else{
  $manifest|Add-Member -NotePropertyName DeferredMfg -NotePropertyValue $true -Force
  $manifest.PSObject.Properties.Remove('NativeMfg')
  $manifest|Add-Member -NotePropertyName ProviderPolicy -NotePropertyValue ([pscustomobject]@{Schema=1;Channel=(GetOptiShadeMfgPolicyChannel);Requested='deferred';RecordedSource=$false;RecordedLegacy=$false;RecordedSm86=$false;Evidence='runtime_check_in_game'}) -Force
  $manifest|Add-Member -NotePropertyName AutomaticMfgStatus -NotePropertyValue 'MFG component selected for an in-game compatibility check. Install-time game, adapter and provider checks did not block selection; no unverified provider files were changed.' -Force
 }
 WriteState $manifest $ManifestPath
}
function GetOptiShadeAutoIntentFingerprint($Manifest,$NeuralAdapterOverride=$null){
 # Compare current canonical preferences, not a cached planner fingerprint.
 # Automatic model identity refresh is allowed; explicit adapter identity and
 # every input to the next selection remain protected from stale saves.
 $context=[ordered]@{
  desired=(CopyOptiShadeAutoDesired $Manifest.AutoCompatibility.Desired)
  exclusions=@(GetOptiShadeAutoComponentExclusions $Manifest)
  neuralSelection=[string]$Manifest.NeuralAdapterSelection
  explicitNeuralAdapter=$(if($Manifest.NeuralAdapterSelection -ceq 'explicit'){if($NeuralAdapterOverride){$NeuralAdapterOverride}else{$Manifest.NeuralAdapter}}else{$null})
  neuralGpuName=[string]$Manifest.NeuralGpuName
  neuralVariant=$(if($Manifest.NeuralRuntimeVariant){[string]$Manifest.NeuralRuntimeVariant}else{'auto'})
  renderingHint=$Manifest.AutoCompatibility.RenderingHint
  nativeFgPreparation=$Manifest.AutoCompatibility.NativeFgPreparation
  staticQualification=$Manifest.AutoCompatibility.StaticQualification
  staticSelection=$Manifest.AutoCompatibility.StaticSelection
 }
 GetOptiShadeAutoHash ($context|ConvertTo-Json -Depth 12 -Compress)
}
function AssertOptiShadeAutoPreparationCurrent([string]$ManifestPath,$Guard,[string]$AllowedRoute=''){
 $current=ReadOptiShadeState $ManifestPath
 $intent=GetOptiShadeAutoIntentFingerprint $current
 if($intent -cne $Guard.Intent -and $Guard.InitialNeuralAdapter -and $Guard.PreparedNeuralAdapter){
  # The selected physical device may have a new driver or uniquely rebound
  # LUID. Admit only the exact measured identity already approved by this plan.
  if(($current.NeuralAdapter|ConvertTo-Json -Depth 6 -Compress) -ceq ($Guard.PreparedNeuralAdapter|ConvertTo-Json -Depth 6 -Compress)){$intent=GetOptiShadeAutoIntentFingerprint $current $Guard.InitialNeuralAdapter}
 }
 if($current.Status -cne 'Installed' -or [string]$current.AutoCompatibility.Fingerprint -cne $Guard.Fingerprint -or $intent -cne $Guard.Intent){throw 'Auto preparation preferences changed during the operation. The current component choices, adapter and Off preferences were retained. Retry component preparation to replan.'}
 if([string]$current.FrameGenerationRoute -cne $Guard.Route){
  if(-not $AllowedRoute -or [string]$current.FrameGenerationRoute -cne $AllowedRoute){throw 'The selected frame-generation route changed during Auto preparation. Retry component preparation to replan.'}
  $Guard.Route=$AllowedRoute
 }
 return $current
}
function InvokeOptiShadeAutoPreparation([string]$ManifestPath,[string]$Payload,$Gpu,[scriptblock]$Progress={param($text,$completed=0,$total=0)},$Desired=$null,[switch]$RetryFailed,[string[]]$QualificationRecordPaths=@(),$QualificationTarget=$null){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 [void](RecoverOptiShadeRouteTransaction $ManifestPath)
 $manifest=ReadOptiShadeState $ManifestPath;AssertClosed $manifest.Game
 AssertAntiCheatMutation $manifest.Game $manifest.LaunchExe 'Prepare Auto compatibility'
 if($QualificationRecordPaths.Count){ImportOptiShadeStaticQualifications $ManifestPath $QualificationRecordPaths $QualificationTarget;$manifest=ReadOptiShadeState $ManifestPath}
 if(-not $Desired -and $manifest.AutoCompatibility){$Desired=$manifest.AutoCompatibility.Desired}
 $plan=GetOptiShadeAutoPreparationPlan $manifest $Payload $Gpu $Desired
 $prior=$manifest.AutoCompatibility;$same=$prior -and [string]$prior.Fingerprint -ceq $plan.Fingerprint
 $preparation=[pscustomobject]@{Schema=1;Enabled=[bool]$plan.Desired.enabled;Desired=$plan.Preferences;Fingerprint=$plan.Fingerprint;ExecutableHash=$plan.Identity.SHA256;Executable=$plan.Identity.Path;Architecture=$plan.Identity.Architecture;Evidence='installation_only';State='preparing';PreparedUtc='';Features=$plan.Features;RenderingHint=$prior.RenderingHint;NativeFgPreparation=$prior.NativeFgPreparation;StaticQualification=$prior.StaticQualification;StaticRanking=$plan.StaticRanking;StaticSelection=$prior.StaticSelection}
 if($plan.StaticRanking.State -eq 'selected'){$preparation.StaticSelection=[pscustomobject]@{Route=$plan.StaticRanking.SelectedRoute;Id=$plan.StaticRanking.SelectedId;Use=$plan.StaticRanking.Use;Fingerprint=$plan.StaticRanking.Fingerprint}}
 # Commit migrated explicit removals with the same receipt as preparation.
 # An empty list marks the new format; ambiguous older choices remain visible
 # as needs_review feature evidence until an explicit component action resolves it.
 $manifest|Add-Member AutoComponentExclusions @($plan.ComponentIntent.Exclusions) -Force
 $manifest|Add-Member AutoCompatibility $preparation -Force
 $manifest|Add-Member Downloads 'Pending' -Force;WriteState $manifest $ManifestPath
 $guard=[pscustomobject]@{Fingerprint=$plan.Fingerprint;Intent=(GetOptiShadeAutoIntentFingerprint $manifest);Route=[string]$manifest.FrameGenerationRoute;InitialNeuralAdapter=$(if($manifest.NeuralAdapterSelection -ceq 'explicit'){$manifest.NeuralAdapter}else{$null});PreparedNeuralAdapter=$(if($plan.Candidate.State -ceq 'candidate'){GetOptiShadeAdapterReceipt $plan.Candidate.Adapter}else{$null})}
 # GetNewClosure() creates a dynamic module that cannot resolve manager
 # functions dot-sourced into this script scope. Capture function scriptblocks
 # explicitly so the callbacks retain their originating PowerShell session.
 $assertCurrentCommand=(Get-Command AssertOptiShadeAutoPreparationCurrent -CommandType Function).ScriptBlock
 $progressCommand=(Get-Command InvokeOptiShadeMutationProgress -CommandType Function).ScriptBlock
 $ownedPathCommand=(Get-Command OwnedPath -CommandType Function).ScriptBlock
 $writeStateCommand=(Get-Command WriteState -CommandType Function).ScriptBlock
 $preparationProgress={
  param($text,$completed=0,$total=0)
  & $progressCommand $ManifestPath $Progress $text $completed $total
  $null=& $assertCurrentCommand $ManifestPath $guard
 }.GetNewClosure()
 $save={
  $current=& $assertCurrentCommand $ManifestPath $guard
  if(Test-Path -LiteralPath (& $ownedPathCommand (Split-Path $ManifestPath) 'MfgRouteTransaction.json')){throw 'Auto preparation has a pending ownership transaction. Its receipt and recovery files were retained.'}
  $current|Add-Member AutoCompatibility $preparation -Force
  if($preparation.State -ne 'preparing'){
   $needsReview=@($preparation.Features.PSObject.Properties|Where-Object {$_.Value.State -ceq 'needs_review'}).Count -gt 0
   $current|Add-Member Downloads $(if($needsReview -or $preparation.State -in @('partial','recovery_required')){'Pending'}else{'Complete'}) -Force
  }
  & $writeStateCommand $current $ManifestPath
 }.GetNewClosure()
 $steps=@([pscustomobject]@{Feature='imageEffects';Id='Effects'},[pscustomobject]@{Feature='upscaling';Id='Providers'},[pscustomobject]@{Feature='nr';Id='Neural'})
 $index=0
 foreach($step in $steps){
  $index++;$feature=$preparation.Features.($step.Feature)
  if($feature.State -ne 'candidate'){continue}
  if($same -and -not $RetryFailed -and $prior.Features.($step.Feature).State -eq 'failed'){
   $feature.State='failed';$feature.Reason=[string]$prior.Features.($step.Feature).Reason+' Use Retry downloads to explicitly retry this preparation.';& $save;continue
  }
  try{
   & $Progress ('Auto: preparing '+$step.Feature+'...') ($index-1) $steps.Count
   $current=& $assertCurrentCommand $ManifestPath $guard
   if($step.Id -eq 'Mfg'){
    if($feature.Route -eq 'portable-fsr2x'){
     # This selection already has one durable owner. Revalidation preserves its
     # active source and never enables a second frame-generation provider.
      if($current.Architecture -ne 'x86' -and -not(TestOptiShadeAutoComponentVerified $current $plan.Catalogue 'Providers')){$null=InstallOptiShadeAddon $ManifestPath $Payload 'Providers' $plan.Gpu $preparationProgress}
      $current=& $assertCurrentCommand $ManifestPath $guard
      if(-not $same){$null=SelectPortableFsr2x $ManifestPath $Payload;$null=& $assertCurrentCommand $ManifestPath $guard 'portable-fsr2x'}
    }elseif($feature.Route -in @('source','legacy','sm86')){
     if(-not(TestOptiShadeAutoMfgVerified $current $feature.Route)){$null=InstallOptiShadeAddon $ManifestPath $Payload 'Mfg' $plan.Gpu $preparationProgress}
    }elseif($feature.Route -in @('native','native_probe')){
     $providerInstalled=[bool]($current.SourceMfg -or $current.OptionalMfg -or $current.Sm86Mfg)
     $selectionRecorded=if($feature.Route -ceq 'native'){[bool]$current.NativeMfg}else{[bool]$current.DeferredMfg}
     if(-not $providerInstalled -and (-not $selectionRecorded -or 'Mfg' -notin @(GetOptiShadeAddonSelection $current))){RecordOptiShadeAutoMfgSelection $ManifestPath $feature.Route}
    }
    $feature.State=if($feature.Route -eq 'native_probe'){'waiting_for_runtime'}else{'prepared'}
   }elseif($step.Id -eq 'Neural'){
    if(-not(TestOptiShadeAutoComponentVerified $current $plan.Catalogue 'Neural')){$null=InstallOptiShadeAddon $ManifestPath $Payload 'Neural' $plan.NeuralGpu $preparationProgress}
    else{$null=EnsureNeuralRuntime $ManifestPath $plan.NeuralGpu $preparationProgress}
    $feature.State=if($feature.Route -eq 'legacy_nr'){'prepared_waiting_for_inputs'}else{'prepared'}
   }else{
    if(-not(TestOptiShadeAutoComponentVerified $current $plan.Catalogue $step.Id)){$null=InstallOptiShadeAddon $ManifestPath $Payload $step.Id $plan.Gpu $preparationProgress -SkipAllFx}
    $feature.State='prepared'
   }
   $feature.Reason=if($feature.State -eq 'prepared'){'Owned dependencies are prepared. Live admission, accepted intent and output remain unverified.'}else{$feature.Reason}
  }catch{
   $feature.State='failed';$feature.Reason=$_.Exception.GetBaseException().Message
   # A retained journal pins the exact before/after receipt. Do not rewrite it
   # to save a label; the UI derives recovery_required from that same owner.
    if(Test-Path -LiteralPath (& $ownedPathCommand (Split-Path $ManifestPath) 'MfgRouteTransaction.json')){$preparation.State='recovery_required';throw}
  }
  & $save
 }
 $states=@($preparation.Features.PSObject.Properties|ForEach-Object {$_.Value.State})
 $preparation.State=if($states -contains 'failed'){'partial'}elseif(@($states|Where-Object {$_ -like 'waiting_*' -or $_ -in @('unsupported','deferred','needs_wrapper','needs_review','prepared_waiting_for_inputs')}).Count){'prepared_with_limits'}else{'prepared'}
 $preparation.PreparedUtc=[DateTime]::UtcNow.ToString('o');& $save
 & $Progress 'Auto preparation complete; Play will qualify a new live session.' $steps.Count $steps.Count
  $null=& $assertCurrentCommand $ManifestPath $guard
 return $preparation
 }finally{ExitOptiShadeMutation $storeMutation}
}
function FormatOptiShadeAutoPreparation($Preparation,[string]$ManifestPath=''){
 if($ManifestPath -and (Test-Path -LiteralPath (OwnedPath (Split-Path $ManifestPath) 'MfgRouteTransaction.json'))){return 'Auto preparation: recovery_required (installation evidence only). A pending ownership transaction must be recovered or reviewed before preparation continues. Its recorded receipt and recovery files are retained.'}
 if(-not $Preparation){return 'Install OptiShade, choose components, then enable features in game.'}
 $lines=@('Auto preparation: '+[string]$Preparation.State+' (installation evidence only).')
 if($Preparation.StaticRanking -and $Preparation.StaticRanking.Fingerprint -cne 'none'){$lines+=('Static qualification: '+[string]$Preparation.StaticRanking.State+' - '+[string]$Preparation.StaticRanking.Reason)}
 foreach($name in @('nr','upscaling','frameGeneration','imageEffects')){$feature=$Preparation.Features.$name;if($feature){$lines+=($name+': '+$feature.State+' - '+$feature.Reason)}}
 $lines+='Play starts a new Auto session using these preferences. In-game Off is respected for that session.'
 return $lines -join "`n"
}
function NewOptiShadeAutoSessionIntent([string]$Game,$Identity,$Desired,[string]$NotBeforeBirth='0',[DateTime]$Now=[DateTime]::UtcNow){
 $desired=CopyOptiShadeAutoDesired $Desired
 $minimum=[uint64]0;if(-not [uint64]::TryParse($NotBeforeBirth,[ref]$minimum)){throw 'Invalid Play process-birth boundary.'}
 [pscustomobject]@{Game=[IO.Path]::GetFullPath($Game);Executable=[string]$Identity.Path;ExecutableHash=[string]$Identity.SHA256;Desired=$desired;NotBeforeBirth=[string]$minimum;Pid=[uint32]0;Birth='';State='discovering';Reason='Waiting for the selected rendering executable and a live runtime.';CreatedUtc=$Now;DiscoveryDeadlineUtc=$Now.AddMinutes(10);NextPollUtc=$Now;LastSnapshot=$null;LastRequest=$null;LastConfiguredPlan='';HasSubmitted=$false;RequiresRebind=$true;TransportRetries=0;SnapshotFailures=0;RebindCount=0;RebindWindowUtc=$Now;Terminal=$false}
}
function TestOptiShadeAutoSessionSnapshot($Intent,$Snapshot){
 if($Snapshot.schema -ne (GetOptiShadeRuntimeProtocolSchema) -or $Snapshot.code -cne 'ok' -or -not $Snapshot.binding -or $Snapshot.binding.evidence -cne 'os_image_birth_and_pipe_pid'){throw 'Auto requires an operating-system-bound live runtime snapshot.'}
 $birth=[uint64]0;if(-not [uint64]::TryParse([string]$Snapshot.birth,[ref]$birth) -or $birth -lt [uint64]$Intent.NotBeforeBirth -or [string]$Snapshot.binding.birth -cne [string]$Snapshot.birth){throw 'This runtime predates the current Play intent or has changed process birth.'}
 $expected=[string]$Intent.Executable;$actual=[string]$Snapshot.binding.executable
 # C# resolves physical paths using the Windows extended path prefix. Receipts
 # may store their ordinary form; strip only that standard prefix for equality.
 if($expected.StartsWith('\\?\UNC\')){$expected='\\'+$expected.Substring(8)}elseif($expected.StartsWith('\\?\')){$expected=$expected.Substring(4)}
 if($actual.StartsWith('\\?\UNC\')){$actual='\\'+$actual.Substring(8)}elseif($actual.StartsWith('\\?\')){$actual=$actual.Substring(4)}
 if(-not [string]::Equals($expected,$actual,[StringComparison]::OrdinalIgnoreCase)){throw 'This runtime is not the selected rendering executable.'}
 if([uint32]$Snapshot.pid -eq 0 -or ($Intent.Pid -and ([uint32]$Snapshot.pid -ne $Intent.Pid -or [string]$Snapshot.birth -cne $Intent.Birth))){throw 'The bound game session ended or changed. A new Play/Auto action is required.'}
 return $true
}
function GetOptiShadeAutoSessionAction($Intent,$Snapshot,[DateTime]$Now=[DateTime]::UtcNow){
 [void](TestOptiShadeAutoSessionSnapshot $Intent $Snapshot)
 if($Intent.Terminal){return [pscustomobject]@{Operation='observe';Request=$null}}
 if(-not $Snapshot.auto){$Intent.Terminal=$true;$Intent.State='update_required';$Intent.Reason='This live runtime does not advertise Auto. Close the game and update its installed runtime.';return [pscustomobject]@{Operation='observe';Request=$null}}
 $Intent.Pid=[uint32]$Snapshot.pid;$Intent.Birth=[string]$Snapshot.birth;$Intent.LastSnapshot=$Snapshot
 $auto=$Snapshot.auto
 if($Intent.ObserveOnly){$Intent.State=[string]$auto.state;$Intent.Reason=[string]$auto.reason;return [pscustomobject]@{Operation='observe';Request=$null}}
 if($Intent.HasSubmitted){$Intent.Desired=CopyOptiShadeAutoDesired $auto.desired}
 $changed=$Intent.LastConfiguredPlan -and $Intent.LastConfiguredPlan -cne [string]$auto.planId
 if($changed){$Intent.RequiresRebind=$true}
 if($Intent.HasSubmitted -and -not $Intent.Desired.enabled){$Intent.State='off';$Intent.Reason='Current session Auto Off is retained.';$Intent.RequiresRebind=$false;return [pscustomobject]@{Operation='observe';Request=$null}}
 if(-not $Intent.RequiresRebind){$Intent.State=[string]$auto.state;$Intent.Reason=[string]$auto.reason;return [pscustomobject]@{Operation='observe';Request=$null}}
 if(($Now-$Intent.RebindWindowUtc).TotalSeconds -ge 30){$Intent.RebindCount=0;$Intent.RebindWindowUtc=$Now}
 if($Intent.RebindCount -ge 6){$Intent.State='waiting_for_stable_context';$Intent.Reason='The rendering context is changing; Auto is waiting before rebinding.';return [pscustomobject]@{Operation='observe';Request=$null}}
 foreach($name in @('revision','planId','renderingAdapterLuid','deviceIdentity','deviceGenerationSource','deviceGeneration','outputId','outputGeneration','api','architecture','view','providerIdentity','modelIdentity','driverVersion','desired')){if(-not $auto.PSObject.Properties[$name]){throw ('The runtime Auto baseline is missing '+$name)}}
 $request=[ordered]@{schema=(GetOptiShadeRuntimeProtocolSchema);pid=$Intent.Pid;birth=$Intent.Birth;id=[guid]::NewGuid().ToString('N');operation='auto.configure';planId=$auto.planId;revision=$auto.revision;renderingAdapterLuid=$auto.renderingAdapterLuid;deviceIdentity=$auto.deviceIdentity;deviceGenerationSource=$auto.deviceGenerationSource;deviceGeneration=$auto.deviceGeneration;outputId=$auto.outputId;outputGeneration=$auto.outputGeneration;api=$auto.api;architecture=$auto.architecture;view=$auto.view;providerIdentity=$auto.providerIdentity;modelIdentity=$auto.modelIdentity;driverVersion=$auto.driverVersion;desired=(CopyOptiShadeAutoDesired $Intent.Desired)}
 $Intent.LastRequest=$request|ConvertTo-Json -Depth 8 -Compress;$Intent.TransportRetries=0;$Intent.RebindCount++;$Intent.State='requesting';$Intent.Reason='Submitting current-session Auto intent to the observed rendering context.'
 return [pscustomobject]@{Operation='configure';Request=$Intent.LastRequest}
}
function CompleteOptiShadeAutoSessionCommand($Intent,$Response){
 if($Response.schema -ne (GetOptiShadeRuntimeProtocolSchema) -or [uint32]$Response.pid -ne $Intent.Pid -or [string]$Response.birth -cne $Intent.Birth){throw 'The runtime session changed while applying Auto.'}
 $request=$Intent.LastRequest|ConvertFrom-Json
 if([string]$Response.id -cne [string]$request.id){throw 'The Auto response does not match the submitted command.'}
 if($Response.code -eq 'conflict'){$Intent.RequiresRebind=$true;$Intent.LastRequest=$null;$Intent.State='conflict';$Intent.Reason='Rendering context changed; reading a fresh baseline.';return}
 if($Response.code -in @('accepted','queued','waiting_for_rendering_context','restart_required','busy','unavailable')){
  $Intent.HasSubmitted=$true;$Intent.RequiresRebind=$Response.code -eq 'busy';$Intent.LastConfiguredPlan=[string]$request.planId;$Intent.State=[string]$Response.code
  if($Response.auto){$Intent.Desired=CopyOptiShadeAutoDesired $Response.auto.desired;$Intent.Reason=[string]$Response.auto.reason}
  $Intent.LastRequest=$null;return
 }
 $Intent.Terminal=$true;$Intent.State='request_failed';$Intent.Reason='The runtime rejected Auto: '+[string]$Response.code;$Intent.LastRequest=$null
}
function FormatOptiShadeAutoRuntimeSnapshot($Snapshot){
 $auto=$Snapshot.auto
 $lines=@('Session PID '+[string]$Snapshot.pid+' | birth '+[string]$Snapshot.birth)
 if($Snapshot.mfg){
  $mfg=$Snapshot.mfg
  $installation=if($mfg.installationProviderEvidence -like 'matching game manifest receipt*'){[string]$mfg.installationProvider}else{'unknown'}
  $decision=if($mfg.policyDecisionEvidence -like 'matching game manifest provider-policy receipt*'){[string]$mfg.policyDecision}else{'unknown'}
  $loaded=if($mfg.loadedProviderVerified -and $mfg.loadedProvider){[string]$mfg.loadedProvider}else{'unknown'}
  $sourceInput=if($null -ne $mfg.sourceInput){ConvertTo-Json -InputObject $mfg.sourceInput -Compress -Depth 8}else{'unknown ('+[string]$mfg.sourceInputEvidence+')'}
  $requestedMultiplier=if($null -ne $mfg.requestedMultiplier){[string]$mfg.requestedMultiplier}else{'unknown'}
  $accepted=if($null -ne $mfg.accepted){[string]$mfg.accepted}else{'unknown'}
  $ratio=if($null -ne $mfg.effectiveObservedRatio){[string]$mfg.effectiveObservedRatio}else{'unknown'}
  $sampleAge=if($null -ne $mfg.latestOutputSampleAgeMs){[string]$mfg.latestOutputSampleAgeMs+' ms'}else{'unknown'}
  $blocking=if($mfg.firstBlockingReason){[string]$mfg.firstBlockingReason}else{'none reported'}
  $frameGeneration=if($mfg.frameGeneration){[string]$mfg.frameGeneration.kind}else{'unknown'}
  $lines+=('MFG receipt: installation provider='+$installation+'; policy decision='+$decision+'. Receipt does not prove loaded files or visible output.')
  $lines+=('MFG live state: loaded provider='+$loaded+'; frame generation='+$frameGeneration+'; source input='+$sourceInput+'; stage='+[string]$mfg.stage+'; requested multiplier='+$requestedMultiplier+'; accepted='+$accepted+'; observed ratio='+$ratio+'; latest sample age='+$sampleAge+'; first blocker='+$blocking+'.')
 }
 if(-not $auto){$lines+='Live runtime found; Auto capability is unavailable in this installed version.';return $lines -join "`n"}
 $lines[0]+=' | '+[string]$auto.state
 $lines+=('Rendering adapter LUID: '+[string]$auto.renderingAdapterLuid+' | '+[string]$auto.api+' | output '+[string]$auto.outputId)
 foreach($name in @('nr','upscaling','frameGeneration')){
  $feature=$auto.features.$name;if(-not $feature){continue}
  $observed=if($feature.observed.displayVerified){'display verified'}elseif($feature.observed.presentSubmitted){'presentation submitted; display unverified'}elseif($feature.observed.gpuCompleted){'GPU work completed; presentation unverified'}elseif($feature.observed.recorded -or $feature.observed.generated){'work reported; completion unverified'}else{'no output observed'}
  $lines+=($name+': requested='+[string]$feature.requested+'; accepted='+[string]$feature.accepted+'; '+[string]$feature.state+'; '+$observed+'. '+[string]$feature.reason)
 }
 return $lines -join "`n"
}
function GetOptiShadeAutoPreparationHintContext($Snapshot){
 $auto=$Snapshot.auto;$cap=$auto.nativeFgCapability
 # The first snapshot can precede the provider worker's hash publication.
 # Include that publication's identity so it is saved once it becomes ready.
 return (@([string]$Snapshot.birth,[string]$auto.renderingAdapterLuid,[string]$auto.deviceIdentity,[string]$auto.deviceGeneration,[string]$auto.outputId,[string]$auto.outputGeneration,[string]$cap.observed,[string]$cap.providerImageHashed,[string]$cap.providerIdentity,[string]$cap.maximumAdditionalFrames,[string]$cap.view) -join '|')
}
function NewOptiShadeAutoNativeFgPreparation($Intent,$Snapshot,$Candidate){
 $cap=$Snapshot.auto.nativeFgCapability
 if(-not(TestOptiShadeNativeFgCapabilityShape $cap) -or $Candidate.State -ne 'candidate'){return $null}
 foreach($field in @('renderingAdapterLuid','deviceIdentity','deviceGeneration','deviceGenerationSource','outputId','outputGeneration','api','architecture','view')){
  if(-not $Snapshot.auto.PSObject.Properties[$field] -or [string]$cap.$field -cne [string]$Snapshot.auto.$field){return $null}
 }
 $adapter=$Candidate.Adapter
 if([string]$cap.renderingAdapterLuid -cne [string]$adapter.Luid -or [uint32]$cap.vendorId -ne [uint32]$adapter.VendorId -or [uint32]$cap.deviceId -ne [uint32]$adapter.DeviceId -or [int]$cap.renderingFamily -ne [int]$adapter.Family -or [int]$cap.computeMajor -ne [int]$adapter.ComputeMajor -or [int]$cap.computeMinor -ne [int]$adapter.ComputeMinor -or -not $adapter.DriverVersion -or [string]$cap.driverVersion -cne [string]$adapter.DriverVersion){return $null}
 if([string]$cap.executableSha256 -ine [string]$Intent.ExecutableHash -or [string]$cap.executable -ine [IO.Path]::GetFileName([string]$Intent.Executable)){return $null}
 # The native worker already hashed the loaded image away from rendering.
 # Do not hash game/provider files in this timer. Closed-game preparation
 # rechecks their current bytes before this record can select any provider.
 return [pscustomobject]@{Schema=1;ExecutableHash=$Intent.ExecutableHash;Pid=[uint32]$Snapshot.pid;Birth=[string]$Snapshot.birth;Adapter=(GetOptiShadeAdapterReceipt $adapter);ManagerVersion=(GetBundledOptiShadeVersion);ProviderPolicyHash=(HashFile (Join-Path $PSScriptRoot 'provider-policy.json'));Capability=($cap|ConvertTo-Json -Depth 6 -Compress|ConvertFrom-Json);Evidence='verified_process_capability';Use='next_closed_game_preparation_only';CapturedUtc=[DateTime]::UtcNow.ToString('o')}
}
function SaveOptiShadeAutoRenderingHint([string]$ManifestPath,$Intent,$Snapshot,$Gpu){
 # Read-only observation of a protected image is not a reusable binary qualification.
 if($Intent.ObserveOnly -and -not [string]$Intent.ExecutableHash){return $false}
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 [void](TestOptiShadeAutoSessionSnapshot $Intent $Snapshot)
 if(-not $Snapshot.auto.renderingAdapterLuid){return $false}
 $candidate=ResolveOptiShadeAdapterCandidate $Gpu '' ([string]$Snapshot.auto.renderingAdapterLuid)
 if($candidate.State -ne 'candidate'){return $false}
 if(Test-Path -LiteralPath (OwnedPath (Split-Path $ManifestPath) 'MfgRouteTransaction.json')){return $false}
 $manifest=ReadOptiShadeState $ManifestPath
 if(-not $manifest.AutoCompatibility -and $Intent.ObserveOnly){
  $identity=GetOptiShadeRenderingExecutable $manifest
  if($identity.SHA256 -cne $Intent.ExecutableHash -or $identity.Path -ine $Intent.Executable){return $false}
  $manifest|Add-Member AutoCompatibility ([pscustomobject]@{Schema=1;Enabled=$false;ExecutableHash=$identity.SHA256;Desired=(CopyOptiShadeAutoDesired $null $false);Features=[pscustomobject]@{}}) -Force
 }
 if(-not $manifest.AutoCompatibility -or [string]$manifest.AutoCompatibility.ExecutableHash -cne $Intent.ExecutableHash){return $false}
 $hint=[pscustomobject]@{Schema=1;ExecutableHash=$Intent.ExecutableHash;Pid=[uint32]$Snapshot.pid;Birth=[string]$Snapshot.birth;Adapter=(GetOptiShadeAdapterReceipt $candidate.Adapter);DeviceIdentity=$Snapshot.auto.deviceIdentity;DeviceGeneration=$Snapshot.auto.deviceGeneration;DeviceGenerationSource=$Snapshot.auto.deviceGenerationSource;OutputId=$Snapshot.auto.outputId;OutputGeneration=$Snapshot.auto.outputGeneration;Evidence='previous_live_process_snapshot_for_preparation_only'}
 $old=$manifest.AutoCompatibility.RenderingHint
 $changed=-not($old -and [string]$old.Adapter.Luid -ceq [string]$hint.Adapter.Luid -and [string]$old.Adapter.DriverVersion -ceq [string]$hint.Adapter.DriverVersion -and [string]$old.Birth -ceq $hint.Birth -and [string]$old.DeviceIdentity -ceq [string]$hint.DeviceIdentity -and [string]$old.OutputId -ceq [string]$hint.OutputId -and [string]$old.OutputGeneration -ceq [string]$hint.OutputGeneration)
 $native=NewOptiShadeAutoNativeFgPreparation $Intent $Snapshot $candidate
 if($native){
  $previous=$manifest.AutoCompatibility.NativeFgPreparation
  if(-not $previous -or [string]$previous.Birth -cne [string]$native.Birth -or [string]$previous.Capability.providerIdentity -cne [string]$native.Capability.providerIdentity -or [string]$previous.Capability.deviceIdentity -cne [string]$native.Capability.deviceIdentity -or [string]$previous.Capability.outputId -cne [string]$native.Capability.outputId -or [string]$previous.Capability.outputGeneration -cne [string]$native.Capability.outputGeneration -or [string]$previous.Capability.maximumAdditionalFrames -cne [string]$native.Capability.maximumAdditionalFrames){$manifest.AutoCompatibility|Add-Member NativeFgPreparation $native -Force;$changed=$true}
 }
 if(-not $changed){return $false}
 $manifest.AutoCompatibility|Add-Member RenderingHint $hint -Force;WriteState $manifest $ManifestPath;return $true
 }finally{ExitOptiShadeMutation $storeMutation}
}
