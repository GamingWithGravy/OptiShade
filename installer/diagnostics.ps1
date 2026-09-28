. "$PSScriptRoot/crash-dumps.ps1"
function ReadDiagnosticTail([string]$Path,[int]$MaxBytes=65536){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return 'Not available'}
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try{$size=[int][Math]::Min($MaxBytes,$stream.Length);[void]$stream.Seek(-$size,[IO.SeekOrigin]::End);$buffer=New-Object byte[] $size;$n=$stream.Read($buffer,0,$size);[Text.Encoding]::UTF8.GetString($buffer,0,$n)}finally{$stream.Dispose()}
}
function ReadDiagnosticHead([string]$Path){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return 'Not available'}
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try{$buffer=New-Object byte[] ([int][Math]::Min(65536,$stream.Length));$n=$stream.Read($buffer,0,$buffer.Length);[Text.Encoding]::UTF8.GetString($buffer,0,$n)}finally{$stream.Dispose()}
}
function GetDiagnosticLogWindow([string]$Path){
 $result=[ordered]@{Status='Missing or unreadable';Bytes=$null;ModifiedUtc=$null;ScannedBytes=0;OlderBytesOmitted=$null;Context='Selected lines from a bounded recent window; evidence, not a diagnosis. No match does not prove absence.';MatchesInWindow=0;Lines=@();FailureLines=@()}
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
    if($line -notmatch '(?i)\[E\]|\[W\]|\|\s*(ERROR|WARN)|exception|failed|failure|DXGI_ERROR|887A000[567]|device removed|MFG unlock|Set FPS Limit|Hold Frame|Neural Rendering state|DLSS-NR.*(feature|evaluate result|SUPERSAMPLE)|rendering GPU|swapchain.*(size|format|resize)|OpenXR|GetFullPath'){continue}
    $result.MatchesInWindow++;$kept.Enqueue($line);$chars+=$line.Length
    if($line -match '(?i)\[E\]|\|\s*ERROR|exception|failed|failure|DXGI_ERROR|887A000[567]|device removed|GetFullPath'){
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
function GetDiagnosticContext([string]$Game){
 $context=[ordered]@{CapturedUtc=[DateTime]::UtcNow.ToString('o');TimeZone=[TimeZoneInfo]::Local.Id;UtcOffsetMinutes=[TimeZoneInfo]::Local.GetUtcOffset((Get-Date)).TotalMinutes;LauncherScripts=@();ConfigIdentity=@();VR=@();Hardware=@{}}
 foreach($name in @('manager.ps1','diagnostics.ps1','crash-dumps.ps1','library.ps1','ownership.ps1')){
  try{$item=Get-Item -LiteralPath (Join-Path $PSScriptRoot $name) -ErrorAction Stop;$context.LauncherScripts+=@{Name=$name;SHA256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash}}catch{}
 }
 foreach($name in @('OptiScaler.ini','ReShade.ini')){
  try{$item=Get-Item -LiteralPath (OwnedPath $Game $name) -ErrorAction Stop
   if($item.Length -gt 1MB){throw 'Oversized config'}
   $context.ConfigIdentity+=@{Name=$name;Bytes=$item.Length;ModifiedUtc=$item.LastWriteTimeUtc.ToString('o');SHA256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash}
  }catch{$context.ConfigIdentity+=@{Name=$name;Status='Missing, unreadable or oversized'}}
 }
 foreach($key in @('HKLM:\SOFTWARE\Khronos\OpenXR\1','HKCU:\SOFTWARE\Khronos\OpenXR\1')){
  try{$value=Get-ItemProperty -LiteralPath $key -Name ActiveRuntime -ErrorAction Stop;$context.VR+=@{Registry=$key;ActiveRuntime=$value.ActiveRuntime;Evidence='Registered runtime only; not proof of an active headset or VR session'}}catch{}
 }
 if(-not $context.VR.Count){$context.VR=@(@{Evidence='No readable OpenXR ActiveRuntime registration; VR may use another route'})}
 try{$context.Hardware.CPU=@(Get-CimInstance Win32_Processor -ErrorAction Stop|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)}catch{$context.Hardware.CPU='Unavailable'}
 try{$os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop;$context.Hardware.Memory=@{TotalPhysicalKB=$os.TotalVisibleMemorySize;FreePhysicalKB=$os.FreePhysicalMemory;TotalVirtualKB=$os.TotalVirtualMemorySize;FreeVirtualKB=$os.FreeVirtualMemory;Evidence='Single export-time snapshot, not a performance trend'}}catch{$context.Hardware.Memory='Unavailable'}
 return $context
}
function GetSimulatorCrashText([string]$Game){
 $reports=@()
 # Only known simulator report names in the selected install; never search user documents.
 foreach($file in @(Get-ChildItem -LiteralPath $Game -Filter 'AsoboReport-Crash-*.txt' -File -ErrorAction SilentlyContinue|Where-Object {-not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 4)){
  try{$reports+=@{Name=$file.Name;ModifiedUtc=$file.LastWriteTimeUtc.ToString('o');Bytes=$file.Length;Context='Historical simulator text report; correlate timestamps before linking it to this incident. Latest 64 KiB retained.';Text=(ReadDiagnosticTail $file.FullName)}}catch{$reports+=@{Name=$file.Name;Status='Unavailable'}}
 }
 return $reports
}
function GetStartupEvidence([string]$Game){
 $e=[ordered]@{Captured=(Get-Date).ToString('o');Context='Observed files and log tails, not proof of rendering';Logs=@{};Files=@();Settings=@{}}
 foreach($relative in @('OptiShadeData/Performance.log','OptiShadeData/ReShade.log','OptiShadeData/OptiScaler.log','ReShade.log','OptiScaler.log','Log.txt','OptiShadeData/Import-last-error.txt')){
  try{$path=OwnedPath $Game $relative;$item=Get-Item -LiteralPath $path -ErrorAction Stop;$e.Logs[$relative]=@{Bytes=$item.Length;LastWriteUtc=$item.LastWriteTimeUtc.ToString('o');Tail=(ReadDiagnosticTail $path)}}catch{$e.Logs[$relative]=@{Status='Missing or unreadable'}}
 }
 foreach($relative in @('winmm.dll','dxgi.dll','d3d12.dll','version.dll','OptiScaler.dll','ReShade64.dll','OptiShadeData/Engine/OptiScaler.dll','OptiShadeData/Engine/ReShade64.dll','sl.interposer.dll','sl.common.dll','sl.dlss.dll','sl.dlss_g.dll','sl.reflex.dll','nvngx_dlss.dll','nvngx_dlssg.dll','nvngx_dlssnr.dll','OptiShadeData/Engine/dlss-enabler-headless.dll','dlss-enabler-headless.dll')){
  try{$item=Get-Item -LiteralPath (OwnedPath $Game $relative) -ErrorAction Stop;$e.Files+=@{Path=$relative;Bytes=$item.Length;Version=$item.VersionInfo.FileVersion;LastWriteUtc=$item.LastWriteTimeUtc.ToString('o')}}catch{$e.Files+=@{Path=$relative;Status='Missing or unreadable'}}
 }
 try{$section='';foreach($line in Get-Content -LiteralPath (OwnedPath $Game 'OptiScaler.ini') -ErrorAction Stop){if($line -match '^\[([^]]+)\]'){$section=$Matches[1]}elseif($section -in @('Menu','Upscalers','FrameGen','DlssNr','Plugins','Framerate','DLSSG','DLSS','FSR','FSRFG','XeSS','XeFG','Reflex','NvngxFG','Fakenvapi','Hotfix','Log') -and $line -match '^\s*([A-Za-z0-9]+)\s*=\s*(true|false|auto|[A-Za-z0-9_.-]{1,40})\s*$'){$e.Settings[$section+'.'+$Matches[1]]=$Matches[2]}}}catch{}
 return $e
}
function SavePreRestoreEvidence([string]$Game,[string]$Folder){
 $e=GetStartupEvidence $Game;$e.Context='Captured before Restore; historical evidence, not current installed state'
 $json=$e|ConvertTo-Json -Depth 8
 foreach($pair in @(@($Game,'<GAME>'),@($env:USERPROFILE,'<USERPROFILE>'))){if($pair[0]){$json=$json.Replace(($pair[0]|ConvertTo-Json -Compress).Trim('"'),$pair[1])}}
 if([Text.Encoding]::UTF8.GetByteCount($json) -gt 1MB){throw 'Pre-restore evidence exceeds size limit'}
 $dest=OwnedPath $Folder 'PreRestoreDiagnostics.json';$tmp=OwnedPath $Folder 'PreRestoreDiagnostics.tmp'
 try{[IO.File]::WriteAllText($tmp,$json,[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $tmp -Destination $dest -Force}finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}
}
function GetDetailedSupportReport([string]$Game,[string]$Store){
 $report=GetOptiShadeSupportReport $Game $Store
 $report.SchemaVersion=6;$report.ReportId=[guid]::NewGuid().ToString('N');$report.RuntimeEvidence='Logs and optional process metadata. Installed files alone do not establish active features.'
 $report.CaptureContext=GetDiagnosticContext $Game
 $report.SimulatorCrashText=@(GetSimulatorCrashText $Game)
 $report.LogEvidence=@{}
 $report.StartupEvidence=GetStartupEvidence $Game
 $report.PreRestoreEvidence='No saved pre-restore evidence available'
 try{if($Store){$saved=OwnedPath (Split-Path (ManifestPath $Store $Game)) 'PreRestoreDiagnostics.json';if((Get-Item -LiteralPath $saved -ErrorAction Stop).Length -le 1MB){$report.PreRestoreEvidence=Get-Content -LiteralPath $saved -Raw -Encoding UTF8|ConvertFrom-Json}}}catch{$report.PreRestoreEvidence='No readable pre-restore evidence available'}
 $report.XPlaneLaunch='No saved X-Plane launch attempt'
 try{$launch=OwnedPath (Split-Path (ManifestPath $Store $Game)) 'XPlane-launch.json';if((Get-Item -LiteralPath $launch -ErrorAction Stop).Length -le 65536){$report.XPlaneLaunch=Get-Content -LiteralPath $launch -Raw -Encoding UTF8|ConvertFrom-Json}}catch{}
 $report.CaptureAdvice='For black screens, export while the simulator is running if possible. Otherwise close the simulator and export before Restore. Saved pre-restore evidence is historical and timestamped.'
 # Environment.OSVersion can report the host manifest's compatibility version (6.2), not the installed OS.
 try{$os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop|Select-Object -First 1;if($null -eq $os){throw 'No OS metadata'};$report.Windows=@{Name=$os.Caption;Version=$os.Version;Build=$os.BuildNumber}}catch{$report.Windows='Unavailable (OS metadata query failed)'}
 try{$gameExe=if(Test-Path -LiteralPath (OwnedPath $Game 'FlightSimulator2024.exe')){'FlightSimulator2024.exe'}elseif(Test-Path -LiteralPath (OwnedPath $Game 'X-Plane.exe')){'X-Plane.exe'}else{'FlightSimulator.exe'};$exe=Get-Item -LiteralPath (OwnedPath $Game $gameExe);$report.GameExecutable=@{Name=$exe.Name;Version=$exe.VersionInfo.FileVersion;Bytes=$exe.Length}}catch{$report.GameExecutable='Unavailable'}
 try{$report.Displays=@(Get-CimInstance Win32_VideoController|Select-Object Name,DriverVersion,CurrentHorizontalResolution,CurrentVerticalResolution,CurrentRefreshRate,VideoModeDescription)}catch{$report.Displays='Unavailable'}
 try{Add-Type -AssemblyName System.Windows.Forms;$report.MonitorLayout=@([Windows.Forms.Screen]::AllScreens|ForEach-Object {@{Primary=$_.Primary;X=$_.Bounds.X;Y=$_.Bounds.Y;Width=$_.Bounds.Width;Height=$_.Bounds.Height}})}catch{$report.MonitorLayout='Unavailable'}
 $report.LogTails=@{}
 $report.LogStarts=@{}
 foreach($relative in @('OptiShadeData/Performance.log','OptiShadeData/ReShade.log','OptiShadeData/OptiScaler.log','ReShade.log','OptiScaler.log','Log.txt','OptiShadeData/Import-last-error.txt')){
  try{$report.LogTails[$relative]=ReadDiagnosticTail (OwnedPath $Game $relative) 1048576}catch{$report.LogTails[$relative]='Unavailable or locked'}
  try{$report.LogEvidence[$relative]=GetDiagnosticLogWindow (OwnedPath $Game $relative)}catch{$report.LogEvidence[$relative]=@{Status='Unavailable'}}
  try{$report.LogStarts[$relative]=ReadDiagnosticHead (OwnedPath $Game $relative)}catch{$report.LogStarts[$relative]='Unavailable or locked'}
 }
 try{$report.LogTails['Installer.log']=ReadDiagnosticTail (Join-Path $Store 'Installer.log') 262144;$report.LogEvidence['Installer.log']=GetDiagnosticLogWindow (Join-Path $Store 'Installer.log')}catch{$report.LogTails['Installer.log']='Unavailable'}
 $report.LogCapture='Last 1 MiB per runtime log and 256 KiB installer log, plus first 64 KiB initialization. Selected failure/feature lines from each latest 16 MiB window include timestamps and omitted-byte counts. Older or excess matching lines can be omitted. Logs may predate this export or current installation.'
 $report.OptionalMfg=@{Evidence='Installed files/settings are not proof of generated frames';Status='Not available';Log='Not available'}
 try{
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
   elseif($section -in @('Menu','Upscalers','FrameGen','DlssNr','Plugins','Framerate','DLSSG','DLSS','FSR','FSRFG','XeSS','XeFG','Reflex','NvngxFG','Fakenvapi','Hotfix','Log') -and $line -match '^\s*([A-Za-z0-9]+)\s*=\s*(true|false|auto|[A-Za-z0-9_.-]{1,40})\s*$'){$report.FeatureSettings[$section+'.'+$Matches[1]]=$Matches[2]}
  }
 }catch{}
 try{$report.InputDevices=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='HIDClass'" -ErrorAction Stop|Select-Object -First 40 Name,Status,Service)}catch{$report.InputDevices='Unavailable'}
 $report.RecentDisplayEvents=@();$report.DisplayEventQuery='Completed; see matching events below'
 try{
  $report.RecentDisplayEvents=@(Get-WinEvent -FilterHashtable @{LogName='System';Id=4101;StartTime=(Get-Date).AddDays(-3)} -MaxEvents 5 -ErrorAction Stop|Where-Object Id -eq 4101|ForEach-Object {@{Time=$_.TimeCreated.ToString('o');EventId=$_.Id;Details=$_.Message.Substring(0,[Math]::Min(4096,$_.Message.Length))}})
 }catch{$report.DisplayEventQuery='No events returned or event log unavailable: '+$_.FullyQualifiedErrorId}
 $report.DisplayEventContext='Display-driver recovery events are system-wide; they do not prove MSFS or OptiShade caused the failure.'
 $report.LoadedModules=@();$report.Processes=@();$report.ModuleInspection='Simulator not running or unavailable'
 foreach($process in Get-Process FlightSimulator2024,FlightSimulator,X-Plane -ErrorAction SilentlyContinue){
  try{
   $report.Processes+=@{Name=$process.ProcessName;Id=$process.Id;Started=$process.StartTime.ToString('o');Responding=$process.Responding;WorkingSetBytes=$process.WorkingSet64;CpuSeconds=$process.TotalProcessorTime.TotalSeconds;HasMainWindow=($process.MainWindowHandle -ne 0)}
   $report.LoadedModules+=@($process.Modules|Where-Object {$_.ModuleName -match '^(winmm|dxgi|d3d12|OptiScaler|ReShade64|dlss-enabler-headless|nvngx.*|sl\..*|amd_fidelityfx.*|libxess.*|openxr_loader|openvr_api|vrclient_x64|gameoverlayrenderer64|DiscordHook64|RTSSHooks64|nvspcap64)\.dll$' -or $_.FileName -match '[\\/]NVIDIA[\\/]NGX[\\/]models[\\/]'}|ForEach-Object {@{ProcessId=$process.Id;Name=$_.ModuleName;Path=$_.FileName;Version=$_.FileVersionInfo.FileVersion;Location=$(if($_.FileName.StartsWith($Game,[StringComparison]::OrdinalIgnoreCase)){'Game folder'}elseif($_.FileName.StartsWith($env:WINDIR,[StringComparison]::OrdinalIgnoreCase)){'Windows folder'}else{'Other location'})}})
   $report.ModuleInspection='Observed loaded modules; not proof an optional feature rendered successfully'
  }catch{$report.ModuleInspection='Process access unavailable; no elevation requested'}
 }
 $report.RecentCrashEvents=@();$report.CrashEventQuery='Completed; see matching events below'
 try{
  $events=Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000,1001;StartTime=(Get-Date).AddDays(-3)} -MaxEvents 100 -ErrorAction Stop
  $report.RecentCrashEvents=@($events|Where-Object {$_.Message -match '(FlightSimulator(2024)?|X-Plane)\.exe'}|Select-Object -First 20|ForEach-Object {@{Time=$_.TimeCreated.ToString('o');Provider=$_.ProviderName;EventId=$_.Id;Details=$_.Message.Substring(0,[Math]::Min(4096,$_.Message.Length))}})
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
function ExportDiagnosticReport($Report,[string]$Destination,[ValidateSet('zip','txt')][string]$Format='zip',[string]$Game='', [bool]$IncludeDumps=$false,[string]$AdditionalDump='',[string]$IssueDescription=''){
 if($IssueDescription.Length -gt 12000){throw 'Please keep the issue description under 12,000 characters.'}
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
  if((Get-Item -LiteralPath $temporary).Length -gt 19000000){throw 'Diagnostic ZIP exceeds the 19 MB export limit. Existing export was preserved.'}
  if(Test-Path -LiteralPath $Destination){[IO.File]::Replace($temporary,$Destination,$temporary+'.backup');Remove-Item -LiteralPath ($temporary+'.backup')}else{[IO.File]::Move($temporary,$Destination)}
  return (Get-Item -LiteralPath $Destination).Length
 }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
}
