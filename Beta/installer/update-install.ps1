param([string]$Payload,[string]$Installer,[switch]$ValidateOnly)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/ownership.ps1"
. "$PSScriptRoot/library.ps1"
. "$PSScriptRoot/executable.ps1"

function GetUpdateStringHash([string]$Text){
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-',''))}finally{$sha.Dispose()}
}
function GetUpdateManifestFingerprint($Manifest){
 $lines=[Collections.Generic.List[string]]::new()
 foreach($key in @('Version','Game','Installer','Status','Architecture','ExecutableIdentity','RouteDLL','InstallMethod','RendererApi','AutoCompatibility','AutoComponentExclusions','IncludeEffects','Components','PreserveThirdParty','OptionalMfg','OptionalMfgVersion','OptionalMfgLoader','SourceMfg','SourceMfgRollback','Sm86Mfg','Sm86MfgVersion','Sm86MfgSHA256','Sm86MfgLoader','Sm86MfgFiles','Sm86MfgIniBefore','ProviderPolicy','FrameGenerationRoute','FrameGenerationRouteRollback','ProviderAdapter','NeuralAdapter','NeuralAdapterSelection','NeuralGpuName','NeuralGpuSelection','LaunchExe','Downloads','OptionalDlss','FxPresetRelative','AllFxInstalled','NeuralRuntimeVariant','NeuralRuntimeHash','DlssRuntimeProfile','NeuralPreparation')){
  $value=if(-not $Manifest.PSObject.Properties[$key]){''}elseif($null -eq $Manifest.$key){'null'}elseif($Manifest.$key -is [string] -or $Manifest.$key.GetType().IsPrimitive){[string]$Manifest.$key}else{ConvertTo-Json -InputObject $Manifest.$key -Depth 8 -Compress}
  $lines.Add($key+'='+$value)
 }
 foreach($dir in @($Manifest.OwnedDirectories|ForEach-Object {[string]$_}|Sort-Object)){$lines.Add('D|'+$dir)}
 foreach($file in @($Manifest.Files|Sort-Object @{Expression={[string]$_.Path}},@{Expression={[string]$_.SourcePath}},@{Expression={[string]$_.Backup}})){
  $lines.Add(('F|{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f [string]$file.Path,[string]$file.SourcePath,[string]$file.Hash,[string]$file.PreviousHash,[string]$file.Backup,[string][bool]$file.Mutable,[string][bool]$file.Retained))
 }
 return GetUpdateStringHash ($lines -join [string][char]10)
}
function GetUpdateReceiptFingerprint([string]$Path){return GetUpdateManifestFingerprint (ReadOptiShadeState $Path)}
function WriteUpdateJournal($Journal,[string]$Path){
 $folder=Split-Path $Path -Parent
 [void][IO.Directory]::CreateDirectory($folder)
 $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
 try{
  $json=$Journal|ConvertTo-Json -Depth 10
  if([Text.Encoding]::UTF8.GetByteCount($json) -gt 2MB){throw 'Update resume journal exceeded its safety limit.'}
  [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
  if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[System.Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
 }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function AssertUpdateDiskSpace($Targets,[long]$PayloadBytes){
 $needed=@{}
 foreach($target in @($Targets|Where-Object {-not $_.Deferred})){
  $needed[$target.Drive]+=2*$PayloadBytes+64MB
 }
 foreach($drive in $needed.Keys){
  if(([IO.DriveInfo]::new($drive)).AvailableFreeSpace -lt $needed[$drive]){throw "Not enough disk space on $drive for the remaining game update and rollback files. Free $([math]::Ceiling($needed[$drive]/1MB)) MB and retry. No additional game files were changed."}
 }
}

function GetOptiShadeUpdateTargetIdentity($Manifest){
 $proxy=GetOptiShadeInstalledLoaderPath $Manifest
 Write-Verbose ('Recorded proxy value: '+[string]$proxy+'; files='+(@($Manifest.Files|ForEach-Object {([string]$_.Path)+'|'+([string]$_.SourcePath)}) -join ';'))
 if(-not $proxy){throw 'An installation has no unambiguous recorded core loader. Automatic update stopped.'}
 $record=@($Manifest.Files|Where-Object {$_.Path -ieq $proxy -and $_.SourcePath -in @('winmm.dll','ReShade32.dll')})
 if($record.Count -ne 1 -or $record[0].Mutable){throw 'An installation has ambiguous core loader ownership.'}
 $expectedArchitecture=if($record[0].SourcePath -eq 'ReShade32.dll'){'x86'}else{'x64'}
 if($Manifest.Architecture -and $Manifest.Architecture -cne $expectedArchitecture){throw 'The recorded core loader and game architecture disagree.'}
 $executable=[string]$Manifest.LaunchExe
 if(-not $executable){
  # Only older qualified simulator receipts have a deterministic migration.
  # Generic titles must retain their actual selected executable, never a guess.
  $name=switch([string]$Manifest.RouteDLL){'OptiShadeMSFS2024.dll'{'FlightSimulator2024.exe'};'OptiShadeMSFS2020.dll'{'FlightSimulator.exe'};'OptiShadeXPlane12.dll'{'X-Plane.exe'};default{''}}
  if($name){$executable=OwnedPath $Manifest.Game $name}else{throw 'The rendering executable is not recorded. Select the actual game EXE in Setup before updating.'}
 }
 $game=[IO.Path]::GetFullPath([string]$Manifest.Game).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
 $prefix=$game+[IO.Path]::DirectorySeparatorChar
 if(-not [IO.Path]::IsPathRooted($executable) -or -not [IO.Path]::GetFullPath($executable).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'The recorded rendering executable is outside this installation. No replacement executable was guessed.'}
 $executable=OwnedPath $game ([IO.Path]::GetFullPath($executable).Substring($prefix.Length))
 if([IO.Path]::GetFileName($executable) -ieq 'gamelaunchhelper.exe'){
  $renderName=switch([string]$Manifest.RouteDLL){'OptiShadeMSFS2024.dll'{'FlightSimulator2024.exe'};'OptiShadeMSFS2020.dll'{'FlightSimulator.exe'};default{throw 'The launch helper has no recorded rendering route. Select the actual game EXE before updating.'}}
  $executable=OwnedPath $game $renderName
 }
 if(-not(Test-Path -LiteralPath $game -PathType Container) -or -not(Test-Path -LiteralPath $executable -PathType Leaf)){
  return [pscustomobject]@{Proxy=$proxy;Executable=$executable;Architecture=$expectedArchitecture;ExecutableHash='';Deferred=$true;Reason=('The recorded rendering executable is unavailable: '+$executable+'. Reconnect or locate this installation, then resume the update.')}
 }
 $metadata=$null
 try{$identity=GetOptiShadeExecutableIdentity $executable}catch{
  if(-not(TestOptiShadeExecutableAccessDenied $_)){throw}
  $identity=GetOptiShadeRecordedXboxExecutableIdentity $Manifest $executable
  if(-not $identity){throw 'The game executable is unreadable and has no previously installed, qualified Xbox MSFS identity. Select a readable rendering EXE before updating.'}
  $metadata=$identity.Metadata
 }
 if($identity.Architecture -cne $expectedArchitecture){throw 'The current rendering executable architecture changed. Review its installation method before updating.'}
 $current=HashFile (OwnedPath $Manifest.Game $proxy)
 if($current -and $current -cne [string]$record[0].Hash){throw 'The recorded core loader changed outside OptiShade. Automatic update stopped to preserve it.'}
 if(-not $metadata){$metadata=GetOptiShadeExecutableMetadata $executable}
 [pscustomobject]@{Proxy=$proxy;Executable=$executable;Architecture=$identity.Architecture;ExecutableHash=$identity.SHA256;ExecutableMetadata=$metadata;Deferred=$false;Reason=''}
}

function GetOptiShadeWholeManagerUpdateTargets([string]$Store,$Catalog){
 $targets=@()
 foreach($record in @(GetFusionInstallationReceipts $Store -Strict|Sort-Object FullName)){
  $m=ReadOptiShadeState $record.FullName
  if($m.Status -eq 'Installing'){throw "A previous update was interrupted inside $($m.Game). Repair that installation before continuing the whole-manager update."}
  if($m.Status -ne 'Installed'){continue}
  # Validation is read-only: recovery is a separate mutation, never silently
  # performed by the downloaded installer's --check-update preflight.
  if(GetOptiShadeRouteRecovery $record.FullName){throw "A provider route transaction is pending for $($m.Game). Resume its recovery in Setup before updating."}
  Write-Verbose ('Update identity preflight: '+[string]$m.Game)
  $identity=GetOptiShadeUpdateTargetIdentity $m
  $conflicts=@();if(-not $identity.Deferred){AssertClosed $m.Game;$conflicts=@(GetFusionUpdateConflicts $m)}
  if($m.OptionalMfg){
   $provider=@($Catalog|Where-Object Path -match '^OptiShadeData[\\/]MFG[\\/]RTXMFG\.dll$')
   $owned=@($m.Files|Where-Object {$_.Path -in (GetOptiShadeMfgLoaderAliases) -and $_.Hash -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'})
   if($provider.Count -ne 1 -or $owned.Count -ne 1 -or $owned[0].Mutable -or $owned[0].SourcePath -in @('winmm.dll','ReShade32.dll')){throw 'Recorded MFG provider needs review before updating any installation.'}
  }
  $beforeFingerprint=GetUpdateManifestFingerprint $m;CleanModBackupReferences $m (Split-Path $record.FullName)
  foreach($f in $m.Files){if($f.Backup -and (HashFile (OwnedPath (Split-Path $record.FullName) $f.Backup)) -ne $f.PreviousHash){throw 'An original backup is missing. Automatic update stopped.'}}
  $targets+=,[pscustomobject]@{Manifest=$m;Receipt=[IO.Path]::GetFullPath($record.FullName);BeforeFingerprint=$beforeFingerprint;Proxy=$identity.Proxy;Executable=$identity.Executable;ExecutableHash=$identity.ExecutableHash;ExecutableMetadata=$identity.ExecutableMetadata;Architecture=$identity.Architecture;Deferred=[bool]$identity.Deferred;DeferredReason=[string]$identity.Reason;Conflicts=$conflicts;Drive=[IO.Path]::GetPathRoot([IO.Path]::GetFullPath($m.Game));Skip=$false;JournalEntry=$null}
 }
 return $targets
}
function AssertOptiShadeUpdateTargetUnchanged($Target){
 $identityChanged=$false
 if($Target.ExecutableHash){try{$identityChanged=(HashFile $Target.Executable) -cne $Target.ExecutableHash}catch{$identityChanged=$true}}
 else{
  try{$now=GetOptiShadeExecutableMetadata $Target.Executable;$identityChanged=(ConvertTo-Json $now -Compress) -cne (ConvertTo-Json $Target.ExecutableMetadata -Compress)}catch{$identityChanged=$true}
 }
 if((GetUpdateReceiptFingerprint $Target.Receipt) -cne $Target.BeforeFingerprint -or $identityChanged){throw 'The game or its ownership changed after update preflight. No files in this target were changed.'}
}

function SetOptiShadeUpdateResumeTarget($Target,$Entry){
 $Target.JournalEntry=$Entry
 if($Entry.Executable -and ((FullPath $Entry.Executable) -ine (FullPath $Target.Executable) -or $Entry.Architecture -cne $Target.Architecture)){throw 'A recorded game executable changed after this update was planned. Reopen the manager to review its current installation.'}
 if(-not $Target.Deferred -and $Entry.ExecutableHash -and $Entry.ExecutableHash -cne $Target.ExecutableHash){throw 'A recorded game executable changed after this update was planned. Reopen the manager to review its current installation.'}
 if(-not $Target.Deferred -and -not $Target.ExecutableHash -and $Entry.ExecutableMetadata -and (ConvertTo-Json $Entry.ExecutableMetadata -Compress) -cne (ConvertTo-Json $Target.ExecutableMetadata -Compress)){throw 'A recorded game executable changed after this update was planned. Reopen the manager to review its current installation.'}
 if([string]$Entry.State -eq 'Completed'){
  if(-not $Entry.CompletedFingerprint -or (GetUpdateReceiptFingerprint $Target.Receipt) -cne [string]$Entry.CompletedFingerprint){throw 'A previously completed game installation changed after this update. Review it in Setup before resuming.'}
  $Target.Skip=$true;return
 }
 if([string]$Entry.State -notin @('Pending','Failed','Updating','Deferred')){throw 'An update target has an invalid resume state. No further game files were changed.'}
 if((GetUpdateReceiptFingerprint $Target.Receipt) -cne [string]$Entry.BeforeFingerprint){throw ('The interrupted update target or its installation record changed: '+$Target.Manifest.Game+'. Use Repair for that installation, then run the update again.')}
 if($Target.Deferred){$Target.Skip=$true;$Entry.State='Deferred';$Entry.Failure=$Target.DeferredReason}
 else{
  $Target.Skip=$false
  foreach($pair in @(@('Executable',$Target.Executable),@('ExecutableHash',$Target.ExecutableHash),@('ExecutableMetadata',$Target.ExecutableMetadata),@('Architecture',$Target.Architecture))){$Entry|Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force}
  if($Entry.State -eq 'Deferred'){$Entry.State='Pending';$Entry.Failure=''}
 }
 $Entry.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
}

# Check every extracted payload file before changing any installation.
$catalogPath=Join-Path $Payload 'files.json'
$catalog=ReadOptiShadeJson $catalogPath 'Payload catalogue JSON' -Shape Array
if(-not $catalog.Count){throw 'The staged installer has an empty payload catalogue.'}
foreach($entry in $catalog){if((HashFile (OwnedPath $Payload $entry.Path)) -ne $entry.Hash){throw "Staged payload is missing or damaged: $($entry.Path)"}}
$payloadHash=HashFile $catalogPath
$installerHash=HashFile $Installer
if($payloadHash -notmatch '^[A-Fa-f0-9]{64}$' -or $installerHash -notmatch '^[A-Fa-f0-9]{64}$'){throw 'The staged update identity could not be verified.'}

$store=if($env:OPTISHADE_STORE){$env:OPTISHADE_STORE}else{Join-Path $env:LOCALAPPDATA 'OptiShade'}
$updateMutation=$null
if(-not $ValidateOnly){$updateMutation=EnterOptiShadeMutation -StateRoot $store}
$priorAntiCheatUpdateMode=$script:AntiCheatUpdateMode
$script:AntiCheatUpdateMode=$true
try{
[void](OwnedPath $store 'UpdateTransactions/check')
# Preflight every installation before changing any of them.
$targets=@(GetOptiShadeWholeManagerUpdateTargets $store $catalog)
$payloadBytes=0L;foreach($entry in $catalog){$payloadBytes+=(Get-Item -LiteralPath (OwnedPath $Payload $entry.Path)).Length}

if($ValidateOnly){
 AssertUpdateDiskSpace $targets $payloadBytes
 "Validated $($catalog.Count) payload files and $(@($targets|Where-Object {-not $_.Deferred}).Count) available recorded installation(s); $(@($targets|Where-Object Deferred).Count) unavailable installation(s) are retained for scoped deferral."
 return
}

$targetIdentity=@($targets|ForEach-Object {$_.Receipt.ToLowerInvariant()}|Sort-Object)
$targetSetHash=GetUpdateStringHash ($targetIdentity -join [string][char]10)
$journalPath=OwnedPath $store ('UpdateTransactions/'+$payloadHash.ToLowerInvariant()+'-'+$targetSetHash.ToLowerInvariant()+'.json')
$journal=$null
if(Test-Path -LiteralPath $journalPath){
 $candidate=ReadOptiShadeJson $journalPath 'Update resume journal JSON' -MaxBytes 2097152
 if($candidate.Schema -ne 1 -or $candidate.PayloadHash -cne $payloadHash -or $candidate.InstallerHash -cne $installerHash -or $candidate.TargetSetHash -cne $targetSetHash){throw 'An update resume journal does not match this verified payload. No game files were changed.'}
 $journalTargets=@($candidate.Targets)
 if($journalTargets.Count -ne $targets.Count){throw 'The recorded update target set changed. Reopen the manager and review the update again.'}
 if($candidate.Status -eq 'Complete'){
  $stillComplete=$true
  foreach($target in $targets){
   $entry=@($journalTargets|Where-Object {$_.Receipt -ieq $target.Receipt})
   if($entry.Count -ne 1 -or -not $entry[0].CompletedFingerprint -or (GetUpdateReceiptFingerprint $target.Receipt) -cne [string]$entry[0].CompletedFingerprint){$stillComplete=$false;break}
  }
  if($stillComplete){"Update already completed for $($targets.Count) recorded installation(s).";return}
  $candidate=$null
 }elseif($candidate.Status -ne 'Active'){throw 'The update resume journal has an unsupported state. No game files were changed.'}
 $journal=$candidate
}
if(-not $journal){
 $journalTargets=@()
 foreach($target in $targets){
  $journalTargets+=,[pscustomobject][ordered]@{Receipt=$target.Receipt;Game=[string]$target.Manifest.Game;Executable=$target.Executable;ExecutableHash=$target.ExecutableHash;ExecutableMetadata=$target.ExecutableMetadata;Architecture=$target.Architecture;BeforeFingerprint=$target.BeforeFingerprint;State=$(if($target.Deferred){'Deferred'}else{'Pending'});CompletedFingerprint='';Failure=[string]$target.DeferredReason;UpdatedUtc=[DateTime]::UtcNow.ToString('o')}
 }
 $journal=[pscustomobject][ordered]@{Schema=1;TransactionId=[guid]::NewGuid().ToString('N');PayloadHash=$payloadHash;InstallerHash=$installerHash;TargetSetHash=$targetSetHash;Status='Active';CreatedUtc=[DateTime]::UtcNow.ToString('o');CompletedUtc='';Targets=$journalTargets}
 WriteUpdateJournal $journal $journalPath
}

foreach($target in $targets){
 $entry=@($journal.Targets|Where-Object {$_.Receipt -ieq $target.Receipt})
 if($entry.Count -ne 1){throw 'The update resume journal is missing a target. No further game files were changed.'}
 $entry=$entry[0];SetOptiShadeUpdateResumeTarget $target $entry
}
WriteUpdateJournal $journal $journalPath
$remaining=@($targets|Where-Object {-not $_.Skip})
AssertUpdateDiskSpace $remaining $payloadBytes

$completedNow=0
foreach($target in $remaining){
 $m=$target.Manifest;$entry=$target.JournalEntry
 $entry.State='Updating';$entry.Failure='';$entry.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
 WriteUpdateJournal $journal $journalPath
 try{
  AssertOptiShadeUpdateTargetUnchanged $target
  $mp=InstallFusion $m.Game $Payload $store $Installer $target.Proxy $target.Conflicts -ReplaceExisting $true -PreserveConfiguration $true -Executable $target.Executable -ExpectedExecutableMetadata $target.ExecutableMetadata
  $updated=ReadOptiShadeState $mp
  foreach($key in @('LaunchExe','Downloads','OptionalDlss','FxPresetRelative','AllFxInstalled','InstallMethod','RendererApi','NeuralRuntimeVariant','NeuralRuntimeHash','DlssRuntimeProfile','NeuralPreparation')){if($m.PSObject.Properties[$key]){$updated|Add-Member -NotePropertyName $key -NotePropertyValue $m.$key -Force}}
  WriteState $updated $mp
 }catch{
  $failure=$_
  $entry.State='Failed';$entry.Failure=$failure.Exception.Message.Substring(0,[Math]::Min(1024,$failure.Exception.Message.Length));$entry.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
  try{WriteUpdateJournal $journal $journalPath}catch{Write-Warning 'The update failed and its resume journal could not be refreshed.'}
  if($failure.Exception.Message -like 'UserConsentRequired:*'){continue}
  throw $failure
 }
 $entry.CompletedFingerprint=GetUpdateReceiptFingerprint $target.Receipt
 $entry.State='Completed';$entry.Failure='';$entry.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
 WriteUpdateJournal $journal $journalPath
 $completedNow++
}
$incomplete=@($journal.Targets|Where-Object {$_.State -ne 'Completed'})
if($incomplete.Count){
 if(@($incomplete|Where-Object {$_.Failure -like 'UserConsentRequired:*'}).Count){throw 'UserConsentRequired: Some game updates were deferred. Open Update Manager to review their anti-cheat warnings.'}
 $deferred=@($incomplete|Where-Object State -eq 'Deferred')
 if($deferred.Count -eq $incomplete.Count){throw ('InstallationsDeferred: Available game updates were applied. '+$deferred.Count+' unavailable installation(s) remain in the existing resume journal. Reconnect or locate them and resume this manager update. '+(($deferred|ForEach-Object {[string]$_.Failure}) -join ' '))}
 throw 'The update stopped with unfinished game targets recorded for resume.'
}
$journal.Status='Complete';$journal.CompletedUtc=[DateTime]::UtcNow.ToString('o')
WriteUpdateJournal $journal $journalPath
$resumed=$targets.Count-$remaining.Count
"Updated $completedNow supported game installation(s); $resumed already-completed installation(s) were verified and skipped. Presets and configuration preserved. Resume journal: complete."
}finally{$script:AntiCheatUpdateMode=$priorAntiCheatUpdateMode;ExitOptiShadeMutation $updateMutation}
