# Read-only discovery. Never enable machine-wide dumping or upload memory data.
function GetCrashDumpCandidates([string]$Game,[string]$AdditionalDump=''){
 $roots=@()
 if($Game -and (Test-Path -LiteralPath $Game -PathType Container)){
  foreach($relative in @('','OptiShadeData','Streamline','sl-logs')){
   $root=if($relative){Join-Path $Game $relative}else{$Game}
   $roots+=@{Path=$root;Filter='*.dmp';Origin='Selected game'}
  }
 }
 if($env:LOCALAPPDATA){$roots+=@{Path=(Join-Path $env:LOCALAPPDATA 'CrashDumps');Filter='FlightSimulator*.dmp';Origin='Windows CrashDumps'}}
 foreach($werRoot in @("$env:LOCALAPPDATA/Microsoft/Windows/WER/ReportArchive","$env:LOCALAPPDATA/Microsoft/Windows/WER/ReportQueue","$env:ProgramData/Microsoft/Windows/WER/ReportArchive","$env:ProgramData/Microsoft/Windows/WER/ReportQueue")){
  foreach($dir in @(Get-ChildItem -LiteralPath $werRoot -Directory -Filter 'AppCrash_FlightSimulator*' -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)} | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 10)){
   $roots+=@{Path=$dir.FullName;Filter='*.dmp';Origin='Windows Error Reporting'}
   $roots+=@{Path=$dir.FullName;Filter='*.mdmp';Origin='Windows Error Reporting'}
  }
 }
 $found=@{};$cutoff=[DateTime]::UtcNow.AddDays(-3)
 foreach($root in $roots){
  $folder=Get-Item -LiteralPath $root.Path -ErrorAction SilentlyContinue
  if(-not $folder -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
  foreach($file in @(Get-ChildItem -LiteralPath $root.Path -File -Filter $root.Filter -ErrorAction SilentlyContinue | Where-Object {$_.LastWriteTimeUtc -ge $cutoff -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)} | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 20)){
   $found[$file.FullName]=[pscustomobject]@{Path=$file.FullName;Name=$file.Name;Origin=$root.Origin;Bytes=$file.Length;ModifiedUtc=$file.LastWriteTimeUtc.ToString('o')}
  }
 }
 if($AdditionalDump){
  $file=Get-Item -LiteralPath $AdditionalDump -ErrorAction Stop
  if($file.PSIsContainer -or $file.Extension -notin @('.dmp','.mdmp') -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Choose a regular .dmp or .mdmp file.'}
  $found[$file.FullName]=[pscustomobject]@{Path=$file.FullName;Name=$file.Name;Origin='Manually selected';Bytes=$file.Length;ModifiedUtc=$file.LastWriteTimeUtc.ToString('o')}
 }
 @($found.Values | Sort-Object @{Expression={if($_.Origin -eq 'Manually selected'){0}else{1}}},@{Expression='ModifiedUtc';Descending=$true} | Select-Object -First 20)
}

function AddCrashDumpsToArchive($Zip,$Stream,$Candidates,[string]$Temporary,[long]$Limit=19000000){
 $inventory=@();$included=0;$readBytes=0L
 foreach($candidate in $Candidates){
  # No source paths in the public inventory. The binary itself cannot be redacted.
  $row=[ordered]@{Name=$candidate.Name;Origin=$candidate.Origin;Bytes=$candidate.Bytes;ModifiedUtc=$candidate.ModifiedUtc;Status='Not included';SHA256=$null;Entry=$null}
  $inventory+=,$row
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
 $index=[ordered]@{Context='Existing crash dumps only; no live-process dump created. A dump may be from an earlier session. Match timestamps and fault events. Binaries contain unredacted memory: share privately with support, not publicly.';Search='Selected game folders, simulator-named Windows CrashDumps, matching WER folders, and any manually selected dump. Recent automatic discovery: 3 days. No whole-drive search.';Included=$included;Candidates=$inventory;IfMissing='If no dump is available, export immediately after the next crash or add the dump supplied by the simulator. Black screens without a crash may produce no dump.'}
 $entry=$Zip.CreateEntry('Crash-dump-index.json',[IO.Compression.CompressionLevel]::Optimal)
 $writer=[IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
 try{$writer.Write(($index|ConvertTo-Json -Depth 6))}finally{$writer.Dispose()}
}
