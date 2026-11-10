function InitializeOptiShadeGpuIdentity {
 if(-not ('OptiShadeGpuIdentity' -as [type])){try{Add-Type -Path (Join-Path $PSScriptRoot 'GpuIdentityClient.cs') -ErrorAction Stop}catch{if(-not ('OptiShadeGpuIdentity' -as [type])){throw}}}
}
function GetOptiShadeGpuFacts {
 try{InitializeOptiShadeGpuIdentity;return [OptiShadeGpuIdentity]::Read()}
 catch{return [pscustomobject]@{Adapters=@();Complete=$false;Error=('Hardware identity unavailable: '+$_.Exception.GetBaseException().Message)}}
}
function ResolveOptiShadeAdapterCandidate($Gpu,[string]$SelectedName='',[string]$Luid=''){
 # Name-only callers may still display their inventory, but names cannot
 # authorize an architecture-specific provider/model. Probe measured facts.
 $inventory=if($Gpu -and $Gpu.PSObject.Properties['Adapters']){$Gpu}else{GetOptiShadeGpuFacts}
 if(-not $Luid -and $inventory.PSObject.Properties['Complete'] -and -not $inventory.Complete){return [pscustomobject]@{State='unknown_adapter';Adapter=$null;Reason='The hardware inventory is incomplete; Auto will wait for an exact rendering LUID instead of choosing from a partial list.'}}
 if($Luid){
  $observed=@($inventory.Adapters|Where-Object {[string]$_.Luid -ceq $Luid})
  if($observed.Count -eq 1 -and [uint32]$observed[0].VendorId -ne 0x10DE){
   $adapter=$observed[0];$name=[string]$adapter.Name;$vendor=switch([uint32]$adapter.VendorId){0x1002{'AMD'}0x8086{'Intel'}default{'non-NVIDIA'}}
   return [pscustomobject]@{State='unsupported_hardware';Adapter=$adapter;Reason=('The selected rendering adapter is {0} ({1}, LUID {2}), not the NVIDIA RTX GPU. NVIDIA NR/MFG cannot run on this adapter. If this game should use the RTX GPU, set its Windows graphics preference to High performance and restart the game before checking Auto again.' -f $name,$vendor,$Luid)}
  }
 }
 $adapters=@($inventory.Adapters|Where-Object {-not $_.Software -and [uint32]$_.VendorId -eq 0x10DE})
 if($Luid){$adapters=@($adapters|Where-Object {[string]$_.Luid -ceq $Luid})}
 elseif($SelectedName){$adapters=@($adapters|Where-Object {[string]$_.Name -ieq $SelectedName})}
 if($adapters.Count -gt 1){return [pscustomobject]@{State='ambiguous_adapter';Adapter=$null;Reason='Multiple physical NVIDIA adapters remain possible; a matching live rendering LUID is required.'}}
 if($adapters.Count -ne 1){return [pscustomobject]@{State='unknown_adapter';Adapter=$null;Reason='No current NVIDIA adapter matches the recorded physical identity.'}}
 $adapter=$adapters[0]
 if(-not $adapter.ComputeCapabilityKnown -or [int]$adapter.Family -notin @(20,30,40,50) -or -not $adapter.Luid -or [string]$adapter.Luid -eq '0'){
  return [pscustomobject]@{State='unknown_architecture';Adapter=$adapter;Reason='The system driver did not establish an admitted RTX architecture for this adapter. Existing providers/models are retained.'}
 }
 return [pscustomobject]@{State='candidate';Adapter=$adapter;Reason='Measured installation candidate; the game rendering device and output remain unverified.'}
}
function GetOptiShadeNeuralAdapterEligibility($Candidate){return $Candidate}
function GetOptiShadeAdapterReceipt($Adapter){
 if(-not $Adapter){return $null}
 [pscustomobject]@{Schema=1;Luid=[string]$Adapter.Luid;VendorId=[uint32]$Adapter.VendorId;DeviceId=[uint32]$Adapter.DeviceId;SubSystemId=[uint32]$Adapter.SubSystemId;ComputeMajor=[int]$Adapter.ComputeMajor;ComputeMinor=[int]$Adapter.ComputeMinor;Family=[int]$Adapter.Family;DriverVersion=[string]$Adapter.DriverVersion;Evidence='inventory_candidate';Name=[string]$Adapter.Name}
}
function GetOptiShadeNeuralAdapterChoices($Gpu){
 foreach($adapter in @($Gpu.Adapters)){
  $candidate=GetOptiShadeNeuralAdapterEligibility (ResolveOptiShadeAdapterCandidate $Gpu '' ([string]$adapter.Luid))
  if($candidate.State -ne 'candidate'){continue}
  $choice=GetOptiShadeAdapterReceipt $candidate.Adapter
  $choice|Add-Member Label ($choice.Name+' | adapter '+$choice.Luid) -Force
  $choice
 }
}
function SetOptiShadeNeuralAdapterSelection($Manifest,$Gpu,[string]$Luid){
 if([string]::IsNullOrWhiteSpace($Luid)){throw 'Select an identified physical adapter.'}
 $candidate=GetOptiShadeNeuralAdapterEligibility (ResolveOptiShadeAdapterCandidate $Gpu '' $Luid)
 if($candidate.State -ne 'candidate'){throw ('The selected neural adapter is no longer available: '+$candidate.Reason)}
 $Manifest|Add-Member NeuralAdapter (GetOptiShadeAdapterReceipt $candidate.Adapter) -Force
 $Manifest|Add-Member NeuralAdapterSelection 'explicit' -Force
 $Manifest|Add-Member NeuralGpuName ([string]$candidate.Adapter.Name) -Force
 $Manifest|Add-Member NeuralGpuSelection 'User selected measured adapter; active renderer not observed' -Force
 if($Manifest.AutoCompatibility){
  $Manifest.AutoCompatibility|Add-Member Fingerprint '' -Force
  $Manifest.AutoCompatibility|Add-Member State 'preferences_changed' -Force
  $Manifest|Add-Member Downloads 'Pending' -Force
 }
}
function ResolveOptiShadeNeuralAdapter($Manifest,$Gpu){
 if($Gpu -and $Gpu.PSObject.Properties['PreferredRenderingLuid'] -and $Gpu.PreferredRenderingLuid){return GetOptiShadeNeuralAdapterEligibility (ResolveOptiShadeAdapterCandidate $Gpu '' ([string]$Gpu.PreferredRenderingLuid))}
 if($Manifest -and $Manifest.PSObject.Properties['NeuralAdapter'] -and $Manifest.NeuralAdapter){
  $record=$Manifest.NeuralAdapter;$candidate=ResolveOptiShadeAdapterCandidate $Gpu '' ([string]$record.Luid)
  if($candidate.State -eq 'candidate' -and [uint32]$candidate.Adapter.DeviceId -eq [uint32]$record.DeviceId -and [uint32]$candidate.Adapter.VendorId -eq [uint32]$record.VendorId -and [uint32]$candidate.Adapter.SubSystemId -eq [uint32]$record.SubSystemId){return GetOptiShadeNeuralAdapterEligibility $candidate}
  if($Gpu.PSObject.Properties['Complete'] -and -not $Gpu.Complete){return [pscustomobject]@{State='unknown_adapter';Adapter=$null;Reason='The previous rendering LUID is absent from an incomplete inventory. Auto will wait for the actual rendering device before rebinding.'}}
  # LUIDs may change after a reboot. Rebind only a single matching measured
  # device identity for preparation; this is not a current rendering claim.
  $matches=@($Gpu.Adapters|Where-Object {-not $_.Software -and [uint32]$_.VendorId -eq [uint32]$record.VendorId -and [uint32]$_.DeviceId -eq [uint32]$record.DeviceId -and [uint32]$_.SubSystemId -eq [uint32]$record.SubSystemId})
  if($matches.Count -eq 1){return GetOptiShadeNeuralAdapterEligibility (ResolveOptiShadeAdapterCandidate $Gpu '' ([string]$matches[0].Luid))}
  # With exactly one physical NVIDIA GPU there is nothing to choose between
  # (integrated AMD/Intel adapters cannot run NR), so a record that no longer
  # matches field for field still resolves to that GPU. Several NVIDIA GPUs keep
  # waiting for the rendering device the game reports.
  $single=ResolveOptiShadeAdapterCandidate $Gpu ''
  if($single.State -eq 'candidate'){return GetOptiShadeNeuralAdapterEligibility $single}
  return [pscustomobject]@{State='unknown_adapter';Adapter=$null;Reason='The recorded neural adapter changed or cannot be identified uniquely. Auto will bind the next observed rendering device.'}
 }
 $selected=if($Manifest){[string]$Manifest.NeuralGpuName}else{''}
 GetOptiShadeNeuralAdapterEligibility (ResolveOptiShadeAdapterCandidate $Gpu $selected)
}
function GetOptiShadeNeuralModelCatalog {
 # Generated from the same reviewed policy as the native hash/family table.
 # Recognition authorizes preparation only; it never proves inference/output.
 $path=Join-Path $PSScriptRoot 'neural-model-policy.json'
 $policy=Get-Content -LiteralPath $path -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
 if($policy.schema -ne 1 -or @($policy.models).Count -eq 0){throw 'Invalid packaged neural model policy.'}
 $ids=@{};$hashes=@{}
 foreach($model in @($policy.models)){
  if($model.Id -notmatch '^[a-z0-9-]+$' -or $ids.ContainsKey([string]$model.Id) -or $model.ModelHash -cnotmatch '^[0-9A-F]{64}$' -or $hashes.ContainsKey([string]$model.ModelHash)){throw 'Invalid or duplicate packaged neural model identity.'}
  if($model.Variant -notin @('auto','compat-3109','official-3109','v7-3109') -or @($model.Families).Count -eq 0 -or @($model.Families|Where-Object {$_ -notin @(20,30,40,50)}).Count -gt 0){throw 'Invalid packaged neural model admission.'}
  $ids[[string]$model.Id]=$true;$hashes[[string]$model.ModelHash]=$true
 }
 @($policy.models)
}
function GetOptiShadeNeuralModelByHash([string]$Hash){
 $matches=@(GetOptiShadeNeuralModelCatalog|Where-Object {$_.ModelHash -ieq $Hash});if($matches.Count -eq 1){return $matches[0]};return $null
}
