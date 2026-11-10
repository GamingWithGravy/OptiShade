function InitializeOptiShadeRuntimeControl {
 if(-not ('OptiShadeControlClient' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'RuntimeControlClient.cs') -ReferencedAssemblies System.dll,System.Core.dll,System.Web.Extensions.dll}
}
function GetOptiShadeRuntimeProtocolSchema { return [OptiShadeControlClient]::ProtocolSchema }
function NewOptiShadeRuntimeRequest([int]$ProcessId,[string]$Operation='discover',[string]$Birth=''){
 @{schema=(GetOptiShadeRuntimeProtocolSchema);pid=$ProcessId;id=[guid]::NewGuid().ToString('N');birth=$Birth;operation=$Operation}|ConvertTo-Json -Compress
}
function GetOptiShadeRuntimeSnapshot([int]$ProcessId){
 InitializeOptiShadeRuntimeControl
 return ([OptiShadeControlClient]::Snapshot([uint32]$ProcessId)|ConvertFrom-Json)
}
function NormalizeOptiShadeRuntimeEvidencePath([string]$Path){
 if(-not $Path){return ''}
 try{$value=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')}catch{return ''}
 if($value.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)){$value='\\'+$value.Substring(8)}
 elseif($value.StartsWith('\\?\',[StringComparison]::OrdinalIgnoreCase)){$value=$value.Substring(4)}
 return $value.TrimEnd('\','/')
}
function AddOptiShadeRuntimeInstallerEvidence($Snapshot,$Manifest,[string]$SelectedGamePath){
 if(-not $Snapshot -or -not $Snapshot.mfg){return $Snapshot}
 $mfg=$Snapshot.mfg
 $mfg|Add-Member installationProvider $null -Force
 $mfg|Add-Member installationProviderEvidence 'no matching verified installation receipt' -Force
 $mfg|Add-Member policyDecision $null -Force
 $mfg|Add-Member policyDecisionEvidence 'installer decision receipt is unavailable or does not match this runtime' -Force
 if(-not $Manifest -or $Manifest.Status -cne 'Installed' -or -not $Snapshot.binding -or
    [string]$Snapshot.binding.evidence -cne 'os_image_birth_and_pipe_pid' -or
    -not [string]$Snapshot.binding.executable -or -not [string]$Snapshot.birth -or [uint32]$Snapshot.pid -eq 0){return $Snapshot}
 $selected=NormalizeOptiShadeRuntimeEvidencePath $SelectedGamePath
 $installed=NormalizeOptiShadeRuntimeEvidencePath ([string]$Manifest.Game)
 $boundExe=NormalizeOptiShadeRuntimeEvidencePath ([string]$Snapshot.binding.executable)
 $launchExe=NormalizeOptiShadeRuntimeEvidencePath ([string]$Manifest.LaunchExe)
 # Windows paths are case-insensitive. Final-path APIs can return different
 # casing than the user-selected path (especially on non-system volumes).
 $pathComparer=[StringComparer]::OrdinalIgnoreCase
 if(-not $selected -or -not $pathComparer.Equals($selected,$installed) -or -not $launchExe -or -not $pathComparer.Equals($boundExe,$launchExe)){return $Snapshot}
 $record=$Manifest.ProviderPolicy
 if(-not $record -or $record.Schema -ne 1 -or $record.Evidence -cnotin @('installation_only','pinned_upstream_installation') -or
    [string]$record.Channel -cnotin @('stable','beta') -or [string]$record.Requested -cnotin @('source','legacy','sm86','native','portable-fsr2x','none','unsupported_game','unsupported_channel','ambiguous_adapter','unknown_adapter','unknown_architecture','conflicting_receipts','receipt_adapter_mismatch','payload_missing') -or
    $record.RecordedSource -isnot [bool] -or $record.RecordedLegacy -isnot [bool] -or $record.RecordedSm86 -isnot [bool]){return $Snapshot}
 if($record.Evidence -ceq 'pinned_upstream_installation' -and
    ($record.Requested -cne 'sm86' -or -not $record.RecordedSm86 -or $record.RecordedSource -or $record.RecordedLegacy)){return $Snapshot}
 foreach($pair in @(@('SourceMfg',[bool]$record.RecordedSource),@('OptionalMfg',[bool]$record.RecordedLegacy),@('Sm86Mfg',[bool]$record.RecordedSm86))){
  $property=$Manifest.PSObject.Properties[[string]$pair[0]]
  # Older and current automatic-selector receipts omit false top-level flags.
  # The explicit typed Recorded* fields are authoritative only for that absence;
  # malformed or contradictory present flags, and missing true flags, reject.
  if($property){if($property.Value -isnot [bool] -or [bool]$property.Value -ne [bool]$pair[1]){return $Snapshot}}
  elseif([bool]$pair[1]){return $Snapshot}
 }
 $providers=@();if($record.RecordedSource){$providers+=,'source'};if($record.RecordedLegacy){$providers+=,'legacy'};if($record.RecordedSm86){$providers+=,'sm86'}
 if($providers.Count -gt 1){$mfg.installationProviderEvidence='conflicting provider receipt flags; installation provider remains unknown';return $Snapshot}
 $provider=if($providers.Count -eq 1){$providers[0]}elseif([string]$Manifest.FrameGenerationRoute -eq 'portable-fsr2x'){'portable-fsr2x'}else{'none_recorded'}
 $mfg|Add-Member installationProvider $provider -Force
 $mfg|Add-Member installationProviderEvidence 'matching game manifest receipt; installation state only, not proof of current loaded files' -Force
 $mfg|Add-Member policyDecision ([string]$record.Requested) -Force
 $mfg|Add-Member policyDecisionEvidence 'matching game manifest provider-policy receipt; policy selection only' -Force
 return $Snapshot
}
