$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/diagnostics.ps1"
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('optishade-launcher-export-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temporary)
try{
 $store=Join-Path $temporary 'store';[void][IO.Directory]::CreateDirectory($store)
 [IO.File]::WriteAllText((Join-Path $store 'Installer.log'),"2026-10-22T12:00:00Z component update failed`r`nAPI candidates=DX12`r`n")
 [IO.File]::WriteAllText((Join-Path $store 'Manager-error.txt'),"System.Management.Automation.RuntimeException: named control missing`r`nAt C:\Users\alice\AppData\Local\OptiShade\Sessions\setup-test\manager.ps1:1376`r`n")
 [IO.File]::WriteAllText((Join-Path $store 'Update-error.txt'),"System.UnauthorizedAccessException: Xbox package renderer is encrypted`r`n")
 $launcherLogs=GetOptiShadeLauncherLogEvidence $store
 foreach($name in @('Installer.log','Manager-error.txt','Update-error.txt')){
  if($launcherLogs.Files.$name.Status -ne 'Read'){throw "Launcher log collector did not read $name"}
  if($null -eq $launcherLogs.LogTails.$name){throw "Launcher log collector omitted the tail for $name"}
 }
 if($launcherLogs.Files.'Manager-error.txt'.ModifiedUtc -eq $null -or $launcherLogs.Files.'Manager-error.txt'.Bytes -le 0){throw 'Manager failure metadata is incomplete.'}
 $session=GetSafeLastSessionSnapshot ([pscustomobject]@{
  Simulator='X-Plane.exe';PID='4242';NRActivationAttemptCount='2';NRActivationHistory='2026-10-25T09:50:00.000Z On source=in-game-panel; 2026-10-25T09:51:00.000Z Off source=hotkey';NRActivationLastAction='Off';NRActivationLastSource='hotkey';NRActivationOutcome='Deactivation requested';XP12BridgeAdmissionStage='Blocked before NR frame submission';XP12BridgeFirstBlockReason='Core guide history warming up';XP12BridgeLatestBlockReason='Vulkan device cannot import this D3D12 image format';XP12BridgeLatestBlockUtc='2026-10-26T12:55:35.000Z';XP12BridgeBlockCount='2';XP12BridgeBlockAPI='Vulkan';XP12BridgeBlockDevice='101';XP12BridgeBlockOwner='202';XP12BridgeBlockGeneration='303';XP12BridgeBlockQueue='404';FGStateQueryStage='Provider call pending';FGStateResult='Pending'
  FGStateProviderFaulted='Yes';FGStateProviderExceptionCode='0xC0000005';FGStateProviderExceptionAddress='0x7FFAA4B72C5D';FGStateProviderAccessOperation='0';FGStateProviderFaultAddress='0x128'
  FGStateCallerThreadId='17';FGPresentSampleSource='Streamline interposer-wrapped DXGI swapchain Present';FGPresentSwapchainId='123456'
  FGStateThreadMatchesLastPresent='False';FGStateQueryCount='9';FGStateIntervalMs='16';SecretPath='C:\private\do-not-export.txt';LastFailure=('x'*513)
  XP12VulkanPresentQueue='9001';XP12VulkanPresentDevice='900';XP12VulkanPresentWaitCount='32';XP12VulkanPresentWaitHandles='101,102';XP12VulkanPresentWaitHandlesCaptured='2';XP12VulkanPresentWaitHandlesTruncated='true'
  XP12VulkanPresentSwapchainCount='1';XP12VulkanPresentImages='301:4';XP12VulkanPresentGenerations='7';XP12VulkanPresentResults='1000001003';XP12VulkanPresentGlobalResult='1000001003'
  XP12VulkanPresentPerResultsKnown='true';XP12VulkanPresentHasPNext='false';XP12VulkanPresentTruncated='true';XP12VulkanPresentSnapshotValid='true'
  XP12VulkanAcquireApi='1';XP12VulkanAcquireResult='1000001003';XP12VulkanAcquireDevice='900';XP12VulkanAcquireSwapchain='301';XP12VulkanAcquireSwapchainGeneration='7';XP12VulkanAcquireTimeout='18446744073709551615'
  XP12VulkanAcquireSemaphore='777';XP12VulkanAcquireFence='0';XP12VulkanAcquireDeviceMask='0';XP12VulkanAcquireHasPNext='false';XP12VulkanAcquireImageIndexValid='true';XP12VulkanAcquireImageIndex='4'
  XP12VulkanSubmitApi='2';XP12VulkanSubmitSource='1';XP12VulkanSubmitQueue='9001';XP12VulkanSubmitFence='0';XP12VulkanSubmitResult='0'
  XP12VulkanSubmitBatchCount='1';XP12VulkanSubmitBatchesCaptured='1';XP12VulkanSubmitBatchSummary='1,1,1@0,0,0,1,1,1,0'
  XP12VulkanSubmitWaitCount='1';XP12VulkanSubmitWaitHandles='101';XP12VulkanSubmitWaitCaptured='1';XP12VulkanSubmitWaitDetails='101:0:1:0:0';XP12VulkanSubmitWaitDetailsTruncated='false'
  XP12VulkanSubmitSignalCount='1';XP12VulkanSubmitSignalHandles='102';XP12VulkanSubmitSignalCaptured='1';XP12VulkanSubmitSignalDetails='102:0:0:0:0';XP12VulkanSubmitSignalDetailsTruncated='false'
  XP12VulkanSubmitCommandCount='1';XP12VulkanSubmitCommandHandles='103';XP12VulkanSubmitCommandsCaptured='1';XP12VulkanSubmitHasPNext='false'
  XP12VulkanSubmitTruncated='false';XP12VulkanSubmitSnapshotValid='true';XP12VulkanSubmitObservedSinceWrite='6';XP12VulkanSubmitOmittedSinceWrite='5'
  XP12VulkanSyncEventSequence='9';XP12VulkanSyncEventsDropped='2';XP12VulkanSyncSemaphoreCreates='12';XP12VulkanSyncSemaphoreDestroys='9'
  XP12VulkanSyncFenceCreates='3';XP12VulkanSyncFenceDestroys='2';XP12VulkanSyncRecentEvents='9,1,2,abc,def,0,0,1,7,0,1'
 })
 $lastSessionIdentity=[pscustomobject]@{PID='25744';ProcessBirthFileTime='134373451550785895'}
 $captureIdentity=GetAutomaticCaptureSessionCorrelation 'session-25744-134373451550785895.status.txt' $lastSessionIdentity
 if($captureIdentity.Status -ne 'Same process identity as LastSession' -or $captureIdentity.Meaning -notmatch 'does not prove timestamp overlap'){throw 'Matching automatic capture identity was not safely correlated to LastSession.'}
 if((GetAutomaticCaptureSessionCorrelation 'session-25744-134373451550785896.status.txt' $lastSessionIdentity).Status -ne 'Different process identity from LastSession'){throw 'Reused PID with a different process birth was incorrectly correlated.'}
 if((GetAutomaticCaptureSessionCorrelation 'session-25745-134373451550785895.status.txt' $lastSessionIdentity).Status -ne 'Different process identity from LastSession'){throw 'A different PID was incorrectly correlated.'}
 if((GetAutomaticCaptureSessionCorrelation 'session-25744-134373451550785895.status.txt' $null).Status -ne 'LastSession identity unavailable'){throw 'Capture identity was treated as correlated without a LastSession.'}
 if((GetAutomaticCaptureSessionCorrelation 'session-0-134373451550785895.status.txt' $lastSessionIdentity).Status -ne 'Filename identity unavailable'){throw 'An invalid automatic capture filename supplied identity evidence.'}
 foreach($field in @('NRActivationAttemptCount','NRActivationHistory','NRActivationLastAction','NRActivationLastSource','NRActivationOutcome','XP12BridgeAdmissionStage','XP12BridgeFirstBlockReason','XP12BridgeLatestBlockReason','XP12BridgeLatestBlockUtc','XP12BridgeBlockCount','XP12BridgeBlockAPI','XP12BridgeBlockDevice','XP12BridgeBlockOwner','XP12BridgeBlockGeneration','XP12BridgeBlockQueue','FGStateQueryStage','FGStateResult','FGStateProviderFaulted','FGStateProviderExceptionCode','FGStateProviderExceptionAddress','FGStateProviderAccessOperation','FGStateProviderFaultAddress','FGStateCallerThreadId','FGPresentSampleSource','FGPresentSwapchainId','XP12VulkanPresentQueue','XP12VulkanPresentDevice','XP12VulkanPresentWaitHandles','XP12VulkanPresentWaitHandlesTruncated','XP12VulkanPresentImages','XP12VulkanPresentGenerations','XP12VulkanPresentResults','XP12VulkanAcquireApi','XP12VulkanAcquireResult','XP12VulkanAcquireSwapchainGeneration','XP12VulkanAcquireImageIndexValid','XP12VulkanAcquireImageIndex','XP12VulkanSubmitApi','XP12VulkanSubmitSource','XP12VulkanSubmitWaitHandles','XP12VulkanSubmitSignalHandles','XP12VulkanSubmitCommandHandles','XP12VulkanSubmitBatchSummary','XP12VulkanSyncEventSequence','XP12VulkanSyncEventsDropped','XP12VulkanSyncSemaphoreCreates','XP12VulkanSyncSemaphoreDestroys','XP12VulkanSyncFenceCreates','XP12VulkanSyncFenceDestroys','XP12VulkanSyncRecentEvents')){
  if(-not $session.PSObject.Properties[$field]){throw "Safe LastSession snapshot omitted expected field $field."}
 }
 if($session.NRActivationHistory -ne '2026-10-25T09:50:00.000Z On source=in-game-panel; 2026-10-25T09:51:00.000Z Off source=hotkey'){throw 'Safe LastSession snapshot truncated or altered the bounded NR action history.'}
 if($session.PSObject.Properties['SecretPath'] -or $session.PSObject.Properties['LastFailure']){throw 'Safe LastSession snapshot retained a non-allowlisted or oversized field.'}
 $destination=Join-Path $temporary 'launcher.zip'
 $report=[pscustomobject]@{
  SchemaVersion=1;ReportType='Launcher-only diagnostics';CapturedUtc=[DateTime]::UtcNow.ToString('o')
  CaptureContext='Launcher evidence only; runtime state not inferred.'
  RuntimeSnapshot=[pscustomobject]@{LastSession=$session}
  ManagedInstallations=@([pscustomobject]@{Title='Fixture';Compatibility=[pscustomobject]@{ApiCandidates=@('DX12')}})
  RecentUpdateResults=@([pscustomobject]@{Item='Neural';Result='Not updated: fixture'})
  LogTails=$launcherLogs.LogTails;LogEvidence=$launcherLogs.Files;LogCapture=$launcherLogs.Limits
 }
 [void](ExportDiagnosticReport $report $destination 'zip' 'OptiShade launcher')
 if(-not(Test-Path -LiteralPath $destination -PathType Leaf)){throw 'Launcher diagnostics ZIP was not created.'}
 Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
 $zip=[IO.Compression.ZipFile]::OpenRead($destination)
 try{
  $names=@($zip.Entries|ForEach-Object FullName)
  foreach($required in @('Report.txt','Report.json','Reproduction-notes.txt')){if($required -notin $names){throw "Launcher diagnostics ZIP is missing $required"}}
  foreach($pattern in @('Logs/\d+-Installer\.log\.txt','Logs/\d+-Manager-error\.txt\.txt','Logs/\d+-Update-error\.txt\.txt')){if(-not @($names|Where-Object {$_ -match $pattern}).Count){throw "Launcher diagnostics ZIP is missing an expected launcher log matching $pattern"}}
  $entry=$zip.GetEntry('Report.json');$reader=[IO.StreamReader]::new($entry.Open())
  try{$json=$reader.ReadToEnd()}finally{$reader.Dispose()}
  if($json -notmatch 'Launcher-only diagnostics' -or $json -notmatch 'DX12' -or $json -notmatch 'Not updated: fixture' -or $json -notmatch 'System.Management.Automation.RuntimeException' -or $json -notmatch 'System.UnauthorizedAccessException' -or $json -notmatch 'ModifiedUtc' -or $json -match 'C:\\Users\\alice'){throw 'Launcher report context, failure evidence, metadata, update results, or path redaction were incorrect.'}
  foreach($evidence in @('Provider call pending','Pending','Streamline interposer-wrapped DXGI swapchain Present','123456','XP12VulkanPresentQueue','9001','XP12VulkanPresentDevice','900','XP12VulkanPresentWaitHandlesTruncated','XP12VulkanPresentImages','301:4','XP12VulkanPresentGenerations','7','XP12VulkanAcquireApi','1000001003','XP12VulkanAcquireSwapchainGeneration','XP12VulkanAcquireImageIndex','"4"','XP12VulkanSubmitApi','XP12VulkanSubmitSource','XP12VulkanSubmitWaitDetails','101:0:1:0:0','XP12VulkanSubmitObservedSinceWrite','"6"','XP12VulkanSyncSemaphoreCreates','"12"','XP12VulkanSyncRecentEvents','9,1,2,abc,def,0,0,1,7,0,1')){if($json -notmatch [regex]::Escape($evidence)){throw "Launcher ZIP omitted LastSession evidence: $evidence"}}
  if($json -match 'do-not-export|C:\\private'){throw 'Launcher ZIP leaked a non-allowlisted LastSession path.'}
  $installerEntryName=@($names|Where-Object {$_ -match 'Logs/\d+-Installer\.log\.txt'})[0]
  $log=$zip.GetEntry($installerEntryName);$reader=[IO.StreamReader]::new($log.Open())
  try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
  if($text -notmatch 'component update failed' -or $text -notmatch 'API candidates=DX12'){throw 'Installer log tail is missing from the diagnostic ZIP.'}
  foreach($entryName in @(@($names|Where-Object {$_ -match 'Logs/\d+-Manager-error\.txt\.txt'})[0],@($names|Where-Object {$_ -match 'Logs/\d+-Update-error\.txt\.txt'})[0])){
   $entry=$zip.GetEntry($entryName);$reader=[IO.StreamReader]::new($entry.Open())
   try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
   if($text -match 'C:\\Users\\alice'){throw "$entryName leaked the fixture profile path."}
  }
 }finally{$zip.Dispose()}
 'Launcher diagnostic ZIP and allowlisted LastSession evidence round-trip passed; ZIP stayed in the temporary local test folder.'
}finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}}
