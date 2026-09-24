$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/diagnostics.ps1"
Add-Type -Path "$PSScriptRoot/../installer/DumpSummary.cs"
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Check($ok,$message){if(-not $ok){throw $message};"PASS: $message"}
$root=Join-Path $env:TEMP ('OptiShade-summary-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
$path=Join-Path $root 'fixture.dmp'
$file=[IO.File]::Open($path,[IO.FileMode]::Create)
$w=[IO.BinaryWriter]::new($file)
function U32([long]$offset,[uint32]$value){$file.Position=$offset;$w.Write($value)}
function U64([long]$offset,[uint64]$value){$file.Position=$offset;$w.Write($value)}
try{
 $file.SetLength(4096)
 U32 0 0x504d444d;U32 4 0xa793;U32 8 4;U32 12 32;U32 20 1700000000
 # System, module list, exception, thread list.
 U32 32 7;U32 36 56;U32 40 128
 U32 44 4;U32 48 112;U32 52 256
 U32 56 6;U32 60 168;U32 64 512
 U32 68 3;U32 72 52;U32 76 768
 $file.Position=128;$w.Write([uint16]9);U32 136 10;U32 144 26200
 U32 256 1;U64 260 0x10000000;U32 268 0x100000;U32 280 1024
 U32 292 0x20002;U32 296 0x10000
 $name=[Text.Encoding]::Unicode.GetBytes('C:\Users\PrivatePerson\Game\sl.dlss_g.dll');U32 1024 $name.Length;$file.Position=1028;$w.Write($name)
 U32 512 42;U32 520 ([Convert]::ToUInt32('C0000005',16));U64 536 0x100270f6;U32 544 2;U64 552 1;U64 560 8
 U32 672 256;U32 676 1280
 U32 768 1;U32 772 42;U64 796 0x20000000;U32 804 64;U32 808 1600;U32 812 256;U32 816 1280
 U32 1328 0x100003;U64 1432 0x20000000;U64 1528 0x100270f6
 U64 1600 0x10001234;U64 1608 0x12345678
}finally{$w.Dispose()}
$summary=[OptiShade.Diagnostics.DumpSummary]::Analyze($path)
Check ($summary -match 'sl.dlss_g.dll\+0x270F6') 'Exception address resolved to module plus exact offset'
Check ($summary -match 'Access violation: write at 0x8') 'Access violation operation and target extracted'
Check ($summary -match 'version=2.2.1.0') 'Module file version extracted'
Check ($summary -match 'sl.dlss_g.dll\+0x1234' -and $summary -match 'NOT an unwound call stack') 'Stack candidates labelled honestly'
Check ($summary -notmatch 'PrivatePerson|C:\\Users') 'Module directory and personal path omitted'
Check ($summary -match 'completed metadata extraction') 'Valid fixture fully parsed'
# Full-memory dumps can keep the stack in Memory64List rather than ThreadList.
$file=[IO.File]::Open($path,[IO.FileMode]::Open);$w=[IO.BinaryWriter]::new($file)
try{
 U32 8 5;U32 80 9;U32 84 32;U32 88 1800
 U32 804 0;U64 1800 1;U64 1808 1900;U64 1816 0x20000000;U64 1824 64
 U64 1900 0x10005678
}finally{$w.Dispose()}
$summary=[OptiShade.Diagnostics.DumpSummary]::Analyze($path)
Check ($summary -match 'sl.dlss_g.dll\+0x5678') 'Full-memory stream supplies stack candidates when thread stack is absent'
# The same streams inside a large dump must remain cheap and exportable.
$file=[IO.File]::Open($path,[IO.FileMode]::Open);try{$file.SetLength(300MB)}finally{$file.Dispose()}
$before=(Get-Item $path).LastWriteTimeUtc
$summary=[OptiShade.Diagnostics.DumpSummary]::Analyze($path)
Check ($summary -match 'completed metadata extraction' -and $summary -match 'Bytes read: [0-9]{1,4};') '300 MB dump analysed through small bounded reads'
$dest=Join-Path $root 'report.zip'
$report=[pscustomobject]@{SchemaVersion=5;LogTails=[pscustomobject]@{Log='fixture'}}
[void](ExportDiagnosticReport $report $dest zip $root $true $path)
$zip=[IO.Compression.ZipFile]::OpenRead($dest)
try{
 Check ([bool]$zip.GetEntry('Crash-analysis/1-summary.txt')) 'Oversized dump produces a text file in ZIP'
 Check (-not @($zip.Entries|Where-Object FullName -like '*.dmp').Count) 'Raw memory not attached by default'
 $reader=[IO.StreamReader]::new($zip.GetEntry('Crash-analysis/1-summary.txt').Open());try{Check ($reader.ReadToEnd() -match 'sl.dlss_g.dll\+0x270F6') 'Export retains fault location'}finally{$reader.Dispose()}
}finally{$zip.Dispose()}
Check ((Get-Item $dest).Length -lt 100000 -and (Get-Item $path).LastWriteTimeUtc -eq $before) 'Small export and source unchanged'
# Malformed input must return a useful failure, without throwing or allocating its claims.
$bad=Join-Path $root 'bad.dmp';[IO.File]::WriteAllBytes($bad,[byte[]](77,68,77,80))
Check ([OptiShade.Diagnostics.DumpSummary]::Analyze($bad) -match 'incomplete/unavailable') 'Truncated header handled'
$file=[IO.File]::Open($path,[IO.FileMode]::Open);$w=[IO.BinaryWriter]::new($file);try{U32 256 ([uint32]::MaxValue)}finally{$w.Dispose()}
Check ([OptiShade.Diagnostics.DumpSummary]::Analyze($path) -match 'incomplete/unavailable') 'Hostile module count rejected without allocation'
$resolved=[IO.Path]::GetFullPath($root)
$tempPrefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
if($resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'OptiShade-summary-test-*'){
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
'PASS: temporary large fixture removed'
