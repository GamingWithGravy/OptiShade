. "$PSScriptRoot/json-state.ps1"
. "$PSScriptRoot/crash-dumps.ps1"
function ReadDiagnosticTail([string]$Path,[int]$MaxBytes=65536){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return 'Not available'}
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try{
  $bom=New-Object byte[] 3;$count=$stream.Read($bom,0,3)
  $encoding=[Text.Encoding]::UTF8;$unit=1
  if($count -ge 2 -and $bom[0] -eq 255 -and $bom[1] -eq 254){$encoding=[Text.Encoding]::Unicode;$unit=2}
  elseif($count -ge 2 -and $bom[0] -eq 254 -and $bom[1] -eq 255){$encoding=[Text.Encoding]::BigEndianUnicode;$unit=2}
  $start=[Math]::Max(0,$stream.Length-[Math]::Max(0,$MaxBytes))
  if($unit -eq 2 -and $start%2){$start++}
  [void]$stream.Seek($start,[IO.SeekOrigin]::Begin)
  $buffer=New-Object byte[] ([int][Math]::Min($MaxBytes,$stream.Length-$start));$n=0
  while($n -lt $buffer.Length){$read=$stream.Read($buffer,$n,$buffer.Length-$n);if(-not $read){break};$n+=$read}
  return $encoding.GetString($buffer,0,$n).TrimStart([char]0xFEFF)
 }finally{$stream.Dispose()}
}
function GetSourceMfgDiagnosticLog([string]$SessionText,[string]$TemporaryFolder){
 $result=@{Association='Unavailable';Text='Not available'}
 try{
  if(-not $SessionText -or $SessionText.Length -gt 16384){return $result}
  $session=$SessionText|ConvertFrom-Json
  if($session.product -cne 'OptiShadeMFG' -or $session.abi -ne 131072){return $result}
  $processId=[uint32]$session.pid
  if(-not $processId -or -not $session.processBirth -or -not $session.heartbeat){return $result}
  $birth=[DateTime]::FromFileTimeUtc([long]$session.processBirth)
  $heartbeat=([DateTime]'1970-01-01T00:00:00Z').ToUniversalTime().AddSeconds([long]$session.heartbeat)
  if($heartbeat -lt $birth -or $heartbeat -gt [DateTime]::UtcNow.AddMinutes(2)){return $result}
  $path=Join-Path $TemporaryFolder ('MfgUnlock-'+$processId+'.log')
  $file=Get-Item -LiteralPath $path -ErrorAction Stop
  if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $result}
  # PID reuse or another run must not substitute for the receipt's session.
  if($file.CreationTimeUtc -lt $birth.AddSeconds(-2) -or $file.CreationTimeUtc -gt $heartbeat.AddMinutes(2) -or $file.LastWriteTimeUtc -lt $birth.AddSeconds(-2) -or $file.LastWriteTimeUtc -gt $heartbeat.AddMinutes(2)){return $result}
  $result.Association='Matches source session PID and process-time window; may be historical, not proof of live output'
  $result.ProcessId=$processId;$result.ProcessBirthFileTime=[string]$session.processBirth
  $result.LastWriteUtc=$file.LastWriteTimeUtc.ToString('o')
  $result.Text=ReadDiagnosticTail $path 262144
 }catch{$result.Association='Unavailable or rejected source-session identity'}
 return $result
}

