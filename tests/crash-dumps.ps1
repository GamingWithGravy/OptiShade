$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/diagnostics.ps1"
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Check($ok,$message){if(-not $ok){throw $message};"PASS: $message"}
$root=Join-Path $env:TEMP ('OptiShade-dump-test-'+[guid]::NewGuid().ToString('N'))
$oldLocal=$env:LOCALAPPDATA;$oldProgram=$env:ProgramData
try{
 $env:LOCALAPPDATA="$root/Local";$env:ProgramData="$root/Program"
 New-Item -ItemType Directory "$root/Game","$root/Local/CrashDumps","$root/Other" -Force|Out-Null
 $valid=[Text.Encoding]::ASCII.GetBytes('MDMP'+('fixture-memory'*5000))
 [IO.File]::WriteAllBytes("$root/Game/sl-crash.dmp",$valid)
 [IO.File]::WriteAllBytes("$root/Local/CrashDumps/Unrelated.exe.1.dmp",$valid)
 [IO.File]::WriteAllBytes("$root/Local/CrashDumps/FlightSimulator.exe.1.dmp",$valid)
 [IO.File]::WriteAllBytes("$root/Game/stale.dmp",$valid);(Get-Item "$root/Game/stale.dmp").LastWriteTimeUtc=[DateTime]::UtcNow.AddDays(-5)
 [IO.File]::WriteAllBytes("$root/Other/manual.dmp",$valid)
 [IO.File]::WriteAllText("$root/Game/invalid.dmp",'not a dump')
 $report=[pscustomobject]@{SchemaVersion=4;LogTails=[pscustomobject]@{Log='fixture'}}
 $candidates=@(GetCrashDumpCandidates "$root/Game" "$root/Other/manual.dmp")
 Check ($candidates.Count -eq 4 -and $candidates[0].Origin -eq 'Manually selected') 'Discovery excludes unrelated and stale dumps; manual selection takes priority'
 $dest="$root/report.zip"
 $size=ExportDiagnosticReport $report $dest zip "$root/Game" $true "$root/Other/manual.dmp"
 $zip=[IO.Compression.ZipFile]::OpenRead($dest)
 try{
  $reader=[IO.StreamReader]::new($zip.GetEntry('Crash-dump-index.json').Open());try{$index=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
  Check ($index.Included -eq 3) 'Three intact dumps included with index'
  foreach($entry in @($zip.Entries|Where-Object FullName -like 'Dumps/*')){
   $memory=[IO.MemoryStream]::new();$input=$entry.Open();try{$input.CopyTo($memory);Check ([Convert]::ToBase64String($memory.ToArray()) -eq [Convert]::ToBase64String($valid)) 'Dump preserved byte for byte'}finally{$input.Dispose();$memory.Dispose()}
  }
  Check ((@($index.Candidates|Where-Object Status -like 'Skipped:*')).Count -eq 1) 'Invalid or excess dump is explicitly reported'
 }finally{$zip.Dispose()}
 Check ($size -lt 19000000 -and -not @(Get-ChildItem $root -Filter '*.tmp-*').Count) 'Export fits cap and removes compression temporary files'
 # An incompressible dump must never be truncated to fit.
 $noise=New-Object byte[] 1000000;$rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($noise)}finally{$rng.Dispose()}
 [Array]::Copy([Text.Encoding]::ASCII.GetBytes('MDMP'),$noise,4);[IO.File]::WriteAllBytes("$root/Other/noise.dmp",$noise)
 $candidate=[pscustomobject]@{Path="$root/Other/noise.dmp";Name='noise.dmp';Origin='Fixture';Bytes=$noise.Length;ModifiedUtc=[DateTime]::UtcNow.ToString('o')}
 $stream=[IO.File]::Open("$root/small.zip",[IO.FileMode]::Create);$zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
 try{AddCrashDumpsToArchive $zip $stream @($candidate) "$root/small.tmp" 500000}finally{$zip.Dispose();$stream.Dispose()}
 $zip=[IO.Compression.ZipFile]::OpenRead("$root/small.zip")
 try{$reader=[IO.StreamReader]::new($zip.GetEntry('Crash-dump-index.json').Open());try{$index=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()};Check ($index.Included -eq 0 -and $index.Candidates[0].Status -like '*exceed ZIP limit*' -and @($zip.Entries|Where-Object FullName -like 'Dumps/*').Count -eq 0) 'Oversized compressed dump omitted intact with reason'}finally{$zip.Dispose()}
 Check ((Get-Item "$root/Other/noise.dmp").Length -eq 1000000) 'Original dump is untouched'
 $disabled="$root/no-dumps.zip";[void](ExportDiagnosticReport $report $disabled zip "$root/Game" $false)
 $zip=[IO.Compression.ZipFile]::OpenRead($disabled);try{Check (-not $zip.GetEntry('Crash-dump-index.json')) 'Opt-out exports no crash dumps'}finally{$zip.Dispose()}
}finally{$env:LOCALAPPDATA=$oldLocal;$env:ProgramData=$oldProgram}
