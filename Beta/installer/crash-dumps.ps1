# Read-only discovery; nothing here turns dumping on. Crash dumps are turned on
# per game after install by the manager (EnableOptiShadeCrashDumps, ownership.ps1)
# and from the Troubleshooter (CrashDumps.cs), each with one Windows approval.
function GetCrashDumpCandidates([string]$Game,[string]$AdditionalDump=''){
 $selected=if(Test-Path -LiteralPath (Join-Path $Game 'X-Plane.exe')){'X-Plane.exe'}elseif(Test-Path -LiteralPath (Join-Path $Game 'FlightSimulator2024.exe')){'FlightSimulator2024.exe'}elseif(Test-Path -LiteralPath (Join-Path $Game 'FlightSimulator.exe')){'FlightSimulator.exe'}else{'Unknown'}
 $roots=@()
 if($Game -and (Test-Path -LiteralPath $Game -PathType Container)){
  foreach($relative in @('','OptiShadeData','Streamline','sl-logs')){
   $root=if($relative){Join-Path $Game $relative}else{$Game}
   $roots+=@{Path=$root;Filter='*.dmp';Origin='Selected game'}
  }
 }
 if($env:LOCALAPPDATA){$roots+=@{Path=(Join-Path $env:LOCALAPPDATA 'CrashDumps');Filter='*.dmp';Origin='Windows CrashDumps'}}
 foreach($werRoot in @("$env:LOCALAPPDATA/Microsoft/Windows/WER/ReportArchive","$env:LOCALAPPDATA/Microsoft/Windows/WER/ReportQueue","$env:ProgramData/Microsoft/Windows/WER/ReportArchive","$env:ProgramData/Microsoft/Windows/WER/ReportQueue")){
  foreach($dir in @(Get-ChildItem -LiteralPath $werRoot -Directory -Filter 'AppCrash_*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'FlightSimulator|X-Plane' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)} | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 10)){
   $roots+=@{Path=$dir.FullName;Filter='*.dmp';Origin='Windows Error Reporting'}
   $roots+=@{Path=$dir.FullName;Filter='*.mdmp';Origin='Windows Error Reporting'}
  }
 }
 $found=@{};$cutoff=[DateTime]::UtcNow.AddDays(-3)
 foreach($root in $roots){
  $folder=Get-Item -LiteralPath $root.Path -ErrorAction SilentlyContinue
  if(-not $folder -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
  foreach($file in @(Get-ChildItem -LiteralPath $root.Path -File -Filter $root.Filter -ErrorAction SilentlyContinue | Where-Object {$_.LastWriteTimeUtc -ge $cutoff -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)} | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 20)){
   if($root.Origin -eq 'Windows CrashDumps' -and $file.Name -notmatch '(?i)FlightSimulator|X-Plane'){continue}
   $found[$file.FullName]=[pscustomobject]@{Path=$file.FullName;Name=$file.Name;Origin=$root.Origin;Bytes=$file.Length;ModifiedUtc=$file.LastWriteTimeUtc.ToString('o')}
  }
 }
 if($AdditionalDump){
  $file=Get-Item -LiteralPath $AdditionalDump -ErrorAction Stop
  if($file.PSIsContainer -or $file.Extension -notin @('.dmp','.mdmp') -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Choose a regular .dmp or .mdmp file.'}
  $found[$file.FullName]=[pscustomobject]@{Path=$file.FullName;Name=$file.Name;Origin='Manually selected';Bytes=$file.Length;ModifiedUtc=$file.LastWriteTimeUtc.ToString('o')}
 }
 try{if(-not ('OptiShade.Diagnostics.DumpSummary' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'DumpSummary.cs') -ErrorAction Stop}}catch{}
 foreach($candidate in $found.Values){
  $identity=if(($candidate.Name+' '+[IO.Path]::GetFileName([IO.Path]::GetDirectoryName($candidate.Path))) -match '(?i)FlightSimulator2024'){'FlightSimulator2024.exe'}elseif($candidate.Name -match '(?i)FlightSimulator'){'FlightSimulator.exe'}elseif(($candidate.Name+' '+$candidate.Path) -match '(?i)X-Plane'){'X-Plane.exe'}else{'Unknown'}
  $identityBasis='Simulator filename/path inference; module metadata unavailable'
  try{$actual=[OptiShade.Diagnostics.DumpSummary]::Executable($candidate.Path);if($actual -ne 'Unknown'){$identity=$actual;$identityBasis='Executable from minidump module list'}}catch{}
  $candidate|Add-Member NoteProperty IdentityBasis $identityBasis
  $dumpUtc=$candidate.ModifiedUtc;$timeBasis='File modification UTC; dump header unavailable'
  $reader=$null;try{$reader=[IO.File]::OpenRead($candidate.Path);$head=New-Object byte[] 24;if($reader.Read($head,0,24) -eq 24 -and [BitConverter]::ToUInt32($head,0) -eq 0x504d444d){$dumpUtc=([DateTime]::SpecifyKind([DateTime]'1970-01-01',[DateTimeKind]::Utc)).AddSeconds([BitConverter]::ToUInt32($head,20)).ToString('o');$timeBasis='Minidump header UTC'}}catch{}finally{if($reader){$reader.Dispose()}}
  $candidate|Add-Member NoteProperty DumpUtc $dumpUtc
  $candidate|Add-Member NoteProperty TimeBasis $timeBasis
  $age=([DateTime]::UtcNow-[DateTime]::Parse($dumpUtc).ToUniversalTime()).TotalHours
  $relation=if($identity -eq $selected -and $age -ge 0 -and $age -le 24){'Recent selected simulator; correlate timestamp with incident'}elseif($identity -eq 'Unknown'){'Unattributed; not current crash evidence'}else{'Historical or foreign simulator; not current crash evidence'}
  $candidate|Add-Member NoteProperty ExecutableIdentity $identity
  $candidate|Add-Member NoteProperty SelectedSimulator $selected
  $candidate|Add-Member NoteProperty AgeHoursAtExport ([Math]::Round($age,3))
  $candidate|Add-Member NoteProperty Correlation $relation
 }
 @($found.Values | Sort-Object @{Expression={if($_.Correlation -like 'Recent selected*'){0}elseif($_.Origin -eq 'Manually selected'){1}else{2}}},@{Expression='ModifiedUtc';Descending=$true} | Select-Object -First 20)
}

function AddCrashDumpsToArchive($Zip,$Stream,$Candidates,[string]$Temporary,[long]$Limit=19000000,[bool]$IncludeRaw=$false){
 $inventory=@();$included=0;$readBytes=0L;$analysed=0
 $analysisReady=$false
 try{
  if(-not ('OptiShade.Diagnostics.DumpSummary' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'DumpSummary.cs') -ErrorAction Stop}
  $analysisReady=$true
 }catch{}
 foreach($candidate in $Candidates){
  # No source paths in the public inventory. The binary itself cannot be redacted.
  $row=[ordered]@{Name=$candidate.Name;Origin=$candidate.Origin;Bytes=$candidate.Bytes;ModifiedUtc=$candidate.ModifiedUtc;DumpUtc=$candidate.DumpUtc;TimeBasis=$candidate.TimeBasis;IdentityBasis=$candidate.IdentityBasis;ExecutableIdentity=$candidate.ExecutableIdentity;SelectedSimulator=$candidate.SelectedSimulator;AgeHoursAtExport=$candidate.AgeHoursAtExport;Correlation=$candidate.Correlation;Status='Not included';SHA256=$null;Entry=$null;TextEntry=$null;AnalysisStatus='Not analysed: eight-summary limit'}
  $inventory+=,$row
  # Extract metadata BEFORE binary size limits. Seek only relevant streams, even
  # for multi-GB dumps; never copy arbitrary memory strings into the text report.
  if($analysed -lt 8 -and $Stream.Position+1MB -lt $Limit){
   $analysed++
   $summary=if($analysisReady){[OptiShade.Diagnostics.DumpSummary]::Analyze($candidate.Path)}else{'Analysis status: unavailable; local dump reader could not be initialized.'}
   if($summary.Length -gt 262144){$summary=$summary.Substring(0,262144)+"`r`nAnalysis output truncated at text limit."}
   $row.TextEntry="Crash-analysis/$analysed-summary.txt"
   $row.AnalysisStatus=if($summary -match 'incomplete/unavailable|unavailable;|truncated at text limit'){'Partial or unavailable: see text report'}else{'Metadata extracted; not an unwound call stack'}
   $entry=$Zip.CreateEntry($row.TextEntry,[IO.Compression.CompressionLevel]::Optimal)
   $writer=[IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
   try{$writer.Write("Correlation: $($candidate.Correlation)`r`nSelected simulator: $($candidate.SelectedSimulator)`r`nDump executable: $($candidate.ExecutableIdentity)`r`nDump UTC: $($candidate.DumpUtc)`r`nAge at export (hours): $($candidate.AgeHoursAtExport)`r`n`r`n"+$summary)}finally{$writer.Dispose()}
  }
  if(-not $IncludeRaw){$row.Status='Text analysis only; original dump retained locally';continue}
  if($included -ge 3){$row.Status='Skipped: three-dump limit';continue}
  if($candidate.Bytes -gt 256MB -or $readBytes+$candidate.Bytes -gt 512MB){$row.Status='Skipped: source-size limit; original file retained';continue}
  $trial=$Temporary+'.dump'
  $input=$null;$probeStream=$null;$probeZip=$null;$adding=$false
  try{
   $input=[IO.File]::Open($candidate.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
   if($input.Length -ne $candidate.Bytes){throw 'Dump changed since discovery'}
   $header=New-Object byte[] 4
   if($input.Read($header,0,4) -ne 4 -or [Text.Encoding]::ASCII.GetString($header) -ne 'MDMP'){throw 'Not a Windows minidump (MDMP signature missing)'}
   $input.Position=0;$readBytes+=$input.Length
   $sha=[Security.Cryptography.SHA256]::Create()
   try{$row.SHA256=([BitConverter]::ToString($sha.ComputeHash($input))).Replace('-','')}finally{$sha.Dispose()}
   $input.Position=0
   # Pre-compress on disk, never load a large dump into manager memory. Only add
   # complete dumps that fit; reserve 256 KB for the index and ZIP directory.
   $probeStream=[IO.File]::Open($trial,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
   $probeZip=[IO.Compression.ZipArchive]::new($probeStream,[IO.Compression.ZipArchiveMode]::Create,$true)
   $entry=$probeZip.CreateEntry('dump.dmp',[IO.Compression.CompressionLevel]::Optimal)
   $out=$entry.Open();try{$input.CopyTo($out)}finally{$out.Dispose()}
   $probeZip.Dispose();$probeZip=$null
   if($Stream.Position+$probeStream.Length+256KB -gt $Limit){$row.Status='Skipped: compressed dump would exceed ZIP limit; original file retained';continue}
   $input.Position=0;$included++;$row.Entry="Dumps/$included-crash.dmp"
   $adding=$true
   $entry=$Zip.CreateEntry($row.Entry,[IO.Compression.CompressionLevel]::Optimal)
   $out=$entry.Open();try{$input.CopyTo($out)}finally{$out.Dispose()}
   $row.Status='Included unmodified; may contain private memory data'
  }catch{if($adding){throw};$row.Status='Skipped: unavailable, changing, locked, or invalid dump'}
  finally{
   if($probeZip){$probeZip.Dispose()};if($probeStream){$probeStream.Dispose()};if($input){$input.Dispose()}
   if(Test-Path -LiteralPath $trial){Remove-Item -LiteralPath $trial -Force}
  }
 }
 $index=[ordered]@{Context='Existing crash dumps only; no live-process dump created. Text summaries are extracted locally, even when raw dumps exceed ZIP limits. Stack-address candidates are not debugger-unwound call stacks. Match dump timestamps and fault events. Share reports privately.';Search='Selected game folders, simulator-named Windows CrashDumps, matching WER folders, and any manually selected dump. Recent automatic discovery: 3 days. No whole-drive search.';Included=$included;TextReports=$analysed;Candidates=$inventory;IfMissing='If no dump is available, export immediately after the next crash or add the dump supplied by the simulator. Black screens without a crash may produce no dump.'}
 $entry=$Zip.CreateEntry('Crash-dump-index.json',[IO.Compression.CompressionLevel]::Optimal)
 $writer=[IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
 try{$writer.Write(($index|ConvertTo-Json -Depth 6))}finally{$writer.Dispose()}
}