function ReadDiagnosticHead([string]$Path){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return 'Not available'}
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try{$buffer=New-Object byte[] ([int][Math]::Min(65536,$stream.Length));$n=$stream.Read($buffer,0,$buffer.Length);[Text.Encoding]::UTF8.GetString($buffer,0,$n)}finally{$stream.Dispose()}
}
function GetOptiShadeLauncherLogEvidence([string]$Store){
 # Keep this list explicit: launcher diagnostics may include exception details,
 # but must not recursively collect arbitrary files from the user's profile.
 $limits=[ordered]@{'Installer.log'=1048576;'Manager-error.txt'=262144;'Update-error.txt'=262144;'Launcher-update-error.txt'=65536;'Launcher-update-error.shown.txt'=65536}
 $tails=[ordered]@{};$evidence=[ordered]@{}
 foreach($name in $limits.Keys){
  $path=Join-Path $Store $name
  $record=[ordered]@{Status='Missing';Name=$name;Bytes=$null;ModifiedUtc=$null;CapturedBytes=0;OlderBytesOmitted=$null;Context='Launcher-owned diagnostic file; contents may be historical and must be correlated with the reported time.'}
  try{
   $item=Get-Item -LiteralPath $path -ErrorAction Stop
   if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Not a regular launcher log file'}
   $record.Bytes=[long]$item.Length;$record.ModifiedUtc=$item.LastWriteTimeUtc.ToString('o')
   $record.CapturedBytes=[Math]::Min([long]$limits[$name],[long]$item.Length)
   $record.OlderBytesOmitted=[Math]::Max(0,[long]$item.Length-[long]$record.CapturedBytes)
   $tails[$name]=ReadDiagnosticTail $path ([int]$limits[$name])
   $record.Status='Read'
  }catch{
   $record.Status=if($_.FullyQualifiedErrorId -match 'PathNotFound|ItemNotFound'){ 'Missing' }else{ 'Unavailable or rejected: '+$_.Exception.GetType().Name }
   $tails[$name]=$record.Status
  }
  $evidence[$name]=[pscustomobject]$record
 }
 return [pscustomobject]@{Schema=1;Files=[pscustomobject]$evidence;LogTails=[pscustomobject]$tails;Limits='Installer.log 1 MiB; Manager-error.txt and Update-error.txt 256 KiB each; launcher update errors 64 KiB each. No recursive profile scan.'}
}
function GetDiagnosticLogWindow([string]$Path){
 $result=[ordered]@{Status='Missing or unreadable';Bytes=$null;ModifiedUtc=$null;ScannedBytes=0;OlderBytesOmitted=$null;Context='Selected lines from a bounded recent window; evidence, not a diagnosis. No match does not prove absence.';MatchesInWindow=0;Lines=@();FailureLines=@();FirstFailureInWindow=$null}
 try{
  $item=Get-Item -LiteralPath $Path -ErrorAction Stop
  if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Not a regular log'}
  $result.Bytes=$item.Length;$result.ModifiedUtc=$item.LastWriteTimeUtc.ToString('o')
  $result.ScannedBytes=[Math]::Min(16MB,$item.Length);$result.OlderBytesOmitted=[Math]::Max(0,$item.Length-16MB)
  $reader=[IO.StringReader]::new((ReadDiagnosticTail $Path 16777216))
  $kept=New-Object 'System.Collections.Generic.Queue[string]';$chars=0
  $failures=New-Object 'System.Collections.Generic.Queue[string]';$failureChars=0
  try{
   while($null -ne ($line=$reader.ReadLine())){
    if($line.Length -gt 4096){$line='[line truncated] '+$line.Substring($line.Length-4096)}
    if($line -notmatch '(?i)\[E\]|\[W\]|\|\s*(ERROR|WARN)|exception|failed|failure|DXGI_ERROR|887A000[567]|device removed|MFG unlock|Set FPS Limit|Hold Frame|Neural Rendering state|NR observation:|DLSS-NR.*(feature|evaluate result|SUPERSAMPLE)|rendering GPU|swapchain.*(size|format|resize)|Hardware monitor|TAA native-FG|simulator adapter|OptiShade UI theme|OptiShade output context|Vulkan UI surface|OpenXR|GetFullPath'){continue}
    $result.MatchesInWindow++;$kept.Enqueue($line);$chars+=$line.Length
    if($line -match '(?i)\[E\]|\|\s*ERROR|exception|failed|failure|DXGI_ERROR|887A000[567]|device removed|GetFullPath'){
     if($null -eq $result.FirstFailureInWindow){$result.FirstFailureInWindow=$line}
     $failures.Enqueue($line);$failureChars+=$line.Length
     while($failures.Count -gt 100 -or $failureChars -gt 32768){$failureChars-=$failures.Dequeue().Length}
    }
    while($kept.Count -gt 300 -or $chars -gt 65536){$chars-=$kept.Dequeue().Length}
   }
  }finally{$reader.Dispose()}
  $result.Lines=@($kept.ToArray());$result.FailureLines=@($failures.ToArray());$result.Status='Read; latest matches capped at 300 lines / 64K characters, plus 100 failure lines / 32K characters reserved independently'
 }catch{$result.Status='Missing, locked or unreadable'}
 return $result
}
function GetSafeLastSessionSnapshot($Saved){
 if(-not $Saved){return $null}
 $safe=[ordered]@{}
   foreach($key in @('Simulator','RouteDLL','PID','ProcessBirthFileTime','CapturedUtc','API','Device','Generation','NRRoute','FGMode','Requested','NRActivationAttemptCount','NRActivationHistory','NRActivationLastAction','NRActivationLastSource','NRActivationOutcome','XP12BridgeAdmissionStage','XP12BridgeFirstBlockReason','XP12BridgeLatestBlockReason','XP12BridgeLatestBlockUtc','XP12BridgeBlockCount','XP12BridgeBlockAPI','XP12BridgeBlockDevice','XP12BridgeBlockOwner','XP12BridgeBlockGeneration','XP12BridgeBlockQueue','FGStateQueryStage','FGStateResult','FGProviderFunctionAvailable','FGStateCallerModule','FGStateCallerModuleOffset','FGStateCallerThreadId','FGStateQueryCount','FGStateIntervalMs','FGStateAgeSincePresentMs','FGPresentSampleSource','FGPresentCallerThreadId','FGPresentSwapchainId','FGStateThreadMatchesLastPresent','FGPresentCallCount','FGPresentCallCountAtStateQuery','FGStateProviderFaulted','FGStateProviderExceptionCode','FGStateProviderExceptionAddress','FGStateProviderAccessOperation','FGStateProviderFaultAddress','XP12VulkanPresentQueue','XP12VulkanPresentDevice','XP12VulkanPresentWaitCount','XP12VulkanPresentWaitHandles','XP12VulkanPresentWaitHandlesCaptured','XP12VulkanPresentWaitHandlesTruncated','XP12VulkanPresentSwapchainCount','XP12VulkanPresentImages','XP12VulkanPresentGenerations','XP12VulkanPresentResults','XP12VulkanPresentGlobalResult','XP12VulkanPresentPerResultsKnown','XP12VulkanPresentHasPNext','XP12VulkanPresentTruncated','XP12VulkanPresentSnapshotValid','XP12VulkanAcquireApi','XP12VulkanAcquireResult','XP12VulkanAcquireDevice','XP12VulkanAcquireSwapchain','XP12VulkanAcquireSwapchainGeneration','XP12VulkanAcquireTimeout','XP12VulkanAcquireSemaphore','XP12VulkanAcquireFence','XP12VulkanAcquireDeviceMask','XP12VulkanAcquireHasPNext','XP12VulkanAcquireImageIndexValid','XP12VulkanAcquireImageIndex','LastStreamlineToken','LastPresentStartToken','TagMask','ContractStage','NRStage','SubmissionStage','GPUCompletion','XP12BridgeStage','LastFailure','LastSuccessfulTicket')){
  if($Saved.PSObject.Properties[$key]){$value=[string]$Saved.$key;$limit=if($key -eq 'NRActivationHistory'){2048}else{512};if($value.Length -le $limit){$safe[$key]=$value}}
 }
  foreach($key in @('XP12VulkanSubmitApi','XP12VulkanSubmitSource','XP12VulkanSubmitQueue','XP12VulkanSubmitFence','XP12VulkanSubmitResult','XP12VulkanSubmitBatchCount','XP12VulkanSubmitBatchesCaptured','XP12VulkanSubmitBatchSummary','XP12VulkanSubmitWaitCount','XP12VulkanSubmitWaitHandles','XP12VulkanSubmitWaitCaptured','XP12VulkanSubmitWaitDetails','XP12VulkanSubmitWaitDetailsTruncated','XP12VulkanSubmitSignalCount','XP12VulkanSubmitSignalHandles','XP12VulkanSubmitSignalCaptured','XP12VulkanSubmitSignalDetails','XP12VulkanSubmitSignalDetailsTruncated','XP12VulkanSubmitCommandCount','XP12VulkanSubmitCommandHandles','XP12VulkanSubmitCommandsCaptured','XP12VulkanSubmitHasPNext','XP12VulkanSubmitTruncated','XP12VulkanSubmitSnapshotValid','XP12VulkanSubmitObservedSinceWrite','XP12VulkanSubmitOmittedSinceWrite')){
   if($Saved.PSObject.Properties[$key]){$value=[string]$Saved.$key;if($value.Length -le 512){$safe[$key]=$value}}
  }
  foreach($key in @('XP12VulkanSyncEventSequence','XP12VulkanSyncEventsDropped','XP12VulkanSyncSemaphoreCreates','XP12VulkanSyncSemaphoreDestroys','XP12VulkanSyncFenceCreates','XP12VulkanSyncFenceDestroys','XP12VulkanSyncRecentEvents')){
   if($Saved.PSObject.Properties[$key]){$value=[string]$Saved.$key;if($value.Length -le 512){$safe[$key]=$value}}
  }
 return [pscustomobject]$safe
}
function GetAutomaticCaptureSessionCorrelation([string]$Name,$LastSession){
 $match=[regex]::Match($Name,'^session-(?<Pid>[1-9][0-9]{0,9})-(?<Birth>[0-9]{1,20})(?:[-.][A-Za-z0-9._-]+)?\.txt$')
 if(-not $match.Success){return [pscustomobject]@{Status='Filename identity unavailable';CapturePID='';CaptureBirthFileTime='';Meaning='No process identity inferred.'}}
 $capturePid=$match.Groups['Pid'].Value;$captureBirth=$match.Groups['Birth'].Value
 if(-not $LastSession -or [string]$LastSession.PID -notmatch '^[1-9][0-9]{0,9}$' -or [string]$LastSession.ProcessBirthFileTime -notmatch '^[0-9]{1,20}$'){
  return [pscustomobject]@{Status='LastSession identity unavailable';CapturePID=$capturePid;CaptureBirthFileTime=$captureBirth;Meaning='Capture filename contains a PID and process-birth value, but no safe LastSession identity is available for comparison.'}
 }
 $same=([string]$LastSession.PID -ceq $capturePid -and [string]$LastSession.ProcessBirthFileTime -ceq $captureBirth)
 return [pscustomobject]@{Status=$(if($same){'Same process identity as LastSession'}else{'Different process identity from LastSession'});CapturePID=$capturePid;CaptureBirthFileTime=$captureBirth;Meaning='PID and process-birth identity only; does not prove timestamp overlap, capture completeness, or rendered output.'}
}
function GetDiagnosticContext([string]$Game){
 $context=[ordered]@{CapturedUtc=[DateTime]::UtcNow.ToString('o');TimeZone=[TimeZoneInfo]::Local.Id;UtcOffsetMinutes=[TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes;LauncherScripts=@();ConfigIdentity=@();VR=@();OpenXRLayers=@();OpenXRAssessment=@();Hardware=@{}}
 foreach($name in @('manager.ps1','diagnostics.ps1','crash-dumps.ps1','library.ps1','ownership.ps1')){
  try{$item=Get-Item -LiteralPath (Join-Path $PSScriptRoot $name) -ErrorAction Stop;$context.LauncherScripts+=@{Name=$name;SHA256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash}}catch{}
 }
 foreach($name in @('OptiScaler.ini','ReShade.ini','OptiShadeData/XPlane-compatibility.ini')){
  try{$item=Get-Item -LiteralPath (OwnedPath $Game $name) -ErrorAction Stop
   if($item.Length -gt 1MB){throw 'Oversized config'}
   $context.ConfigIdentity+=@{Name=$name;Bytes=$item.Length;ModifiedUtc=$item.LastWriteTimeUtc.ToString('o');SHA256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash}
  }catch{$context.ConfigIdentity+=@{Name=$name;Status='Missing, unreadable or oversized'}}
 }
 # This is the setting for the NEXT process. An already running session may
 # have read a different value; loaded route must be matched in runtime logs.
 $context.XPlaneCompatibility=@{NextLaunchRoute='native-vulkan';RecordedRoute='Missing';Evidence='Saved settings only; not proof of this process route'}
 try{
  $routeFile=OwnedPath $Game 'OptiShadeData/XPlane-compatibility.ini'
  if((Test-Path -LiteralPath $routeFile -PathType Leaf) -and (Get-Item -LiteralPath $routeFile).Length -le 64KB){
   $section='';foreach($line in [IO.File]::ReadAllLines($routeFile)){
    if($line -match '^\s*\[([^\]]+)\]'){$section=$Matches[1].Trim();continue}
    if($section -ieq 'XPlane' -and $line -match '^\s*GraphicsRoute\s*=\s*([^;#\s]+)'){
     $value=$Matches[1].ToLowerInvariant();$context.XPlaneCompatibility.RecordedRoute='Invalid'
     if($value -in @('native-vulkan','legacy-dxgi','menu-only')){$context.XPlaneCompatibility.RecordedRoute=$value;$context.XPlaneCompatibility.NextLaunchRoute=$value};break
    }
   }
  }
 }catch{$context.XPlaneCompatibility.RecordedRoute='Unreadable'}
 # All supported simulator/OpenXR processes are x64. Query Registry64
 # explicitly so diagnostics match the registry view used by the 64-bit loader.
 foreach($hive in @([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryHive]::CurrentUser)){
  $base=$null;$runtimeKey=$null
  try{
   $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,[Microsoft.Win32.RegistryView]::Registry64)
   $runtimeKey=$base.OpenSubKey('SOFTWARE\Khronos\OpenXR\1',$false)
   if($runtimeKey){
    $runtime=$runtimeKey.GetValue('ActiveRuntime',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    if($runtime){$context.VR+=@{Registry=([string]$hive+'\SOFTWARE\Khronos\OpenXR\1');RegistryView='Registry64';ActiveRuntime=[string]$runtime;Evidence='Registered runtime only; not proof of an active headset or VR session'}}
   }
  }catch{}finally{if($runtimeKey){$runtimeKey.Dispose()};if($base){$base.Dispose()}}
 }
 # Read-only layer discovery. Registration is never labelled as active.
 foreach($hive in @([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryHive]::CurrentUser)){
  $base=$null
  try{
   $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,[Microsoft.Win32.RegistryView]::Registry64)
   foreach($kind in @('Implicit','Explicit')){
    $layerKey=$null
    try{
     $layerKey=$base.OpenSubKey(('SOFTWARE\Khronos\OpenXR\1\ApiLayers\'+$kind),$false)
     if(-not $layerKey){continue}
     foreach($manifest in @($layerKey.GetValueNames()|Where-Object {$_ -match '\.json$'}|Select-Object -First 32)){
      try{
       if($layerKey.GetValueKind($manifest) -ne [Microsoft.Win32.RegistryValueKind]::DWord){continue}
       $disabled=$layerKey.GetValue($manifest,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
       if($null -eq $disabled){continue}
       $record=@{Kind=$kind;RegistryView='Registry64';Manifest=$manifest;Disabled=([int]$disabled -ne 0);Evidence='Registration only; inspect loaded modules and OpenXR session logs for activation'}
       try{$item=Get-Item -LiteralPath $manifest -ErrorAction Stop
        if($item.Length -le 256KB -and -not($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
         $layer=(Get-Content -LiteralPath $item.FullName -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop).api_layer
         $record.Name=[string]$layer.name;$record.Library=[string]$layer.library_path;$record.APIVersion=[string]$layer.api_version
        }
       }catch{$record.ReadStatus='Manifest unavailable'}
       $context.OpenXRLayers+=$record
      }catch{}
     }
    }finally{if($layerKey){$layerKey.Dispose()}}
   }
  }catch{}finally{if($base){$base.Dispose()}}
 }
 if(-not $context.VR.Count){$context.VR=@(@{Evidence='No readable OpenXR ActiveRuntime registration; VR may use another route'})}
 try{
  $localReShade=FullPath (Join-Path $Game 'ReShade64.dll')
  $localLayerReady=$false
  $localManifest=OwnedPath $Game 'OptiShadeData/OpenXR/OptiShade_XR.json'
  if(Test-Path -LiteralPath $localManifest -PathType Leaf){
   try{
    $item=Get-Item -LiteralPath $localManifest -ErrorAction Stop
    if($item.Length -gt 65536 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unsafe local OpenXR manifest'}
    $localLayer=(Get-Content -LiteralPath $localManifest -Raw -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop).api_layer
    $localLibrary=if([IO.Path]::IsPathRooted([string]$localLayer.library_path)){FullPath ([string]$localLayer.library_path)}else{FullPath (Join-Path (Split-Path $localManifest -Parent) ([string]$localLayer.library_path))}
    if([string]$localLayer.name -ceq 'XR_APILAYER_optishade' -and [string]::Equals($localLibrary,$localReShade,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $localReShade -PathType Leaf)){
     $localLayerReady=$true
     $context.OpenXRAssessment+=@{Status='Game-local OptiShade OpenXR layer installed';Manifest=$localManifest;Library=$localLibrary;Evidence='The OptiShade Play/direct launch path enables this layer in the simulator process; global registry registration is not required.'}
    }else{
     $context.OpenXRAssessment+=@{Status='Game-local OptiShade OpenXR layer is invalid';Manifest=$localManifest;Library=$localLibrary;Expected=$localReShade}
    }
   }catch{$context.OpenXRAssessment+=@{Status='Game-local OptiShade OpenXR layer could not be verified';Manifest=$localManifest}}
  }
  $reshadeLayers=@($context.OpenXRLayers|Where-Object {-not $_.Disabled -and $_.Name -eq 'XR_APILAYER_reshade'})
  if(-not $reshadeLayers.Count){
   if(-not $localLayerReady){$context.OpenXRAssessment+=@{Status='No usable ReShade OpenXR layer found';Evidence='Pancake ReShade can still work; OpenXR headset swapchains need the game-local OptiShade layer, a registered layer, or another supported VR route.'}}
  }else{
   foreach($layer in $reshadeLayers){
    $resolved=''
    try{
     $manifest=FullPath ([string]$layer.Manifest)
     $library=[string]$layer.Library
     $resolved=if([IO.Path]::IsPathRooted($library)){FullPath $library}else{FullPath (Join-Path (Split-Path $manifest -Parent) $library)}
    }catch{}
    if($resolved -and [string]::Equals($resolved,$localReShade,[StringComparison]::OrdinalIgnoreCase)){
     $context.OpenXRAssessment+=@{Status='OptiShade ReShade is registered for OpenXR';Manifest=$layer.Manifest;Library=$resolved}
    }elseif($resolved){
     $context.OpenXRAssessment+=@{Status='Different ReShade OpenXR DLL registered';Manifest=$layer.Manifest;Library=$resolved;Expected=$localReShade;Evidence='A second ReShade module can abort when OptiShade already loaded its game-local ReShade DLL.'}
    }else{
     $context.OpenXRAssessment+=@{Status='ReShade OpenXR layer could not be resolved';Manifest=$layer.Manifest}
    }
   }
  }
 }catch{$context.OpenXRAssessment+=@{Status='OpenXR ReShade ownership assessment unavailable'}}
 try{$context.Hardware.CPU=@(Get-CimInstance Win32_Processor -OperationTimeoutSec 3 -ErrorAction Stop|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)}catch{$context.Hardware.CPU='Unavailable'}
 try{$os=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 3 -ErrorAction Stop;$context.Hardware.Memory=@{TotalPhysicalKB=$os.TotalVisibleMemorySize;FreePhysicalKB=$os.FreePhysicalMemory;TotalVirtualKB=$os.TotalVirtualMemorySize;FreeVirtualKB=$os.FreeVirtualMemory;Evidence='Single export-time snapshot, not a performance trend'}}catch{$context.Hardware.Memory='Unavailable'}
 return $context
}
function GetSimulatorCrashText([string]$Game){
 $reports=@();$roots=@(@{Path=$Game;Role='Selected game'})
 # Resolve only this simulator's documented data roots; never scan AppData.
 $title=if(Test-Path -LiteralPath (Join-Path $Game 'FlightSimulator2024.exe')){'Microsoft Flight Simulator 2024'}elseif(Test-Path -LiteralPath (Join-Path $Game 'FlightSimulator.exe')){'Microsoft Flight Simulator'}else{''}
 if($title){
  if($env:APPDATA){$roots+=@{Path=(Join-Path $env:APPDATA $title);Role='Simulator roaming data'}}
  if($env:LOCALAPPDATA){
   $family=if($title -eq 'Microsoft Flight Simulator 2024'){'Microsoft.Limitless_8wekyb3d8bbwe'}else{'Microsoft.FlightSimulator_8wekyb3d8bbwe'}
   foreach($area in @('LocalState','LocalCache')){$roots+=@{Path=(Join-Path $env:LOCALAPPDATA "Packages/$family/$area");Role=('Simulator package '+$area)}}
  }
 }
 $files=@()
 foreach($root in $roots){
  if(-not(Test-Path -LiteralPath $root.Path -PathType Container)){continue}
  try{
   $check=FullPath $root.Path
   while($check){if((Get-Item -LiteralPath $check -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked report root'};$parent=[IO.Path]::GetDirectoryName($check);if($parent -eq $check){break};$check=$parent}
   foreach($file in @(Get-ChildItem -LiteralPath $root.Path -Filter 'AsoboReport-Crash*.txt' -File -ErrorAction Stop)){
    if($file.Name -notmatch '^AsoboReport-Crash(?:-[^\\/:]+)?[.]txt$' -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
    $files+=@{File=$file;Role=$root.Role}
   }
  }catch{$reports+=@{SourceRole=$root.Role;Status='Report location unavailable or linked'}}
 }
 foreach($entry in @($files|Sort-Object {$_.File.LastWriteTimeUtc} -Descending|Select-Object -First 4)){
  $file=$entry.File
  try{$reports+=@{Name=$file.Name;SourceRole=$entry.Role;ModifiedUtc=$file.LastWriteTimeUtc.ToString('o');Bytes=$file.Length;Context='Historical simulator text report; correlate timestamps before linking it to this incident. Latest 64 KiB retained.';Text=(ReadDiagnosticTail $file.FullName)}}catch{$reports+=@{Name=$file.Name;SourceRole=$entry.Role;Status='Unavailable'}}
 }
 return $reports
}
function GetStartupEvidence([string]$Game){
 $e=[ordered]@{Captured=(Get-Date).ToString('o');Context='Observed files and log tails, not proof of rendering';Logs=@{};Files=@();Settings=@{}}
  foreach($relative in @('OptiShadeData/Performance.log','OptiShadeData/ReShade.log','OptiShadeData/OptiScaler.log','ReShade.log','OptiScaler.log','Log.txt','dlss5-feed.log','host64/dlss5-feed-host.log','OptiShadeData/Import-last-error.txt')){
  try{$path=OwnedPath $Game $relative;$item=Get-Item -LiteralPath $path -ErrorAction Stop;$e.Logs[$relative]=@{Bytes=$item.Length;LastWriteUtc=$item.LastWriteTimeUtc.ToString('o');Tail=(ReadDiagnosticTail $path)}}catch{$e.Logs[$relative]=@{Status='Missing or unreadable'}}
 }
  foreach($relative in @('winmm.dll','dxgi.dll','d3d12.dll','version.dll','d3d9.dll','OptiShadeLegacyNR.addon32','host64/dlss5-feed-host64.exe','host64/winmm.dll','host64/dxgi.dll','OptiScaler.dll','ReShade64.dll','OptiShadeData/Engine/OptiScaler.dll','OptiShadeData/Engine/ReShade64.dll','sl.interposer.dll','sl.common.dll','sl.dlss.dll','sl.dlss_g.dll','sl.reflex.dll','nvngx_dlss.dll','nvngx_dlssg.dll','nvngx_dlssnr.dll','OptiShadeData/Engine/dlss-enabler-headless.dll','dlss-enabler-headless.dll')){
  try{$item=Get-Item -LiteralPath (OwnedPath $Game $relative) -ErrorAction Stop;$e.Files+=@{Path=$relative;Bytes=$item.Length;Version=$item.VersionInfo.FileVersion;LastWriteUtc=$item.LastWriteTimeUtc.ToString('o')}}catch{$e.Files+=@{Path=$relative;Status='Missing or unreadable'}}
 }
 try{$section='';foreach($line in Get-Content -LiteralPath (OwnedPath $Game 'OptiScaler.ini') -ErrorAction Stop){if($line -match '^\[([^]]+)\]'){$section=$Matches[1]}elseif($section -in @('Menu','Upscalers','FrameGen','DlssNr','Plugins','Framerate','DLSSG','DLSS','FSR','FSRFG','XeSS','XeFG','Reflex','NvngxFG','Fakenvapi','Hotfix','Log','UI' ) -and $line -match '^\s*([A-Za-z0-9]+)\s*=\s*(true|false|auto|[A-Za-z0-9_.-]{1,40})\s*$'){$e.Settings[$section+'.'+$Matches[1]]=$Matches[2]}}}catch{}
 return $e
}
function GetOptiShadeComponentEvidence([string]$Game){
 $result=[ordered]@{Context='Selected installation only. File presence/hash is not proof the component ran. Log observations can be historical.';Files=@();Build=@{};Monitor=@{};MonitorEvents=@()}
 foreach($relative in @('OptiShadeData/Tools/OptiShadeSensors.exe','OptiShadeData/Engine/Routes/OptiShadeMSFS2024.dll','OptiShadeData/Engine/Routes/OptiShadeMSFS2020.dll','OptiShadeData/Engine/Routes/OptiShadeXPlane12.dll','OptiShadeData/Engine/Routes/OptiShadeGeneric.dll')){
  try{$item=Get-Item -LiteralPath (OwnedPath $Game $relative) -ErrorAction Stop
   if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked file'}
   $result.Files+=@{Path=$relative;Bytes=$item.Length;SHA256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash;ModifiedUtc=$item.LastWriteTimeUtc.ToString('o');Status='Present'}
  }catch{$result.Files+=@{Path=$relative;Status='Missing or unreadable'}}
 }
 try{$item=Get-Item -LiteralPath (OwnedPath $Game 'OptiShadeData/BuildIdentity.json') -ErrorAction Stop
  if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 65536){throw 'Invalid or oversized identity'}
  $identity=ReadOptiShadeJson $item.FullName 'Installed build identity' -MaxBytes 65536
  foreach($key in @('Version','Channel','PrivateTesting','PrivateBuildLabel','PrivateTestNumber','SourceHead','SourceSHA256','BuildInputsSHA256','BuiltUtc','BuildMode','NativeBuildSourceSHA256','ReusedFromExecutableSHA256','ManagerRepackedUtc')){
   if($identity.PSObject.Properties[$key]){$value=[string]$identity.$key;if($value.Length -le 128){$result.Build[$key]=$value}}
  }
  $result.Build.IdentityFileSHA256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
  $result.Build.NativeBinaries=[ordered]@{}
  foreach($entry in @($identity.NativeBinaries.PSObject.Properties|Select-Object -First 64)){
   if($entry.Name.Length -le 180 -and $entry.Name -notmatch '(^|[\\/])\.\.([\\/]|$)|:|^[/\\]' -and [string]$entry.Value -match '^[A-Fa-f0-9]{64}$'){$result.Build.NativeBinaries[$entry.Name]=[string]$entry.Value}
  }
  $result.Build.Status='Recorded installed build identity; hashes here describe build artifacts, not proof of loaded or unchanged installed modules'
 }catch{$result.Build.Status='Missing or unreadable'}
 try{$section='';foreach($line in Get-Content -LiteralPath (OwnedPath $Game 'OptiShadeData/HardwareMonitor.ini') -ErrorAction Stop){
  if($line -match '^\[([^]]+)\]'){$section=$Matches[1]}elseif($section -eq 'Overlay' -and $line -match '^\s*(Enabled|X|Y)\s*=\s*(\d{1,4})\s*$'){$result.Monitor[$Matches[1]]=[int]$Matches[2]}
 }}catch{$result.Monitor.Status='No readable saved preferences'}
 foreach($relative in @('OptiShadeData/Performance.log','OptiShadeData/OptiScaler.log','OptiScaler.log')){
  try{$tail=ReadDiagnosticTail (OwnedPath $Game $relative) 262144
   $events=@($tail -split '\r?\n'|Where-Object {$_ -match 'Hardware monitor (helper|heartbeat|pipe|start|missing|provider|:)' }|Select-Object -Last 16)
   foreach($line in $events){$result.MonitorEvents+=@{Log=$relative;Line=$line.Substring(0,[Math]::Min(1024,$line.Length))}}
  }catch{}
 }
 return $result
}
function SavePreRestoreEvidence([string]$Game,[string]$Folder){
 $e=GetStartupEvidence $Game;$e.Context='Captured before Restore; historical evidence, not current installed state'
 $json=$e|ConvertTo-Json -Depth 8
 foreach($pair in @(@($Game,'<GAME>'),@($env:USERPROFILE,'<USERPROFILE>'))){if($pair[0]){$json=$json.Replace(($pair[0]|ConvertTo-Json -Compress).Trim('"'),$pair[1])}}
 if([Text.Encoding]::UTF8.GetByteCount($json) -gt 1MB){throw 'Pre-restore evidence exceeds size limit'}
 $dest=OwnedPath $Folder 'PreRestoreDiagnostics.json';$tmp=OwnedPath $Folder 'PreRestoreDiagnostics.tmp'
 try{[IO.File]::WriteAllText($tmp,$json,[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $tmp -Destination $dest -Force}finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}
}
function GetMfgSessionAssessment($Status,$Processes,[DateTime]$NowUtc=[DateTime]::UtcNow){
 $result=[ordered]@{Association='Unknown';ControlMode='Unknown';ControlPhase='Unknown';RequestedMultiplier=$null;GameFrameGenerationOn=$null;Pending=$null;SetOptionsResult=$null;AppliedOptions='Unknown';ObservedMultiplier='Unknown';RuntimeMaximumGeneratedFrames=$null;DynamicSupported=$null;TransientRetryStreak=$null;TransientRetryDelayMs=$null;NotInitializedRetryCount=$null;InvalidStateRetryCount=$null;Note='Hook activity and accepted options are not measured frame output.'}
 try{
  $state=if($Status -is [string]){$Status|ConvertFrom-Json}else{$Status}
  [uint64]$validatedBirth=0
  if(-not [uint64]::TryParse([string]$state.processBirth,[ref]$validatedBirth) -or $validatedBirth -eq 0){$result.Association='Unverifiable process birth';return $result}
  $matching=@($Processes|Where-Object { $_.Id -eq $state.pid -and $_.StartedFileTimeUtc -eq [string]$validatedBirth -and $_.SelectedInstallation -eq 'Matched' })
  $heartbeat=[DateTimeOffset]::FromUnixTimeSeconds([long]$state.heartbeat).UtcDateTime
  if($matching.Count -ne 1 -or [Math]::Abs(($NowUtc-$heartbeat).TotalSeconds) -gt 30){$result.Association='Unmatched or stale';return $result}
  $result.Association='Current selected process'
  $result.ControlMode=[string]$state.mode
  $result.RequestedMultiplier=$state.multiplier
  $result.GameFrameGenerationOn=[bool]$state.gameFrameGenerationOn
  $result.Pending=[bool]$state.pending
  $result.ControlPhase=if($state.PSObject.Properties['controlPhase']){[string]$state.controlPhase}elseif($state.pending){'requested'}elseif($state.applied){'accepted'}else{'unknown'}
  $result.RuntimeMaximumGeneratedFrames=$state.numFramesToGenerateMax
  $result.DynamicSupported=$state.dynamicMfgSupported
  if($state.PSObject.Properties['transientRetryStreak']){$result.TransientRetryStreak=$state.transientRetryStreak}
  if($state.PSObject.Properties['transientRetryDelayMs']){$result.TransientRetryDelayMs=$state.transientRetryDelayMs}
  if($state.PSObject.Properties['notInitializedRetryCount']){$result.NotInitializedRetryCount=$state.notInitializedRetryCount}
  if($state.PSObject.Properties['invalidStateRetryCount']){$result.InvalidStateRetryCount=$state.invalidStateRetryCount}
  $rawResult=if($null -ne $state.setOptionsResult){[int]$state.setOptionsResult}elseif($null -ne $state.lastSetOptionsResult){[int]$state.lastSetOptionsResult}else{$null}
  $result.SetOptionsResult=$rawResult
  if($null -ne $rawResult -and $rawResult -eq 0){$result.AppliedOptions='Accepted options; not rendering proof'}
  elseif($null -ne $rawResult){$result.AppliedOptions='Rejected/pending Streamline options result '+$rawResult}
  if($state.followGame -and -not $state.gameFrameGenerationOn){
   $result.Note='Follow Game is active and the game currently reports frame generation off; a 2x/default display is not evidence that a higher OptiShade request failed.'
  }elseif($state.pending -and $rawResult -eq 38){
   $result.Note='Requested MFG change is pending after Streamline InvalidState (38), a transient lifecycle condition targeted by the retry repair.'
  }elseif($state.pending -and $rawResult -eq 21){
   $result.Note='Requested MFG change is pending after Streamline NotInitialized (21); retry is expected after the feature finishes initializing.'
  }
  if($state.intervalValidSamples -gt 0 -and $state.realFpsMilli -gt 0 -and $state.dlssFpsMilli -gt 0){
   $result.ObservedMultiplier=[Math]::Round(([double]$state.dlssFpsMilli/[double]$state.realFpsMilli),2)
  }
 }catch{$result.Association='Unreadable or incomplete'}
 return $result
}

function GetOptiShadeProcessAssociation([string]$Game,[string]$ProcessName,[string]$ExecutablePath,$Modules,[string]$ExpectedExecutable=''){
 $expected=if(Test-Path -LiteralPath (Join-Path $Game 'X-Plane.exe')){'X-Plane'}elseif(Test-Path -LiteralPath (Join-Path $Game 'FlightSimulator2024.exe')){'FlightSimulator2024'}elseif(Test-Path -LiteralPath (Join-Path $Game 'FlightSimulator.exe')){'FlightSimulator'}else{''}
 if(-not $expected){
  if(-not $ExpectedExecutable){return @{State='Unknown';Reason='No selected rendering executable is recorded for this non-simulator game'}}
  try{
   $selected=FullPath $ExpectedExecutable
   if(-not $ExecutablePath -or $ExecutablePath -eq 'Unknown'){return @{State='Unknown';Reason='Running process executable path is unavailable; name alone is not enough to associate this game'}}
   $actual=FullPath $ExecutablePath
   if([IO.Path]::GetFileName($selected) -ine [IO.Path]::GetFileName($actual)){return @{State='Other installation';Reason='Running executable name does not match the selected rendering executable'}}
   if($actual -ieq $selected){return @{State='Matched';Reason='Exact selected rendering executable path matches the running process'}}
   return @{State='Other installation';Reason='Same-named executable is running from a different installation'}
  }catch{return @{State='Unknown';Reason='Selected or running executable path could not be verified'}}
 }
 if($ProcessName -ine $expected){return @{State='Other installation';Reason='Simulator family does not match selected installation'}}
 $root=(FullPath $Game).TrimEnd('\');$parent=(FullPath (Split-Path $ExecutablePath -Parent)).TrimEnd('\')
 if($parent -ieq $root){return @{State='Matched';Reason='Simulator family and executable directory match'}}
 # MS Store may execute from WindowsApps, while loading the selected Content
 # folder's recorded game-local renderer. Require both relationships.
 if($ExecutablePath -match '(?i)\\WindowsApps\\' -and (Test-Path -LiteralPath (Join-Path $Game 'gamelaunchhelper.exe')) -and (Test-Path -LiteralPath (Join-Path $Game 'MicrosoftGame.Config'))){
  foreach($module in $Modules){
   if($module.Name -notin @('dxgi.dll','winmm.dll','OptiScaler.dll','ReShade64.dll','OptiShadeMSFS2024.dll','OptiShadeMSFS2020.dll','OptiShadeGeneric.dll','dlssg_sm86.dll')){continue}
   try{$path=FullPath $module.Path;if($path.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){
     return @{State='Matched';Reason='MS Store simulator family plus selected Content-folder renderer module'}
   }}catch{}
  }
 }
 return @{State='Other installation';Reason='No deterministic relationship to selected installation observed'}
}
function GetOptiShadeRouteHealth([string]$Game,$Report){
 $simulator=if(Test-Path -LiteralPath (OwnedPath $Game 'X-Plane.exe')){'X-Plane 12'}elseif(Test-Path -LiteralPath (OwnedPath $Game 'FlightSimulator2024.exe')){'MSFS 2024'}elseif(Test-Path -LiteralPath (OwnedPath $Game 'FlightSimulator.exe')){'MSFS 2020'}else{'Unknown'}
 $expectedName=switch($simulator){'MSFS 2024'{'FlightSimulator2024'}'MSFS 2020'{'FlightSimulator'}'X-Plane 12'{'X-Plane'}default{''}}
 if(-not $expectedName -and $Report.SelectedExecutable.Name){$expectedName=[IO.Path]::GetFileNameWithoutExtension([string]$Report.SelectedExecutable.Name)}
 $matching=@($Report.Processes|Where-Object {$_.SelectedInstallation -eq 'Matched' -and $_.Name -ieq $expectedName})
 $matchedPid=if($matching.Count -eq 1){[int]$matching[0].Id}else{0}
 $modules=@($Report.LoadedModules|Where-Object {$matchedPid -gt 0 -and $_.ProcessId -eq $matchedPid})
 $moduleNames=@($modules|ForEach-Object {[string]$_.Name})
 $apiModules=@($moduleNames|Where-Object {$_ -in @('vulkan-1.dll','d3d12.dll','d3d11.dll','d3d10.dll','d3d9.dll','opengl32.dll')}|Select-Object -Unique)
 $api=if($apiModules.Count){'Modules observed: '+($apiModules -join ', ')+'; active rendering API requires runtime device evidence'}elseif($simulator -eq 'X-Plane 12' -and $Report.XPlaneLaunch.Validation -eq 'Passed'){'Vulkan configured by validated OptiShade launch; live API not observed'}else{'Unknown - no matching live API module evidence'}

 $logTexts=[Collections.Generic.List[string]]::new()
 $logSource=$Report.LogTails
 if($logSource){
  $keys=if($logSource -is [Collections.IDictionary]){@($logSource.Keys)}else{@($logSource.PSObject.Properties.Name)}
  foreach($key in $keys){
   try{$value=if($logSource -is [Collections.IDictionary]){$logSource[$key]}else{$logSource.$key};if($value){$logTexts.Add([string]$value)}}catch{}
  }
 }
 $logBlob=$logTexts -join ([Environment]::NewLine)
 $gpuEvidence='Not observed in captured runtime logs'
 $gpuMatches=[regex]::Matches($logBlob,'(?im)^[^\r\n]{0,512}rendering GPU[^\r\n]{0,512}$')
 if($gpuMatches.Count){$gpuEvidence=$gpuMatches[$gpuMatches.Count-1].Value.Trim()}

 $nrSnapshots=@()
 try{$nrSnapshots=@($Report.NrEffectiveState.Snapshots|Where-Object {$_})}catch{}
 $latestNr=if($nrSnapshots.Count){$nrSnapshots[$nrSnapshots.Count-1]}else{$null}
 $generations=@($nrSnapshots|ForEach-Object {if($_.PSObject.Properties['generation'] -and [string]$_.generation){[string]$_.generation}}|Select-Object -Unique)
 $ownerStability=if($generations.Count -eq 1){'Stable across recorded NR snapshots'}elseif($generations.Count -gt 1){'Presentation generation changed across recorded NR snapshots'}else{'Unknown - no owner generation snapshot'}
 $lastSuccessfulFrame='Not observed'
 foreach($snapshot in $nrSnapshots){
  $completed=if($snapshot.PSObject.Properties['completed']){[string]$snapshot.completed}else{''}
  $composed=if($snapshot.PSObject.Properties['composed']){[string]$snapshot.composed}else{''}
  if(($completed -and $completed -notin @('0','false','False')) -or ($composed -and $composed -notin @('0','false','False'))){
   $lastSuccessfulFrame=if($snapshot.PSObject.Properties['LogTimestamp']){[string]$snapshot.LogTimestamp}else{'Observed in NR snapshot; timestamp unavailable'}
  }
 }
 $nr=[ordered]@{Requested='Unknown';Route='Unknown';Owner='Unknown';OwnerGeneration='Unknown';View='Unknown';Frame='Unknown';CompletedFrame='Unknown';Evaluated='Unknown';Completed='Unknown';Composed='Unknown';GpuMs='Unknown';LastSuccessfulFrame=$lastSuccessfulFrame}
 if($latestNr){
  foreach($pair in @(@('Requested','request'),@('Route','Route'),@('Owner','owner'),@('OwnerGeneration','generation'),@('View','view'),@('Frame','frame'),@('CompletedFrame','completedFrame'),@('Evaluated','evaluated'),@('Completed','completed'),@('Composed','composed'),@('GpuMs','gpuMs'),@('Submitted','submitted'),@('SubmittedFrame','submittedFrame'),@('SubmissionQueue','submissionQueue'),@('FenceSignalFailed','fenceSignalFailed'))){
   if($latestNr.PSObject.Properties[$pair[1]]){$nr[$pair[0]]=[string]$latestNr.($pair[1])}
  }
 }

 $mfg=$Report.OptionalMfg.SessionAssessment
 $mfgState=$null
 if($mfg -and $mfg.Association -eq 'Current selected process'){
  try{$mfgState=if($Report.OptionalMfg.Status -is [string]){$Report.OptionalMfg.Status|ConvertFrom-Json}else{$Report.OptionalMfg.Status}}catch{}
 }
 $fg=[ordered]@{Association=if($mfg){$mfg.Association}else{'Unknown'};Phase=if($mfg){$mfg.ControlPhase}else{'Unknown'};RequestedMultiplier=if($mfg){$mfg.RequestedMultiplier}else{$null};ObservedMultiplier=if($mfg){$mfg.ObservedMultiplier}else{'Unknown'};LastStreamlineResult=if($mfg){$mfg.SetOptionsResult}else{$null};TransientRetryStreak=if($mfg){$mfg.TransientRetryStreak}else{$null};TransientRetryDelayMs=if($mfg){$mfg.TransientRetryDelayMs}else{$null};Provider='Unknown';ProviderSelection='Unknown'}
 if($mfgState){
  if($mfgState.PSObject.Properties['activeProviderPath']){$fg.Provider=[IO.Path]::GetFileName([string]$mfgState.activeProviderPath)}
  if($mfgState.PSObject.Properties['providerSelectionSource']){$fg.ProviderSelection=[string]$mfgState.providerSelectionSource}
 }

 $vulkanRequested='Not applicable'
 try{
  $layerProperty=$Report.XPlaneLaunch.Effective.PSObject.Properties['VK_INSTANCE_LAYERS']
  if($layerProperty){$vulkanRequested=[string]$layerProperty.Value}
 }catch{}
 $vulkanLoader=$moduleNames -icontains 'vulkan-1.dll'
 $reshadeLoaded=$moduleNames -icontains 'ReShade64.dll'
 $vulkanSelection=if($simulator -ne 'X-Plane 12'){'Not applicable'}elseif($vulkanRequested -match 'VK_LAYER_OptiShade_effects' -and $vulkanLoader -and $reshadeLoaded){'OptiShade layer requested by validated launch and runtime module observed; Vulkan loader activation is not directly queried'}elseif($vulkanRequested -match 'VK_LAYER_OptiShade_effects'){'OptiShade layer requested by saved launch evidence; live activation not proven'}else{'OptiShade Vulkan layer not proven in captured evidence'}
 $deviceRecreations=[regex]::Matches($logBlob,'(?i)DLSS-NR Vulkan: device changed; abandoning old device state').Count

 $openxrLoader=$moduleNames -icontains 'openxr_loader.dll'
 $openvrObserved=($moduleNames -icontains 'openvr_api.dll') -or ($moduleNames -icontains 'vrclient_x64.dll')
 $openxrNamed=$logBlob -match '(?i)XR_APILAYER_optishade'
 $localOpenxrReady=$false
 try{$localOpenxrReady=@($Report.CaptureContext.OpenXRAssessment|Where-Object {$_.Status -eq 'Game-local OptiShade OpenXR layer installed'}).Count -gt 0}catch{}
 $openxrSelection=if($openxrNamed){'OptiShade OpenXR layer named in runtime log evidence'}elseif($openxrLoader -and $localOpenxrReady){'OpenXR loader and local OptiShade layer are present; active layer selection is not directly proven'}elseif($localOpenxrReady){'Local OptiShade OpenXR layer installed; no matching live loader evidence'}else{'No OptiShade OpenXR activation evidence'}
 $vrRoute=if($openxrLoader){'OpenXR loader observed'}elseif($openvrObserved){'OpenVR/SteamVR module observed'}else{'No live VR runtime module observed'}

 $lastLifecycle='No lifecycle invalidation line captured'
 $lifecycleMatches=[regex]::Matches($logBlob,'(?im)^[^\r\n]{0,768}(?:invalidat(?:e|ed|ion)|device changed; abandoning old device state)[^\r\n]{0,768}$')
 if($lifecycleMatches.Count){$lastLifecycle=$lifecycleMatches[$lifecycleMatches.Count-1].Value.Trim()}
 if($mfgState -and $mfgState.PSObject.Properties['universalRouteFailureReason'] -and [string]$mfgState.universalRouteFailureReason -notin @('none','')){
  $lastLifecycle='MFG route: '+[string]$mfgState.universalRouteFailureReason
 }

 $contractRows=@([regex]::Matches($logBlob,'(?im)^[^\r\n]{0,200}RouteHealth contract:[^\r\n]{0,2048}$')|Select-Object -Last 8|ForEach-Object {
  $row=[ordered]@{Evidence=$_.Value.Trim();Context='Producer validation. priorSubmission refers to preceding observed execution, not completion of this new NR recording.'}
  foreach($m in [regex]::Matches($_.Value,'\b([A-Za-z]+)=([A-Za-z0-9.-]+)')){$row[$m.Groups[1].Value]=$m.Groups[2].Value}
  [pscustomobject]$row
 })
 $lastSession=$null;$sessionAssociation='Unavailable';$currentSession='unavailable'
 try{
  $sessionPath=OwnedPath $Game 'OptiShadeData/LastSession.json'
  $item=Get-Item -LiteralPath $sessionPath -ErrorAction Stop
  if($item.Length -lt 65536 -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
   $saved=Get-Content -LiteralPath $sessionPath -Raw|ConvertFrom-Json
   if($saved.Simulator -ieq ($expectedName+'.exe')){
     $saved=GetSafeLastSessionSnapshot $saved
    $lastSession=$saved;$sessionAssociation='Historical last session; not live evidence'
    if($matchedPid -gt 0 -and [string]$saved.PID -eq [string]$matchedPid){
     $process=Get-Process -Id $matchedPid -ErrorAction Stop
     if([string]$process.StartTime.ToUniversalTime().ToFileTimeUtc() -eq [string]$saved.ProcessBirthFileTime){$currentSession=$saved;$sessionAssociation='Current process identity matched; snapshot timestamp applies'}
    }
   }
  }
 }catch{}
 $contractFailures=@([regex]::Matches($logBlob,'(?im)^[^\r\n]{0,200}TAA native-FG r[0-9]+:[^\r\n]{0,2048}$')|Select-Object -Last 8|ForEach-Object {$_.Value.Trim()})
 return [pscustomobject][ordered]@{
  Schema=3;CurrentSession=$currentSession;LastSession=$lastSession;SessionEvidence=$sessionAssociation;MatchedProcess=$matching;RouteModules=@($modules|Where-Object {$_.Name -match '^OptiShade(MSFS2024|MSFS2020|XPlane12|Generic)\.dll$'});CapturedUtc=[DateTime]::UtcNow.ToString('o');Simulator=$simulator;ProcessAssociation=$(if($matching.Count -eq 1){'One current selected simulator process matched'}elseif($matching.Count -gt 1){'Multiple selected simulator processes matched'}else{'No selected simulator process matched'});GraphicsApi=$api;RenderingGpuEvidence=$gpuEvidence;
  PrimaryPresentationOwner=[pscustomobject]@{OwnerStability=$ownerStability;Owner=$nr.Owner;Generation=$nr.OwnerGeneration;View=$nr.View;Frame=$nr.Frame;CompletedFrame=$nr.CompletedFrame};
  ProducerContracts=$contractRows;ProducerContractMessages=$contractFailures;
  NeuralRendering=[pscustomobject]$nr;FrameGeneration=[pscustomobject]$fg;
  Vulkan=[pscustomobject]@{LayerRequest=$vulkanRequested;SelectionEvidence=$vulkanSelection;LoaderObserved=$vulkanLoader;DeviceRecreationEventsInCapturedLogs=$deviceRecreations};
  OpenXR=[pscustomobject]@{Route=$vrRoute;LoaderObserved=$openxrLoader;LocalOptiShadeLayerInstalled=$localOpenxrReady;SelectionEvidence=$openxrSelection};
  LastLifecycleEvidence=$lastLifecycle;
  EvidenceRule='Requested/configured, accepted, GPU-completed and displayed output are separate states. Unknown or not observed is preserved instead of inferred.'
 }
}
function GetDiagnosticModuleIdentity([string]$Path,[string]$Game,$Manifest){
 $result=@{SHA256='Unknown';Ownership='Unknown third party or unrecorded';SelectedEntrypoint='Unknown; loaded module alone does not identify the invoked export'}
 try{
  $item=Get-Item -LiteralPath $Path -ErrorAction Stop
  if($item.PSIsContainer -or $item.Length -gt 256MB -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $result}
  $result.SHA256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
  $base=(FullPath $Game).TrimEnd('\')+'\';$full=FullPath $Path
  if($full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){
   $relative=$full.Substring($base.Length)
   $entry=@($Manifest.Files|Where-Object {$_.Path -eq $relative -or $_.Relative -eq $relative})
   if($entry.Count -eq 1 -and ($entry[0].InstalledHash -eq $result.SHA256 -or $entry[0].Hash -eq $result.SHA256)){$result.Ownership='Matches OptiShade ownership receipt'}
   else{$result.Ownership='Selected game folder; ownership not verified'}
  }elseif($full -match '(?i)[\\/]NVIDIA[\\/]NGX[\\/]models[\\/]'){$result.Ownership='NVIDIA OTA location; not an OptiShade-owned file'}
 }catch{}
 return $result
}
function GetOptiMfgRuntimeEvidence($Report,[string]$Game){
 $local=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'OptiMFG/runtime'
 $roots=@([pscustomobject]@{Path=$local;Source='local controller log folder'})
 if($Game){try{$roots+=,[pscustomobject]@{Path=(OwnedPath $Game 'OptiShadeData/OptiMFG/Runtime');Source='selected game component runtime'}}catch{}}
 $result=[ordered]@{Status='No OptiMFG runtime logs found';Context='Bounded controller/helper log tails from the per-user log folder and selected game component folder. Session and process identity must still be matched.';LocationsChecked=0;Logs=@()}
 $seen=0;$seenPaths=@{}
 foreach($root in $roots){
  if(-not(Test-Path -LiteralPath $root.Path -PathType Container)){continue}
  $result.LocationsChecked++
  # Walk a small, bounded directory set. Runtime versions have used both a
  # flat log directory and a nested exports/logs directory. Do not follow
  # reparse points or crawl an entire user profile.
  $folders=[Collections.Generic.Queue[object]]::new();$folders.Enqueue([pscustomobject]@{Path=$root.Path;Depth=0});$visitedFolders=0
  while($folders.Count -and $seen -lt 8 -and $visitedFolders -lt 24){
   $folder=$folders.Dequeue();$visitedFolders++
   foreach($pattern in @('controller-*.jsonl','helper-v4-*.jsonl','helper-v5-*.jsonl','fps-capture-error*.txt','*.log')){
    foreach($file in @(Get-ChildItem -LiteralPath $folder.Path -Filter $pattern -File -ErrorAction SilentlyContinue|Where-Object {-not($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 3)){
     if($seen -ge 8){break};$key=[IO.Path]::GetFullPath($file.FullName).ToLowerInvariant();if($seenPaths.ContainsKey($key)){continue};$seenPaths[$key]=$true;$seen++
     $entry=[ordered]@{Name=$file.Name;Source=$root.Source;RelativePath=$file.FullName.Substring($root.Path.TrimEnd('\/').Length).TrimStart('\/');Bytes=$file.Length;ModifiedUtc=$file.LastWriteTimeUtc.ToString('o');Status='Captured'}
     try{if($file.Length -gt 8MB){$entry.Status='Skipped: log exceeds 8 MiB'}else{$tail=ReadDiagnosticTail $file.FullName 524288;if($env:USERPROFILE){$tail=$tail.Replace($env:USERPROFILE,'<USERPROFILE>')};$Report.LogTails['OptiMFG/'+$seen+'-'+$file.Name]=$tail}}catch{$entry.Status='Unreadable or locked'}
     $result.Logs+=,$entry
    }
    if($seen -ge 8){break}
   }
   if($folder.Depth -lt 3 -and $seen -lt 8){
    foreach($child in @(Get-ChildItem -LiteralPath $folder.Path -Directory -Force -ErrorAction SilentlyContinue|Where-Object {-not($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}|Select-Object -First 16)){$folders.Enqueue([pscustomobject]@{Path=$child.FullName;Depth=$folder.Depth+1})}
   }
  }
  if($seen -ge 8){break}
 }
 if($result.Logs.Count){$result.Status='OptiMFG runtime evidence captured'}
 $Report|Add-Member -NotePropertyName OptiMfgRuntime -NotePropertyValue $result -Force
}
function GetDetailedSupportReportCore([string]$Game,[string]$Store){
 $report=GetOptiShadeSupportReport $Game $Store
 $receipt=$null
 try{if($Store){$receiptPath=ManifestPath $Store $Game;if((Get-Item -LiteralPath $receiptPath).Length -le 16MB){$receipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json}}}catch{}
 $selectedExecutable=''
 $selectedIdentity=$null
 try{if($receipt -and $receipt.LaunchExe){$selectedIdentity=GetOptiShadeRenderingExecutable $receipt -AllowRecordedUnknown;$selectedExecutable=[string]$selectedIdentity.Path}}catch{}
 $report.SelectedExecutable=[ordered]@{Name=if($selectedExecutable){[IO.Path]::GetFileName($selectedExecutable)}else{'Unknown'};SHA256=if($selectedIdentity){$selectedIdentity.SHA256}else{''};Architecture=if($selectedIdentity){$selectedIdentity.Architecture}else{'Unknown'};ApiCandidates=if($selectedIdentity){@($selectedIdentity.ApiCandidates)}else{@()};Evidence='Selected rendering image inspection only; active API and device require matching runtime evidence.'}
 $isKnownSimulator=[bool]((Test-Path -LiteralPath (OwnedPath $Game 'FlightSimulator2024.exe')) -or (Test-Path -LiteralPath (OwnedPath $Game 'FlightSimulator.exe')) -or (Test-Path -LiteralPath (OwnedPath $Game 'X-Plane.exe')))
 $report.SchemaVersion=8;$report.ReportId=[guid]::NewGuid().ToString('N');$report.RuntimeEvidence='Logs and optional process metadata. Installed files alone do not establish active features.'
 $report.CaptureContext=GetDiagnosticContext $Game
 $report.SimulatorCrashText=if($isKnownSimulator){@(GetSimulatorCrashText $Game)}else{@()}
 $report.SimulatorCrashTextContext=if($isKnownSimulator){'Known simulator-specific crash locations; timestamps and process identity still require correlation.'}else{'No simulator crash locations were searched for this generic game.'}
 $report.LogEvidence=@{}
 $report.StartupEvidence=GetStartupEvidence $Game
 $report.ComponentEvidence=GetOptiShadeComponentEvidence $Game
 $report.PreRestoreEvidence='No saved pre-restore evidence available'
 try{if($Store){$saved=OwnedPath (Split-Path (ManifestPath $Store $Game)) 'PreRestoreDiagnostics.json';if((Get-Item -LiteralPath $saved -ErrorAction Stop).Length -le 1MB){$report.PreRestoreEvidence=Get-Content -LiteralPath $saved -Raw -Encoding UTF8|ConvertFrom-Json}}}catch{$report.PreRestoreEvidence='No readable pre-restore evidence available'}
 $report.XPlaneLaunch='No saved X-Plane launch attempt'
 try{$launch=OwnedPath (Split-Path (ManifestPath $Store $Game)) 'XPlane-launch.json';if((Get-Item -LiteralPath $launch -ErrorAction Stop).Length -le 65536){$report.XPlaneLaunch=Get-Content -LiteralPath $launch -Raw -Encoding UTF8|ConvertFrom-Json}}catch{}
 $report.CaptureAdvice='For black screens, export while the simulator is running if possible. Otherwise close the simulator and export before Restore. Saved pre-restore evidence is historical and timestamped.'
 # Environment.OSVersion can report the host manifest's compatibility version (6.2), not the installed OS.
 try{$os=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 3 -ErrorAction Stop|Select-Object -First 1;if($null -eq $os){throw 'No OS metadata'};$report.Windows=@{Name=$os.Caption;Version=$os.Version;Build=$os.BuildNumber}}catch{$report.Windows='Unavailable (OS metadata query failed)'}
 try{$gameExe=if(Test-Path -LiteralPath (OwnedPath $Game 'FlightSimulator2024.exe')){'FlightSimulator2024.exe'}elseif(Test-Path -LiteralPath (OwnedPath $Game 'X-Plane.exe')){'X-Plane.exe'}else{'FlightSimulator.exe'};$exe=Get-Item -LiteralPath (OwnedPath $Game $gameExe);$report.GameExecutable=@{Name=$exe.Name;Version=$exe.VersionInfo.FileVersion;Bytes=$exe.Length}}catch{$report.GameExecutable='Unavailable'}
 try{$report.Displays=@(Get-CimInstance Win32_VideoController -OperationTimeoutSec 3|Select-Object Name,DriverVersion,CurrentHorizontalResolution,CurrentVerticalResolution,CurrentRefreshRate,VideoModeDescription)}catch{$report.Displays='Unavailable'}
 try{Add-Type -AssemblyName System.Windows.Forms;$report.MonitorLayout=@([Windows.Forms.Screen]::AllScreens|ForEach-Object {@{Primary=$_.Primary;X=$_.Bounds.X;Y=$_.Bounds.Y;Width=$_.Bounds.Width;Height=$_.Bounds.Height}})}catch{$report.MonitorLayout='Unavailable'}
 $report.LogTails=@{}
 $report.LogStarts=@{}
 foreach($relative in @('OptiShadeData/Performance.log','OptiShadeData/ReShade.log','OptiShadeData/OptiScaler.log','ReShade.log','OptiScaler.log','Log.txt','OptiShadeData/Import-last-error.txt')){
  try{$report.LogTails[$relative]=ReadDiagnosticTail (OwnedPath $Game $relative) 1048576}catch{$report.LogTails[$relative]='Unavailable or locked'}
  try{$report.LogEvidence[$relative]=GetDiagnosticLogWindow (OwnedPath $Game $relative)}catch{$report.LogEvidence[$relative]=@{Status='Unavailable'}}
  try{$report.LogStarts[$relative]=ReadDiagnosticHead (OwnedPath $Game $relative)}catch{$report.LogStarts[$relative]='Unavailable or locked'}
 }
 GetOptiMfgRuntimeEvidence $report $Game
 try{$report.LogTails['Installer.log']=ReadDiagnosticTail (Join-Path $Store 'Installer.log') 262144;$report.LogEvidence['Installer.log']=GetDiagnosticLogWindow (Join-Path $Store 'Installer.log')}catch{$report.LogTails['Installer.log']='Unavailable'}
 $report.LogCapture='Last 1 MiB per runtime log and 256 KiB installer log, plus first 64 KiB initialization. Selected failure/feature lines from each latest 16 MiB window include timestamps and omitted-byte counts. Older or excess matching lines can be omitted. Logs may predate this export or current installation.'
  $report.OptionalMfg=@{Evidence='Installed files/settings are not proof of generated frames';Status='Not available';Log='Not available';Installation=@{Provider='Not recorded';LoaderName='Not applicable';LoadedPath='Not observed';SHA256='Not available';Ownership='Not recorded'}}
  try{
   $mfgReceipt=ReadOptiShadeState (ManifestPath $Store $Game)
   if($mfgReceipt.OptionalMfg){
    $loader=GetOptiShadeMfgLoaderName $mfgReceipt;$loaderPath=OwnedPath $Game $loader
    $record=@($mfgReceipt.Files|Where-Object {$_.Path -in (GetOptiShadeMfgLoaderAliases) -and $_.Hash -eq 'E9CA3587854EEB723E0579F7DDF6CFB1E6CF4BED79B0D75BC716003ED98FE040'})|Select-Object -First 1
    $report.OptionalMfg.Installation=@{Provider='Pinned upstream legacy MFG';LoaderName=$loader;LoadedPath='Not observed';InstalledPath=$loaderPath;RecordedPath=$(if($record){[string]$record.Path}else{'Not recorded'});SHA256=(HashFile $loaderPath);Ownership=$(if($record){'Pinned hash recorded by selected OptiShade receipt'}else{'Ownership record not matched'});SelectionEvidence=[string]$mfgReceipt.OptionalMfgLoaderEvidence}
   }elseif($mfgReceipt.SourceMfg){
    $sourcePath=OwnedPath $Game 'OptiShadeData/MFG/OptiShadeMFG.dll'
    $report.OptionalMfg.Installation=@{Provider='OptiShade source MFG';LoaderName='OptiShadeMFG.dll';LoadedPath='Not observed';InstalledPath=$sourcePath;SHA256=(HashFile $sourcePath);Ownership='Source provider receipt'}
   }elseif($mfgReceipt.Sm86Mfg){
    $loader=[string]$mfgReceipt.Sm86MfgLoader;$loaderPath=OwnedPath $Game $loader
    $record=@($mfgReceipt.Files|Where-Object {$_.Path -ieq $loader -and $_.Component -eq 'Mfg'}|Select-Object -First 1)
    $report.OptionalMfg.Installation=@{Provider='Pinned upstream DLSSG for SM86 (OptiScaler-hosted experiment)';Version=[string]$mfgReceipt.Sm86MfgVersion;LoaderName=$loader;LoadedPath='Not observed';InstalledPath=$loaderPath;SHA256=(HashFile $loaderPath);ArchiveSHA256=[string]$mfgReceipt.Sm86MfgSHA256;Ownership=$(if($record -and $record[0].Hash -eq (HashFile $loaderPath)){'Pinned upstream file hash matches the selected OptiShade receipt'}else{'Loader ownership record does not match the selected installation'});Evidence='Provider receipt and files do not prove load, compatibility, or generated output. Upstream OptiScaler coexistence and RTX 20/30 game output remain unqualified.'}
    $report.OptionalMfg.SM86Logs=@();$logRoots=@((OwnedPath $Game 'OptiShadeData/Engine/dlssg_sm86/logs'),(OwnedPath $Game 'dlssg_sm86/logs'))
    try{
     $logs=@();foreach($logRoot in $logRoots){if(Test-Path -LiteralPath $logRoot -PathType Container){$logs+=@(Get-ChildItem -LiteralPath $logRoot -File -ErrorAction Stop|Where-Object {$_.Name -match '^(loader|backend)_\d+\.jsonl$' -and -not($_.Attributes -band [IO.FileAttributes]::ReparsePoint)})}}
     foreach($file in @($logs|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 4)){
      $report.OptionalMfg.SM86Logs+=@{Name=$file.Name;ModifiedUtc=$file.LastWriteTimeUtc.ToString('o');Bytes=$file.Length;Association='Stored under the selected game folder; log PID is not by itself proof of the current process';Text=(ReadDiagnosticTail $file.FullName 65536)}
     }
     $report.OptionalMfg.SM86LogNote='At most four upstream loader/backend logs are included, 64 KiB each. Logs can be historical. Provider diagnostics and installed files do not prove that generated frames reached the display.'
    }catch{$report.OptionalMfg.SM86LogCollection='No readable upstream SM86 logs were found in the selected game folder.'}
   }
  }catch{$report.OptionalMfg.Installation.Collection='Unavailable or ownership could not be verified'}
 try{
  $report.OptionalMfg.SourceBuild=ReadDiagnosticTail (OwnedPath $Game 'OptiShadeData/MFG/source-build.json') 16384
  $report.OptionalMfg.SourceSession=ReadDiagnosticTail (OwnedPath $Game 'OptiShadeData/MFG/session.json') 16384
  $report.OptionalMfg.SourceLog=GetSourceMfgDiagnosticLog $report.OptionalMfg.SourceSession $env:TEMP
  $report.OptionalMfg.SourceActivation=ReadDiagnosticTail (OwnedPath $Game 'OptiShadeData/MFG/source-backend.json') 16384
  $mfgStatus=OwnedPath $Game 'RTXMFG-Universal.status.json'
  $report.OptionalMfg.Status=ReadDiagnosticTail $mfgStatus 65536
  $report.OptionalMfg.Settings=ReadDiagnosticTail (OwnedPath $Game 'RTXMFG-Universal.json') 65536
  $gameName=if(Test-Path -LiteralPath (OwnedPath $Game 'FlightSimulator2024.exe')){'FlightSimulator2024'}else{'FlightSimulator'}
  $mfgLog=Get-ChildItem -LiteralPath $env:TEMP -Filter ('RTXMFG-'+$gameName+'-*.log') -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 1
  if($mfgLog){$report.OptionalMfg.Log=ReadDiagnosticTail $mfgLog.FullName 262144;$report.OptionalMfg.LogTimestamp=$mfgLog.LastWriteTimeUtc.ToString('o');$report.OptionalMfg.LogNote='Newest log for this simulator executable; may originate from another installation.'}
 }catch{$report.OptionalMfg.Collection='Unavailable or unreadable'}
 $report.FeatureSettings=@{}
 try{
  $section='';foreach($line in Get-Content -LiteralPath (OwnedPath $Game 'OptiScaler.ini')){
   if($line -match '^\[([^]]+)\]'){$section=$Matches[1]}
   elseif($section -in @('Menu','Upscalers','FrameGen','DlssNr','Plugins','Framerate','DLSSG','DLSS','FSR','FSRFG','XeSS','XeFG','Reflex','NvngxFG','Fakenvapi','Hotfix','Log','UI' ) -and $line -match '^\s*([A-Za-z0-9]+)\s*=\s*(true|false|auto|[A-Za-z0-9_.-]{1,40})\s*$'){$report.FeatureSettings[$section+'.'+$Matches[1]]=$Matches[2]}
  }
 }catch{}
 $report.FeatureSettingsContext='Saved tuning only. auto requires policy resolution; NR starts off each session. Live requests and GPU completion require matching runtime evidence.'
 $report.NrEffectiveState=@{LiveRequest='Unknown';SelectedRoute='Unknown';ModelCreated='Unknown';Evaluated='Unknown';Composed='Unknown';GpuCompleted='Unknown';Evidence='Read timestamped runtime stage/route counters for the matching process. No state inferred from saved booleans.'}
 $report.NrEffectiveState=GetNrObservationEvidence $report.LogTails
 $report.BoundedLogArchives=@{}
 foreach($relative in @('OptiShadeData/Performance.log.first.log','OptiShadeData/Performance.1.log','OptiShadeData/Performance.2.log','OptiShadeData/ReShade.log.first.log','OptiShadeData/ReShade.log.1','OptiShadeData/ReShade.log.2','ReShade.log.first.log','ReShade.log.1','ReShade.log.2')){
  try{$path=OwnedPath $Game $relative;if(Test-Path -LiteralPath $path -PathType Leaf){$report.BoundedLogArchives[$relative]=@{ModifiedUtc=(Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o');Text=(ReadDiagnosticTail $path 65536);Context='First failure or rotated tail; correlate session timestamps'}}}catch{}
 }
 try{$report.InputDevices=@(Get-CimInstance Win32_PnPEntity -OperationTimeoutSec 3 -Filter "PNPClass='HIDClass'" -ErrorAction Stop|Select-Object -First 40 Name,Status,Service)}catch{$report.InputDevices='Unavailable'}
 $report.RecentDisplayEvents=@();$report.DisplayEventQuery='Completed; see matching events below'
 try{
  $report.RecentDisplayEvents=@(Get-WinEvent -FilterHashtable @{LogName='System';Id=4101;StartTime=(Get-Date).AddDays(-3)} -MaxEvents 5 -ErrorAction Stop|Where-Object Id -eq 4101|ForEach-Object {@{Time=$_.TimeCreated.ToString('o');EventId=$_.Id;Details=$_.Message.Substring(0,[Math]::Min(4096,$_.Message.Length))}})
 }catch{$report.DisplayEventQuery='No events returned or event log unavailable: '+$_.FullyQualifiedErrorId}
 $report.DisplayEventContext='Display-driver recovery events are system-wide; they do not prove MSFS or OptiShade caused the failure.'
 $report.XPlaneRuntimeLaunch=@()
 $report.LoadedModules=@();$report.Processes=@();$report.ModuleInspection=if($isKnownSimulator){'Simulator not running or unavailable'}else{'Selected game process not running or unavailable'}
 foreach($process in Get-Process FlightSimulator2024,FlightSimulator,X-Plane -ErrorAction SilentlyContinue){
  try{
   $association='Unknown';$exePath='Unknown'
   try{if($process.Path){$exePath=$process.Path;$association=if((FullPath (Split-Path $exePath -Parent)).TrimEnd('\') -eq (FullPath $Game).TrimEnd('\')){'Matched'}else{'Other installation'}}}catch{}
   $report.Processes+=@{Name=$process.ProcessName;Id=$process.Id;Started=$process.StartTime.ToString('o');StartedUtc=$process.StartTime.ToUniversalTime().ToString('o');StartedFileTimeUtc=[string]$process.StartTime.ToUniversalTime().ToFileTimeUtc();ExecutablePath=$exePath;SelectedInstallation=$association;Responding=$process.Responding;WorkingSetBytes=$process.WorkingSet64;CpuSeconds=$process.TotalProcessorTime.TotalSeconds;HasMainWindow=($process.MainWindowHandle -ne 0)}
    $report.LoadedModules+=@($process.Modules|Where-Object {$_.ModuleName -match '^(winmm|dxgi|d3d12|version|dinput8|d3d9|d3d10|d3d11|dsound|wininet|winhttp|xinput1_1|xinput1_2|xinput1_3|xinput1_4|xinput9_1_0|xinputuap|OptiScaler|ReShade64|OptiShadeMSFS2024|OptiShadeMSFS2020|OptiShadeXPlane12|OptiShadeGeneric|OptiShadeMFG|dlss-enabler-headless|nvngx.*|sl\..*|amd_fidelityfx.*|libxess.*|vulkan-1|openxr_loader|openvr_api|vrclient_x64|gameoverlayrenderer64|DiscordHook64|RTSSHooks64|nvspcap64)\.dll$' -or $_.FileName -match '[\\/]NVIDIA[\\/]NGX[\\/]models[\\/]'}|ForEach-Object {@{ProcessId=$process.Id;Name=$_.ModuleName;Path=$_.FileName;Location=$(if($_.FileName.StartsWith($Game,[StringComparison]::OrdinalIgnoreCase)){'Game folder'}elseif($_.FileName.StartsWith($env:WINDIR,[StringComparison]::OrdinalIgnoreCase)){'Windows folder'}else{'Other location'})}})
   if($process.ProcessName -eq 'X-Plane' -and $association -eq 'Matched'){
    try{$metadata=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id) -OperationTimeoutSec 3 -ErrorAction Stop
     $parentName='Unavailable';try{$parentName=(Get-Process -Id $metadata.ParentProcessId -ErrorAction Stop).ProcessName}catch{}
     $report.XPlaneRuntimeLaunch+=@{ProcessId=$process.Id;AllowReShadeArgument=([string]$metadata.CommandLine -match '(?:^|\s)--allow_reshade(?:\s|$)');ParentName=$parentName;Evidence='Command-line flag and parent metadata only; child layer activation requires loaded modules/runtime logs.'}
    }catch{$report.XPlaneRuntimeLaunch+=@{ProcessId=$process.Id;Status='Process metadata unavailable'}}
   }
   $report.ModuleInspection='Observed loaded modules; not proof an optional feature rendered successfully'
  }catch{$report.ModuleInspection='Process access unavailable; no elevation requested'}
 }
 # Generic PC titles use their recorded rendering executable as the process
 # identity. Never associate by basename alone: Steam/Epic/Xbox can run another
 # copy with the same filename, and only the selected install may contribute
 # live modules or runtime-control evidence to this report.
 if(-not $isKnownSimulator -and $selectedExecutable){
  $selectedLeaf=[IO.Path]::GetFileName($selectedExecutable);$selectedName=[IO.Path]::GetFileNameWithoutExtension($selectedLeaf)
  $report.SelectedGameProcessEvidence=@{ExpectedExecutable=$selectedLeaf;SelectedPath=$selectedExecutable;Search='Matching process name followed by exact executable path comparison';State='Not running or process path unavailable'}
  foreach($process in Get-Process -Name $selectedName -ErrorAction SilentlyContinue){
   try{
    $exePath=if($process.Path){[string]$process.Path}else{'Unknown'}
    $link=GetOptiShadeProcessAssociation $Game $process.ProcessName $exePath @() $selectedExecutable
    if($link.State -ne 'Matched'){continue}
    $report.Processes+=@{Name=$process.ProcessName;Id=$process.Id;Started=$process.StartTime.ToString('o');StartedUtc=$process.StartTime.ToUniversalTime().ToString('o');StartedFileTimeUtc=[string]$process.StartTime.ToUniversalTime().ToFileTimeUtc();ExecutablePath=$exePath;SelectedInstallation='Matched';AssociationReason=$link.Reason;Responding=$process.Responding;WorkingSetBytes=$process.WorkingSet64;CpuSeconds=$process.TotalProcessorTime.TotalSeconds;HasMainWindow=($process.MainWindowHandle -ne 0)}
    $report.LoadedModules+=@($process.Modules|Where-Object {$_.ModuleName -match '^(winmm|dxgi|d3d12|version|dinput8|d3d9|d3d10|d3d11|dsound|wininet|winhttp|xinput1_1|xinput1_2|xinput1_3|xinput1_4|xinput9_1_0|xinputuap|OptiScaler|ReShade64|OptiShadeMSFS2024|OptiShadeMSFS2020|OptiShadeXPlane12|OptiShadeGeneric|OptiShadeMFG|dlss-enabler-headless|nvngx.*|sl\..*|amd_fidelityfx.*|libxess.*|vulkan-1|openxr_loader|openvr_api|vrclient_x64|gameoverlayrenderer64|DiscordHook64|RTSSHooks64|nvspcap64)\.dll$' -or $_.FileName -match '[\\/]NVIDIA[\\/]NGX[\\/]models[\\/]'}|ForEach-Object {@{ProcessId=$process.Id;Name=$_.ModuleName;Path=$_.FileName;Location=$(if($_.FileName.StartsWith($Game,[StringComparison]::OrdinalIgnoreCase)){'Game folder'}elseif($_.FileName.StartsWith($env:WINDIR,[StringComparison]::OrdinalIgnoreCase)){'Windows folder'}else{'Other location'})}})
    $report.SelectedGameProcessEvidence.State='Exact selected executable process matched'
   }catch{$report.SelectedGameProcessEvidence.State='Process metadata unavailable; no elevation requested'}
  }
  if($report.SelectedGameProcessEvidence.State -eq 'Exact selected executable process matched'){$report.ModuleInspection='Observed modules in the exact selected game executable; not proof an optional feature rendered successfully'}
 }
 foreach($observed in $report.Processes){
  try{$related=@($report.LoadedModules|Where-Object {$_.ProcessId -eq $observed.Id});$link=GetOptiShadeProcessAssociation $Game $observed.Name $observed.ExecutablePath $related $selectedExecutable;$observed.SelectedInstallation=$link.State;$observed.AssociationReason=$link.Reason}catch{$observed.SelectedInstallation='Unknown';$observed.AssociationReason='Process association evidence unavailable'}
 }
 # Include bounded evidence from other observed simulator processes without
 # attributing their modules/logs to the selected installation.
 $report.OtherSimulatorLogs=@()
 foreach($observed in $report.Processes){
  if($observed.SelectedInstallation -eq 'Matched' -or $observed.ExecutablePath -eq 'Unknown'){continue}
  $otherRoot=Split-Path $observed.ExecutablePath -Parent
  $other=@{ProcessId=$observed.Id;Executable=$observed.ExecutablePath;Context='Other running installation; not the selected game';Logs=@{}}
  foreach($relative in @('Log.txt','ReShade.log','OptiShadeData/ReShade.log','OptiShadeData/Performance.log')){
   try{$file=Join-Path $otherRoot $relative;$item=Get-Item -LiteralPath $file -ErrorAction Stop
    if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
    $other.Logs[$relative]=@{ModifiedUtc=$item.LastWriteTimeUtc.ToString('o');Text=(ReadDiagnosticTail $file 65536)}
   }catch{}
  }
  $report.OtherSimulatorLogs+=@($other)
 }
  foreach($module in $report.LoadedModules){$identity=GetDiagnosticModuleIdentity $module.Path $Game $receipt;foreach($key in $identity.Keys){$module[$key]=$identity[$key]}}
  if($report.OptionalMfg.Installation.Provider -eq 'Pinned upstream legacy MFG'){
   $loader=[string]$report.OptionalMfg.Installation.LoaderName;$installPath=[string]$report.OptionalMfg.Installation.InstalledPath
   $loaderName=[IO.Path]::GetFileName($loader);$loaded=@($report.LoadedModules|Where-Object {$_.Name -ieq $loaderName -and $_.Path -ieq $installPath})
   $report.OptionalMfg.Installation.LoadedPath=if($loaded.Count){$loaded[0].Path}else{'Not observed in the matching simulator process'}
   $report.OptionalMfg.Installation.LoadObservation=if($loaded.Count){'Verified game-local module path; see LoadedModules hash/ownership fields'}else{'No matching loaded module observed'}
  }elseif($report.OptionalMfg.Installation.Provider -like 'Pinned upstream DLSSG for SM86*'){
   $loader=[string]$report.OptionalMfg.Installation.LoaderName;$installPath=[string]$report.OptionalMfg.Installation.InstalledPath
   $loaderName=[IO.Path]::GetFileName($loader);$loaded=@($report.LoadedModules|Where-Object {$_.Name -ieq $loaderName -and $_.Path -ieq $installPath})
   $report.OptionalMfg.Installation.LoadedPath=if($loaded.Count){$loaded[0].Path}else{'Not observed in the matching simulator process'}
   $report.OptionalMfg.Installation.LoadObservation=if($loaded.Count){'OptiScaler-hosted provider module observed at the receipt path; compatibility and generated output still need runtime validation'}else{'Provider module was not observed at the receipt path in the matching game process'}
  }elseif($report.OptionalMfg.Installation.Provider -eq 'OptiShade source MFG'){
   $loaded=@($report.LoadedModules|Where-Object {$_.Name -ieq 'OptiShadeMFG.dll' -and $_.Path -ieq $report.OptionalMfg.Installation.InstalledPath})
   $report.OptionalMfg.Installation.LoadedPath=if($loaded.Count){$loaded[0].Path}else{'Not observed in the matching simulator process'}
   $report.OptionalMfg.Installation.LoadObservation=if($loaded.Count){'Verified game-local module path; see LoadedModules hash/ownership fields'}else{'No matching loaded module observed'}
  }
 $report.ExporterIdentity=@{Version=$report.InstallerVersion;Context='Collector version; loaded components have separate hashes and versions'}
 $report.AutomaticCapture=@{Note='Saved suspected-stall evidence. Automatic monitoring waits 5 minutes after launch, then requires 120 seconds of window nonresponse or 180 seconds without presentation-trace progress. This may still be a long load or pause, not proof of a defect. Use the dedicated troubleshooter for an on-demand raw thread/stack capture.';Files=@{}}
 try{
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Game).TrimEnd('\').ToUpperInvariant()))).Replace('-','')}finally{$sha.Dispose()}
   $diagnosticsRoot=if($Store){Join-Path $Store 'Diagnostics'}elseif($env:OPTISHADE_DIAGNOSTICS_DIR){$env:OPTISHADE_DIAGNOSTICS_DIR}else{Join-Path $env:LOCALAPPDATA 'OptiShade/Diagnostics'}
   $autoRoot=Join-Path $diagnosticsRoot ('AutoHang/'+$key)
  if(Test-Path -LiteralPath $autoRoot){
   foreach($file in @(Get-ChildItem -LiteralPath $autoRoot -File|Where-Object {$_.Name -match '^session-\d+-\d+.*\.txt$' -and -not($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 8)){
    $report.AutomaticCapture.Files[$file.Name]=ReadDiagnosticTail $file.FullName 65536
   }
  }
 }catch{$report.AutomaticCapture.Note+=' Capture cache unavailable: '+$_.Exception.GetType().Name}

 $report.OptionalMfg.SessionAssessment=GetMfgSessionAssessment $report.OptionalMfg.Status $report.Processes
 $report.RuntimeControl=@()
 try{
  . "$PSScriptRoot/runtime-control.ps1"
  foreach($sessionProcess in @($report.Processes|Where-Object {$_.SelectedInstallation -eq 'Matched'}|Select-Object -First 3)){
   try{$report.RuntimeControl+=GetOptiShadeRuntimeSnapshot ([int]$sessionProcess.Id)}catch{$report.RuntimeControl+=@{Pid=$sessionProcess.Id;Status='Unavailable';Reason=$_.Exception.GetBaseException().Message}}
  }
 }catch{$report.RuntimeControl=@(@{Status='Unavailable';Reason=$_.Exception.Message})}
 $report.RouteHealth=GetOptiShadeRouteHealth $Game $report
 $captureCorrelation=[ordered]@{}
 foreach($fileName in @($report.AutomaticCapture.Files.Keys)){
  $captureCorrelation[$fileName]=GetAutomaticCaptureSessionCorrelation ([string]$fileName) $report.RouteHealth.LastSession
 }
 $report.AutomaticCapture.SessionCorrelation=[ordered]@{Files=$captureCorrelation;Rule='Compare capture filename PID and process-birth identity with the selected installation LastSession record. A match identifies the same process instance only; it does not prove time-window overlap or displayed output.'}
 $report.RecentCrashEvents=@();$report.CrashEventQuery='Completed; see matching events below'
 try{
  $events=Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000,1001;StartTime=(Get-Date).AddDays(-3)} -MaxEvents 100 -ErrorAction Stop
  $crashPattern=if($isKnownSimulator){'(FlightSimulator(2024)?|X-Plane)\.exe'}elseif($selectedExecutable){[regex]::Escape([IO.Path]::GetFileName($selectedExecutable))}else{'(?!)'}
  $report.RecentCrashEvents=@($events|Where-Object {$_.Message -match $crashPattern}|Select-Object -First 20|ForEach-Object {@{Time=$_.TimeCreated.ToString('o');Provider=$_.ProviderName;EventId=$_.Id;Details=$_.Message.Substring(0,[Math]::Min(4096,$_.Message.Length))}})
 }catch{$report.CrashEventQuery='No events returned or event log unavailable: '+$_.FullyQualifiedErrorId}
 $report.Limitations='No simulator/hardware reproduction is implied. Existing crash dumps are summarized as text in ZIP exports; summaries contain exception/module/thread metadata and stack-address candidates, not debugger-unwound call stacks; no live-process dump is created and nothing is uploaded. Windows fault events may be unavailable; a faulting module is not proof of root cause. Active API/backend, swapchains, NR/FG and device-removed details are available only where runtime logs captured them.'
 $report.Note='Local report only. Paths for the selected game and user profile are redacted. Review all remaining log/event text before sharing. No credentials or automatic upload service are configured.'
 $json=$report|ConvertTo-Json -Depth 10
 foreach($pair in @(@($Game,'<GAME>'),@($env:USERPROFILE,'<USERPROFILE>'))){if($pair[0]){foreach($variant in @($pair[0],$pair[0].Replace('\','/'))){$escaped=($variant|ConvertTo-Json -Compress).Trim('"');$json=[regex]::Replace($json,[regex]::Escape($escaped),$pair[1],[Text.RegularExpressions.RegexOptions]::IgnoreCase)}}}
 return ($json|ConvertFrom-Json)
}

function ConvertDiagnosticValueToText($Value,[int]$Depth=0){
 $indent='  '*$Depth
 if($null -eq $Value){return $indent+'Not available'}
 if($Depth -gt 12){return $indent+'[Nesting limit]'}
 if($Value -is [string] -or $Value.GetType().IsPrimitive -or $Value -is [decimal] -or $Value -is [datetime]){return $indent+[string]$Value}
 if($Value -is [Collections.IDictionary]){
  foreach($key in $Value.Keys){$indent+[string]$key+':';ConvertDiagnosticValueToText $Value[$key] ($Depth+1)}
 }elseif($Value -is [Collections.IEnumerable]){
  $index=0;foreach($item in $Value){$index++;$indent+'Item '+$index+':';ConvertDiagnosticValueToText $item ($Depth+1)}
  if(-not $index){$indent+'None recorded'}
 }else{
  foreach($property in $Value.PSObject.Properties){$indent+$property.Name+':';ConvertDiagnosticValueToText $property.Value ($Depth+1)}
 }
}
function ConvertSupportReportToText($Report){
 $lines=@('OptiShade diagnostic report','==========================','Review before sharing with Gravy on Discord. No automatic upload.','')
 foreach($property in $Report.PSObject.Properties){
  $lines+=@($property.Name,('-'*$property.Name.Length))
  $lines+=@(ConvertDiagnosticValueToText $property.Value)
  $lines+=''
 }
 return ($lines -join "`r`n")
}
function ConvertOptiShadeDiagnosticExport($Report){
 # Reduce before serialization: the input can contain large or arbitrary log
 # strings. This is a bounded technical export, not a claim of anonymity.
 $state=@{Nodes=0;Characters=0;Omissions=[Collections.Generic.List[string]]::new()}
 function CleanValue($Value,[int]$Depth,[string]$Role){
  $state.Nodes++
  if($Depth -gt 12 -or $state.Nodes -gt 10000){if($state.Omissions.Count -lt 100){$state.Omissions.Add('Nesting/item budget reached')};return '[omitted: report budget]'}
  if($null -eq $Value){return $null}
  if($Value -is [string]){
   $text=[string]$Value
   $remaining=[Math]::Max(0,1000000-$state.Characters)
   $limit=[Math]::Min(32768,$remaining)
   if($text.Length -gt $limit){
    if($state.Omissions.Count -lt 100){$state.Omissions.Add('String shortened: '+$Role)}
    $half=[int][Math]::Floor($limit/2)
    $text=$text.Substring(0,$half)+' [middle omitted] '+$text.Substring($text.Length-$half)
   }
   $state.Characters+=$text.Length
   # Remove URL credentials before the email filter can split their syntax.
   $text=[regex]::Replace($text,'(?i)\b(?:https?|ftp)://[^\s"<>]+',{param($m) try{$u=[uri]$m.Value;return $u.Scheme+'://'+$u.Host+$u.AbsolutePath}catch{return '<URL>'}})
   $text=[regex]::Replace($text,'(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b','<EMAIL>')
   $technicalVersion=$Role -match '^(FileVersion|ProductVersion|DriverVersion|Version|BuildNumber)$' -and $text -match '^\d+(?:\.\d+){1,4}$'
   if(-not $technicalVersion){
    $text=[regex]::Replace($text,'\b(?:[0-9]{1,3}\.){3}[0-9]{1,5}\b',{
     param($m)
     $prefix=$text.Substring([Math]::Max(0,$m.Index-32),[Math]::Min(32,$m.Index))
     if($prefix -match '(?i)(version|driver|build)\s*[:=v]?\s*$'){return $m.Value}
     $ip=$null;if([Net.IPAddress]::TryParse($m.Value,[ref]$ip)){return '<IP>'};return $m.Value
    })
   }
   $text=[regex]::Replace($text,'(?i)[A-Z]:[\\/]+Users[\\/]+[^\\/\r\n"<>]+','<USERPROFILE>')
   $text=[regex]::Replace($text,'(?i)\\\\[^\\\s]+\\[^\s"<>]+','<NETWORK_PATH>')
   $text=[regex]::Replace($text,'(?i)(\b(?:password|passwd|token|secret|access_token|refresh_token|api_key|authorization|cookie)\b["''\s]*[:=]["''\s]*)([^\s,;"''<>]+)','$1<REDACTED>')
   return $text
  }
  if($Value.GetType().IsPrimitive -or $Value -is [decimal]){return $Value}
  if($Value -is [datetime]){return $Value.ToString('o')}
  if($Value -is [Collections.IEnumerable] -and $Value -isnot [Collections.IDictionary]){
   $items=[Collections.Generic.List[object]]::new();foreach($item in $Value){if($items.Count -ge 300){if($state.Omissions.Count -lt 100){$state.Omissions.Add('Array shortened: '+$Role)};break};$items.Add((CleanValue $item ($Depth+1) $Role))};return ,$items.ToArray()
  }
  $out=[ordered]@{}
  $keys=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties.Name)}
  # Reserve structure and failure identity before bulk log copies.
  $keys=@($keys|Sort-Object @{Expression={if($_ -match '^(LogTails|LogStarts|BoundedLogArchives)$'){1}else{0}}})
  foreach($key in $keys){
   if($out.Count -ge 300){if($state.Omissions.Count -lt 100){$state.Omissions.Add('Object shortened: '+$Role)};break}
   $name=[string]$key
   if($name -match '(?i)^(SerialNumber|DeviceID|PNPDeviceID|MachineName|ComputerName|UserName|Domain|Password|Token|Secret|AccessToken|RefreshToken|Cookie|Authorization|ApiKey)$'){$out[$name]='<REDACTED>';continue}
   # Keep technical property names; arbitrary paths/identifiers are data too.
   $safe=[string](CleanValue $name ($Depth+1) 'property name')
   if($safe.Length -gt 160){$safe=$safe.Substring(0,160)}
   if($out.Contains($safe)){$safe+='-'+$out.Count}
   $out[$safe]=CleanValue $Value.$key ($Depth+1) $safe
  }
  return [pscustomobject]$out
 }
 $result=CleanValue $Report 0 'report'
 $result|Add-Member -NotePropertyName ExportBudget -NotePropertyValue ([pscustomobject]@{Schema=1;Omissions=@($state.Omissions.ToArray());TextCharacters=$state.Characters;Nodes=$state.Nodes;Privacy='Bounded technical report with identifier filtering. Review before sharing; user text can still contain personal details.'}) -Force
 return $result
}

function GetOptiShadeDiagnosticEvidenceIndex($Report){
 # Index existing, sanitized evidence. Do not join unrelated sessions or infer
 # acceptance, rendered API, HDR, headset delivery or scanout from file presence.
 $processes=@($Report.Processes|Where-Object {$_.SelectedInstallation -eq 'Matched'})
 $firstFailures=@()
 foreach($entry in @($Report.LogEvidence.PSObject.Properties|Select-Object -First 16)){
  if($entry.Value.FirstFailureInWindow){$firstFailures+=,[pscustomobject]@{Source=$entry.Name;Line=$entry.Value.FirstFailureInWindow;Association='First failure in this bounded file window, not necessarily first in the session; correlate timestamps and process identity.'}}
 }
 return [pscustomobject][ordered]@{
  Schema=1;ReportId=$Report.ReportId;CapturedUtc=[DateTime]::UtcNow.ToString('o')
  Build=[pscustomobject]@{Source='Report.json / ComponentEvidence.Build';SourceSHA256=$Report.ComponentEvidence.Build.SourceSHA256;BuildInputsSHA256=$Report.ComponentEvidence.Build.BuildInputsSHA256;PrivateBuildLabel=$Report.ComponentEvidence.Build.PrivateBuildLabel;Status=if($Report.ComponentEvidence.Build.SourceSHA256){'Installed identity recorded; compare against candidate receipt'}else{'Unavailable'}}
  Session=[pscustomobject]@{MatchedProcessCount=$processes.Count;Association=$Report.RouteHealth.SessionEvidence;Evidence='Report.json / Processes and RouteHealth.LastSession; matching PID alone is insufficient';CurrentState='Use timestamped runtime binding; no live state inferred by this index'}
  Stages=@(
   [pscustomobject]@{Stage='Selected executable';Source='Report.json / SelectedExecutable';Meaning='Hash and import candidates, not active graphics API'},
   [pscustomobject]@{Stage='Installed provider and loaded modules';Source='Report.json / OptionalMfg.Installation and LoadedModules';Meaning='Compare recorded and observed module hashes'},
   [pscustomobject]@{Stage='Desired, accepted and observed';Source='Runtime-control.json and Route-health.json';Meaning='Keep missing, stale and unavailable states distinct'},
   [pscustomobject]@{Stage='Frame and resource lifetime';Source='Report.json / RouteHealth.ProducerContracts, LastSession and bounded logs';Meaning='Correlate frame, device, queue and generation; later fence values are not decision-time evidence'},
   [pscustomobject]@{Stage='VR and HDR';Source='Report.json / CaptureContext, RouteHealth.OpenXR and output logs';Meaning='Registered runtime or desktop mirror does not prove headset output; texture format does not prove display HDR'},
   [pscustomobject]@{Stage='Displayed output';Source='Owner capture and scenario record required';Meaning='Not qualified by this diagnostic export'}
  )
  FirstFailuresInCapturedWindows=$firstFailures
  Qualification='Not performed. This index organizes evidence and never grants game, GPU, HDR or VR support.'
 }
}

function ExportDiagnosticReport($Report,[string]$Destination,[ValidateSet('zip','txt')][string]$Format='zip',[string]$Game='', [bool]$IncludeDumps=$false,[string]$AdditionalDump='',[string]$IssueDescription=''){
 $Report=ConvertOptiShadeDiagnosticExport $Report
 $Report|Add-Member -NotePropertyName EvidenceIndex -NotePropertyValue (GetOptiShadeDiagnosticEvidenceIndex $Report) -Force
 if($IssueDescription.Length -gt 12000){throw 'Please keep the issue description under 12,000 characters.'}
 $IssueDescription=[string](ConvertOptiShadeDiagnosticExport ([pscustomobject]@{Issue=$IssueDescription})).Issue
 $issueReport="User-reported issue (not independently verified)`r`n===============================================`r`n"+$IssueDescription
 $text=ConvertSupportReportToText $Report
 if($IssueDescription.Trim()){$text=$issueReport+"`r`n`r`n"+$text}
 $encoding=[Text.UTF8Encoding]::new($false)
 if($encoding.GetByteCount($text) -gt 8MB){throw 'Diagnostic report exceeded the 8 MB text limit. No export was written.'}
 $temporary=$Destination+'.tmp-'+[guid]::NewGuid().ToString('N')
 try{
  if($Format -eq 'txt'){[IO.File]::WriteAllText($temporary,$text,$encoding)}else{
   Add-Type -AssemblyName System.IO.Compression
   $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
   try{
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try{
     $entries=[ordered]@{'Report.txt'=$text;'Reproduction-notes.txt'="Tell Gravy what happened:`r`n- What were you doing immediately before it happened?`r`n- Does it happen every time?`r`n- Simulator anti-aliasing/upscaler setting:`r`n- NR and frame-generation settings:`r`n- HDR, VR, monitors and extra game windows:`r`n- Other graphics mods/overlays:`r`n- Approximate crash time and time zone:`r`n- Attach the error and graphics-settings screenshots separately if useful.`r`n`r`nReview Report.txt and logs before attaching this ZIP to Discord. Exporting does not send anything. Logs are bounded tails; absent evidence does not prove a feature was inactive."}
     $entries['Report.json']=$Report|ConvertTo-Json -Depth 14
     $entries['Evidence-index.json']=$Report.EvidenceIndex|ConvertTo-Json -Depth 8
     if($Report.PSObject.Properties['RouteHealth']){$entries['Route-health.json']=$Report.RouteHealth|ConvertTo-Json -Depth 10}
     if($Report.PSObject.Properties['RuntimeControl']){$entries['Runtime-control.json']=$Report.RuntimeControl|ConvertTo-Json -Depth 12}
     $entries['User-issue.txt']=$issueReport
     $logIndex=0
     foreach($property in $Report.LogTails.PSObject.Properties){$logIndex++;$name=([IO.Path]::GetFileName($property.Name) -replace '[^A-Za-z0-9_.-]','_');$entries["Logs/$logIndex-$name.txt"]=[string]$property.Value}
     foreach($name in $entries.Keys){
      $entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
      $writer=[IO.StreamWriter]::new($entry.Open(),$encoding)
      try{$writer.Write($entries[$name])}finally{$writer.Dispose()}
     }
     if($IncludeDumps){AddCrashDumpsToArchive $zip $stream @(GetCrashDumpCandidates $Game $AdditionalDump) $temporary}
    }finally{if($zip){$zip.Dispose()}}
   }finally{$stream.Dispose()}
  }
  $exportLimit=if($IncludeDumps){20MB}else{10MB}
  if((Get-Item -LiteralPath $temporary).Length -gt $exportLimit){throw 'Diagnostic export exceeds the selected size limit. Existing export was preserved.'}
  if(Test-Path -LiteralPath $Destination){[IO.File]::Replace($temporary,$Destination,$temporary+'.backup');Remove-Item -LiteralPath ($temporary+'.backup')}else{[IO.File]::Move($temporary,$Destination)}
  return (Get-Item -LiteralPath $Destination).Length
 }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
}

function GetDetailedSupportReport([string]$Game,[string]$Store,[ValidateRange(1,30000)][int]$DeadlineMilliseconds=30000){
 # Bound even a blocked provider/event-log call. The child only reads diagnostic
 # sources; cancelling it cannot interrupt installation or mutate game files.
 $folder=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-diagnostic-worker-'+[guid]::NewGuid().ToString('N'))
 [void][IO.Directory]::CreateDirectory($folder)
 $request=Join-Path $folder 'request.json';$output=Join-Path $folder 'report.json'
 $process=$null;$clock=[Diagnostics.Stopwatch]::StartNew()
 try{
  [IO.File]::WriteAllText($request,(@{Game=$Game;Store=$Store}|ConvertTo-Json),[Text.UTF8Encoding]::new($true))
  $start=[Diagnostics.ProcessStartInfo]::new()
  $start.FileName=Join-Path $PSScriptRoot 'FusionSetup.exe'
  $start.Arguments='--diagnostic-worker "'+$request+'"'
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true
  # Avoid inheriting PowerShell 7 module resolution into the Windows helper.
  $start.EnvironmentVariables['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
  $process=[Diagnostics.Process]::Start($start)
  if(-not $process.WaitForExit([Math]::Max(1,$DeadlineMilliseconds-[int]$clock.ElapsedMilliseconds))){
   $process.Kill();[void]$process.WaitForExit(1000)
   return [pscustomobject]@{SchemaVersion=8;ReportId=[guid]::NewGuid().ToString('N');CollectionStatus='Incomplete - time budget reached';ElapsedMilliseconds=$clock.ElapsedMilliseconds;Limitations='Collection stopped at its deadline. Hardware, crash and runtime evidence may be missing. This is not evidence that the game or feature was working.';Game='<selected game>';LogTails=[pscustomobject]@{}}
  }
  $report=ReadOptiShadeJson $output 'Diagnostic worker result JSON' -MaxBytes 8388608
  $report|Add-Member -NotePropertyName CollectionElapsedMilliseconds -NotePropertyValue $clock.ElapsedMilliseconds -Force
  return $report
 }catch{
  return [pscustomobject]@{SchemaVersion=8;ReportId=[guid]::NewGuid().ToString('N');CollectionStatus='Incomplete - collector could not finish';FailureType=$_.Exception.GetType().FullName;Limitations='No successful diagnostic collection is implied. Retry diagnostics; keep the matching simulator crash text.';LogTails=[pscustomobject]@{}}
 }finally{
  if($process){if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(1000)};$process.Dispose()}
  # Only the two known files in this freshly generated local workspace are removed.
  foreach($file in @($request,$output)){if(Test-Path -LiteralPath $file -PathType Leaf){Remove-Item -LiteralPath $file -Force}}
  if(-not(Get-ChildItem -LiteralPath $folder -Force)){Remove-Item -LiteralPath $folder}
 }
}

function GetNrObservationEvidence($LogTails){
 $records=@()
 $keys=if($LogTails -is [Collections.IDictionary]){@($LogTails.Keys)}else{@($LogTails.PSObject.Properties.Name)}
 foreach($key in $keys){
  $matches=[regex]::Matches([string]$LogTails.$key,'(?m)^([^\r\n]{0,160})NR observation: ([^\r\n]{1,2048})\r?$')
  if(-not $matches.Count){continue}
  $last=$matches[$matches.Count-1];$body=$last.Groups[2].Value
  $row=[ordered]@{Source=[IO.Path]::GetFileName([string]$key);Context='Recorded session snapshot; recent/age values refer to log time, not export time. Completion is GPU work, not proof of displayed image quality.';LogTimestamp=$last.Groups[1].Value.Trim();Route='unknown'}
  if($body -match 'route=(.*?) owner='){$row.Route=$Matches[1]}
  foreach($field in @('pid','request','effective','owner','generation','view','device','queue','frame','completedFrame','enabled','visible','evaluated','completed','composed','recent','ageMs','gpuMs','frequency','submitted','submittedFrame','submissionQueue','fenceSignalFailed')){
   $match=[regex]::Match($body,'(?:^| )'+$field+'=([A-Za-z0-9.+-]{1,32})(?: |$)')
   if($match.Success){$row[$field]=$match.Groups[1].Value}
  }
  if($row.Contains('request') -and $row.Contains('completed')){$records+=,[pscustomobject]$row}
 }
 return [pscustomobject]@{Schema=1;Snapshots=@($records|Select-Object -First 8);LiveState='Not inferred from log snapshots';MissingMeaning='No matching record means unavailable evidence, not an inactive feature.'}
}
