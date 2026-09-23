$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/diagnostics.ps1"
function OwnedPath($Game,$Relative){Join-Path $Game $Relative}
function GetOptiShadeSupportReport($Game,$Store){[ordered]@{GameFolder=$Game;InstallerVersion='0.20.5'}}
function Get-CimInstance { @() }
function Get-Process { @() }
function Get-WinEvent { @([pscustomobject]@{TimeCreated=Get-Date;ProviderName='Application Error';Id=1000;Message=('FlightSimulator2024.exe '+$game+' '+$env:USERPROFILE)}) }
function Check($value,$message){if(-not $value){throw $message};"PASS: $message"}
$game=Join-Path $env:TEMP ('OptiShade-diagnostics-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$game/OptiShadeData" -Force|Out-Null
Set-Content "$game/FlightSimulator2024.exe" 'fixture'
Set-Content "$game/OptiScaler.ini" "[Menu]`nShortcutKey=45`n[Credentials]`nToken=do-not-export"
[IO.File]::WriteAllText("$game/OptiShadeData/Performance.log",('x'*70000)+"`nDXGI_ERROR_DEVICE_HUNG $game $env:USERPROFILE")
$tail=ReadDiagnosticTail "$game/OptiShadeData/Performance.log"
Check ($tail.Length -le 65536 -and $tail.Contains('DXGI_ERROR_DEVICE_HUNG')) 'Log tail is bounded and retains latest device failure'
$report=GetDetailedSupportReport $game ''
$json=$report|ConvertTo-Json -Depth 10
Check ($report.SchemaVersion -eq 2 -and $report.ReportId -match '^[0-9a-f]{32}$') 'Versioned report has anonymous unique ID'
Check ($report.FeatureSettings.'Menu.ShortcutKey' -eq '45' -and -not $json.Contains('do-not-export')) 'Settings whitelist excludes unrelated credentials'
Check (-not $json.Contains(($game|ConvertTo-Json -Compress).Trim('"')) -and $report.GameFolder -eq '<GAME>' -and $report.LogTails.'OptiShadeData/Performance.log'.Contains('<USERPROFILE>')) 'Game and profile paths redacted from logs and events'
Check ($report.RecentCrashEvents.Count -eq 1 -and $report.GameExecutable.Name -eq 'FlightSimulator2024.exe') 'Crash metadata and game executable metadata present'
Check ($report.LogTails.'ReShade.log' -eq 'Not available') 'Missing runtime evidence is explicit'
$plain=Join-Path $game 'Report.txt';$archive=Join-Path $game 'Report.zip'
$bytes=ExportDiagnosticReport $report $plain 'txt'
$body=[IO.File]::ReadAllText($plain)
Check ($bytes -gt 0 -and $body.Contains('DXGI_ERROR_DEVICE_HUNG') -and $body.Contains('FeatureSettings') -and -not $body.Contains($game)) 'Plain text export contains readable redacted evidence'
$zipBytes=ExportDiagnosticReport $report $archive 'zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try{
 Check ($zip.GetEntry('Report.txt') -and $zip.GetEntry('Reproduction-notes.txt') -and @($zip.Entries|Where-Object FullName -like 'Logs/*').Count -eq 4) 'Discord ZIP contains report, reproduction checklist and four log tails'
 foreach($entry in $zip.Entries){$reader=[IO.StreamReader]::new($entry.Open());try{$contents=$reader.ReadToEnd();Check (-not $contents.Contains($game) -and -not $contents.Contains($env:USERPROFILE)) ('Redacted ZIP entry '+$entry.FullName)}finally{$reader.Dispose()}}
}finally{$zip.Dispose()}
Check ($zipBytes -lt 4MB) 'ZIP size remains bounded for fixture'
$replacement=ExportDiagnosticReport $report $archive 'zip'
Check ($replacement -gt 0) 'Existing report can be replaced completely'
$before=[IO.File]::ReadAllBytes($archive)
$tooLarge=[pscustomobject]@{Evidence=('x'*(4MB+1))}
$rejected=$false;try{ExportDiagnosticReport $tooLarge $archive 'zip'}catch{$rejected=$true}
Check ($rejected -and [Convert]::ToBase64String($before) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($archive))) 'Oversize export fails without replacing existing archive'
Check (@(Get-ChildItem $game -Filter '*.tmp-*').Count -eq 0) 'No partial export files remain'
