$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/components.ps1"
. "$root/Beta/installer/neural-download.ps1"
. "$root/Beta/installer/mfg.ps1"
. "$root/Beta/installer/auto-compatibility.ps1"
$script:checks=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Clone($Value){$Value|ConvertTo-Json -Depth 30 -Compress|ConvertFrom-Json}
function OwnedPath([string]$Root,[string]$Relative){
 $base=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
 $target=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
 if(-not $target.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture path escapes its declared root.'}
 $check=$target;while($check){if(Test-Path -LiteralPath $check){if((Get-Item -LiteralPath $check -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked fixture path refused.'}};$next=Split-Path $check -Parent;if($next -eq $check){break};$check=$next};return $target
}
function AssertClosed([string]$Game){if(-not(Test-Path -LiteralPath (Join-Path $Game 'fixture-only')) -or (Test-Path -LiteralPath (Join-Path $Game 'fixture-running'))){throw 'Fixture game is not closed.'}}
function AssertAntiCheatMutation([string]$Game,[string]$Exe,[string]$Action){AssertClosed $Game}
function GetOptiShadeGpuFacts {return $script:fixtureGpu}
function WriteFixtureExe([string]$Path){
 $bytes=New-Object byte[] 1024;$stream=[IO.MemoryStream]::new($bytes,$true);$writer=[IO.BinaryWriter]::new($stream)
 try{$writer.Write([uint16]0x5a4d);$stream.Position=0x3c;$writer.Write([uint32]0x80);$stream.Position=0x80;$writer.Write([uint32]0x4550);$writer.Write([uint16]0x8664);$writer.Write([uint16]1);$stream.Position=0x94;$writer.Write([uint16]240);$writer.Write([uint16]2);$writer.Write([uint16]0x20b);$stream.Position=0x98+60;$writer.Write([uint32]512);$stream.Position=0x98+240+8;$writer.Write([uint32]512);$writer.Write([uint32]0x1000);$writer.Write([uint32]512);$writer.Write([uint32]512)}finally{$writer.Dispose()};[IO.File]::WriteAllBytes($Path,$bytes)
}
function NewRecord($Binding,$Target,$Candidate,[decimal]$Quality,[string]$ArtifactPath){
 $sourceId='fixture-capture-'+$Candidate.Id;$values=@($Quality,10,2,4000,12,16);$measurements=[ordered]@{};$i=0
 foreach($metric in $script:policy.metrics){$measurements[$metric.name]=[pscustomobject]@{state='measured';value=$values[$i++];unit=$metric.unit;method=$Target.methods.($metric.name);recordId=$sourceId}}
 $output=[ordered]@{};foreach($name in $script:policy.requiredOutputEvidence){$output[$name]=[pscustomobject]@{state='measured';recordId=$sourceId}}
 [pscustomobject]@{schema=1;policyRevision=1;source=[pscustomobject]@{kind='reviewed_physical_game_capture';schema=1;recordId=$sourceId;capturedUtc=[DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture);session=[pscustomobject]@{pid=1234;birth='200';executableSha256=$Binding.executableSha256;adapterLuid=$Binding.adapterLuid;deviceIdentity='device-1';deviceGeneration=1;outputId='output-1';outputGeneration=1;providerArtifactsSha256=$Candidate.ArtifactSetSha256};artifact=[pscustomobject]@{path=[IO.Path]::GetFileName($ArtifactPath);sha256=(HashFile $ArtifactPath)}};binding=(Clone $Binding);target=(Clone $Target);candidate=[pscustomobject]@{id=$Candidate.Id;route=$Candidate.Route;artifactSetSha256=$Candidate.ArtifactSetSha256;multiplier=2};qualification=[pscustomobject]@{state='measured';reason='Explicitly synthetic fixture record; no real hardware qualification';samples=120;durationMs=2000};measurements=[pscustomobject]$measurements;outputEvidence=[pscustomobject]$output}
}
function Wrap($Document){[pscustomobject]@{Document=$Document;DocumentSha256=(GetOptiShadeQualificationDigest $Document);ArtifactVerified=$true}}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-qualified-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($fixture)
try{
 $script:policy=ReadOptiShadeQualificationPolicy
 Check (TestOptiShadeQualificationPolicy $script:policy) 'Canonical qualification policy was rejected.'
 foreach($field in @('bindingFields','outputFields','requiredOutputEvidence','tieBreak')){
  $bad=Clone $script:policy;$bad.$field=@($bad.$field|Select-Object -Skip 1)
  Check (-not(TestOptiShadeQualificationPolicy $bad)) ('Omitted revision-1 '+$field+' changed admission semantics.')
  $bad=Clone $script:policy;[Array]::Reverse($bad.$field)
  Check (-not(TestOptiShadeQualificationPolicy $bad)) ('Reordered revision-1 '+$field+' changed admission semantics.')
 }
 foreach($field in @('unit','maximum','integer')){$bad=Clone $script:policy;$bad.metrics[0].$field=if($field -eq 'integer'){$true}else{'different'};Check (-not(TestOptiShadeQualificationPolicy $bad)) ('Changed metric '+$field+' was accepted at the same policy revision.')}
 foreach($field in @('schema','revision','recordSchema')){$bad=Clone $script:policy;$bad.$field='1';Check (-not(TestOptiShadeQualificationPolicy $bad)) ('String '+$field+' was coerced into a trusted policy version.')}
 $bad=Clone $script:policy;$bad.liveAdaptivePolicy=$true;Check (-not(TestOptiShadeQualificationPolicy $bad)) 'Live adaptive policy was enabled through static ranking.'
 $target=[pscustomobject]@{comparisonId=('A'*64);configurationSha256=('B'*64);featureScope='frame_generation_only_nr_off';output=[pscustomobject]@{kind='desktop';width=1920;height=1080;colorSpace='srgb';windowMode='borderless';refreshNumerator=120;refreshDenominator=1;displayAdapterLuid='42';displayIdentity='fixture-display';viewCount=1};limits=[pscustomobject]@{maximumQualityLoss=0.1;maximumLatencyP95Ms=30;maximumGpuOverheadP95Ms=8;maximumMemoryBytes=8000;maximumFrameAgeP95Ms=30;maximumRealFrameP95Ms=40;minimumSamples=60;minimumDurationMs=1000;maximumAgeSeconds=600;availableMemoryBytes=10000;requiredMemoryHeadroomBytes=1000};methods=[pscustomobject]@{qualityLoss='fixture-normalized-loss-v1';latencyP95Ms='fixture-input-to-photon-v1';gpuOverheadP95Ms='fixture-paired-gpu-v1';peakMemoryBytes='fixture-peak-resident-v1';frameAgeP95Ms='fixture-capture-to-display-v1';realFrameP95Ms='fixture-real-present-v1'}}
 Check (TestOptiShadeQualificationTarget $target $script:policy) 'Declared fixture output/latency/memory contract was rejected.'
 $game=Join-Path $fixture 'game';$payload=Join-Path $fixture 'payload';$captureRoot=Join-Path $fixture 'captures'
 foreach($directory in @($game,$payload,$captureRoot)){[void][IO.Directory]::CreateDirectory($directory)}
 $exe=Join-Path $game 'ForzaHorizon4.exe';WriteFixtureExe $exe
 [IO.File]::WriteAllText((Join-Path $game 'fixture-only'),'fixture');[IO.File]::WriteAllText((Join-Path $game 'dxgi.dll'),'fixture runtime, never loaded');[IO.File]::WriteAllText((Join-Path $game 'OptiScaler.ini'),"[FrameGen]`nFGType=Auto`n")
 $nativeProvider=Join-Path $game 'sl.dlss_g.dll';[IO.File]::WriteAllText($nativeProvider,'fixture provider, never loaded');$providerHash=HashFile $nativeProvider
 $catalogue=@();$files=@();foreach($relative in @('OptiShadeData/Shaders/Fixture.fx','OptiShadeData/Engine/libxess.dll','OptiShadeData/Engine/amd_fidelityfx_loader_dx12.dll','OptiShadeData/Engine/amd_fidelityfx_framegeneration_dx12.dll')){
  foreach($base in @($game,$payload)){$path=Join-Path $base $relative;[void][IO.Directory]::CreateDirectory((Split-Path $path));[IO.File]::WriteAllText($path,'fixture payload '+$relative)}
  $hash=HashFile (Join-Path $payload $relative);$catalogue+=[pscustomobject]@{Path=$relative;Hash=$hash};$files+=[pscustomobject]@{Path=$relative;Hash=$hash;Mutable=$false}
 }
 WriteState @($catalogue) (Join-Path $payload 'files.json')
 $files+=[pscustomobject]@{Path='dxgi.dll';Hash=(HashFile (Join-Path $game 'dxgi.dll'));Mutable=$false};$files+=[pscustomobject]@{Path='OptiScaler.ini';Hash=(HashFile (Join-Path $game 'OptiScaler.ini'));Mutable=$true}
 $identity=GetOptiShadeExecutableIdentity $exe
 $script:fixtureGpu=[pscustomobject]@{Known=$true;Complete=$true;Names='NVIDIA RTX fixture';Adapters=@([pscustomobject]@{Name='NVIDIA RTX fixture';Luid='42';VendorId=0x10DE;DeviceId=0x2684;SubSystemId=1;Software=$false;ComputeCapabilityKnown=$true;ComputeMajor=8;ComputeMinor=9;Family=40;DriverVersion='nvcuda-file:32.0.15.8000'})}
 $desired=CopyOptiShadeAutoDesired;$desired.nr='off'
 $manifest=Join-Path $fixture 'manifest.json'
 $cap=[pscustomobject]@{kind='native_streamline_dlssg';observed=$true;passive=$true;api='d3d12';architecture='x64';vendorId=0x10DE;deviceId=0x2684;renderingFamily=40;computeMajor=8;computeMinor=9;driverVersion='nvcuda-file:32.0.15.8000';renderingAdapterLuid='42';deviceIdentity='device-1';deviceGeneration=1;deviceGenerationSource='primary_output_binding';outputId='output-1';outputGeneration=1;view=0;executable=[IO.Path]::GetFileName($exe);executableSha256=$identity.SHA256;providerIdentity=('streamline-dlssg-file:'+$providerHash);providerFileSha256=$providerHash;providerFilePath=$nativeProvider;providerImageHashed=$true;maximumAdditionalFrames=1;sampleAgeMs=10;evidence='forwarded_game_get_state'}
 $nativeReceipt=[pscustomobject]@{Schema=1;ExecutableHash=$identity.SHA256;Pid=1234;Birth='200';Adapter=(GetOptiShadeAdapterReceipt $script:fixtureGpu.Adapters[0]);ManagerVersion=(GetBundledOptiShadeVersion);ProviderPolicyHash=(HashFile "$root/Beta/installer/provider-policy.json");Capability=$cap;Evidence='verified_process_capability'}
 $m=[pscustomobject]@{Game=$game;Status='Installed';Version=(GetBundledOptiShadeVersion);LaunchExe=$exe;Architecture='x64';RouteDLL='OptiShadeGeneric.dll';Components=@('Effects','Providers');Files=$files;AutoCompatibility=[pscustomobject]@{Desired=$desired;NativeFgPreparation=$nativeReceipt;StaticQualification=[pscustomobject]@{Schema=1;TargetSource='recorded_qualification_target';Use=$script:policy.use;Target=$target;Records=@()}}}
 WriteState $m $manifest
 $emptyPlan=GetOptiShadeAutoPreparationPlan $m $payload $script:fixtureGpu $desired
 Check ($emptyPlan.StaticRanking.State -eq 'unknown' -and $emptyPlan.Features.frameGeneration.Route -eq 'native_probe') ('An empty qualification invented a selected provider: '+$emptyPlan.StaticRanking.Reason)
 Check ($emptyPlan.StaticRanking.PreparationBinding.adapterLuid -ceq '42') ('Production planner did not expose its actual FG preparation identity: '+$emptyPlan.StaticRanking.Reason)
 $binding=$emptyPlan.StaticRanking.PreparationBinding;$candidates=@($emptyPlan.StaticRanking.CandidateIdentities)
 $capture=Join-Path $captureRoot 'capture-fixture.bin';[IO.File]::WriteAllText($capture,'Synthetic fixture bytes, not a reviewed physical capture.')
 $native=NewRecord $binding $target (@($candidates|Where-Object Id -eq 'native')[0]) 0.04 $capture
 $portable=NewRecord $binding $target (@($candidates|Where-Object Id -eq 'portable-fsr2x')[0]) 0.01 $capture
 $nativePath=Join-Path $captureRoot 'native.json';$portablePath=Join-Path $captureRoot 'portable.json';WriteState $native $nativePath;WriteState $portable $portablePath
 $records=@((Wrap $native),(Wrap $portable))
 $rank=GetOptiShadeQualifiedPlanRanking $binding $target $candidates $records $script:policy
 Check ($rank.State -eq 'selected' -and $rank.SelectedRoute -eq 'portable-fsr2x' -and @($rank.Candidates|Where-Object State -eq 'measured').Count -eq 2) ('Comparable records did not rank by declared quality: '+($rank.Candidates|ConvertTo-Json -Depth 8 -Compress))
 $rankReverse=GetOptiShadeQualifiedPlanRanking $binding $target @($candidates[1],$candidates[0]) @($records[1],$records[0]) $script:policy
 Check ($rankReverse.Fingerprint -ceq $rank.Fingerprint) 'Input order changed deterministic ranking or its fingerprint.'
 $tie=Clone $portable;$tie.measurements=Clone $native.measurements;foreach($metric in $script:policy.metrics){$tie.measurements.($metric.name).recordId=$tie.source.recordId}
 $tied=GetOptiShadeQualifiedPlanRanking $binding $target $candidates @((Wrap $native),(Wrap $tie)) $script:policy
 Check ($tied.SelectedRoute -eq 'native') 'Exact metric ties did not use ordinal candidate ID.'
 $oldCulture=[Globalization.CultureInfo]::CurrentCulture
 try{[Globalization.CultureInfo]::CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('tr-TR');$culture=GetOptiShadeQualifiedPlanRanking $binding $target @($candidates[1],$candidates[0]) @((Wrap $tie),(Wrap $native)) $script:policy;Check ($culture.Fingerprint -ceq $tied.Fingerprint) 'Culture changed ordering or numeric identity.'}finally{[Globalization.CultureInfo]::CurrentCulture=$oldCulture}
 foreach($metric in $script:policy.metrics){
  $a=Clone $native;$b=Clone $tie;$b.measurements.($metric.name).value=if($metric.name -eq 'qualityLoss'){0.03}elseif($metric.name -eq 'peakMemoryBytes'){3999}else{[decimal]$a.measurements.($metric.name).value-1}
  $result=GetOptiShadeQualifiedPlanRanking $binding $target $candidates @((Wrap $a),(Wrap $b)) $script:policy
  Check ($result.SelectedRoute -eq 'portable-fsr2x') ('Lexicographic '+$metric.name+' comparison was ignored: '+($result|ConvertTo-Json -Depth 8 -Compress))
 }
 $preserved=GetOptiShadeQualifiedPlanRanking $binding $target $candidates $records $script:policy 'native'
 Check ($preserved.State -eq 'preserved' -and $preserved.SelectedRoute -eq 'native') 'A lower metric replaced an existing selection.'
 foreach($field in $script:policy.bindingFields){
  $bad=Clone $portable
  if($field -in @('vendorId','deviceId','subSystemId')){$bad.binding.$field=[long]$bad.binding.$field+1}else{$bad.binding.$field=[string]$bad.binding.$field+'x'}
  $result=GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy
  Check ($result.State -eq 'unknown') ('Stale '+$field+' evidence was accepted.')
 }
 foreach($field in $script:policy.outputFields){
  $bad=Clone $portable;if($field -in @('width','height','refreshNumerator','refreshDenominator','viewCount')){$bad.target.output.$field=[long]$bad.target.output.$field+1}else{$bad.target.output.$field=[string]$bad.target.output.$field+'x'}
  Check ((GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy).State -eq 'unknown') ('Changed '+$field+' output contract was reused.')
 }
 foreach($metric in $script:policy.metrics){
  foreach($state in @('unknown','unsupported')){$bad=Clone $portable;$bad.measurements.($metric.name).state=$state;$bad.measurements.($metric.name).value=$null;$result=GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy;Check ($result.State -eq $state) ('Missing '+$metric.name+' '+$state+' was collapsed to zero/measured.')}
  foreach($field in @('unit','method','recordId')){$bad=Clone $portable;$bad.measurements.($metric.name).$field='other';Check ((GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy).State -eq 'unknown') ('Unbound '+$metric.name+' '+$field+' was accepted.')}
  $bad=Clone $portable;$bad.measurements.($metric.name).value=-1;Check ((GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy).State -eq 'unknown') ('Negative '+$metric.name+' was accepted.')
 }
 foreach($value in @([double]::NaN,[double]::PositiveInfinity,'1')){$bad=Clone $portable;$bad.measurements.latencyP95Ms.value=$value;Check ((GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy).State -eq 'unknown') 'Nonfinite/string latency was coerced into measured evidence.'}
 foreach($name in $script:policy.requiredOutputEvidence){$bad=Clone $portable;$bad.outputEvidence.$name.state='submitted';Check ((GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy).State -eq 'unknown') ('A submitted counter replaced '+$name+' output evidence.')}
 foreach($kind in @('provider_counter','software_gl','warp','cpu_fixture')){$bad=Clone $portable;$bad.source.kind=$kind;Check ((GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy).State -eq 'unknown') ('Nonphysical '+$kind+' supplied physical qualification.')}
 foreach($field in @('schema','policyRevision')){$bad=Clone $portable;$bad.$field=2;Check ((GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy).State -eq 'unknown') ('Unknown '+$field+' was accepted.')}
 foreach($field in @('pid','birth','deviceIdentity','deviceGeneration','outputId','outputGeneration','providerArtifactsSha256')){$bad=Clone $portable;$bad.source.session.$field=$null;Check ((GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy).State -eq 'unknown') ('Missing source '+$field+' binding was accepted.')}
 foreach($delta in @(-601,60)){$bad=Clone $portable;$bad.source.capturedUtc=[DateTime]::UtcNow.AddSeconds($delta).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');Check ((GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy).State -eq 'unknown') 'Stale/future capture was admitted.'}
 $bad=Clone $portable;$bad.measurements.peakMemoryBytes.value=9500;$bad.target.limits.maximumMemoryBytes=10000;$memoryTarget=Clone $bad.target
 Check ((GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $memoryTarget $script:policy).State -eq 'unsupported') 'Recorded peak plus declared headroom exceeded the memory budget.'
 $bad=Clone $portable;$bad.measurements.latencyP95Ms.value=31;Check ((GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy).State -eq 'unsupported') 'Declared latency limit was ignored.'
 $bad=Clone $portable;$bad.qualification.samples=59;Check ((GetOptiShadeQualificationRecordResult (Wrap $bad) $candidates[1] $binding $target $script:policy).State -eq 'unknown') 'Insufficient sample count qualified a plan.'
 $bad=Clone $target;$bad.limits.PSObject.Properties.Remove('maximumLatencyP95Ms');Check ((GetOptiShadeQualifiedPlanRanking $binding $bad $candidates $records $script:policy).State -eq 'unknown') 'A missing latency limit was replaced with a guessed threshold.'
 Check ((GetOptiShadeQualifiedPlanRanking $binding $target @($candidates[0],$candidates[0]) $records $script:policy).State -eq 'unknown') 'Duplicate candidates were silently tie-broken.'
 Check ((GetOptiShadeQualifiedPlanRanking $binding $target $candidates @($records[0],$records[1],$records[1]) $script:policy).State -eq 'unknown') 'Multiple records were cherry-picked for one candidate.'
 $unverified=Clone $records[1];$unverified.ArtifactVerified=$false;Check ((GetOptiShadeQualificationRecordResult $unverified $candidates[1] $binding $target $script:policy).State -eq 'unknown') 'Unchecked source bytes supplied qualification.'
 # Actual planner consumes hash-pinned on-disk evidence and changes the real
 # preparation route; neither registry import nor ranking sets a live intent.
 ImportOptiShadeStaticQualifications $manifest @($nativePath,$portablePath) $target
 $m=ReadOptiShadeState $manifest;$plan=GetOptiShadeAutoPreparationPlan $m $payload $script:fixtureGpu $desired
 Check ($plan.StaticRanking.State -eq 'selected' -and $plan.Features.frameGeneration.Route -eq 'portable-fsr2x' -and $plan.Features.frameGeneration.Evidence -eq 'installation_only') 'Actual Auto planner did not consume the selected static route honestly.'
 Check (-not $plan.StaticRanking.LiveAdaptivePolicy -and $plan.StaticRanking.Use -eq 'closed_game_preparation_for_recorded_target_only') 'Static selection acquired live/adaptive authority.'
 $before=HashFile $manifest;$failed=$false;try{ImportOptiShadeStaticQualifications $manifest @($nativePath,$nativePath) $target}catch{$failed=$true};Check ($failed -and (HashFile $manifest) -ceq $before) 'Duplicate import partially replaced the evidence receipt.'
 $nativeBytes=[IO.File]::ReadAllBytes($nativeProvider);[IO.File]::WriteAllText($nativeProvider,'changed provider');$badPlan=GetOptiShadeAutoPreparationPlan $m $payload $script:fixtureGpu $desired;Check ($badPlan.StaticRanking.State -eq 'unknown' -and $badPlan.Features.frameGeneration.Route -ne 'portable-fsr2x') 'Changed actual provider bytes reused static qualification.';[IO.File]::WriteAllBytes($nativeProvider,$nativeBytes)
 $reportBytes=[IO.File]::ReadAllBytes($portablePath);[IO.File]::AppendAllText($portablePath,"`n");Check ((GetOptiShadeAutoPreparationPlan $m $payload $script:fixtureGpu $desired).StaticRanking.State -eq 'unknown') 'Changed pinned record bytes were silently reparsed.';[IO.File]::WriteAllBytes($portablePath,$reportBytes)
 $captureBytes=[IO.File]::ReadAllBytes($capture);[IO.File]::WriteAllText($capture,'changed capture');Check ((GetOptiShadeAutoPreparationPlan $m $payload $script:fixtureGpu $desired).StaticRanking.State -eq 'unknown') 'Changed source capture bytes were trusted.';[IO.File]::WriteAllBytes($capture,$captureBytes)
 $core=Join-Path $game 'dxgi.dll';$coreBytes=[IO.File]::ReadAllBytes($core);[IO.File]::WriteAllText($core,'changed runtime');Check ((GetOptiShadeAutoPreparationPlan $m $payload $script:fixtureGpu $desired).StaticRanking.State -eq 'unknown') 'Changed runtime bytes retained qualification.';[IO.File]::WriteAllBytes($core,$coreBytes)
 $other=Clone $script:fixtureGpu.Adapters[0];$other.Luid='99';$other.Name='Other selected NR GPU';$script:fixtureGpu.Adapters+=@($other);$m|Add-Member NeuralAdapter (GetOptiShadeAdapterReceipt $other) -Force
 $different=GetOptiShadeAutoPreparationPlan $m $payload $script:fixtureGpu $desired
 Check ($different.Candidate.Adapter.Luid -ceq '99' -and $different.StaticRanking.PreparationBinding.adapterLuid -ceq '42' -and $different.StaticRanking.State -eq 'selected') 'The NR preference was reused as the FG rendering adapter.'
 $script:fixtureGpu.Adapters=@($script:fixtureGpu.Adapters[0]);$m.PSObject.Properties.Remove('NeuralAdapter')
 # Representable capture targets cannot admit an output mode that this actual
 # desktop provider selector has not independently qualified.
 foreach($case in @(
  @{name='OpenXR single view';kind='openxr';viewCount=1;windowMode='xr';expected='unsupported'},
  @{name='OpenXR multiple views';kind='openxr';viewCount=2;windowMode='xr';expected='unsupported'},
  @{name='scRGB HDR';colorSpace='scrgb';expected='unsupported'},
  @{name='PQ HDR';colorSpace='pq';expected='unsupported'},
  @{name='exclusive fullscreen';windowMode='exclusive';expected='unsupported'},
  @{name='cross-adapter display';displayAdapterLuid='99';expected='unsupported'},
  @{name='invalid multiple-view desktop';viewCount=2;expected='unknown'}
 )){
  $different=Clone $m
  foreach($key in $case.Keys){if($key -notin @('name','expected')){$different.AutoCompatibility.StaticQualification.Target.output.$key=$case[$key]}}
  $blocked=GetOptiShadeAutoPreparationPlan $different $payload $script:fixtureGpu $desired
  Check ($blocked.StaticRanking.State -ceq $case.expected -and $blocked.Features.frameGeneration.Route -ne 'portable-fsr2x') ('Recorded data admitted '+$case.name+' without an independent production output contract.')
 }
 $off=Clone $desired;$off.frameGeneration='off';$disabled=GetOptiShadeAutoPreparationPlan $m $payload $script:fixtureGpu $off;Check ($disabled.Features.frameGeneration.State -eq 'off' -and $disabled.StaticRanking.State -eq 'unsupported') 'A qualification record replaced explicit FG Off.'
 $combined=CopyOptiShadeAutoDesired;Check ((GetOptiShadeAutoPreparationPlan $m $payload $script:fixtureGpu $combined).StaticRanking.State -eq 'unsupported') 'FG-only evidence qualified combined NR+FG.'
 $xp=Clone $m;$xp.RouteDLL='OptiShadeXPlane12.dll';Check ((GetOptiShadeAutoPreparationPlan $xp $payload $script:fixtureGpu $desired).StaticRanking.State -eq 'unsupported') 'Static records bypassed the XP12 implementation/qualification gate.'
 foreach($route in @('native','portable-fsr2x')){$selected=Clone $m;$selected|Add-Member FrameGenerationRoute $route -Force;$preserve=GetOptiShadeAutoPreparationPlan $selected $payload $script:fixtureGpu $desired;Check ($preserve.Features.frameGeneration.Route -eq $route -and $preserve.StaticRanking.State -eq 'preserved') ('Static ranking replaced explicit '+$route+' selection.')}
 # Production preparation executes the existing FSR transaction; only its OS
 # GPU inventory and closed-game/anti-cheat boundaries are fixture-controlled.
 $prepared=InvokeOptiShadeAutoPreparation $manifest $payload $script:fixtureGpu {param($text,$completed,$total)} $desired -QualificationRecordPaths @($nativePath,$portablePath) -QualificationTarget $target
 $installed=ReadOptiShadeState $manifest
 Check ($prepared.Features.frameGeneration.Route -eq 'portable-fsr2x' -and $prepared.Features.frameGeneration.State -eq 'prepared' -and $installed.FrameGenerationRoute -eq 'portable-fsr2x') ('Ranked FSR choice did not reach the real provider transaction: '+$prepared.Features.frameGeneration.Reason)
 Check ($installed.AutoCompatibility.StaticQualification.Records.Count -eq 2 -and $installed.AutoCompatibility.StaticSelection.Route -eq 'portable-fsr2x') 'Preparation lost the immutable evidence references or retained selection.'
 Check (-not(GetOptiShadeRouteRecovery $manifest)) 'Static selection left an incomplete provider transaction.'
 Check ((FormatOptiShadeAutoPreparation $prepared) -match 'Static qualification: selected') 'Actual manager preparation summary omitted static ranking state.'
 [IO.File]::AppendAllText($portablePath,"`n");$keep=GetOptiShadeAutoPreparationPlan (ReadOptiShadeState $manifest) $payload $script:fixtureGpu $desired
 Check ($keep.StaticRanking.State -eq 'unknown' -and $keep.Features.frameGeneration.Route -eq 'portable-fsr2x') 'Expired/changed evidence migrated a previously prepared route.'
 "Qualified static planning: $script:checks assertions passed. Real parser, hash-bound records, actual Auto preparation and existing FSR transaction executed; all capture values/provider bytes/GPU inventory are synthetic fixture inputs, not physical qualification."
}finally{Remove-Item -LiteralPath $fixture -Recurse -Force}
