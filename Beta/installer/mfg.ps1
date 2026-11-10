. "$PSScriptRoot/anti-cheat.ps1"
. "$PSScriptRoot/sm86-mfg.ps1"
. "$PSScriptRoot/provider-policy.ps1"
# Optional upstream RTXMFG integration. Upstream code retains its MIT licence.
function EnsureAutomaticMfg([string]$ManifestPath,[string]$Payload,$GpuNames,[scriptblock]$Progress=$null){
 # Retire automatic installation of the legacy provider. The portable FSR
 # route remains available only for receipts that explicitly selected it.
 $existing=ReadOptiShadeState $ManifestPath
 if($existing.AutoCompatibility){return 'Recorded provider and configuration retained. Use Components to prepare or change optional features.'}
 if($existing.PSObject.Properties['FrameGenerationRoute'] -and $existing.FrameGenerationRoute -eq 'portable-fsr2x'){
  SelectPortableFsr2x $ManifestPath $Payload
  return 'Portable FSR 2x selection retained; legacy MFG provider installation is disabled.'
 }
 return 'Legacy MFG provider installation is disabled. Install OptiMFG separately from Components.'
 $storeMutation=$null;$decision='not-evaluated'
 try{
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 if(Get-Command RecoverOptiShadeRouteTransaction -ErrorAction SilentlyContinue){[void](RecoverOptiShadeRouteTransaction $ManifestPath)}
 $m=ReadOptiShadeState $ManifestPath
 # Core repair already restores its owned payload and retains configuration.
 # Auto owns subsequent preparation/selection for these receipts. Running the
 # older selector here would re-enable a retained FSR route despite Auto Off.
 if($m.AutoCompatibility){return 'Recorded provider and configuration retained. Use Components to prepare or change optional features.'}
 if($m.PSObject.Properties['FrameGenerationRoute'] -and $m.FrameGenerationRoute -eq 'portable-fsr2x'){SelectPortableFsr2x $ManifestPath $Payload;return 'Portable FSR 2x selected; automatic MFG installation is suppressed. Restart to apply; output needs testing.'}
 try{
  $channel=GetOptiShadeMfgPolicyChannel;$decision=GetOptiShadeInstallProviderDecision $m $Payload $GpuNames $channel
  switch($decision){'source'{InstallSourceMfg $ManifestPath $Payload $GpuNames};'legacy'{InstallLegacyMfg $ManifestPath $Payload $GpuNames};'sm86'{InstallSm86Mfg $ManifestPath $GpuNames $Progress};'native'{$null};default{throw ('provider policy selected '+$decision)}}
  WriteOptiShadeMfgAttemptEvidence $ManifestPath $decision $(if($decision -eq 'native'){'selected'}else{'prepared'})
  $message='Provider policy: '+$decision+'. Installation is not proof of live output; rendering-device qualification remains mandatory.'
 }catch{if(Test-Path -LiteralPath (OwnedPath (Split-Path $ManifestPath) 'MfgRouteTransaction.json')){throw};WriteOptiShadeMfgAttemptEvidence $ManifestPath $decision 'failed' $_;$message='Provider policy '+$decision+' was not applied: '+$_.Exception.Message}
 $m=ReadOptiShadeState $ManifestPath;$m|Add-Member ProviderPolicy ([pscustomobject]@{Schema=1;Channel=$channel;Requested=$decision;RecordedSource=[bool]$m.SourceMfg;RecordedLegacy=[bool]$m.OptionalMfg;RecordedSm86=[bool]$m.Sm86Mfg;Evidence='installation_only'}) -Force
 $m|Add-Member AutomaticMfgStatus $message -Force;WriteState $m $ManifestPath;return $message
 }catch{WriteOptiShadeMfgAttemptEvidence $ManifestPath $decision 'failed' $_;throw}
 finally{ExitOptiShadeMutation $storeMutation}
}
function SetMfgIniValue([string]$Text,[string]$Section,[string]$Key,[string]$Value){
 $lines=[Collections.Generic.List[string]]::new();$active=$false;$found=$false;$sectionFound=$false
 foreach($line in ($Text -split '\r?\n')){
  if($line -match '^\s*\[([^]]+)\]'){
   if($active -and -not $found){$lines.Add("$Key=$Value");$found=$true}
   $active=$Matches[1] -eq $Section;if($active){$sectionFound=$true}
  }
  if($active -and $line -match ('^\s*'+[regex]::Escape($Key)+'\s*=')){if(-not $found){$lines.Add("$Key=$Value");$found=$true}}else{$lines.Add($line)}
 }
 if(-not $sectionFound){$lines.Add("[$Section]")}
 if(-not $found){$lines.Add("$Key=$Value")}
 return $lines -join "`r`n"
}
function SelectOptionalMfgLoader($Manifest){
 $aliases=@(GetOptiShadeMfgLoaderAliases)
 $exe='';$imports=@();$identity=$null;$identityError=''
 # Use the same selected rendering image as preparation. A sibling simulator
 # EXE must never supply another game's proxy-import evidence.
 try{$identity=GetOptiShadeRenderingExecutable $Manifest -AllowRecordedUnknown;$exe=[string]$identity.Path;$imports=@($identity.Imports)}catch{$identityError=$_.Exception.GetBaseException().Message}
 $inspectionUnknown=($identityError -or ($identity -and [string]$identity.Evidence -match 'renderer/API and PE hash unknown|rendering executable is not recorded'))
 if($inspectionUnknown){
  # Xbox/MS Store simulator installs may expose only gamelaunchhelper.exe to
  # the manager while Windows denies reads of the actual renderer. That helper
  # is not the graphics process, so its import list cannot disprove the known
  # MSFS route. For this explicit route only, stage the pinned provider under
  # a supported, currently-free alias and let the live game report whether it
  # loads. The route transaction still refuses occupied or unowned targets.
  $knownStoreSimulator=($identity -and [string]$identity.Evidence -match 'Store/Xbox content launch helper selected' -and [string]$Manifest.RouteDLL -in @('OptiShadeMSFS2020.dll','OptiShadeMSFS2024.dll') -and [string]$Manifest.Architecture -ceq 'x64')
  if($knownStoreSimulator -and $aliases -contains 'version.dll' -and -not(Test-Path -LiteralPath (OwnedPath $Manifest.Game 'version.dll')) -and @($Manifest.Files|Where-Object {$_.Path -ieq 'version.dll'}).Count -eq 0){
   return [pscustomobject]@{Name='version.dll';Evidence='MSFS Store/Xbox renderer is unreadable; attempting the pinned provider through free version.dll. Runtime load and MFG output must be checked in-game.'}
  }
  $evidence=if($identityError){$identityError}elseif($identity.Evidence){[string]$identity.Evidence}else{'the selected rendering executable could not be inspected'}
  throw ("Cannot verify a safe MFG loader alias because the selected rendering executable is unknown or unreadable. {0}. No game files were changed. Repair or grant read access to the game executable, then refresh the game list." -f $evidence)
 }
 # Prefer the selected renderer's own imported D3D entry point. In particular,
 # do not pick a generic version.dll merely because it appears before d3d12.dll
 # in the upstream alias list when the game imports both.
 $rendererAliases=@();$apiCandidates=@()
 if($identity -and $identity.PSObject.Properties['ApiCandidates']){$apiCandidates=@($identity.ApiCandidates)}
 $apiAliasMap=@{DX9='d3d9.dll';DX10='d3d10.dll';DX11='d3d11.dll';DX12='d3d12.dll'}
 foreach($api in $apiCandidates){if($apiAliasMap.ContainsKey([string]$api)){$rendererAliases+=,[string]$apiAliasMap[[string]$api]}}
 $orderedAliases=@($rendererAliases)+@($aliases|Where-Object {$_ -ine 'version.dll'})+@('version.dll')
 $orderedAliases=@($orderedAliases|Select-Object -Unique)
 # A static import is stronger evidence that Windows can load the proxy than
 # a DLL-name guess. Each candidate must also be free of game/receipt files.
 foreach($alias in $orderedAliases){
  if($imports -notcontains $alias){continue}
  if(Test-Path -LiteralPath (OwnedPath $Manifest.Game $alias)){continue}
  if(@($Manifest.Files|Where-Object {$_.Path -ieq $alias}).Count){continue}
  $evidence=if($rendererAliases -contains $alias){'Static renderer API import '+$alias+' in '+[IO.Path]::GetFileName($exe)}else{'Static import in '+[IO.Path]::GetFileName($exe)}
  return [pscustomobject]@{Name=$alias;Evidence=$evidence}
 }
 # A filename guess can shadow another mod or a game's own dependency. Do not
 # introduce version.dll (or any other proxy) without evidence that the
 # selected renderer imports it. Keep the user's existing route untouched.
 $evidence=if($identity -and $identity.Evidence){[string]$identity.Evidence}else{'the selected rendering executable could not be inspected'}
 throw ("No supported MFG loader alias is imported by the selected rendering executable. {0}. Keep the existing loader; do not rename or overwrite another game component. Select a supported game executable or keep MFG disabled until a compatible loader path is verified." -f $evidence)
}
function MarkOptiShadeMfgComponentInstalled($Manifest){
 # Current receipts carry an explicit Components list. Provider installers
 # also set their legacy flags, but the manager trusts this list when it is
 # present, so update it with the provider receipt in the same transaction.
 if($Manifest.PSObject.Properties['Components']){
  $components=@($Manifest.Components)
  if('Mfg' -notin $components){$components+=,'Mfg'}
  $Manifest|Add-Member Components @($components|Select-Object -Unique) -Force
 }
}
function SetOptiShadeMfgLoaderRecord($Manifest,[string]$Loader,[string]$ExpectedHash,[string]$PreviousHash,[string]$Backup){
 # Only the exact, immutable receipt for this pinned MFG payload is owned
 # here. Other loader aliases may belong to OptiShade core or another component.
 $aliases=@(GetOptiShadeMfgLoaderAliases)
 $matches=@($Manifest.Files|Where-Object {$_.Path -in $aliases -and $_.Hash -eq $ExpectedHash -and -not $_.Mutable})
 if($matches.Count -gt 1){throw 'Conflicting MFG loader ownership records require recovery before enabling MFG.'}
 if($matches.Count -eq 1){
  $record=$matches[0]
  $record|Add-Member Path $Loader -Force;$record|Add-Member SourcePath '' -Force;$record|Add-Member Hash $ExpectedHash -Force
  $record|Add-Member PreviousHash $PreviousHash -Force;$record|Add-Member Backup $Backup -Force
  $record|Add-Member Mutable $false -Force;$record|Add-Member Retained $true -Force
  return
 }
 $Manifest.Files=@($Manifest.Files)+[pscustomobject]@{Path=$Loader;SourcePath='';Hash=$ExpectedHash;PreviousHash=$PreviousHash;Backup=$Backup;Mutable=$false;Retained=$true}
}
function WriteOptiShadeMfgAdapterEvidence($Gpu,$Manifest,[string]$Purpose){
 if(-not (Get-Command WriteInstallerLog -ErrorAction SilentlyContinue)){return}
 try{
  $candidate=ResolveOptiShadeMfgAdapter $Gpu $Manifest
  if($candidate.State -eq 'candidate'){
   $a=$candidate.Adapter
   WriteInstallerLog ("MFG {0} adapter candidate: name={1}; vendor=0x{2:X4}; device=0x{3:X4}; LUID={4}; family=RTX{5}; evidence={6}; currentRenderingOutput=not-established" -f $Purpose,[string]$a.Name,[uint32]$a.VendorId,[uint32]$a.DeviceId,[string]$a.Luid,[int]$a.Family,[string]$a.ArchitectureEvidence)
  }else{WriteInstallerLog ("MFG {0} adapter candidate unavailable: state={1}; reason={2}" -f $Purpose,[string]$candidate.State,[string]$candidate.Reason)}
 }catch{WriteInstallerLog ("MFG {0} adapter evidence unavailable: {1}" -f $Purpose,$_.Exception.GetBaseException().Message)}
}
function WriteOptiShadeMfgAttemptEvidence([string]$ManifestPath,[string]$Decision,[string]$Outcome,$ErrorRecord=$null){
 if(-not (Get-Command WriteInstallerLog -ErrorAction SilentlyContinue)){return}
 try{
  $manifest=ReadOptiShadeState $ManifestPath
  $files=@()
  foreach($record in @($manifest.Files|Where-Object {$_.Component -eq 'Mfg' -or $_.Path -match '(^|/)MFG/|MFG\\|RTXMFG|dlssg_sm86'})){
   $relative=([string]$record.Path).Replace('\','/')
   $actual='';try{$actual=HashFile (OwnedPath $manifest.Game $relative)}catch{}
   $state=if(-not $actual){'missing'}elseif($record.Hash -and $actual -ieq [string]$record.Hash){'matches-receipt'}else{'changed-from-receipt'}
   $files+=('{0}:{1}:{2}' -f $relative,$state,$actual)
  }
  $identity='';try{$identity=[IO.Path]::GetFileName([string]$manifest.LaunchExe)}catch{}
  $errorText=''
  if($ErrorRecord){$exception=if($ErrorRecord -is [Management.Automation.ErrorRecord]){$ErrorRecord.Exception.GetBaseException()}else{$ErrorRecord.GetBaseException()};$message=[string]$exception.Message
   foreach($sensitivePath in @([string]$manifest.Game,[string](Split-Path $ManifestPath),[string]$env:LOCALAPPDATA,[string]$env:USERPROFILE)){
    if(-not [string]::IsNullOrWhiteSpace($sensitivePath)){$message=[regex]::Replace($message,[regex]::Escape($sensitivePath),'<LOCAL_PATH>',[Text.RegularExpressions.RegexOptions]::IgnoreCase);$message=[regex]::Replace($message,[regex]::Escape($sensitivePath.Replace('\','/')),'<LOCAL_PATH>',[Text.RegularExpressions.RegexOptions]::IgnoreCase)}
   }
   $errorText=('; errorType={0}; hresult=0x{1:X8}; error={2}' -f $exception.GetType().FullName,$exception.HResult,$message)
  }
  WriteInstallerLog ('MFG install evidence: outcome={0}; providerDecision={1}; gameExecutable={2}; receiptSource={3}; receiptLegacy={4}; receiptSm86={5}; files=[{6}]{7}' -f $Outcome,$Decision,$identity,[bool]$manifest.SourceMfg,[bool]$manifest.OptionalMfg,[bool]$manifest.Sm86Mfg,($files -join '|'),$errorText)
 }catch{WriteInstallerLog ('MFG install evidence could not be collected: '+$_.Exception.GetBaseException().Message)}
}
function PrepareOptiShadeDeferredMfgPayload([string]$ManifestPath,[string]$Payload,[string]$Channel,[string]$Decision,[scriptblock]$Progress=$null){
 $m=ReadOptiShadeState $ManifestPath
 if($m.Architecture -ne 'x64'){return $false}
 $metadata=ReadOptiShadeJson (Join-Path $Payload 'OptiShadeData/MFG/source-build.json') 'Source MFG build manifest'
 $source=OwnedPath $Payload 'OptiShadeData/MFG/OptiShadeMFG.dll'
 if($metadata.abi -ne 131072 -or $metadata.sha256 -cne $script:SourceMfgSha256 -or (HashFile $source).ToLowerInvariant() -cne $script:SourceMfgSha256 -or @($metadata.families|Where-Object {$_ -notin @(20,30,40)}).Count){throw 'The inactive MFG payload failed its pinned build identity or capability check.'}
 $relative='OptiShadeData/MFG/OptiShadeMFG.dll';$target=OwnedPath $m.Game $relative;$current=HashFile $target
 if($current){
  $owned=@($m.Files|Where-Object {([string]$_.Path).Replace('\\','/') -ieq $relative})
  if($current -cne $script:SourceMfgSha256.ToUpperInvariant() -or $owned.Count -ne 1 -or $owned[0].Hash -cne $current -or $owned[0].Component -cne 'Mfg'){throw 'An unowned or changed MFG payload already exists. It was left unchanged.'}
 }
 if(Test-Path -LiteralPath (OwnedPath $m.Game 'OptiShadeData/MFG/source-backend.json')){throw 'An MFG activation descriptor already exists. The inactive payload was not staged over an existing route.'}
 [void](InvokeAddonTransaction $ManifestPath 'Mfg' {
  $state=ReadOptiShadeState $ManifestPath
  if(-not (HashFile $target)){
   [void][IO.Directory]::CreateDirectory((Split-Path $target))
   Copy-Item -LiteralPath $source -Destination $target
  }
  if((HashFile $target) -cne $script:SourceMfgSha256.ToUpperInvariant()){throw 'The staged MFG payload failed post-copy verification.'}
  $state=ReadOptiShadeState $ManifestPath
  $state|Add-Member Components @(@(GetOptiShadeAddonSelection $state)+'Mfg'|Select-Object -Unique) -Force
  $state|Add-Member PreparedMfg $true -Force;$state|Add-Member DeferredMfg $true -Force
  $state.PSObject.Properties.Remove('NativeMfg')
  $state|Add-Member ProviderPolicy ([pscustomobject]@{Schema=1;Channel=$Channel;Requested='deferred';RecordedSource=$false;RecordedLegacy=$false;RecordedSm86=$false;Evidence='prepared_waiting_for_supported_loader'}) -Force
  $state|Add-Member AutomaticMfgStatus ('MFG payload prepared inactive for an in-game compatibility check. Install-time route: '+$Decision+'. No loader alias or activation descriptor was added; live game/provider checks decide whether it can run.') -Force
  WriteState $state $ManifestPath
 } $true $Progress)
 return $true
}
function RecordOptiShadeDeferredMfgSelection([string]$ManifestPath,[string]$Channel,[string]$Decision,$ErrorRecord=$null,[string]$Payload='',[scriptblock]$Progress=$null){
 $m=ReadOptiShadeState $ManifestPath
 $prepared=$false;$stageError=$null
 if($Payload){try{$prepared=PrepareOptiShadeDeferredMfgPayload $ManifestPath $Payload $Channel $Decision $Progress}catch{$stageError=$_}}
 $m=ReadOptiShadeState $ManifestPath
 $m|Add-Member Components @(@(GetOptiShadeAddonSelection $m)+'Mfg'|Select-Object -Unique) -Force
 $m|Add-Member DeferredMfg $true -Force;$m.PSObject.Properties.Remove('NativeMfg')
 $evidence=if($prepared){'prepared_waiting_for_supported_loader'}else{'runtime_check_in_game'}
 $m|Add-Member ProviderPolicy ([pscustomobject]@{Schema=1;Channel=$Channel;Requested='deferred';RecordedSource=$false;RecordedLegacy=$false;RecordedSm86=$false;Evidence=$evidence}) -Force
 $reason=if($prepared){'MFG payload prepared inactive for an in-game compatibility check. No loader alias or activation descriptor was added. Install-time result: '+$Decision}else{'MFG selection is installed for an in-game compatibility check. No provider payload was staged; runtime discovery will determine whether this game exposes a compatible path. Install-time result: '+$Decision}
 if($ErrorRecord){$reason+='; provider preparation could not be completed safely, so the selection remains deferred.'}
 if($stageError){$reason+='; inactive payload staging failed safely: '+$stageError.Exception.GetBaseException().Message}
 $m|Add-Member AutomaticMfgStatus $reason -Force
 WriteState $m $ManifestPath
 WriteOptiShadeMfgAttemptEvidence $ManifestPath $Decision 'deferred' $ErrorRecord
 if($prepared){WriteOptiShadeMfgAttemptEvidence $ManifestPath $Decision 'prepared-inactive';return 'MFG payload prepared inactive. No loader or activation marker was added; start the game and check live provider compatibility in-game.'}
 return 'MFG remains selected for an in-game compatibility check, but its payload was not staged. '+$(if($stageError){'Staging stopped safely: '+$stageError.Exception.GetBaseException().Message}else{'This route does not include a compatible payload.'})
}
function InstallOptionalMfg([string]$ManifestPath,[string]$Payload,$GpuNames,[scriptblock]$Progress=$null){
 throw 'The legacy OptiShade MFG installer is retired. Install OptiMFG instead.'
 $storeMutation=$null;$decision='not-evaluated'
 try{
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 if(Get-Command RecoverOptiShadeRouteTransaction -ErrorAction SilentlyContinue){[void](RecoverOptiShadeRouteTransaction $ManifestPath)}
 $guardRecord=ReadOptiShadeState $ManifestPath;AssertAntiCheatMutation $guardRecord.Game $guardRecord.LaunchExe 'Install MFG'
 WriteOptiShadeMfgAdapterEvidence $GpuNames $guardRecord 'install'
 $channel=GetOptiShadeMfgPolicyChannel;$decision=GetOptiShadeInstallProviderDecision (ReadOptiShadeState $ManifestPath) $Payload $GpuNames $channel -AllowPreinstall
 if($decision -eq 'native'){
  # Native game MFG is a valid installed component selection even though it
  # has no separate DLL. Provider support and activation belong to the live
  # in-game callback, not an install-time GPU/renderer probe.
  $m=ReadOptiShadeState $ManifestPath;if($m.PreparedMfg){RemoveOptiShadeAddon $ManifestPath 'Mfg';$m=ReadOptiShadeState $ManifestPath};$m|Add-Member Components @(@(GetOptiShadeAddonSelection $m)+'Mfg'|Select-Object -Unique) -Force
  $m|Add-Member NativeMfg $true -Force;$m.PSObject.Properties.Remove('DeferredMfg')
  $m|Add-Member ProviderPolicy ([pscustomobject]@{Schema=1;Channel=$channel;Requested='native';RecordedSource=$false;RecordedLegacy=$false;RecordedSm86=$false;Evidence='native_provider_checked_in_game'}) -Force
  $m|Add-Member AutomaticMfgStatus 'MFG component installed. Native game provider capability and activation are checked in-game; no separate provider DLL is needed.' -Force
  WriteState $m $ManifestPath
  WriteOptiShadeMfgAttemptEvidence $ManifestPath $decision 'selected'
  return 'MFG component installed for the native game route. Start the game and enable its supported Frame Generation option; live support is checked in-game.'
 }
 if($decision -notin @('source','legacy','sm86')){
  # Unknown or unsupported install-time discovery must not block selecting
  # the component. Record a deferred test route and let the live game be the
  # compatibility check; do not guess a provider, loader alias, or file edit.
  return RecordOptiShadeDeferredMfgSelection $ManifestPath $channel $decision $null $Payload $Progress
 }
 try{switch($decision){'source'{InstallSourceMfg $ManifestPath $Payload $GpuNames};'legacy'{InstallLegacyMfg $ManifestPath $Payload $GpuNames};'sm86'{InstallSm86Mfg $ManifestPath $GpuNames $Progress}}}
 catch{
  # Provider preparation is optional; the component selection is not. Provider
  # installers use a route journal for interrupted mutations. Only fall back to
  # the in-game check when the route has fully rolled back and no provider
  # receipt was committed. Never hide a transaction that needs recovery.
  if(Test-Path -LiteralPath (OwnedPath (Split-Path $ManifestPath) 'MfgRouteTransaction.json')){throw}
  $after=ReadOptiShadeState $ManifestPath
  if($after.SourceMfg -or $after.OptionalMfg -or $after.Sm86Mfg){throw}
  $providerError=$_
  return RecordOptiShadeDeferredMfgSelection $ManifestPath $channel $decision $providerError $Payload $Progress
 }
 WriteOptiShadeMfgAttemptEvidence $ManifestPath $decision 'prepared'
 }catch{WriteOptiShadeMfgAttemptEvidence $ManifestPath $decision 'failed' $_;throw}
 finally{ExitOptiShadeMutation $storeMutation}
}
function InstallLegacyMfg([string]$ManifestPath,[string]$Payload,$GpuNames){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 if(Get-Command RecoverOptiShadeRouteTransaction -ErrorAction SilentlyContinue){[void](RecoverOptiShadeRouteTransaction $ManifestPath)}
 $guardRecord=ReadOptiShadeState $ManifestPath;AssertAntiCheatMutation $guardRecord.Game $guardRecord.LaunchExe 'Install MFG'
 WriteOptiShadeMfgAdapterEvidence $GpuNames $guardRecord 'install'
 if((TestOptiShadeMfgInstallTarget $guardRecord $GpuNames).State -ne 'candidate'){throw 'MFG preparation requires an installed 64-bit game and a measured supported NVIDIA RTX adapter. No provider files were changed.'}
 $candidate=ResolveOptiShadeMfgAdapter $GpuNames $guardRecord
 if($candidate.State -ne 'candidate' -or $candidate.Adapter.Family -ne 40){throw 'This optional MFG setup requires an unambiguous, driver-identified Ada RTX adapter. Existing providers are retained.'}
 $beforeReceiptHash=HashFile $ManifestPath;$m=ReadOptiShadeState $ManifestPath
 if($m.SourceMfg -or $m.Sm86Mfg -or $m.FrameGenerationRoute -eq 'portable-fsr2x'){throw 'Another recorded frame-generation route owns this installation. Select the native route and remove its optional provider before legacy MFG preparation.'}
 if($m.Status -ne 'Installed'){throw 'Install OptiShade first.'}
 AssertClosed $m.Game
 $source=OwnedPath $Payload 'OptiShadeData/MFG/RTXMFG.dll'
 $expected='E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'
 if((HashFile $source) -ne $expected){throw 'Optional MFG payload verification failed.'}
  # Keep the previously recorded alias on repair. If a tester manually moved
  # the pinned DLL to another supported name, verify its hash and adopt that
  # identity instead of reinstalling over version.dll.
  $choice=if($m.OptionalMfg){$null}else{SelectOptionalMfgLoader $m}
  $loader=if($m.OptionalMfg){GetOptiShadeMfgLoaderName $m}else{$choice.Name}
  $dest=OwnedPath $m.Game $loader
 $repairMissing=$false
 if($m.PSObject.Properties['OptionalMfg'] -and $m.OptionalMfg){
   $records=@($m.Files|Where-Object {$_.Path -in (GetOptiShadeMfgLoaderAliases) -and $_.Hash -eq $expected -and -not $_.Mutable})
   if($records.Count -ne 1){throw 'Optional MFG ownership requires review. The current loader and backups were left untouched.'}
   if($records[0].Backup -and (HashFile (OwnedPath (Split-Path $ManifestPath) $records[0].Backup)) -ne $records[0].PreviousHash){throw 'Optional MFG original backup failed verification. No files were changed.'}
  $current=HashFile $dest
  # A repeat click is a verified no-op. Preserve the user's later FG choices.
   if($current -eq $expected){
    if($records[0].Path -ne $loader){SetOptiShadeMfgLoaderRecord $m $loader $expected $records[0].PreviousHash $records[0].Backup;$m|Add-Member OptionalMfgLoader $loader -Force;WriteState $m $ManifestPath}
    return
   }
   if($current){throw "Optional MFG $loader changed after installation. Review the conflict before reinstalling; no files were changed."}
  # A missing owned file can be safely repaired from the same pinned payload.
  $repairMissing=$true
 }
  if(Test-Path -LiteralPath $dest){throw "Optional MFG $loader is already occupied. No existing loader was replaced."}
 foreach($name in @('RTX40MFGCore.dll','RTX40MFG.asi','RTX40MFG-UI.addon64','RTXMFG.dll','dlss-enabler-headless.dll')){
  if((Test-Path -LiteralPath (OwnedPath $m.Game $name)) -or (Test-Path -LiteralPath (OwnedPath $m.Game ('OptiShadeData/Engine/'+$name)))){throw 'Another MFG component is present. Remove it using its own instructions before enabling optional MFG.'}
 }
 $ini=OwnedPath $m.Game 'OptiScaler.ini';$iniBeforeHash=HashFile $ini
 $text=[IO.File]::ReadAllText($ini)
 if(-not $repairMissing){
  $text=SetMfgIniValue $text 'FrameGen' 'External' 'true'
  $text=SetMfgIniValue $text 'DLSSG' 'AdaMfgUnlock' 'false'
  $text=SetMfgIniValue $text 'DLSSG' 'AmpereMfgUnlock' 'false'
 }
 # All target bytes, original chains and the new receipt are prepared before
 # the existing durable route owner performs the first replacement.
 $previous=@($m.Files|Where-Object {$_.Path -in (GetOptiShadeMfgLoaderAliases) -and $_.Hash -eq $expected -and -not $_.Mutable})
 if($previous.Count -gt 1){throw 'Conflicting MFG loader ownership records require recovery before enabling MFG.'}
 $backup='';$previousHash='';if($previous.Count){$backup=$previous[0].Backup;$previousHash=$previous[0].PreviousHash}
 SetOptiShadeMfgLoaderRecord $m $loader $expected $previousHash $backup
 $m|Add-Member ProviderAdapter (GetOptiShadeAdapterReceipt $candidate.Adapter) -Force
 $m|Add-Member OptionalMfg $true -Force;MarkOptiShadeMfgComponentInstalled $m
 $m.PSObject.Properties.Remove('PreparedMfg');$m.PSObject.Properties.Remove('DeferredMfg');$m.PSObject.Properties.Remove('NativeMfg')
 $m|Add-Member OptionalMfgLoader $loader -Force
 $m|Add-Member OptionalMfgLoaderEvidence $(if($choice){$choice.Evidence}else{'Verified existing alias'}) -Force
 $m|Add-Member OptionalMfgVersion 'v1.3.3-hotfix.2' -Force
 $changes=@([pscustomobject]@{Path=$loader;BeforeHash='';Source=$source;AfterHash=$expected})
 if(-not $repairMissing){$changes+=[pscustomobject]@{Path='OptiScaler.ini';BeforeHash=$iniBeforeHash;Bytes=[Text.UTF8Encoding]::new($false).GetBytes($text)}}
 InvokeOptiShadeRouteTransaction $ManifestPath $beforeReceiptHash $m $changes ('MfgRollback/'+[guid]::NewGuid().ToString('N')) 'Legacy MFG preparation'
 }finally{ExitOptiShadeMutation $storeMutation}
}

$script:SourceMfgSha256="1a74bd7b79581a42ff7025c0e177d8976d43c64179037354a8e62b9c54ee37bc"
function SelectPortableFsr2x([string]$ManifestPath,[string]$Payload){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 [void](RecoverOptiShadeRouteTransaction $ManifestPath)
 $beforeReceiptHash=HashFile $ManifestPath;$m=ReadOptiShadeState $ManifestPath
 if($m.Status -ne 'Installed'){throw 'Install OptiShade first.'}
 AssertClosed $m.Game
 if(-not(TestOptiShadeMfgPreparationGame $m (GetOptiShadeGpuFacts))){throw 'This route requires the qualified MSFS path or a verified current-executable D3D12/Vulkan Streamline DLSS-G capability receipt. Vulkan alone does not qualify a game for MFG.'}
 # Reuse the installed Fusion engine and its pinned FFX provider. No new proxy or scheduler.
 $catalog=ReadOptiShadeJson (Join-Path $Payload 'files.json') 'Payload inventory' -Shape Array
 foreach($relative in @('OptiShadeData/Engine/amd_fidelityfx_loader_dx12.dll','OptiShadeData/Engine/amd_fidelityfx_framegeneration_dx12.dll')){
  $entry=@($catalog|Where-Object {$_.Path.Replace('\','/') -eq $relative})
  $owned=@($m.Files|Where-Object {$_.Path.Replace('\','/') -eq $relative})
  if($entry.Count -ne 1 -or $owned.Count -ne 1 -or $owned[0].Mutable -or $owned[0].Hash -ne $entry[0].Hash -or (HashFile (OwnedPath $m.Game $relative)) -ne $entry[0].Hash){throw "Repair the matching installed provider first: $relative"}
 }
 $changes=@();$sm86Paths=@();$retire=@()
 # Plan SM86 removal without committing a nested transaction. Every byte and
 # the pre-SM86 receipt are saved before the first provider file is changed.
 if($m.Sm86Mfg){
  $sm86Paths=@($m.Sm86MfgFiles|ForEach-Object {([string]$_).Replace('\','/')})
  if(-not $sm86Paths.Count -or @($sm86Paths|Select-Object -Unique).Count -ne $sm86Paths.Count){throw 'SM86 ownership paths are missing or duplicated.'}
  foreach($relative in $sm86Paths){
   $record=@($m.Files|Where-Object {$_.Path.Replace('\','/') -eq $relative -and $_.Component -eq 'Mfg'})
   if($record.Count -ne 1){throw "SM86 ownership record is missing or ambiguous: $relative"}
   $current=[string](HashFile (OwnedPath $m.Game $relative))
   if($current -and $current -cne [string]$record[0].Hash -and -not $record[0].Mutable){throw "SM86 component file changed: $relative. No files were removed."}
   # Preserve a user-edited mutable provider config, as standalone removal does.
   if(-not $current -or ($record[0].Mutable -and $current -cne [string]$record[0].Hash)){continue}
   $source='';$afterHash=''
   if($record[0].Backup){
    $source=OwnedPath (Split-Path $ManifestPath) ([string]$record[0].Backup);$afterHash=[string]$record[0].PreviousHash
    if(-not $afterHash -or (HashFile $source) -cne $afterHash){throw "SM86 original backup is missing or changed: $relative"}
   }
   $changes+=[pscustomobject]@{Path=$relative;BeforeHash=$current;Source=$source;AfterHash=$afterHash}
  }
 }
 $legacyLoader=if($m.OptionalMfg){GetOptiShadeMfgLoaderName $m}else{'version.dll'}
 foreach($relative in @($legacyLoader,'OptiShadeData/MFG/source-backend.json')){
  if($relative -in $sm86Paths){continue}
  $hash=HashFile (OwnedPath $m.Game $relative);if(-not $hash){continue}
  $owned=@($m.Files|Where-Object {$_.Path.Replace('\','/') -eq $relative})
  # An exact core proxy is not an additional frame-generation provider.
  if($owned.Count -eq 1 -and $owned[0].SourcePath -eq 'winmm.dll' -and -not $owned[0].Mutable -and $owned[0].Hash -ceq $hash){continue}
  if($relative -in (GetOptiShadeMfgLoaderAliases)){
   $owned=@($m.Files|Where-Object {$_.Path -in (GetOptiShadeMfgLoaderAliases) -and $_.Hash -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'})
   if(-not $m.OptionalMfg -or $hash -ne 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'){throw "Existing $relative is not the owned legacy MFG provider."}
  }elseif(-not $m.SourceMfg){throw 'Source provider receipt has no matching ownership.'}
  if($owned.Count -ne 1 -or $owned[0].Mutable -or $owned[0].Hash -ne $hash){throw "Unowned or changed provider file: $relative. Nothing changed."}
  $owned[0].Path=$relative;$retire+=,$relative
  $changes+=[pscustomobject]@{Path=$relative;BeforeHash=$hash;Source='';AfterHash=''}
 }
 foreach($relative in @('RTXMFG.dll','RTX40MFGCore.dll','RTX40MFG.asi','RTX40MFG-UI.addon64','dlss-enabler-headless.dll')){
  if(Test-Path -LiteralPath (OwnedPath $m.Game $relative)){throw "Competing provider requires review: $relative"}
 }
 $ini=OwnedPath $m.Game 'OptiScaler.ini';$iniHash=HashFile $ini;$text=[IO.File]::ReadAllText($ini)
 foreach($pair in @(@('External','false'),@('FGInput','DLSSG'),@('FGOutput','FSRFG'),@('Enabled','true'))){$text=SetMfgIniValue $text 'FrameGen' $pair[0] $pair[1]}
 foreach($key in @('AdaMfgUnlock','AmpereMfgUnlock')){$text=SetMfgIniValue $text 'DLSSG' $key 'false'}
 $text=SetMfgIniValue $text 'fakenvapi' 'ForceXeLL' 'false'
 $text=SetMfgIniValue $text 'DLSSG' 'OverrideInterpolationCount' '1'
 $changes+=[pscustomobject]@{Path='OptiScaler.ini';BeforeHash=$iniHash;Bytes=([Text.UTF8Encoding]::new($false).GetBytes($text))}
 foreach($entry in $m.Files){if($entry.Path.Replace('\','/') -in $retire){$entry.Hash='';$entry.SourcePath='';$entry.Retained=$true}}
 if($m.Sm86Mfg){
  $m.Files=@($m.Files|Where-Object {$_.Path.Replace('\','/') -notin $sm86Paths})
  if($m.PSObject.Properties['Components']){$m|Add-Member Components @($m.Components|Where-Object {$_ -ne 'Mfg'}) -Force}
  foreach($key in @('Sm86Mfg','Sm86MfgVersion','Sm86MfgSHA256','Sm86MfgLoader','Sm86MfgFiles','Sm86MfgIniBefore')){$m.PSObject.Properties.Remove($key)}
 }
 $rollbackRelative='MfgRollback/'+[guid]::NewGuid().ToString('N')
 $m|Add-Member SourceMfg $false -Force;$m|Add-Member OptionalMfg $false -Force
 $m|Add-Member FrameGenerationRoute 'portable-fsr2x' -Force
 $m|Add-Member FrameGenerationRouteRollback (OwnedPath (Split-Path $ManifestPath) $rollbackRelative) -Force
 $m|Add-Member ProviderPolicy ([pscustomobject]@{Schema=1;Channel=(GetOptiShadeMfgPolicyChannel);Requested='portable-fsr2x';RecordedSource=$false;RecordedLegacy=$false;RecordedSm86=$false;Evidence='installation_only'}) -Force
 $m|Add-Member AutomaticMfgStatus 'Portable FSR 2x selected. Restart in DX12 and enable game DLSS frame generation. Test with NR off first. Active output remains unverified.' -Force
 InvokeOptiShadeRouteTransaction $ManifestPath $beforeReceiptHash $m $changes $rollbackRelative
 }finally{ExitOptiShadeMutation $storeMutation}
}
function InstallSourceMfg([string]$ManifestPath,[string]$Payload,$GpuNames){
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 if(Get-Command RecoverOptiShadeRouteTransaction -ErrorAction SilentlyContinue){[void](RecoverOptiShadeRouteTransaction $ManifestPath)}
 $guardRecord=ReadOptiShadeState $ManifestPath;AssertAntiCheatMutation $guardRecord.Game $guardRecord.LaunchExe 'Install MFG'
 WriteOptiShadeMfgAdapterEvidence $GpuNames $guardRecord 'install'
 if((TestOptiShadeMfgInstallTarget $guardRecord $GpuNames).State -ne 'candidate'){throw 'MFG preparation requires an installed 64-bit game and a measured supported NVIDIA RTX adapter. No provider files were changed.'}
 $beforeReceiptHash=HashFile $ManifestPath;$m=ReadOptiShadeState $ManifestPath
 if($m.Sm86Mfg -or $m.FrameGenerationRoute -eq 'portable-fsr2x'){throw 'Another recorded frame-generation route owns this installation. Select native game FG and remove that optional provider before source MFG preparation.'}
 if($m.Status -ne 'Installed'){throw 'Install OptiShade first.'}
 AssertClosed $m.Game
 $candidate=ResolveOptiShadeMfgAdapter $GpuNames $guardRecord
 # FG identity never comes from an unrelated NR preference.
 if($candidate.State -ne 'candidate'){throw ('No measured MFG installation candidate: '+$candidate.Reason)}
 $family=[int]$candidate.Adapter.Family
 if((GetOptiShadeProviderDecision (GetOptiShadeMfgPolicyChannel) $family $true $false $true $false $true $true) -ne 'source'){throw 'The shared provider policy does not admit this source-MFG family. Native provider retained.'}
 $metadata=ReadOptiShadeJson (Join-Path $Payload 'OptiShadeData/MFG/source-build.json') 'Source MFG build manifest'
 $source=OwnedPath $Payload 'OptiShadeData/MFG/OptiShadeMFG.dll'
 if($metadata.abi -ne 131072 -or $metadata.sha256 -cne $script:SourceMfgSha256 -or (HashFile $source).ToLowerInvariant() -cne $script:SourceMfgSha256 -or $family -notin @($metadata.families)){throw 'Source MFG build identity/capability manifest mismatch.'}
 foreach($name in @('RTXMFG.dll','RTX40MFGCore.dll','RTX40MFG.asi','RTX40MFG-UI.addon64','dlss-enabler-headless.dll')){
  if(Test-Path -LiteralPath (OwnedPath $m.Game $name)){throw "Another provider file requires review: $name. Nothing was changed."}
 }
 $legacyLoader=if($m.OptionalMfg){GetOptiShadeMfgLoaderName $m}else{'version.dll'}
 $legacy=OwnedPath $m.Game $legacyLoader;$legacyHash=HashFile $legacy
 if($legacyHash){
  $owned=@($m.Files|Where-Object {$_.Path -in (GetOptiShadeMfgLoaderAliases) -and $_.Hash -eq $legacyHash})
  if(-not $m.OptionalMfg -or $owned.Count -ne 1 -or $legacyHash -ne 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'){throw "Existing $legacyLoader is not the recorded legacy MFG backend. Review it in Setup; nothing was changed."}
 }
 $rollbackRelative='MfgRollback/'+[guid]::NewGuid().ToString('N');$folder=Split-Path $ManifestPath;$rollback=OwnedPath $folder $rollbackRelative
 $ini=OwnedPath $m.Game 'OptiScaler.ini';$iniBeforeHash=HashFile $ini;$text=[IO.File]::ReadAllText($ini)
 $text=SetMfgIniValue $text 'FrameGen' 'External' 'true';$text=SetMfgIniValue $text 'DLSSG' 'AdaMfgUnlock' 'false';$text=SetMfgIniValue $text 'DLSSG' 'AmpereMfgUnlock' 'false'
 $activationValue=[ordered]@{schema=1;abi=131072;sha256=$script:SourceMfgSha256;selectedGpu=$candidate.Adapter.Name;adapter=(GetOptiShadeAdapterReceipt $candidate.Adapter);family=$family;status='Installed; awaiting actual rendering device and game connection'}
 $activationBytes=[Text.UTF8Encoding]::new($false).GetBytes(($activationValue|ConvertTo-Json -Depth 8))
 $sha=[Security.Cryptography.SHA256]::Create();try{$activationHash=[BitConverter]::ToString($sha.ComputeHash($activationBytes)).Replace('-','')}finally{$sha.Dispose()}
 $changes=@()
 if($legacyHash){$changes+=[pscustomobject]@{Path=$legacyLoader;BeforeHash=$legacyHash;Source='';AfterHash=''}}
 foreach($item in @([pscustomobject]@{Path='OptiShadeData/MFG/OptiShadeMFG.dll';Hash=$script:SourceMfgSha256.ToUpperInvariant();Source=$source;Bytes=$null},[pscustomobject]@{Path='OptiShadeData/MFG/source-backend.json';Hash=$activationHash;Source='';Bytes=$activationBytes})){
  $dest=OwnedPath $m.Game $item.Path;$current=[string](HashFile $dest);$existing=@($m.Files|Where-Object {([string]$_.Path).Replace('\','/') -ieq $item.Path})
  if($existing.Count -gt 1){throw 'Conflicting source MFG original ownership records require recovery.'}
  if($current -and ($existing.Count -ne 1 -or $existing[0].Mutable -or $current -cne [string]$existing[0].Hash)){throw ('Source MFG destination is unowned or changed: '+$item.Path+'. Existing files were retained.')}
  if($existing.Count -and $existing[0].Backup -and (HashFile (OwnedPath $folder $existing[0].Backup)) -cne [string]$existing[0].PreviousHash){throw 'Source MFG original backup failed verification.'}
  $backup=if($existing.Count){[string]$existing[0].Backup}else{''};$previous=if($existing.Count){[string]$existing[0].PreviousHash}else{''}
  $m.Files=@($m.Files|Where-Object {([string]$_.Path).Replace('\','/') -ine $item.Path})+[pscustomobject]@{Path=$item.Path;SourcePath=$(if($item.Path -like '*.dll'){$item.Path}else{''});Hash=$item.Hash;PreviousHash=$previous;Backup=$backup;Mutable=$false;Retained=$true;Component='Mfg'}
  if($item.Bytes){$activationChange=[pscustomobject]@{Path=$item.Path;BeforeHash=$current;Bytes=[byte[]]$item.Bytes}}
  else{$changes+=[pscustomobject]@{Path=$item.Path;BeforeHash=$current;Source=$item.Source;AfterHash=$item.Hash}}
 }
 # The activation descriptor is last, after the old provider was retired.
 $changes+=[pscustomobject]@{Path='OptiScaler.ini';BeforeHash=$iniBeforeHash;Bytes=[Text.UTF8Encoding]::new($false).GetBytes($text)};$changes+=$activationChange
 foreach($entry in @($m.Files|Where-Object {$_.Path -in (GetOptiShadeMfgLoaderAliases) -and $_.Hash -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'})){$entry.Hash='';$entry.SourcePath='';$entry.Retained=$true}
 # Keep the original pre-source settings through repairs. For a first source
 # install the common journal produces this exact INI snapshot before mutation;
 # the existing migration reader uses its compact compatibility receipt.
 if(-not $m.SourceMfg -or -not $m.SourceMfgRollback){
  [void][IO.Directory]::CreateDirectory($rollback)
  WriteState ([pscustomobject]@{Game=$m.Game;Files=@([pscustomobject]@{Path='OptiScaler.ini';Hash=$iniBeforeHash;Copy=(OwnedPath $rollback 'OptiScaler.ini')})}) (OwnedPath $rollback 'rollback.json')
  $m|Add-Member SourceMfgRollback $rollback -Force
 }
 $m|Add-Member ProviderAdapter (GetOptiShadeAdapterReceipt $candidate.Adapter) -Force
 $m|Add-Member OptionalMfg $false -Force;$m|Add-Member SourceMfg $true -Force;MarkOptiShadeMfgComponentInstalled $m
 $m.PSObject.Properties.Remove('PreparedMfg');$m.PSObject.Properties.Remove('DeferredMfg');$m.PSObject.Properties.Remove('NativeMfg')
 $m.PSObject.Properties.Remove('FrameGenerationRoute')
 $m|Add-Member AutomaticMfgStatus 'Source-built MFG installed. Use Performance > Multi Frame Generation in OptiShade. Hardware output still requires target testing.' -Force
 InvokeOptiShadeRouteTransaction $ManifestPath $beforeReceiptHash $m $changes $rollbackRelative 'Source MFG preparation'
 }finally{ExitOptiShadeMutation $storeMutation}
}
