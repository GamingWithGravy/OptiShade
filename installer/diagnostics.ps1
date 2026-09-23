function ReadDiagnosticTail([string]$Path){
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return 'Not available'}
 $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 try{$size=[int][Math]::Min(65536,$stream.Length);[void]$stream.Seek(-$size,[IO.SeekOrigin]::End);$buffer=New-Object byte[] $size;$n=$stream.Read($buffer,0,$size);[Text.Encoding]::UTF8.GetString($buffer,0,$n)}finally{$stream.Dispose()}
}
function GetDetailedSupportReport([string]$Game,[string]$Store){
 $report=GetOptiShadeSupportReport $Game $Store
 $report.SchemaVersion=2;$report.ReportId=[guid]::NewGuid().ToString('N');$report.RuntimeEvidence='Logs and optional process metadata. Installed files alone do not establish active features.'
 $report.Windows=[Environment]::OSVersion.VersionString
 try{$gameExe=if(Test-Path -LiteralPath (OwnedPath $Game 'FlightSimulator2024.exe')){'FlightSimulator2024.exe'}else{'FlightSimulator.exe'};$exe=Get-Item -LiteralPath (OwnedPath $Game $gameExe);$report.GameExecutable=@{Name=$exe.Name;Version=$exe.VersionInfo.FileVersion;Bytes=$exe.Length}}catch{$report.GameExecutable='Unavailable'}
 try{$report.Displays=@(Get-CimInstance Win32_VideoController|Select-Object Name,DriverVersion,CurrentHorizontalResolution,CurrentVerticalResolution,CurrentRefreshRate,VideoModeDescription)}catch{$report.Displays='Unavailable'}
 try{Add-Type -AssemblyName System.Windows.Forms;$report.MonitorLayout=@([Windows.Forms.Screen]::AllScreens|ForEach-Object {@{Primary=$_.Primary;X=$_.Bounds.X;Y=$_.Bounds.Y;Width=$_.Bounds.Width;Height=$_.Bounds.Height}})}catch{$report.MonitorLayout='Unavailable'}
 $report.LogTails=@{}
 foreach($relative in @('OptiShadeData/Performance.log','ReShade.log','OptiScaler.log')){
  try{$report.LogTails[$relative]=ReadDiagnosticTail (OwnedPath $Game $relative)}catch{$report.LogTails[$relative]='Unavailable or locked'}
 }
 try{$report.LogTails['Installer.log']=ReadDiagnosticTail (Join-Path $Store 'Installer.log')}catch{$report.LogTails['Installer.log']='Unavailable'}
 $report.LogCapture='Last 64 KB per log, captured at export time. Earlier entries may be omitted. Missing logs are explicitly marked.'
 $report.FeatureSettings=@{}
 try{
  $section='';foreach($line in Get-Content -LiteralPath (OwnedPath $Game 'OptiScaler.ini')){
   if($line -match '^\[([^]]+)\]'){$section=$Matches[1]}
   elseif($section -in @('Menu','Upscalers','FrameGen','DlssNr','Plugins') -and $line -match '^([A-Za-z0-9]+)=(true|false|auto|[A-Za-z0-9_.-]{1,40})$'){$report.FeatureSettings[$section+'.'+$Matches[1]]=$Matches[2]}
  }
 }catch{}
 $report.RecentDisplayEvents=@()
 try{
  $report.RecentDisplayEvents=@(Get-WinEvent -FilterHashtable @{LogName='System';Id=4101;StartTime=(Get-Date).AddDays(-3)} -MaxEvents 5 -ErrorAction Stop|Where-Object Id -eq 4101|ForEach-Object {@{Time=$_.TimeCreated.ToString('o');EventId=$_.Id;Details=$_.Message.Substring(0,[Math]::Min(4096,$_.Message.Length))}})
 }catch{}
 $report.DisplayEventContext='Display-driver recovery events are system-wide; they do not prove MSFS or OptiShade caused the failure.'
 $report.LoadedModules=@();$report.ModuleInspection='Simulator not running or unavailable'
 foreach($process in Get-Process FlightSimulator2024,FlightSimulator -ErrorAction SilentlyContinue){
  try{
   $report.LoadedModules=@($process.Modules|Where-Object ModuleName -match '^(winmm|dxgi|d3d12|OptiScaler|ReShade64|nvngx.*|sl\..*|amd_fidelityfx.*|libxess.*)\.dll$'|ForEach-Object {@{Name=$_.ModuleName;Version=$_.FileVersionInfo.FileVersion}})
   $report.ModuleInspection='Observed loaded modules; not proof an optional feature rendered successfully'
  }catch{$report.ModuleInspection='Process access unavailable; no elevation requested'}
 }
 $report.RecentCrashEvents=@()
 try{
  $events=Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000,1001;StartTime=(Get-Date).AddDays(-3)} -MaxEvents 100 -ErrorAction Stop
  $report.RecentCrashEvents=@($events|Where-Object {$_.Message -match 'FlightSimulator(2024)?\.exe'}|Select-Object -First 5|ForEach-Object {@{Time=$_.TimeCreated.ToString('o');Provider=$_.ProviderName;EventId=$_.Id;Details=$_.Message.Substring(0,[Math]::Min(4096,$_.Message.Length))}})
 }catch{}
 $report.Limitations='No simulator/hardware reproduction is implied. No minidump is created or uploaded. Windows fault events may be unavailable; a faulting module is not proof of root cause. Active API/backend, swapchains, NR/FG and device-removed details are available only where runtime logs captured them.'
 $report.Note='Local report only. Paths for the selected game and user profile are redacted. Review all remaining log/event text before sharing. No credentials or automatic upload service are configured.'
 $json=$report|ConvertTo-Json -Depth 10
 foreach($pair in @(@($Game,'<GAME>'),@($env:USERPROFILE,'<USERPROFILE>'))){if($pair[0]){$escaped=($pair[0]|ConvertTo-Json -Compress).Trim('"');$json=$json.Replace($escaped,$pair[1])}}
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
function ExportDiagnosticReport($Report,[string]$Destination,[ValidateSet('zip','txt')][string]$Format='zip'){
 $text=ConvertSupportReportToText $Report
 $encoding=[Text.UTF8Encoding]::new($false)
 if($encoding.GetByteCount($text) -gt 4MB){throw 'Diagnostic report exceeded the 4 MB text limit. No export was written.'}
 $temporary=$Destination+'.tmp-'+[guid]::NewGuid().ToString('N')
 try{
  if($Format -eq 'txt'){[IO.File]::WriteAllText($temporary,$text,$encoding)}else{
   Add-Type -AssemblyName System.IO.Compression
   $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
   try{
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try{
     $entries=[ordered]@{'Report.txt'=$text;'Reproduction-notes.txt'="Tell Gravy what happened:`r`n- What were you doing immediately before it happened?`r`n- Does it happen every time?`r`n- MSFS anti-aliasing/upscaler setting:`r`n- NR and frame-generation settings:`r`n- HDR, VR, monitors and extra game windows:`r`n- Other graphics mods/overlays:`r`n- Approximate crash time and time zone:`r`n- Attach the error and graphics-settings screenshots separately if useful.`r`n`r`nReview Report.txt and logs before attaching this ZIP to Discord. Exporting does not send anything. Logs are bounded tails; absent evidence does not prove a feature was inactive."}
     $logIndex=0
     foreach($property in $Report.LogTails.PSObject.Properties){$logIndex++;$name=([IO.Path]::GetFileName($property.Name) -replace '[^A-Za-z0-9_.-]','_');$entries["Logs/$logIndex-$name.txt"]=[string]$property.Value}
     foreach($name in $entries.Keys){
      $entry=$zip.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
      $writer=[IO.StreamWriter]::new($entry.Open(),$encoding)
      try{$writer.Write($entries[$name])}finally{$writer.Dispose()}
     }
    }finally{if($zip){$zip.Dispose()}}
   }finally{$stream.Dispose()}
  }
  if(Test-Path -LiteralPath $Destination){[IO.File]::Replace($temporary,$Destination,$temporary+'.backup');Remove-Item -LiteralPath ($temporary+'.backup')}else{[IO.File]::Move($temporary,$Destination)}
  return (Get-Item -LiteralPath $Destination).Length
 }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
}
