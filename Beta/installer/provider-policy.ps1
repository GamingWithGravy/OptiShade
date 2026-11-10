. "$PSScriptRoot/gpu-identity.ps1"
function GetOptiShadeProviderDecision([string]$Channel,[int]$Family,[bool]$SourceReceipt,[bool]$LegacyReceipt,[bool]$SupportedGame,[bool]$Ambiguous,[bool]$SourceAvailable,[bool]$LegacyAvailable,[bool]$Sm86Receipt=$false,[bool]$Sm86Available=$true){
 $policy=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'provider-policy.json') -Raw | ConvertFrom-Json
 if($policy.schema -ne 1){throw 'Unsupported provider policy'}
 if(-not $SupportedGame){return 'unsupported_game'}
 if($Ambiguous){return 'ambiguous_adapter'}
 if(($SourceReceipt -and $LegacyReceipt) -or ($Sm86Receipt -and ($SourceReceipt -or $LegacyReceipt))){return 'conflicting_receipts'}
 if($Sm86Receipt){if($Family -notin $policy.providers.sm86.families){return 'receipt_adapter_mismatch'};if($Sm86Available){return 'sm86'};return 'payload_missing'}
 if($SourceReceipt){
  if($Family -notin $policy.providers.source.families){return 'receipt_adapter_mismatch'}
  $rules=$policy.channels.PSObject.Properties[$Channel];$entry=if($rules){$rules.Value.PSObject.Properties[[string]$Family]}else{$null}
  if($entry -and [string]$entry.Value -eq 'sm86'){if($Sm86Available){return 'sm86'};return 'payload_missing'}
  if($SourceAvailable){return 'source'};return 'payload_missing'
 }
 if($LegacyReceipt -and $Channel -eq 'beta' -and $Family -eq 40){if($SourceAvailable){return 'source'};return 'payload_missing'}
 if($LegacyReceipt){if($Family -notin $policy.providers.legacy.families){return 'receipt_adapter_mismatch'};if($LegacyAvailable){return 'legacy'};return 'payload_missing'}
 $rules=$policy.channels.PSObject.Properties[$Channel]
 if(-not $rules){return 'unsupported_channel'}
 $entry=$rules.Value.PSObject.Properties[[string]$Family]
 if(-not $entry){return 'none'}
 $selected=[string]$entry.Value
 if(($selected -eq 'source' -and -not $SourceAvailable) -or ($selected -eq 'legacy' -and -not $LegacyAvailable) -or ($selected -eq 'sm86' -and -not $Sm86Available)){return 'payload_missing'}
 return $selected
}
function TestOptiShadeNativeFgCapabilityShape($Capability){
 try{
  $cap=$Capability
  if(-not $cap -or $cap.observed -isnot [bool] -or -not $cap.observed -or $cap.kind -cne 'native_streamline_dlssg' -or $cap.evidence -cne 'forwarded_game_get_state' -or $cap.api -notin @('d3d12','vulkan') -or $cap.architecture -cne 'x64' -or $cap.providerImageHashed -isnot [bool] -or -not $cap.providerImageHashed){return $false}
  if([string]$cap.providerFileSha256 -cnotmatch '^[A-Fa-f0-9]{64}$' -or [string]$cap.providerIdentity -cne ('streamline-dlssg-file:'+([string]$cap.providerFileSha256)) -or [string]$cap.executableSha256 -cnotmatch '^[A-Fa-f0-9]{64}$'){return $false}
  foreach($field in @('maximumAdditionalFrames','sampleAgeMs','deviceGeneration','outputGeneration','view','vendorId','deviceId','renderingFamily','computeMajor','computeMinor')){
   $value=$cap.$field
   if($value -isnot [int] -and $value -isnot [long] -and $value -isnot [uint32] -and $value -isnot [uint64]){return $false}
   if([decimal]$value -lt 0){return $false}
  }
  if($cap.maximumAdditionalFrames -lt 1 -or $cap.maximumAdditionalFrames -gt 6 -or $cap.sampleAgeMs -gt 3000 -or $cap.deviceGeneration -eq 0 -or $cap.outputGeneration -eq 0 -or $cap.vendorId -ne 0x10DE -or $cap.renderingFamily -notin @(20,30,40,50)){return $false}
  $luid=[uint64]0
  if(-not [uint64]::TryParse([string]$cap.renderingAdapterLuid,[ref]$luid) -or $luid -eq 0 -or [string]$cap.renderingAdapterLuid -cne $luid.ToString([Globalization.CultureInfo]::InvariantCulture)){return $false}
  if([string]$cap.driverVersion -cnotmatch '^nvcuda-file:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' -or -not $cap.deviceIdentity -or -not $cap.outputId -or $cap.deviceGenerationSource -cne 'primary_output_binding'){return $false}
  return $true
 }catch{return $false}
}
function GetOptiShadeVerifiedGenericMfgPreparation($Manifest,$Gpu){
 try{
  $record=$Manifest.AutoCompatibility.NativeFgPreparation
  $birth=[uint64]0;$process=[uint32]0
  if(-not $record -or $record.Schema -ne 1 -or $record.Evidence -cne 'verified_process_capability' -or -not [uint64]::TryParse([string]$record.Birth,[ref]$birth) -or $birth -eq 0 -or -not [uint32]::TryParse([string]$record.Pid,[ref]$process) -or $process -eq 0){return $null}
  $cap=$record.Capability
  if(-not(TestOptiShadeNativeFgCapabilityShape $cap)){return $null}
  if([string]$record.ProviderPolicyHash -cne (HashFile (Join-Path $PSScriptRoot 'provider-policy.json')) -or [string]$record.ManagerVersion -cne (GetBundledOptiShadeVersion)){return $null}
  $identity=GetOptiShadeRenderingExecutable $Manifest
  if($identity.Architecture -cne 'x64' -or $identity.SHA256 -cne [string]$record.ExecutableHash -or $identity.SHA256 -ine [string]$cap.executableSha256 -or [IO.Path]::GetFileName($identity.Path) -ine [string]$cap.executable){return $null}
  # Recheck the exact image observed by the runtime; a different equal-name
  # DLL in a game scan is not equivalent capability or provider provenance.
  $provider=[string]$cap.providerFilePath
  if(-not [IO.Path]::IsPathRooted($provider) -or -not(Test-Path -LiteralPath $provider -PathType Leaf)){return $null}
  $item=Get-Item -LiteralPath $provider -Force
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint -or (HashFile $provider) -ine [string]$cap.providerFileSha256){return $null}
  $candidate=ResolveOptiShadeAdapterCandidate $Gpu '' ([string]$cap.renderingAdapterLuid)
  if($candidate.State -ne 'candidate'){return $null}
  $adapter=$candidate.Adapter
  if([string]$record.Adapter.Luid -cne [string]$cap.renderingAdapterLuid -or [uint32]$adapter.VendorId -ne [uint32]$cap.vendorId -or [uint32]$adapter.DeviceId -ne [uint32]$cap.deviceId -or [int]$adapter.Family -ne [int]$cap.renderingFamily -or [int]$adapter.ComputeMajor -ne [int]$cap.computeMajor -or [int]$adapter.ComputeMinor -ne [int]$cap.computeMinor -or [uint32]$adapter.SubSystemId -ne [uint32]$record.Adapter.SubSystemId -or -not $adapter.DriverVersion -or [string]$adapter.DriverVersion -cne [string]$cap.driverVersion -or [string]$adapter.DriverVersion -cne [string]$record.Adapter.DriverVersion){return $null}
  if($Gpu.PreferredRenderingLuid -and [string]$Gpu.PreferredRenderingLuid -cne [string]$adapter.Luid){return $null}
  return $candidate
 }catch{return $null}
}
function ResolveOptiShadeMfgAdapter($Gpu,$Manifest=$null){
 if($Gpu -and $Gpu.PSObject.Properties['PreferredRenderingLuid'] -and $Gpu.PreferredRenderingLuid){return ResolveOptiShadeAdapterCandidate $Gpu '' ([string]$Gpu.PreferredRenderingLuid)}
 if($Manifest){$prepared=GetOptiShadeVerifiedGenericMfgPreparation $Manifest $Gpu;if($prepared){return $prepared}}
 return ResolveOptiShadeAdapterCandidate $Gpu
}
function TestOptiShadeMfgPreparationGame($Manifest,$Gpu=$null){
 # Preserve the qualified simulator route only for the selected rendering
 # executable. A sibling simulator/helper filename cannot qualify a generic
 # selection. Xbox can deny reads of its encrypted renderer PE; in that case
 # its recorded x64 game route and selected content helper remain authoritative
 # for provider preparation, without attributing helper imports to rendering.
 try{
  $rendering=$Manifest
  if(-not $Manifest.LaunchExe){
   $name=switch([string]$Manifest.RouteDLL){'OptiShadeMSFS2024.dll'{'FlightSimulator2024.exe'};'OptiShadeMSFS2020.dll'{'FlightSimulator.exe'};default{''}}
   if($name){$rendering=$Manifest|ConvertTo-Json -Depth 12|ConvertFrom-Json;$rendering|Add-Member LaunchExe (OwnedPath $Manifest.Game $name) -Force}
  }
  if($rendering.LaunchExe){
   $identity=GetOptiShadeRenderingExecutable $rendering -AllowRecordedUnknown;$name=[IO.Path]::GetFileName($identity.Path)
   $route=if($name -ieq 'gamelaunchhelper.exe' -and $identity.Evidence -match 'Store/Xbox content launch helper selected'){
    switch([string]$Manifest.RouteDLL){'OptiShadeMSFS2024.dll'{'OptiShadeMSFS2024.dll'};'OptiShadeMSFS2020.dll'{'OptiShadeMSFS2020.dll'};default{''}}
   }else{switch($name){'FlightSimulator2024.exe'{'OptiShadeMSFS2024.dll'};'FlightSimulator.exe'{'OptiShadeMSFS2020.dll'};default{''}}}
   if($route -and $identity.Architecture -ceq 'x64' -and (-not $Manifest.RouteDLL -or [string]$Manifest.RouteDLL -ieq $route)){return $true}
  }
 }catch{}
 return [bool](GetOptiShadeVerifiedGenericMfgPreparation $Manifest $Gpu)
}
function TestOptiShadeMfgInstallTarget($Manifest,$Gpu){
 try{
  $identity=GetOptiShadeRenderingExecutable $Manifest -AllowRecordedUnknown
  if($identity.Architecture -cne 'x64'){return [pscustomobject]@{State='unknown_architecture';Reason='A 64-bit rendering executable is required.'}}
  $candidate=ResolveOptiShadeMfgAdapter $Gpu $Manifest
  if($candidate.State -ne 'candidate'){return $candidate}
  if([int]$candidate.Adapter.Family -notin @(20,30,40,50)){return [pscustomobject]@{State='unsupported_hardware';Reason='The selected rendering adapter is not a supported NVIDIA RTX generation.'}}
  return $candidate
 }catch{return [pscustomobject]@{State='unknown_architecture';Reason=$_.Exception.GetBaseException().Message}}
}
function GetOptiShadeInstallProviderDecision($Manifest,[string]$Payload,$GpuNames,[string]$Channel,[switch]$AllowPreinstall){
 $candidate=ResolveOptiShadeMfgAdapter $GpuNames $Manifest
 $supported=TestOptiShadeMfgPreparationGame $Manifest $GpuNames
 if($AllowPreinstall -and -not $supported){
  $preinstall=TestOptiShadeMfgInstallTarget $Manifest $GpuNames
  if($preinstall.State -ne 'candidate'){return [string]$preinstall.State}
  $candidate=$preinstall;$supported=$true
 }
 $source=[bool]($Manifest.PSObject.Properties['SourceMfg'] -and $Manifest.SourceMfg)
 $legacy=[bool]($Manifest.PSObject.Properties['OptionalMfg'] -and $Manifest.OptionalMfg)
 $sm86=[bool]($Manifest.PSObject.Properties['Sm86Mfg'] -and $Manifest.Sm86Mfg)
  if(-not $supported){return 'unsupported_game'}
 if($candidate.State -ne 'candidate'){return [string]$candidate.State}
 $family=[int]$candidate.Adapter.Family
 # Testers reported missing MFG output on RTX 4070 systems, including a
 # 4070 SUPER trace with no valid output samples. Use the same source provider
 # repair across the RTX 4070 family in Stable and Beta. Provider selection
 # alone does not claim generated output has been verified.
 if($Channel -eq 'stable' -and $family -eq 40 -and $candidate.Adapter.Name -match '(?i)\bRTX\s*4070(?:\s*TI)?(?:\s*SUPER)?\b'){
  if(Test-Path -LiteralPath (Join-Path $Payload 'OptiShadeData/MFG/source-build.json')){return 'source'}
  return 'payload_missing'
 }
 # Beta repairs on RTX 4070, 4070 Ti, 4070 SUPER and 4070 Ti SUPER migrate
 # legacy receipts to the source provider. Keep the established legacy route
 # for other RTX 40 models while the 4070 output path is being qualified.
 if($Channel -eq 'beta' -and $family -eq 40 -and $legacy -and -not $source -and -not $sm86 -and $candidate.Adapter.Name -notmatch '(?i)\bRTX\s*4070(?:\s*TI)?(?:\s*SUPER)?\b'){
  if(Test-Path -LiteralPath (Join-Path $Payload 'OptiShadeData/MFG/RTXMFG.dll')){return 'legacy'};return 'payload_missing'
 }
 GetOptiShadeProviderDecision $Channel $family $source $legacy $supported $false (Test-Path -LiteralPath (Join-Path $Payload 'OptiShadeData/MFG/source-build.json')) (Test-Path -LiteralPath (Join-Path $Payload 'OptiShadeData/MFG/RTXMFG.dll')) $sm86 $true
}
function GetOptiShadeMfgPreparationMessage([string]$Decision){
 switch($Decision){
  'native' {return 'This RTX 50 route uses the game-native provider. Select the MFG component to record this route; live DLSS Frame Generation capability and activation are checked in-game. No separate provider DLL is needed.'}
  'unsupported_game' {return 'OptiShade can prepare MFG for this 64-bit game, but activation requires a compatible live DLSS Frame Generation provider from the game. Start the game with its supported Frame Generation option enabled. The current blocker is that the game/provider has not exposed a compatible MFG path; this is a game/provider compatibility limitation, not an OptiShade installation failure. If you expected the game to support MFG, or are unsure, send diagnostics to the Discord channel.'}
  'ambiguous_adapter' {return 'OptiShade could not determine which NVIDIA adapter is rendering this game. Start the game from OptiShade to detect its rendering adapter, then close it and try MFG again. No provider files were changed.'}
  'conflicting_receipts' {return 'OptiShade found conflicting installed frame-generation providers for this game. Review or remove the existing MFG component before installing another provider. No provider files were changed.'}
  'receipt_adapter_mismatch' {return 'The installed MFG provider does not match the current rendering adapter. Review the game installation and adapter before repairing MFG. No provider files were changed.'}
  'payload_missing' {return 'The required MFG provider files are missing from this OptiShade package. Check for updates and try again. No provider files were changed.'}
  'unsupported_channel' {return 'MFG is not available in this OptiShade release channel. No provider files were changed.'}
  'unsupported_hardware' {return 'The selected rendering adapter is not an NVIDIA RTX GPU, so NVIDIA MFG cannot run on it. Set this game to High performance in Windows Graphics settings, restart the game, then start the game from OptiShade to detect the rendering GPU. No provider files were changed.'}
  'unknown_adapter' {return 'OptiShade could not identify a supported NVIDIA rendering adapter for this game. Check the GPU and driver details, then try again. No provider files were changed.'}
  'unknown_architecture' {return 'This game is not using a supported 64-bit rendering process for MFG. No provider files were changed.'}
  default {return ('MFG preparation is unavailable for the current game and adapter ('+$Decision+'). No provider files were changed.')}
 }
}
function GetOptiShadeMfgComponentAdmission([string]$RuntimeDecision,[string]$PreparationDecision,[Nullable[bool]]$LoaderAvailable=$null){
 if($RuntimeDecision -ceq 'native'){
  return [pscustomobject]@{State='native';CanPrepare=$true;RequiresGameLoader=$false;Reason='This route uses the game-native frame-generation provider. Select the MFG component to record the route; live capability and activation are checked in-game. No extra provider DLL is installed.'}
 }
 if($PreparationDecision -notin @('source','legacy','sm86')){
  return [pscustomobject]@{State='deferred';CanPrepare=$true;RequiresGameLoader=$false;Reason=('The MFG component can be selected for this game. No provider or game files are changed until a safe route is known; live capability is checked in-game. Current discovery: '+(GetOptiShadeMfgPreparationMessage $PreparationDecision))}
 }
 # Only the legacy RTX 40 provider is injected through a game-folder proxy.
 # Source and SM86 providers are hosted by the installed OptiShade engine;
 # their install readiness must not depend on renderer import aliases.
 if($PreparationDecision -ceq 'legacy' -and $LoaderAvailable -ne $true){
  return [pscustomobject]@{State='deferred';CanPrepare=$true;RequiresGameLoader=$false;Reason='MFG selection can be recorded without injecting an unverified loader. Start the game and check live provider compatibility in-game; no provider or game files were changed.'}
 }
 $state=if($RuntimeDecision -ceq 'unsupported_game'){'preparable'}else{'available'}
 return [pscustomobject]@{State=$state;CanPrepare=$true;RequiresGameLoader=($PreparationDecision -ceq 'legacy');Reason=$(if($state -ceq 'preparable'){GetOptiShadeMfgPreparationMessage 'unsupported_game'}else{'The selected provider package can be prepared; live game activation remains a separate check.'})}
}
