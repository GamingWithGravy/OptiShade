# Static qualifications are local, hash-pinned evidence for a declared recorded
# output target. They never authorize live activation or waive runtime checks.
. "$PSScriptRoot/qualified-plan-ranking.ps1"

function ReadOptiShadeQualificationPolicy {
 $policy=ReadOptiShadeJson (Join-Path $PSScriptRoot 'qualification-policy.json') 'Static qualification policy'
 if(-not(TestOptiShadeQualificationPolicy $policy)){throw 'The packaged static qualification policy is unsupported.'}
 return $policy
}
function ReadOptiShadeQualificationRecord([string]$Path,[string]$ExpectedSha256='') {
 if(-not [IO.Path]::IsPathRooted($Path)){throw 'Qualification records need an explicit local file path.'}
 $file=OwnedPath (Split-Path ([IO.Path]::GetFullPath($Path))) ([IO.Path]::GetFileName($Path))
 $policy=ReadOptiShadeQualificationPolicy
 $before=HashFile $file
 if(-not(TestOptiShadeQualificationHash $before) -or ($ExpectedSha256 -and $before -cne $ExpectedSha256)){throw 'Qualification record bytes changed or are unavailable.'}
 $document=ReadOptiShadeJson $file 'Recorded physical qualification' -MaxBytes $policy.maximumDocumentBytes
 if((HashFile $file) -cne $before){throw 'Qualification record changed while being read.'}
 $artifact=$document.source.artifact
 if(-not $artifact -or -not(TestOptiShadeQualificationHash $artifact.sha256) -or -not(TestOptiShadeQualificationText $artifact.path 1024) -or [IO.Path]::IsPathRooted([string]$artifact.path)){throw 'Qualification capture needs a pinned relative artifact path.'}
 $evidence=OwnedPath (Split-Path $file) ([string]$artifact.path)
 if((HashFile $evidence) -cne [string]$artifact.sha256){throw 'Qualification capture artifact is missing or changed.'}
 return [pscustomobject]@{Document=$document;DocumentSha256=$before;ArtifactVerified=$true}
}
function ImportOptiShadeStaticQualifications([string]$ManifestPath,[string[]]$RecordPaths,$Target) {
 $storeMutation=EnterOptiShadeMutation -ManifestPath $ManifestPath
 try{
 # Used by the existing Auto preparation entry point for a qualification run's
 # immutable local records. Import records no Working state and writes no game
 # files. The next planner rechecks all source, package and adapter identities.
 $policy=ReadOptiShadeQualificationPolicy
 if(-not(TestOptiShadeQualificationTarget $Target $policy)){throw 'Static qualification needs explicit comparable target limits and output configuration.'}
 if(-not $RecordPaths.Count -or $RecordPaths.Count -gt $policy.maximumCandidates){throw 'Invalid static qualification record count.'}
 [void](RecoverOptiShadeRouteTransaction $ManifestPath)
 $manifest=ReadOptiShadeState $ManifestPath;AssertClosed $manifest.Game
 $records=@();$ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($path in $RecordPaths){
  $record=ReadOptiShadeQualificationRecord $path
  if(-not $ids.Add([string]$record.Document.candidate.id)){throw 'Only one explicit qualification capture per candidate may be imported.'}
  if((ConvertToOptiShadeQualificationCanonical $record.Document.target) -cne (ConvertToOptiShadeQualificationCanonical $Target)){throw 'Qualification records do not share the declared target.'}
  $records+=[pscustomobject]@{Path=[IO.Path]::GetFullPath($path);Sha256=$record.DocumentSha256}
 }
 if(-not $manifest.AutoCompatibility){$manifest|Add-Member AutoCompatibility ([pscustomobject]@{}) -Force}
 $manifest.AutoCompatibility|Add-Member StaticQualification ([pscustomobject]@{Schema=1;TargetSource='recorded_qualification_target';Use=$policy.use;Target=$Target;Records=$records}) -Force
 WriteState $manifest $ManifestPath
 }finally{ExitOptiShadeMutation $storeMutation}
}
function GetOptiShadeStaticExistingRoute($Manifest) {
 if($Manifest.FrameGenerationRoute -cin @('native','portable-fsr2x')){return [string]$Manifest.FrameGenerationRoute}
 if($Manifest.Sm86Mfg){return 'sm86'}
 if($Manifest.SourceMfg){return 'source'}
 if($Manifest.OptionalMfg){return 'legacy'}
 $preference=$Manifest.AutoCompatibility.StaticSelection
 if($preference -and $preference.Use -ceq 'closed_game_preparation_for_recorded_target_only' -and $preference.Route -cin @('native','portable-fsr2x')){return [string]$preference.Route}
 return ''
}
function GetOptiShadeQualificationPayloadSet([object[]]$Catalogue,[string]$Payload,[string[]]$Paths) {
 $artifacts=@();$ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($path in $Paths){
  if(-not $ids.Add($path)){throw 'Duplicate qualification component identity.'}
  $matches=@($Catalogue|Where-Object {([string]$_.Path).Replace('\','/') -ieq $path})
  if($matches.Count -ne 1 -or -not(TestOptiShadeQualificationHash $matches[0].Hash) -or (HashFile (OwnedPath $Payload $path)) -cne [string]$matches[0].Hash){throw 'Qualified candidate payload identity is unknown or changed.'}
  $artifacts+=[pscustomobject]@{path=$path;sha256=[string]$matches[0].Hash}
 }
 if(-not $artifacts.Count){throw 'Qualified candidate has no pinned component set.'}
 return GetOptiShadeQualificationDigest @($artifacts|Sort-Object path)
}
function GetOptiShadeAutoStaticRanking($Manifest,[string]$Payload,$Gpu,$Identity,[object[]]$Catalogue,$Desired,[string]$ProviderDecision) {
 $empty=[pscustomobject]@{Schema=1;State='unknown';SelectedId='';SelectedRoute='';Reason='No current recorded static qualification is attached; ordinary Auto preparation is retained.';Evidence='recorded_qualification_only';Use='closed_game_preparation_for_recorded_target_only';LiveAdaptivePolicy=$false;Candidates=@();Order=@();Fingerprint='none';Target=$null}
 $receipt=$Manifest.AutoCompatibility.StaticQualification
 if(-not $receipt){return $empty}
 try{
  $policy=ReadOptiShadeQualificationPolicy
  if(-not(TestOptiShadeQualificationKeys $receipt @('Schema','TargetSource','Use','Target','Records')) -or $receipt.Schema -ne 1 -or $receipt.TargetSource -cne 'recorded_qualification_target' -or $receipt.Use -cne $policy.use){throw 'Unknown static qualification receipt.'}
  if(-not $Desired.enabled -or $Desired.frameGeneration -ceq 'off' -or $Desired.nr -cne 'off'){$empty.State='unsupported';throw 'Static qualification selection currently requires explicit NR Off and FG Auto. Existing preferences and combined-route gates are retained.'}
  if($Identity.Architecture -cne 'x64' -or $Manifest.RouteDLL -ceq 'OptiShadeXPlane12.dll'){$empty.State='unsupported';throw 'This static selector cannot admit x86, XP12/Vulkan or external capture routes.'}
  # Resolve the FG candidate independently. A preferred NR GPU cannot qualify
  # the FG renderer. Native capability binds the exact executable/provider,
  # measured adapter/driver and accepted device/output of the recorded session.
  $fg=ResolveOptiShadeMfgAdapter $Gpu $Manifest
  $verified=GetOptiShadeVerifiedGenericMfgPreparation $Manifest $Gpu
  if(-not $verified -or $fg.State -cne 'candidate' -or [string]$fg.Adapter.Luid -cne [string]$verified.Adapter.Luid){throw 'Static FG ranking is waiting for an independently matched real rendering-adapter capability.'}
  $cap=$Manifest.AutoCompatibility.NativeFgPreparation.Capability
  if($cap.api -cne 'd3d12' -or $cap.architecture -cne 'x64'){throw 'Static FG ranking has no admitted current D3D12/x64 provider boundary.'}
  if(-not(TestOptiShadeQualificationTarget $receipt.Target $policy)){throw 'Static qualification has no explicit supported target schema.'}
  $output=$receipt.Target.output
  if($output.kind -cne 'desktop' -or $output.viewCount -ne 1 -or $output.colorSpace -cne 'srgb' -or $output.windowMode -cnotin @('windowed','borderless') -or [string]$output.displayAdapterLuid -cne [string]$fg.Adapter.Luid){$empty.State='unsupported';throw 'This static 2x selector admits only one SDR desktop output on the rendering adapter in windowed/borderless mode. XR, HDR, exclusive mode and cross-adapter output require their separate contracts.'}
  $runtime=@();$paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($entry in @($Manifest.Files)){
   $path=([string]$entry.Path).Replace('\','/')
   if((GetOptiShadeAddonId $path) -cne 'Core' -or (TestOptiShadeMutableFile $path) -or $path -notmatch '\.(dll|exe|addon32|addon64)$'){continue}
   if(-not $paths.Add($path) -or -not(TestOptiShadeQualificationHash $entry.Hash) -or (HashFile (OwnedPath $Manifest.Game $path)) -cne [string]$entry.Hash){throw 'The owned runtime identity is changed or ambiguous.'}
   $runtime+=[pscustomobject]@{path=$path;sha256=[string]$entry.Hash}
  }
  if(-not $runtime.Count){throw 'The current installed runtime has no verified binary identity for static qualification.'}
  $adapter=$fg.Adapter
  $binding=[pscustomobject][ordered]@{executableSha256=$Identity.SHA256;architecture=$Identity.Architecture;api=[string]$cap.api;adapterLuid=[string]$adapter.Luid;vendorId=[uint32]$adapter.VendorId;deviceId=[uint32]$adapter.DeviceId;subSystemId=[uint32]$adapter.SubSystemId;driverVersion=[string]$adapter.DriverVersion;managerVersion=(GetBundledOptiShadeVersion);payloadSha256=(HashFile (Join-Path $Payload 'files.json'));providerPolicySha256=(HashFile (Join-Path $PSScriptRoot 'provider-policy.json'));modelPolicySha256=(HashFile (Join-Path $PSScriptRoot 'neural-model-policy.json'));runtimeFilesSha256=(GetOptiShadeQualificationDigest @($runtime|Sort-Object path));qualificationPolicySha256=(HashFile (Join-Path $PSScriptRoot 'qualification-policy.json'))}
  $nativeSet=GetOptiShadeQualificationDigest @([pscustomobject]@{path=[string]$cap.providerFilePath;sha256=([string]$cap.providerFileSha256).ToUpperInvariant()})
  $candidates=@([pscustomobject]@{Id='native';Route='native';State='candidate';Reason='Real game-owned provider boundary; a matching measured record is still required.';ArtifactSetSha256=$nativeSet})
  # The existing FSR route owns a fixed 2x selection through its current durable
  # transition. No second loader or output scheduler is introduced here.
  try{
   $portableSet=GetOptiShadeQualificationPayloadSet $Catalogue $Payload @('OptiShadeData/Engine/amd_fidelityfx_loader_dx12.dll','OptiShadeData/Engine/amd_fidelityfx_framegeneration_dx12.dll')
   $candidates+=[pscustomobject]@{Id='portable-fsr2x';Route='portable-fsr2x';State='candidate';Reason='Existing admitted FSR 2x provider components.';ArtifactSetSha256=$portableSet}
  }catch{$candidates+=[pscustomobject]@{Id='portable-fsr2x';Route='portable-fsr2x';State='unknown';Reason=$_.Exception.GetBaseException().Message;ArtifactSetSha256=''}}
  # Optional MFG remains on its existing pinned provider policy. Ranking does
  # not choose a different optional binary or infer its configured multiplier.
  if($ProviderDecision -cin @('source','legacy','sm86')){$candidates+=[pscustomobject]@{Id=$ProviderDecision;Route=$ProviderDecision;State='unknown';Reason='Optional MFG remains on its existing pinned policy; its complete configured-multiplier qualification is not provided by this static 2x selector.';ArtifactSetSha256=''}}
  $records=@()
  if(@($receipt.Records).Count -gt $policy.maximumCandidates){throw 'Static qualification receipt exceeds its record budget.'}
  foreach($reference in @($receipt.Records)){
   if(-not(TestOptiShadeQualificationKeys $reference @('Path','Sha256')) -or -not(TestOptiShadeQualificationHash $reference.Sha256)){throw 'Invalid qualification evidence reference.'}
   $records+=ReadOptiShadeQualificationRecord ([string]$reference.Path) ([string]$reference.Sha256)
  }
  $rank=GetOptiShadeQualifiedPlanRanking $binding $receipt.Target $candidates $records $policy (GetOptiShadeStaticExistingRoute $Manifest)
  $rank|Add-Member Target $receipt.Target
  # Preparation diagnostics/capture tooling receives exactly the context that
  # was compared. These are installation facts and a recorded target, not a
  # claim that the next process has already selected that output or budget.
  $rank|Add-Member PreparationBinding $binding
  $rank|Add-Member CandidateIdentities @($candidates)
  return $rank
 }catch{$empty.Reason=$_.Exception.GetBaseException().Message;$empty.Fingerprint=GetOptiShadeQualificationDigest ([ordered]@{receipt=$receipt;reason=$empty.Reason});return $empty}
}
