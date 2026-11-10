$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/components.ps1"
. "$root/Beta/installer/neural-download.ps1"
. "$root/Beta/installer/mfg.ps1"
. "$root/Beta/installer/runtime-control.ps1"
. "$root/Beta/installer/auto-compatibility.ps1"
InitializeOptiShadeRuntimeControl
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
function Snapshot($Identity,[string]$Plan='plan-1',[string]$Luid='42',[int]$Generation=1){
 $auto=[pscustomobject]@{revision=1;planId=$Plan;renderingAdapterLuid=$Luid;deviceIdentity='device-1';deviceGenerationSource='primary_output_binding';deviceGeneration=$Generation;outputId='output-1';outputGeneration=$Generation;api='d3d12';architecture='x64';view=0;providerIdentity='';modelIdentity='fixture-model';driverVersion='nvcuda-file:32.0.15.8000';desired=[pscustomobject]@{enabled=$false;nr='off';upscaling='off';frameGeneration='off'};state='off';reason='fixture state';features=[pscustomobject]@{}}
 [pscustomobject]@{schema=2;pid=1234;birth='200';code='ok';binding=[pscustomobject]@{executable=$Identity.Path;birth='200';evidence='os_image_birth_and_pipe_pid'};auto=$auto}
}
function Response($Request,$Auto,[string]$Code='accepted'){
 $requestObject=$Request|ConvertFrom-Json;$auto.desired=$requestObject.desired
 [pscustomobject]@{schema=2;pid=$requestObject.pid;birth=$requestObject.birth;id=$requestObject.id;code=$Code;auto=$Auto}
}
try{
 $game=Join-Path $fixture 'game';$payload=Join-Path $fixture 'payload';[void][IO.Directory]::CreateDirectory($game);[void][IO.Directory]::CreateDirectory($payload)
 $exe=Join-Path $game 'ForzaHorizon4.exe';WriteFixtureExe $exe;[IO.File]::WriteAllText((Join-Path $game 'fixture-only'),'fixture');[IO.File]::WriteAllText((Join-Path $game 'OptiScaler.ini'),'[DlssNR]')
 $catalogue=@();foreach($relative in @('OptiShadeData/Shaders/Fixture.fx','OptiShadeData/Engine/libxess.dll','OptiShadeData/Engine/amd_fidelityfx_loader_dx12.dll','OptiShadeData/Engine/amd_fidelityfx_framegeneration_dx12.dll','OptiShadeData/Engine/nvngx_dlss.dll')){
  $file=Join-Path $payload $relative;[void][IO.Directory]::CreateDirectory((Split-Path $file));[IO.File]::WriteAllText($file,'CPU fixture bytes '+$relative)
  $catalogue+=[pscustomobject]@{Path=$relative;Hash=(HashFile $file)}
 }
 WriteState @($catalogue) (Join-Path $payload 'files.json');$script:fixtureModel=Join-Path $fixture 'fixture-model';[IO.File]::WriteAllText($script:fixtureModel,'fake model; never loaded')
 $manifest=Join-Path $fixture 'manifest.json';WriteState ([pscustomobject]@{Game=$game;Status='Installed';Version=(GetBundledOptiShadeVersion);LaunchExe=$exe;Architecture='x64';RouteDLL='OptiShadeGeneric.dll';Components=@();Files=@()}) $manifest
 $gpu=[pscustomobject]@{Known=$true;Complete=$true;Names='NVIDIA RTX fixture';Adapters=@([pscustomobject]@{Name='NVIDIA RTX fixture';Luid='42';VendorId=0x10DE;DeviceId=0x2684;SubSystemId=1;Software=$false;ComputeCapabilityKnown=$true;ComputeMajor=8;ComputeMinor=9;Family=40;DriverVersion='nvcuda-file:32.0.15.8000'})}
 # The manager executes preparation from a delayed WPF action scriptblock.
 # Invoke the production function through that same closure boundary so helper
 # command lookup remains covered by this integration fixture.
 $prepareAutoCommand=(Get-Command InvokeOptiShadeAutoPreparation -CommandType Function).ScriptBlock
 $prepareAutoAction={& $prepareAutoCommand $manifest $payload $gpu {param($text,$completed,$total)}}.GetNewClosure()
 $prepared=& $prepareAutoAction
 Check ($prepared -isnot [array] -and $prepared.Schema -eq 1) 'Preparation leaked progress/provider output into its returned plan.'
 Check ($prepared.Features.imageEffects.State -eq 'prepared' -and $prepared.Features.upscaling.State -eq 'prepared' -and $prepared.Features.nr.State -eq 'prepared') 'One Auto call did not prepare the actual eligible component dependencies.'
 Check ($prepared.Features.frameGeneration.State -eq 'off' -and $prepared.Features.frameGeneration.Route -eq '') 'Retired MFG was still advertised by Auto.'
 $m=ReadOptiShadeState $manifest;Check (@($m.Components|Where-Object {$_ -in @('Effects','Providers','Neural','Mfg')}).Count -eq 3 -and -not $m.DeferredMfg -and -not $m.NativeMfg) 'Auto selected or recorded the retired MFG component.'
 Check (@($m.Files|Where-Object {$_.Component -eq 'Mfg'}).Count -eq 0 -and -not(Test-Path -LiteralPath (Join-Path $game 'OptiShadeData/MFG/OptiShadeMFG.dll')) -and -not(Test-Path -LiteralPath (Join-Path $game 'version.dll'))) 'Auto staged retired MFG files or a guessed loader.'
 Check (Test-Path -LiteralPath (Join-Path $game 'OptiShadeData/Neural-runtime.json')) 'Auto omitted the runtime-verifiable NR preparation identity.'
 Check ($script:modelDownloads -eq 1 -and $script:nvidiaPreparations -eq 1) 'Auto did not call the existing pinned model/provider boundary exactly once.'
 $again=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {param($text,$completed,$total)}
 Check ($again.Fingerprint -ceq $prepared.Fingerprint -and $script:modelDownloads -eq 1 -and $script:nvidiaPreparations -eq 1) 'An unchanged Auto Play repeatedly downloaded or reinstalled dependencies.'
 $identity=GetOptiShadeExecutableIdentity $exe;$intent=NewOptiShadeAutoSessionIntent $game $identity $prepared.Desired '100';$snap=Snapshot $identity
 $observer=NewOptiShadeAutoSessionIntent $game $identity $prepared.Desired '100';$observer|Add-Member ObserveOnly $true
 $observed=GetOptiShadeAutoSessionAction $observer $snap
 Check ($observed.Operation -eq 'observe' -and -not $observed.Request -and -not $observer.LastRequest -and $observer.Pid -eq $snap.pid) 'Automatic launch observation must bind the runtime without sending feature configuration.'
 $changedSnapshot=Snapshot $identity 'different-plan'
 $observed=GetOptiShadeAutoSessionAction $observer $changedSnapshot
 Check ($observed.Operation -eq 'observe' -and -not $observer.HasSubmitted -and -not $observer.LastRequest) 'A rendering context change must not turn observation into Auto activation.'
 $savedReceipt=[IO.File]::ReadAllBytes($manifest)
 $coreOnly=ReadOptiShadeState $manifest;$coreOnly.PSObject.Properties.Remove('AutoCompatibility');WriteState $coreOnly $manifest
 Check (SaveOptiShadeAutoRenderingHint $manifest $observer $snap $gpu) 'Read-only launch observation must retain adapter evidence for explicit component installation.'
 $observedReceipt=ReadOptiShadeState $manifest
 Check (-not $observedReceipt.AutoCompatibility.Enabled -and -not $observedReceipt.AutoCompatibility.Desired.enabled -and $observedReceipt.AutoCompatibility.RenderingHint.Adapter.Luid -eq '42') 'Observation must not enable Auto while saving component preparation evidence.'
 [IO.File]::WriteAllBytes($manifest,$savedReceipt)


 $action=GetOptiShadeAutoSessionAction $intent $snap;$request=$action.Request|ConvertFrom-Json
 Check ($action.Operation -eq 'configure' -and $request.schema -eq [OptiShadeControlClient]::ProtocolSchema -and $request.operation -ceq 'auto.configure' -and $request.desired.nr -ceq 'auto') 'Prepared preferences did not produce a schema-current live Auto request.'
 Check ($request.deviceIdentity -ceq $snap.auto.deviceIdentity -and $request.deviceGenerationSource -ceq $snap.auto.deviceGenerationSource -and $request.revision -eq $snap.auto.revision -and $request.planId -ceq $snap.auto.planId -and $request.renderingAdapterLuid -ceq $snap.auto.renderingAdapterLuid -and $request.outputGeneration -eq $snap.auto.outputGeneration) 'Auto invented or omitted a live CAS baseline field.'
 foreach($field in @('api','architecture','view','providerIdentity','modelIdentity','driverVersion')){Check ([string]$request.$field -ceq [string]$snap.auto.$field) ('Auto omitted or invented the live '+$field+' CAS field.')}
 $sameBytes=$intent.LastRequest;Check ($sameBytes -ceq $action.Request) 'Transport retry has no identical serialized request to reuse.'
 CompleteOptiShadeAutoSessionCommand $intent (Response $sameBytes $snap.auto 'queued')
 Check ((GetOptiShadeAutoSessionAction $intent $snap).Operation -eq 'observe') 'Queued Auto was repeatedly resubmitted before its owner could acknowledge.'
 $snap.auto.desired.nr='off';$snap.auto.planId='plan-2';$snap.auto.deviceIdentity='device-2';$snap.auto.deviceGeneration=2
 $rebind=GetOptiShadeAutoSessionAction $intent $snap;$rebound=$rebind.Request|ConvertFrom-Json
 Check ($rebound.desired.nr -ceq 'off' -and $rebound.desired.frameGeneration -ceq 'off') 'Context rebinding re-enabled retired MFG or erased independent NR intent.'
 Check ($rebound.id -cne $request.id -and $rebound.deviceIdentity -ceq 'device-2') 'Revised context reused an old command id or device identity.'
 CompleteOptiShadeAutoSessionCommand $intent (Response $rebind.Request $snap.auto)
 $off=CopyOptiShadeAutoDesired;$off.enabled=$false;foreach($n in @('nr','upscaling','frameGeneration')){$off.$n='off'}
 $stop=NewOptiShadeAutoSessionIntent $game $identity $off;$snap.auto.renderingAdapterLuid=$null;$snap.auto.deviceIdentity=$null;$snap.auto.deviceGeneration=0;$snap.auto.outputId=$null;$snap.auto.outputGeneration=0
 $stopAction=GetOptiShadeAutoSessionAction $stop $snap;$stopRequest=$stopAction.Request|ConvertFrom-Json
 Check (-not $stopRequest.desired.enabled -and $null -eq $stopRequest.renderingAdapterLuid -and $stopRequest.deviceGeneration -eq 0) 'Explicit Off was blocked or fabricated a device while the context was unknown.'
 CompleteOptiShadeAutoSessionCommand $stop (Response $stopAction.Request $snap.auto 'waiting_for_rendering_context')
 Check ((GetOptiShadeAutoSessionAction $stop $snap).Operation -eq 'observe' -and $stop.State -eq 'off') 'Off intent was automatically retried as an enable request.'
 $before=NewOptiShadeAutoSessionIntent $game $identity $prepared.Desired '201';$failed=$false;try{$null=GetOptiShadeAutoSessionAction $before (Snapshot $identity)}catch{$failed=$true};Check $failed 'A pre-existing process consumed a newer Play intent.'
 $other=Snapshot $identity;$other.binding.executable=Join-Path $game 'ForzaWebHelper.exe';$failed=$false;try{$null=GetOptiShadeAutoSessionAction $intent $other}catch{$failed=$true};Check $failed 'A same-folder helper consumed renderer intent.'
 $other=Snapshot $identity;$other.pid=4321;$failed=$false;try{$null=GetOptiShadeAutoSessionAction $intent $other}catch{$failed=$true};Check $failed 'A restarted/reused session consumed the old intent.'
 $unknown=Snapshot $identity 'plan-0';$unknown.auto.renderingAdapterLuid=$null;$unknown.auto.deviceIdentity=$null;$unknown.auto.deviceGeneration=0;$unknown.auto.outputId=$null;$unknown.auto.outputGeneration=0
 $waiting=NewOptiShadeAutoSessionIntent $game $identity $prepared.Desired '100';$w=GetOptiShadeAutoSessionAction $waiting $unknown;CompleteOptiShadeAutoSessionCommand $waiting (Response $w.Request $unknown.auto 'waiting_for_rendering_context')
 Check ((GetOptiShadeAutoSessionAction $waiting $unknown).Operation -eq 'observe') 'Unknown device caused a repeated configure loop without new evidence.'
 $ready=Snapshot $identity 'plan-ready';$ready.auto.desired=$unknown.auto.desired
 Check ((GetOptiShadeAutoSessionAction $waiting $ready).Operation -eq 'configure') 'Waiting current-session intent did not rebind when a real context appeared.'
 # Live capability arrives after initial device/model observation. A persisted
 # record can admit the next closed-game preparation but never live activation.
 WriteFixtureExe (Join-Path $game 'FlightSimulator2024.exe')
 Check (-not(TestOptiShadeMfgPreparationGame (ReadOptiShadeState $manifest) $gpu)) 'A sibling simulator filename qualified the selected generic rendering executable.'
 Remove-Item -LiteralPath (Join-Path $game 'FlightSimulator2024.exe')
 $xboxGame=Join-Path $fixture 'xbox-msfs';[void][IO.Directory]::CreateDirectory($xboxGame)
 $xboxHelper=Join-Path $xboxGame 'gamelaunchhelper.exe';$xboxRenderer=Join-Path $xboxGame 'FlightSimulator2024.exe'
 WriteFixtureExe $xboxHelper;WriteFixtureExe $xboxRenderer
 $xboxManifest=[pscustomobject]@{Game=$xboxGame;Status='Installed';LaunchExe=$xboxHelper;Architecture='x64';RouteDLL='OptiShadeMSFS2024.dll';Components=@();Files=@()}
 $realExeIdentity=${function:GetOptiShadeExecutableIdentity}
 function GetOptiShadeExecutableIdentity([string]$File){if($File -ceq $xboxRenderer){throw [UnauthorizedAccessException]::new('Xbox encrypted renderer read denied fixture')};& $realExeIdentity $File}
 try{Check (TestOptiShadeMfgPreparationGame $xboxManifest $gpu) 'Xbox helper with a recorded x64 MSFS 2024 route was rejected when the encrypted renderer denied PE reads.'}finally{Set-Item Function:GetOptiShadeExecutableIdentity $realExeIdentity}
 $nativeSnap=Snapshot $identity 'native-plan';$nativeIntent=NewOptiShadeAutoSessionIntent $game $identity $prepared.Desired '100'
 [void](GetOptiShadeAutoSessionAction $nativeIntent $nativeSnap)
 $beforeCapabilityContext=GetOptiShadeAutoPreparationHintContext $nativeSnap
 [void](SaveOptiShadeAutoRenderingHint $manifest $nativeIntent $nativeSnap $gpu)
 Check (-not (ReadOptiShadeState $manifest).AutoCompatibility.NativeFgPreparation) 'An ordinary device hint invented native FG capability.'
 $nativeProvider=Join-Path $game 'sl.dlss_g.dll';[IO.File]::WriteAllText($nativeProvider,'fixture observed provider image; never loaded');$nativeHash=HashFile $nativeProvider
 $nativeSnap.auto|Add-Member nativeFgCapability ([pscustomobject]@{kind='native_streamline_dlssg';observed=$true;passive=$true;api='d3d12';architecture='x64';vendorId=0x10DE;deviceId=0x2684;renderingFamily=40;computeMajor=8;computeMinor=9;driverVersion='nvcuda-file:32.0.15.8000';renderingAdapterLuid='42';deviceIdentity='device-1';deviceGeneration=1;deviceGenerationSource='primary_output_binding';outputId='output-1';outputGeneration=1;view=0;executable=[IO.Path]::GetFileName($identity.Path);executableSha256=$identity.SHA256;providerIdentity=('streamline-dlssg-file:'+$nativeHash);providerFileSha256=$nativeHash;providerFilePath=$nativeProvider;providerImageHashed=$true;maximumAdditionalFrames=1;sampleAgeMs=10;evidence='forwarded_game_get_state';inputEvidence='not_established_by_capability_query';outputEvidence='not_established_by_capability_query'}) -Force
 $nativeSnap.auto.providerIdentity=$nativeSnap.auto.nativeFgCapability.providerIdentity
 Check ((GetOptiShadeAutoPreparationHintContext $nativeSnap) -cne $beforeCapabilityContext) 'Late provider hashing did not invalidate the manager save context.'
 Check (SaveOptiShadeAutoRenderingHint $manifest $nativeIntent $nativeSnap $gpu) 'Fresh, exact native capability was not persisted for preparation.'
 $nativeManifest=ReadOptiShadeState $manifest
 Check ((GetOptiShadeVerifiedGenericMfgPreparation $nativeManifest $gpu).Adapter.Luid -ceq '42') 'Exact generic D3D12 capability was rejected before provider preparation.'
 Check ($nativeManifest.AutoCompatibility.NativeFgPreparation.Use -ceq 'next_closed_game_preparation_only' -and -not $nativeManifest.AutoCompatibility.NativeFgPreparation.Capability.outputVerified) 'A preparation receipt claimed live or verified generated output.'
 $vulkanManifest=$nativeManifest|ConvertTo-Json -Depth 12|ConvertFrom-Json
 $vulkanManifest.AutoCompatibility.NativeFgPreparation.Capability.api='vulkan'
 Check ((GetOptiShadeVerifiedGenericMfgPreparation $vulkanManifest $gpu).Adapter.Luid -ceq '42') 'An exact generic Vulkan Streamline DLSS-G capability was rejected outside the simulator-specific routes.'
 $sourceMarker=Join-Path $payload 'OptiShadeData/MFG/source-build.json';[void][IO.Directory]::CreateDirectory((Split-Path $sourceMarker));[IO.File]::WriteAllText($sourceMarker,'fixture payload-availability marker; not a deployable provider')
 $preinstallManifest=$nativeManifest|ConvertTo-Json -Depth 12|ConvertFrom-Json
 $preinstallManifest.AutoCompatibility.PSObject.Properties.Remove('NativeFgPreparation')
 Check ((GetOptiShadeInstallProviderDecision $preinstallManifest $payload $gpu 'beta') -eq 'unsupported_game') 'Strict automatic MFG preparation admitted a game without a live provider receipt.'
 Check ((TestOptiShadeMfgInstallTarget $preinstallManifest $gpu).State -eq 'candidate') 'An installed generic x64 game with an unambiguous RTX adapter could not stage MFG before its first provider observation.'
 Check ((GetOptiShadeInstallProviderDecision $preinstallManifest $payload $gpu 'beta' -AllowPreinstall) -eq 'source') 'Manual MFG preinstallation still required the game to expose DLSS-G before first launch.'
 $expectedGenericRoutes=@{20='sm86';30='sm86';40='source';50='native'}
 foreach($family in @(20,30,40,50)){
  foreach($api in @('d3d12','vulkan')){
   $caseGpu=$gpu|ConvertTo-Json -Depth 12|ConvertFrom-Json;$adapter=$caseGpu.Adapters[0]
   $adapter.Family=$family;$adapter.DeviceId=0x1000+$family;$adapter.ComputeMajor=$family;$adapter.ComputeMinor=0;$adapter.Name="NVIDIA RTX $family fixture"
   $caseManifest=$nativeManifest|ConvertTo-Json -Depth 12|ConvertFrom-Json
   $capability=$caseManifest.AutoCompatibility.NativeFgPreparation.Capability
   $capability.api=$api;$capability.renderingFamily=$family;$capability.deviceId=$adapter.DeviceId
   $capability.computeMajor=$adapter.ComputeMajor;$capability.computeMinor=$adapter.ComputeMinor
   $caseManifest.AutoCompatibility.NativeFgPreparation.Adapter.Family=$family
   $caseManifest.AutoCompatibility.NativeFgPreparation.Adapter.DeviceId=$adapter.DeviceId
   $caseManifest.AutoCompatibility.NativeFgPreparation.Adapter.ComputeMajor=$adapter.ComputeMajor
   $caseManifest.AutoCompatibility.NativeFgPreparation.Adapter.ComputeMinor=$adapter.ComputeMinor
   $bound=GetOptiShadeVerifiedGenericMfgPreparation $caseManifest $caseGpu
   Check ($bound -and [int]$bound.Adapter.Family -eq $family -and [string]$bound.Adapter.Luid -ceq '42') ("Generic {0} {1} DLSS-G capability did not bind to its exact RTX adapter." -f $api,$family)
   $decision=GetOptiShadeInstallProviderDecision $caseManifest $payload $caseGpu 'beta'
   Check ($decision -ceq $expectedGenericRoutes[$family]) ("Generic {0} RTX {1} selected {2}, expected {3}." -f $api,$family,$decision,$expectedGenericRoutes[$family])
  }
 }
 $xp12Manifest=$vulkanManifest|ConvertTo-Json -Depth 12|ConvertFrom-Json
 $xp12Manifest.RouteDLL='OptiShadeXPlane12.dll'
 $xp12Unverified=$xp12Manifest|ConvertTo-Json -Depth 12|ConvertFrom-Json
 $xp12Unverified.AutoCompatibility.PSObject.Properties.Remove('NativeFgPreparation')
 $unverifiedVulkan=$vulkanManifest|ConvertTo-Json -Depth 12|ConvertFrom-Json
 $unverifiedVulkan.AutoCompatibility.NativeFgPreparation.Capability.providerImageHashed=$false
 Check (-not(GetOptiShadeVerifiedGenericMfgPreparation $unverifiedVulkan $gpu)) 'A Vulkan game without verified provider-image identity was admitted for MFG.'
 Check (-not(SaveOptiShadeAutoRenderingHint $manifest $nativeIntent $nativeSnap $gpu)) 'Identical live capability rewrote the canonical receipt on every poll.'
 foreach($case in @('helper-view','other-device','stale-state','unhashed-image','wrong-executable','malformed-count','different-driver')){
  $bad=$nativeSnap|ConvertTo-Json -Depth 12|ConvertFrom-Json
  switch($case){'helper-view'{$bad.auto.nativeFgCapability.view=1};'other-device'{$bad.auto.nativeFgCapability.renderingAdapterLuid='99'};'stale-state'{$bad.auto.nativeFgCapability.sampleAgeMs=3001};'unhashed-image'{$bad.auto.nativeFgCapability.providerImageHashed=$false};'wrong-executable'{$bad.auto.nativeFgCapability.executable='ForzaWebHelper.exe'};'malformed-count'{$bad.auto.nativeFgCapability.maximumAdditionalFrames='1'};'different-driver'{$bad.auto.nativeFgCapability.driverVersion='nvcuda-file:32.0.15.8001'}}
  Check (-not(NewOptiShadeAutoNativeFgPreparation $nativeIntent $bad (ResolveOptiShadeAdapterCandidate $gpu '' '42'))) ('Invalid '+$case+' snapshot was saved as native capability.')
 }
  $fixtureAdapterName=$gpu.Adapters[0].Name
  foreach($model in @('NVIDIA GeForce RTX 4070','NVIDIA GeForce RTX 4070 Ti','NVIDIA GeForce RTX 4070 SUPER','NVIDIA GeForce RTX 4070 Ti SUPER')){
   $gpu.Adapters[0].Name=$model
   Check ((GetOptiShadeInstallProviderDecision $nativeManifest $payload $gpu 'stable') -eq 'source') ("Stable did not select the family repair provider for $model.")
  }
  $missingSourcePayload=Join-Path $fixture 'payload-without-source-mfg';[void][IO.Directory]::CreateDirectory($missingSourcePayload)
  Check ((GetOptiShadeInstallProviderDecision $nativeManifest $missingSourcePayload $gpu 'stable') -eq 'payload_missing') 'A stable RTX 4070 family system silently fell back to the provider path with known missing output when the repair payload was absent.'
  $gpu.Adapters[0].Name='NVIDIA GeForce RTX 4090'
  Check ((GetOptiShadeInstallProviderDecision $nativeManifest $payload $gpu 'stable') -eq 'payload_missing') 'The Stable RTX 4070 repair changed provider selection for unrelated RTX 40 cards.'
  $gpu.Adapters[0].Name=$fixtureAdapterName
  $realPolicyChannel=(Get-Command GetOptiShadeMfgPolicyChannel).ScriptBlock
  function GetOptiShadeMfgPolicyChannel { return 'beta' }
  try{
 Check ((GetOptiShadeAutoPreparationPlan $xp12Manifest $payload $gpu).Features.frameGeneration.State -eq 'off') 'Auto did not keep retired MFG disabled for X-Plane.'
 $unverifiedXpPlan=GetOptiShadeAutoPreparationPlan $xp12Unverified $payload $gpu
 Check ($unverifiedXpPlan.Features.frameGeneration.State -eq 'off') 'An unverified X-Plane MFG route remained available in Auto.'
 Check ((GetOptiShadeInstallProviderDecision $nativeManifest $payload $gpu 'beta') -eq 'source') 'A fresh exact generic receipt still hit the simulator-only provider gate.'
 Check ((GetOptiShadeInstallProviderDecision $vulkanManifest $payload $gpu 'beta') -eq 'source') 'A fresh exact generic Vulkan DLSS-G receipt did not reach the cross-game provider path.'
 $realReadJson=(Get-Command ReadOptiShadeJson).ScriptBlock
 function ReadOptiShadeJson([string]$Path,[string]$Role='saved state',[int]$MaxBytes=4194304,[string]$Shape='Object'){
  if($Path -ceq $sourceMarker){throw 'FIXTURE: source provider payload verification reached'}
  & $realReadJson $Path $Role $MaxBytes $Shape
 }
 $genericInstallManifest=Join-Path $fixture 'generic-preinstall/manifest.json';[void][IO.Directory]::CreateDirectory((Split-Path $genericInstallManifest));$manualRecord=$nativeManifest|ConvertTo-Json -Depth 12|ConvertFrom-Json;$manualRecord.LaunchExe=$exe;$manualRecord.RouteDLL='OptiShadeGeneric.dll';$manualRecord.AutoCompatibility.PSObject.Properties.Remove('NativeFgPreparation');WriteState $manualRecord $genericInstallManifest
 try{$reached=$false;$installError='';try{InstallSourceMfg $genericInstallManifest $payload $gpu}catch{$installError=$_.Exception.Message;$reached=$installError -ceq 'FIXTURE: source provider payload verification reached'};Check $reached ('Manual source MFG preinstallation still required a live DLSS-G capability receipt for a generic x64 RTX game. '+$installError)}finally{Set-Item Function:ReadOptiShadeJson $realReadJson}
 $genericPlan=GetOptiShadeAutoPreparationPlan $nativeManifest $payload $gpu
 Check ($genericPlan.Features.frameGeneration.State -eq 'off') 'Auto consumed an old MFG receipt after MFG retirement.'
 $providerBytes=[IO.File]::ReadAllBytes($nativeProvider);[IO.File]::WriteAllText($nativeProvider,'provider changed')
 Check ((GetOptiShadeInstallProviderDecision $nativeManifest $payload $gpu 'beta') -eq 'unsupported_game') 'Changed provider bytes reused prior generic admission.'
 [IO.File]::WriteAllBytes($nativeProvider,$providerBytes)
 $oldDriver=$gpu.Adapters[0].DriverVersion;$gpu.Adapters[0].DriverVersion='new driver'
 Check (-not(GetOptiShadeVerifiedGenericMfgPreparation $nativeManifest $gpu)) 'Changed driver reused previous session capability.';$gpu.Adapters[0].DriverVersion=$oldDriver
 $oldLuid=$gpu.Adapters[0].Luid;$gpu.Adapters[0].Luid='43'
 Check (-not(GetOptiShadeVerifiedGenericMfgPreparation $nativeManifest $gpu)) 'Changed rendering LUID reused previous session capability.';$gpu.Adapters[0].Luid=$oldLuid
 $exeBytes=[IO.File]::ReadAllBytes($exe);$changedExe=[byte[]]$exeBytes.Clone();$changedExe[1023]=1;[IO.File]::WriteAllBytes($exe,$changedExe)
 Check (-not(GetOptiShadeVerifiedGenericMfgPreparation $nativeManifest $gpu)) 'Changed game executable reused previous session capability.';[IO.File]::WriteAllBytes($exe,$exeBytes)
 # A preparation-only repeat may keep the recorded capability without starting
 # or reinstalling a provider; explicit FG Off remains authoritative.
 $preserve=CopyOptiShadeAutoDesired;$preserve.frameGeneration='off'
 [void](InvokeOptiShadeAutoPreparation $manifest $payload $gpu {param($text,$completed,$total)} $preserve)
 Check ((GetOptiShadeVerifiedGenericMfgPreparation (ReadOptiShadeState $manifest) $gpu).Adapter.Luid -ceq '42') 'Rebuilding the Auto preparation receipt dropped validated generic capability.'
  }finally{Set-Item Function:GetOptiShadeMfgPolicyChannel $realPolicyChannel}
 Remove-Item -LiteralPath $sourceMarker
 $damaged=Join-Path $game 'OptiShadeData/Engine/nvngx_dlss.dll';$good=[IO.File]::ReadAllBytes($damaged);[IO.File]::WriteAllText($damaged,'external edit')
 $partial=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {param($text,$completed,$total)}
 Check ($partial.State -eq 'partial' -and $partial.Features.nr.State -eq 'failed' -and $partial.Features.upscaling.State -eq 'prepared') 'An independent NR preparation failure blocked all features or was reported as ready.'
 $repeat=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {param($text,$completed,$total)}
 Check ($repeat.Features.nr.Reason -like '*explicitly retry*' -and [IO.File]::ReadAllText($damaged) -ceq 'external edit') 'Unchanged failed preparation retried indefinitely or overwrote a foreign edit.'
 [IO.File]::WriteAllBytes($damaged,$good);$repaired=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {param($text,$completed,$total)} -RetryFailed
 Check ($repaired.Features.nr.State -eq 'prepared') 'Explicit retry did not resume a repaired, unblocked feature.'
 $disabled=CopyOptiShadeAutoDesired;$disabled.nr='off';$disabled.frameGeneration='off';$offPlan=GetOptiShadeAutoPreparationPlan (ReadOptiShadeState $manifest) $payload $gpu $disabled
 Check ($offPlan.Features.nr.State -eq 'off' -and $offPlan.Features.frameGeneration.State -eq 'off' -and $offPlan.Features.upscaling.State -eq 'candidate') 'Off preferences were replaced by all-on preparation.'
 # Legacy saved MFG intent must not recreate a route during Auto preparation.
 RemoveOptiShadeAddon $manifest 'Mfg';RemoveOptiShadeAddon $manifest 'Providers'
 $mfgOnly=CopyOptiShadeAutoDesired;$mfgOnly.enabled=$true;$mfgOnly.nr='off';$mfgOnly.upscaling='off';$mfgOnly.frameGeneration='auto'
 $realInstallAddon=(Get-Command InstallOptiShadeAddon -CommandType Function).ScriptBlock;$script:autoMfgProviderAttempts=0
 function InstallOptiShadeAddon([string]$ManifestPath,[string]$Payload,[ValidateSet('Effects','Neural','Mfg','Cockpit','Providers')][string]$Id,$Gpu,[scriptblock]$Progress,[switch]$SkipAllFx,[switch]$ExplicitSelection,[string]$DlssRuntimeProfile){
  if($Id -ceq 'Providers'){$script:autoMfgProviderAttempts++;throw 'Fixture: unrelated FSR/XeSS provider installation unavailable.'}
  & $script:realInstallAddon $ManifestPath $Payload $Id $Gpu $Progress -SkipAllFx:$SkipAllFx -ExplicitSelection:$ExplicitSelection -DlssRuntimeProfile $DlssRuntimeProfile
 }
 try{$mfgOnlyResult=InvokeOptiShadeAutoPreparation $manifest $payload $gpu {param($text,$completed,$total)} $mfgOnly}finally{Set-Item Function:InstallOptiShadeAddon $realInstallAddon}
 $mfgOnlyReceipt=ReadOptiShadeState $manifest
 Check ($script:autoMfgProviderAttempts -eq 0 -and $mfgOnlyResult.Features.frameGeneration.State -eq 'off' -and -not $mfgOnlyReceipt.DeferredMfg -and 'Mfg' -notin @(GetOptiShadeAddonSelection $mfgOnlyReceipt)) ('Auto reinstated retired MFG. Attempts='+$script:autoMfgProviderAttempts+'; state='+$mfgOnlyResult.Features.frameGeneration.State+'; deferred='+$mfgOnlyReceipt.DeferredMfg+'; components='+(@(GetOptiShadeAddonSelection $mfgOnlyReceipt)-join ',')+'; reason='+$mfgOnlyResult.Features.frameGeneration.Reason)
 "Auto compatibility: $count assertions passed through production preparation/component transactions and session intent logic. Network/GPU/Windows pipe boundaries are fixture-controlled; no game output is claimed."
}finally{Remove-Item -LiteralPath $fixture -Recurse -Force}
