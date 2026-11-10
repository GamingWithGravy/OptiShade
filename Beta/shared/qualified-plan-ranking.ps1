# OptiShade additions, GPL-3.0-or-later. One static preparation ranker.
# Inputs are recorded qualifications, never fabricated live GPU measurements.
# This module owns no runtime, GPU object, presentation schedule or activation.
function TestOptiShadeQualificationKeys($Value,[string[]]$Required,[string[]]$Optional=@()) {
 if($Value -isnot [pscustomobject] -and $Value -isnot [Collections.IDictionary]){return $false}
 $keys=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)}
 foreach($key in $Required){if($key -cnotin $keys){return $false}}
 foreach($key in $keys){if($key -cnotin $Required -and $key -cnotin $Optional){return $false}}
 return $true
}
function TestOptiShadeQualificationText($Value,[int]$Maximum=256) {
 return ($Value -is [string] -and $Value.Length -gt 0 -and $Value.Length -le $Maximum -and $Value -notmatch '[\x00-\x1f]')
}
function TestOptiShadeQualificationNumber($Value,[switch]$Integer,[switch]$Positive) {
 if($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [uint32] -and $Value -isnot [uint64] -and $Value -isnot [double] -and $Value -isnot [decimal]){return $false}
 try{$number=[decimal]$Value}catch{return $false}
 if($number -lt 0 -or ($Positive -and $number -le 0) -or ($Integer -and [decimal]::Truncate($number) -ne $number)){return $false}
 return $true
}
function TestOptiShadeQualificationHash($Value) {return ($Value -is [string] -and $Value -cmatch '^[0-9A-F]{64}$')}
function TestOptiShadeQualificationLuid($Value) {
 $number=[uint64]0
 return ($Value -is [string] -and [uint64]::TryParse($Value,[ref]$number) -and $number -ne 0 -and $Value -ceq $number.ToString([Globalization.CultureInfo]::InvariantCulture))
}
function ConvertToOptiShadeQualificationCanonical($Value) {
 if($null -eq $Value){return 'null'}
 if($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]){
  [string[]]$keys=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)}
  [Array]::Sort($keys,[StringComparer]::Ordinal)
  $parts=foreach($key in $keys){($key|ConvertTo-Json -Compress)+':'+(ConvertToOptiShadeQualificationCanonical $Value.$key)}
  return '{'+($parts -join ',')+'}'
 }
 if($Value -is [Collections.IEnumerable] -and $Value -isnot [string]){
  $parts=foreach($item in $Value){ConvertToOptiShadeQualificationCanonical $item}
  return '['+($parts -join ',')+']'
 }
 if(TestOptiShadeQualificationNumber $Value){return ([decimal]$Value).ToString('G29',[Globalization.CultureInfo]::InvariantCulture)}
 return ($Value|ConvertTo-Json -Compress)
}
function GetOptiShadeQualificationDigest($Value) {
 $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertToOptiShadeQualificationCanonical $Value))
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','')}finally{$sha.Dispose()}
}
function TestOptiShadeQualificationPolicy($Policy) {
 if(-not(TestOptiShadeQualificationKeys $Policy @('schema','revision','kind','recordSchema','sourceKind','use','maximumCandidates','maximumDocumentBytes','bindingFields','outputFields','metrics','requiredOutputEvidence','tieBreak','liveAdaptivePolicy'))){return $false}
 foreach($field in @('schema','revision','recordSchema','maximumCandidates','maximumDocumentBytes')){if(-not(TestOptiShadeQualificationNumber $Policy.$field -Integer -Positive)){return $false}}
 if($Policy.schema -cne 1 -or $Policy.revision -cne 1 -or $Policy.recordSchema -cne 1 -or $Policy.kind -cne 'optishade-static-qualified-plans' -or $Policy.sourceKind -cne 'reviewed_physical_game_capture' -or $Policy.use -cne 'closed_game_preparation_for_recorded_target_only' -or $Policy.liveAdaptivePolicy -isnot [bool] -or $Policy.liveAdaptivePolicy){return $false}
 if($Policy.maximumCandidates -ne 32 -or $Policy.maximumDocumentBytes -ne 1048576){return $false}
 $arrays=[ordered]@{
  bindingFields=@('executableSha256','architecture','api','adapterLuid','vendorId','deviceId','subSystemId','driverVersion','managerVersion','payloadSha256','providerPolicySha256','modelPolicySha256','runtimeFilesSha256','qualificationPolicySha256')
  outputFields=@('kind','width','height','colorSpace','windowMode','refreshNumerator','refreshDenominator','displayAdapterLuid','displayIdentity','viewCount')
  requiredOutputEvidence=@('distinctTemporalImages','presentationDelivery','cadence','recovery')
  tieBreak=@('preserveExistingSelection','qualityLoss','latencyP95Ms','gpuOverheadP95Ms','peakMemoryBytes','frameAgeP95Ms','realFrameP95Ms','ordinalCandidateId')
 }
 foreach($field in $arrays.Keys){
  if($Policy.$field -is [string] -or @($Policy.$field).Count -ne $arrays[$field].Count){return $false}
  for($i=0;$i -lt $arrays[$field].Count;$i++){if($Policy.$field[$i] -isnot [string] -or $Policy.$field[$i] -cne $arrays[$field][$i]){return $false}}
 }
 $metrics=@('qualityLoss','latencyP95Ms','gpuOverheadP95Ms','peakMemoryBytes','frameAgeP95Ms','realFrameP95Ms')
 $maximums=@('maximumQualityLoss','maximumLatencyP95Ms','maximumGpuOverheadP95Ms','maximumMemoryBytes','maximumFrameAgeP95Ms','maximumRealFrameP95Ms')
 if(@($Policy.metrics).Count -ne $metrics.Count){return $false}
 for($i=0;$i -lt $metrics.Count;$i++){
  $metric=$Policy.metrics[$i]
  if(-not(TestOptiShadeQualificationKeys $metric @('name','unit','maximum','integer')) -or $metric.name -cne $metrics[$i] -or $metric.integer -isnot [bool]){return $false}
  $unit=if($i -eq 0){'ratio'}elseif($i -eq 3){'bytes'}else{'ms'}
  if($metric.unit -cne $unit -or $metric.maximum -cne $maximums[$i] -or $metric.integer -ne ($i -eq 3)){return $false}
 }
 return $true
}
function TestOptiShadeQualificationBinding($Binding,$Policy) {
 if(-not(TestOptiShadeQualificationKeys $Binding @($Policy.bindingFields))){return $false}
 foreach($field in @($Policy.bindingFields)){
  if($field -like '*Sha256'){if(-not(TestOptiShadeQualificationHash $Binding.$field)){return $false}}
  elseif($field -in @('vendorId','deviceId','subSystemId')){if(-not(TestOptiShadeQualificationNumber $Binding.$field -Integer) -or [decimal]$Binding.$field -gt [uint32]::MaxValue){return $false}}
  elseif(-not(TestOptiShadeQualificationText $Binding.$field)){return $false}
 }
 return ($Binding.architecture -cin @('x64','x86','arm64') -and $Binding.api -cin @('d3d10','d3d11','d3d12','vulkan','opengl') -and (TestOptiShadeQualificationLuid $Binding.adapterLuid) -and $Binding.vendorId -gt 0 -and $Binding.deviceId -gt 0)
}
function TestOptiShadeQualificationTarget($Target,$Policy) {
 if(-not(TestOptiShadeQualificationKeys $Target @('comparisonId','output','limits','methods','configurationSha256','featureScope')) -or -not(TestOptiShadeQualificationHash $Target.comparisonId) -or -not(TestOptiShadeQualificationHash $Target.configurationSha256)){return $false}
 if($Target.featureScope -cne 'frame_generation_only_nr_off'){return $false}
 $output=$Target.output
 if(-not(TestOptiShadeQualificationKeys $output @($Policy.outputFields))){return $false}
 foreach($field in @('width','height','refreshNumerator','refreshDenominator','viewCount')){if(-not(TestOptiShadeQualificationNumber $output.$field -Integer -Positive) -or [decimal]$output.$field -gt [uint32]::MaxValue){return $false}}
 if($output.kind -cnotin @('desktop','openxr') -or $output.colorSpace -cnotin @('srgb','scrgb','pq') -or $output.windowMode -cnotin @('windowed','borderless','exclusive','xr') -or -not(TestOptiShadeQualificationLuid $output.displayAdapterLuid) -or -not(TestOptiShadeQualificationText $output.displayIdentity)){return $false}
 if($output.kind -ceq 'desktop' -and ($output.viewCount -ne 1 -or $output.windowMode -ceq 'xr')){return $false}
 $limits=@($Policy.metrics|ForEach-Object {$_.maximum})+@('minimumSamples','minimumDurationMs','maximumAgeSeconds','availableMemoryBytes','requiredMemoryHeadroomBytes')
 if(-not(TestOptiShadeQualificationKeys $Target.limits $limits) -or -not(TestOptiShadeQualificationKeys $Target.methods @($Policy.metrics|ForEach-Object {$_.name}))){return $false}
 foreach($metric in @($Policy.metrics)){
  if(-not(TestOptiShadeQualificationNumber $Target.limits.($metric.maximum) -Integer:$metric.integer) -or -not(TestOptiShadeQualificationText $Target.methods.($metric.name))){return $false}
 }
 foreach($field in @('minimumSamples','minimumDurationMs','maximumAgeSeconds','availableMemoryBytes')){if(-not(TestOptiShadeQualificationNumber $Target.limits.$field -Integer -Positive)){return $false}}
 if(-not(TestOptiShadeQualificationNumber $Target.limits.requiredMemoryHeadroomBytes -Integer) -or $Target.limits.maximumQualityLoss -gt 1 -or $Target.limits.requiredMemoryHeadroomBytes -gt $Target.limits.availableMemoryBytes){return $false}
 return $true
}
function GetOptiShadeQualificationRecordResult($Record,$Candidate,$Binding,$Target,$Policy,[datetime]$Now=[DateTime]::UtcNow) {
 $result=[pscustomobject]@{Id=[string]$Candidate.Id;Route=[string]$Candidate.Route;State='unknown';Reason='No matching recorded qualification is available.';Metrics=$null;RecordId='';RecordSha256=''}
 if($Candidate.State -ceq 'unsupported'){$result.State='unsupported';$result.Reason=[string]$Candidate.Reason;return $result}
 if($Candidate.State -cne 'candidate' -or -not(TestOptiShadeQualificationHash $Candidate.ArtifactSetSha256)){$result.Reason='Candidate component identity or independent admission is unknown.';return $result}
 if(-not $Record){return $result}
 try{
  if(-not(TestOptiShadeQualificationKeys $Record @('Document','DocumentSha256','ArtifactVerified')) -or $Record.ArtifactVerified -isnot [bool] -or -not $Record.ArtifactVerified -or -not(TestOptiShadeQualificationHash $Record.DocumentSha256)){throw 'Evidence artifact bytes have not been independently checked.'}
  $doc=$Record.Document
  if(-not(TestOptiShadeQualificationKeys $doc @('schema','policyRevision','source','binding','target','candidate','qualification','measurements','outputEvidence')) -or -not(TestOptiShadeQualificationNumber $doc.schema -Integer -Positive) -or -not(TestOptiShadeQualificationNumber $doc.policyRevision -Integer -Positive) -or $doc.schema -ne $Policy.recordSchema -or $doc.policyRevision -ne $Policy.revision){throw 'Unknown qualification schema or policy revision.'}
  if(-not(TestOptiShadeQualificationBinding $doc.binding $Policy) -or (ConvertToOptiShadeQualificationCanonical $doc.binding) -cne (ConvertToOptiShadeQualificationCanonical $Binding)){throw 'Qualification executable, API, renderer, driver, package, runtime or policy identity changed.'}
  if(-not(TestOptiShadeQualificationTarget $doc.target $Policy) -or (ConvertToOptiShadeQualificationCanonical $doc.target) -cne (ConvertToOptiShadeQualificationCanonical $Target)){throw 'Qualification output, configuration, comparison, method or declared limits do not match the preparation target.'}
  if(-not(TestOptiShadeQualificationKeys $doc.candidate @('id','route','artifactSetSha256','multiplier')) -or $doc.candidate.id -cne $Candidate.Id -or $doc.candidate.route -cne $Candidate.Route -or $doc.candidate.artifactSetSha256 -cne $Candidate.ArtifactSetSha256 -or -not(TestOptiShadeQualificationNumber $doc.candidate.multiplier -Integer -Positive) -or $doc.candidate.multiplier -ne 2){throw 'Qualification provider components or 2x candidate contract changed.'}
  $source=$doc.source
  if(-not(TestOptiShadeQualificationKeys $source @('kind','schema','recordId','capturedUtc','session','artifact')) -or $source.kind -cne $Policy.sourceKind -or -not(TestOptiShadeQualificationNumber $source.schema -Integer -Positive) -or $source.schema -ne 1 -or -not(TestOptiShadeQualificationText $source.recordId)){throw 'Evidence is not a supported reviewed physical-game capture record.'}
  if(-not(TestOptiShadeQualificationKeys $source.artifact @('path','sha256')) -or -not(TestOptiShadeQualificationText $source.artifact.path 1024) -or -not(TestOptiShadeQualificationHash $source.artifact.sha256)){throw 'Capture artifact identity is missing.'}
  $session=$source.session
  if(-not(TestOptiShadeQualificationKeys $session @('pid','birth','executableSha256','adapterLuid','deviceIdentity','deviceGeneration','outputId','outputGeneration','providerArtifactsSha256')) -or -not(TestOptiShadeQualificationNumber $session.pid -Integer -Positive) -or $session.pid -gt [uint32]::MaxValue -or -not(TestOptiShadeQualificationLuid $session.birth) -or $session.executableSha256 -cne $Binding.executableSha256 -or $session.adapterLuid -cne $Binding.adapterLuid -or $session.providerArtifactsSha256 -cne $Candidate.ArtifactSetSha256){throw 'Capture process or provider/source binding is incomplete.'}
  foreach($field in @('deviceIdentity','outputId')){if(-not(TestOptiShadeQualificationText $session.$field)){throw 'Capture device/output identity is incomplete.'}}
  foreach($field in @('deviceGeneration','outputGeneration')){if(-not(TestOptiShadeQualificationNumber $session.$field -Integer -Positive)){throw 'Capture device/output generation is unknown.'}}
  $captured=[DateTimeOffset]::MinValue
  # PowerShell 7 converts ISO UTC JSON values to DateTime; Windows PowerShell
  # 5.1 retains strings. Accept both exact UTC representations, never local or
  # unspecified time and never a date supplied by the manager as a substitute.
  if($source.capturedUtc -is [DateTime] -and $source.capturedUtc.Kind -eq [DateTimeKind]::Utc){$captured=[DateTimeOffset]$source.capturedUtc}
  elseif($source.capturedUtc -isnot [string] -or $source.capturedUtc -cnotmatch 'Z$' -or -not [DateTimeOffset]::TryParse($source.capturedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$captured)){throw 'Capture time is not explicit UTC.'}
  $age=([DateTimeOffset]$Now.ToUniversalTime()-$captured).TotalSeconds
  if($age -lt 0 -or [decimal]$age -gt [decimal]$Target.limits.maximumAgeSeconds){throw 'Capture time is future or older than the declared qualification age limit.'}
  if(-not(TestOptiShadeQualificationKeys $doc.qualification @('state','reason','samples','durationMs')) -or $doc.qualification.state -cnotin @('measured','unknown','unsupported') -or -not(TestOptiShadeQualificationText $doc.qualification.reason)){throw 'Qualification state is invalid.'}
  if($doc.qualification.state -cne 'measured'){$result.State=[string]$doc.qualification.state;$result.Reason=[string]$doc.qualification.reason;return $result}
  if(-not(TestOptiShadeQualificationNumber $doc.qualification.samples -Integer -Positive) -or -not(TestOptiShadeQualificationNumber $doc.qualification.durationMs -Integer -Positive) -or $doc.qualification.samples -lt $Target.limits.minimumSamples -or $doc.qualification.durationMs -lt $Target.limits.minimumDurationMs){throw 'Capture does not meet the declared sample/duration contract.'}
  if(-not(TestOptiShadeQualificationKeys $doc.outputEvidence @($Policy.requiredOutputEvidence))){throw 'Distinct-image, delivery, cadence and recovery evidence is incomplete.'}
  foreach($name in @($Policy.requiredOutputEvidence)){
   $evidence=$doc.outputEvidence.$name
   if(-not(TestOptiShadeQualificationKeys $evidence @('state','recordId')) -or $evidence.state -cne 'measured' -or $evidence.recordId -cne $source.recordId){throw 'Provider counts, submitted work or unknown output cannot qualify this candidate.'}
  }
  if(-not(TestOptiShadeQualificationKeys $doc.measurements @($Policy.metrics|ForEach-Object {$_.name}))){throw 'Required comparable measurements are incomplete.'}
  $values=[ordered]@{}
  foreach($metric in @($Policy.metrics)){
   $value=$doc.measurements.($metric.name)
   if(-not(TestOptiShadeQualificationKeys $value @('state','value','unit','method','recordId')) -or $value.state -cnotin @('measured','unknown','unsupported')){throw ('Invalid '+$metric.name+' measurement state.')}
   if($value.state -cne 'measured'){$result.State=[string]$value.state;$result.Reason=$metric.name+' is '+$value.state+'; no substitute metric or zero was inferred.';return $result}
   if(-not(TestOptiShadeQualificationNumber $value.value -Integer:$metric.integer) -or $value.unit -cne $metric.unit -or $value.method -cne $Target.methods.($metric.name) -or $value.recordId -cne $source.recordId -or ($metric.name -ceq 'qualityLoss' -and $value.value -gt 1)){throw ('Invalid, incomparable or unbound '+$metric.name+' measurement.')}
   $values[$metric.name]=[decimal]$value.value
   if([decimal]$value.value -gt [decimal]$Target.limits.($metric.maximum)){$result.State='unsupported';$result.Reason=$metric.name+' exceeds the declared target limit; this is a target constraint, not a universal device limit.';return $result}
  }
  if($values.peakMemoryBytes+[decimal]$Target.limits.requiredMemoryHeadroomBytes -gt [decimal]$Target.limits.availableMemoryBytes){$result.State='unsupported';$result.Reason='Recorded peak memory plus declared headroom exceeds the target budget; current runtime budget remains independently checked.';return $result}
  $result.State='measured';$result.Reason='Comparable recorded 2x qualification meets the declared target; live output and current memory remain unverified.'
  $result.Metrics=[pscustomobject]$values;$result.RecordId=[string]$source.recordId;$result.RecordSha256=[string]$Record.DocumentSha256
 }catch{$result.State='unknown';$result.Reason=$_.Exception.GetBaseException().Message}
 return $result
}
function GetOptiShadeQualifiedPlanRanking($Binding,$Target,[object[]]$Candidates,[object[]]$Records,$Policy,[string]$ExistingRoute='',[datetime]$Now=[DateTime]::UtcNow) {
 $result=[pscustomobject]@{Schema=1;State='unknown';SelectedId='';SelectedRoute='';Reason='No comparable current qualification is available; the ordinary preparation policy is retained.';Evidence='recorded_qualification_only';Use='closed_game_preparation_for_recorded_target_only';LiveAdaptivePolicy=$false;Candidates=@();Order=@();Fingerprint=''}
 try{
  if(-not(TestOptiShadeQualificationPolicy $Policy)){throw 'Unknown static qualification policy; live adaptive policy is not admitted.'}
  if(-not(TestOptiShadeQualificationBinding $Binding $Policy)){throw 'Static qualification lacks a complete current preparation identity.'}
  if(-not(TestOptiShadeQualificationTarget $Target $Policy)){throw 'An explicit output, comparison, method and constraint target is required; no thresholds were invented.'}
  if(-not $Candidates.Count -or $Candidates.Count -gt $Policy.maximumCandidates -or $Records.Count -gt $Policy.maximumCandidates){throw 'Qualification candidate/record count is invalid.'}
  $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$evaluated=@()
  foreach($candidate in $Candidates){
   if(-not(TestOptiShadeQualificationText $candidate.Id) -or -not $ids.Add([string]$candidate.Id)){throw 'Duplicate or invalid candidate identity.'}
   $matching=@($Records|Where-Object {$_.Document.candidate.id -ceq $candidate.Id})
   if($matching.Count -gt 1){throw 'Multiple records claim one candidate; select one explicit capture per candidate instead of cherry-picking samples.'}
   $record=if($matching.Count -eq 1){$matching[0]}else{$null}
   $evaluated+=GetOptiShadeQualificationRecordResult $record $candidate $Binding $Target $Policy $Now
  }
  # Ordinal IDs seed a stable insertion sort; no culture-specific Sort-Object,
  # floating tolerance, guessed weights or ratio-derived performance values.
  [string[]]$orderedIds=@($evaluated|ForEach-Object {$_.Id});[Array]::Sort($orderedIds,[StringComparer]::Ordinal)
  $ordered=[Collections.Generic.List[object]]::new()
  foreach($id in $orderedIds){
   $item=@($evaluated|Where-Object {$_.Id -ceq $id})[0]
   if($item.State -cne 'measured'){continue}
   $position=0
   while($position -lt $ordered.Count){
    $other=$ordered[$position];$comparison=0
    foreach($metric in @($Policy.metrics)){$comparison=[decimal]::Compare($item.Metrics.($metric.name),$other.Metrics.($metric.name));if($comparison -ne 0){break}}
    if($comparison -lt 0){break};$position++
   }
   $ordered.Insert($position,$item)
  }
  $result.Candidates=@($orderedIds|ForEach-Object {$id=$_;@($evaluated|Where-Object {$_.Id -ceq $id})[0]})
  $result.Order=@($ordered|ForEach-Object {$_.Id})
  if($ExistingRoute){
   $result.State='preserved';$result.SelectedRoute=$ExistingRoute
   $current=@($evaluated|Where-Object {$_.Route -ceq $ExistingRoute})
   if($current.Count -eq 1){$result.SelectedId=[string]$current[0].Id}
   $result.Reason='An explicit or installed provider selection is retained. Ranking does not migrate a working route or convert unknown measurements into qualification.'
  }elseif($ordered.Count){
   $result.State='selected';$result.SelectedId=$ordered[0].Id;$result.SelectedRoute=$ordered[0].Route
   $result.Reason='Selected the best comparable recorded 2x candidate for closed-game preparation only. Actual runtime device, input, output and budget checks remain required.'
  }elseif(@($evaluated|Where-Object {$_.State -cne 'unsupported'}).Count -eq 0){$result.State='unsupported';$result.Reason='Every independently considered candidate is unsupported for the declared target; ordinary policy and user settings are retained.'}
 }catch{$result.State='unknown';$result.Reason=$_.Exception.GetBaseException().Message}
 $result.Fingerprint=GetOptiShadeQualificationDigest ([ordered]@{state=$result.State;selection=$result.SelectedId;route=$result.SelectedRoute;target=$Target;binding=$Binding;order=$result.Order;candidates=$result.Candidates})
 return $result
}
