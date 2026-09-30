$ErrorActionPreference='Stop'
. "$PSScriptRoot/../installer/diagnostics.ps1"
function OwnedPath($Game,$Relative){Join-Path $Game $Relative}
function GetOptiShadeSupportReport($Game,$Store){[ordered]@{GameFolder=$Game;InstallerVersion='0.20.5'}}
function Get-CimInstance($ClassName) { if($ClassName -eq 'Win32_OperatingSystem'){[pscustomobject]@{Caption='Windows fixture';Version='10.0.26100';BuildNumber='26100'}} }
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
Set-Content "$game/OptiShadeData/ReShade.log" 'Managed effects log fixture'
$report=GetDetailedSupportReport $game ''
Check ($report.Windows.Version -eq '10.0.26100' -and $report.Windows.Build -eq '26100') 'Installed OS metadata replaces misleading compatibility version'
Check ($report.LogTails.'OptiShadeData/ReShade.log' -match 'Managed effects log fixture') 'Managed effects log is included alongside legacy root logs'
$json=$report|ConvertTo-Json -Depth 10
Check ($report.SchemaVersion -eq 7 -and $report.ReportId -match '^[0-9a-f]{32}$') 'Versioned report has anonymous unique ID'
Check ($report.FeatureSettings.'Menu.ShortcutKey' -eq '45' -and -not $json.Contains('do-not-export')) 'Settings whitelist excludes unrelated credentials'
Check (-not $json.Contains(($game|ConvertTo-Json -Compress).Trim('"')) -and $report.GameFolder -eq '<GAME>' -and $report.LogTails.'OptiShadeData/Performance.log'.Contains('<USERPROFILE>')) 'Game and profile paths redacted from logs and events'
Check ($report.RecentCrashEvents.Count -eq 1 -and $report.GameExecutable.Name -eq 'FlightSimulator2024.exe') 'Crash metadata and game executable metadata present'
Check ($report.LogTails.'ReShade.log' -eq 'Not available') 'Missing runtime evidence is explicit'
Check ($report.LogStarts.'OptiShadeData/Performance.log'.Length -eq 65536) 'Startup log prefix retained independently of latest tail'
$plain=Join-Path $game 'Report.txt';$archive=Join-Path $game 'Report.zip'
$bytes=ExportDiagnosticReport $report $plain 'txt'
$body=[IO.File]::ReadAllText($plain)
Check ($bytes -gt 0 -and $body.Contains('DXGI_ERROR_DEVICE_HUNG') -and $body.Contains('FeatureSettings') -and -not $body.Contains($game)) 'Plain text export contains readable redacted evidence'
$zipBytes=ExportDiagnosticReport $report $archive 'zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try{
 Check ($zip.GetEntry('Report.txt') -and $zip.GetEntry('Reproduction-notes.txt') -and @($zip.Entries|Where-Object FullName -like 'Logs/*').Count -eq 8) 'Discord ZIP contains report, reproduction checklist and eight log tails including XP12 and import failures'
 foreach($entry in $zip.Entries){$reader=[IO.StreamReader]::new($entry.Open());try{$contents=$reader.ReadToEnd();Check (-not $contents.Contains($game) -and -not $contents.Contains($env:USERPROFILE)) ('Redacted ZIP entry '+$entry.FullName)}finally{$reader.Dispose()}}
}finally{$zip.Dispose()}
Check ($zipBytes -lt 4MB) 'ZIP size remains bounded for fixture'
$replacement=ExportDiagnosticReport $report $archive 'zip'
Check ($replacement -gt 0) 'Existing report can be replaced completely'
$before=[IO.File]::ReadAllBytes($archive)
$tooLarge=[pscustomobject]@{Evidence=('x'*(8MB+1))}
$rejected=$false;try{ExportDiagnosticReport $tooLarge $archive 'zip'}catch{$rejected=$true}
Check ($rejected -and [Convert]::ToBase64String($before) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($archive))) 'Oversize export fails without replacing existing archive'
Check (@(Get-ChildItem $game -Filter '*.tmp-*').Count -eq 0) 'No partial export files remain'
# A report after Restore must retain the earlier logs without presenting them as live.
$store=Join-Path $game 'Store';$folder=Join-Path $store 'Games/fixture'
New-Item -ItemType Directory -Path $folder -Force|Out-Null
function ManifestPath($Store,$Game){Join-Path $Store 'Games/fixture/manifest.json'}
SavePreRestoreEvidence $game $folder
Set-Content "$game/OptiShadeData/Performance.log" 'new session'
$after=GetDetailedSupportReport $game $store
Check ($after.PreRestoreEvidence.Logs.'OptiShadeData/Performance.log'.Tail -match 'DXGI_ERROR_DEVICE_HUNG' -and $after.LogTails.'OptiShadeData/Performance.log' -match 'new session') 'Historical evidence remains distinct from current logs'
$snapshot=[IO.File]::ReadAllText((Join-Path $folder 'PreRestoreDiagnostics.json'))
Check (-not $snapshot.Contains($game) -and -not $snapshot.Contains($env:USERPROFILE) -and -not $snapshot.Contains('do-not-export')) 'Saved snapshot is redacted and settings are allowlisted'
Check ((Get-Item (Join-Path $folder 'PreRestoreDiagnostics.json')).Length -lt 1MB) 'One bounded snapshot per game'
function Get-Process { @([pscustomobject]@{ProcessName='FlightSimulator2024';Id=123;StartTime=(Get-Date);Responding=$false;WorkingSet64=123456;TotalProcessorTime=[TimeSpan]::FromSeconds(12);MainWindowHandle=[IntPtr]1;Modules=@([pscustomobject]@{ModuleName='winmm.dll';FileName=(Join-Path $game 'winmm.dll');FileVersionInfo=[pscustomobject]@{FileVersion='fixture'}})}) }
$live=GetDetailedSupportReport $game $store
Check ($live.Processes[0].Responding -eq $false -and $live.Processes[0].CpuSeconds -eq 12 -and $live.LoadedModules[0].Location -eq 'Game folder') 'Live process health and module origin captured without module paths'
function Get-Process { @([pscustomobject]@{ProcessName='FlightSimulator';Id=456;StartTime=(Get-Date);Responding=$true;WorkingSet64=1;TotalProcessorTime=[TimeSpan]::Zero;MainWindowHandle=[IntPtr]1;Modules=@([pscustomobject]@{ModuleName='190_E658703.dll';FileName='C:\ProgramData\NVIDIA\NGX\models\sl_common_0\versions\134656\files\190_E658703.dll';FileVersionInfo=[pscustomobject]@{FileVersion='2.14.0'}})}) }
$ota=GetDetailedSupportReport $game $store
Check ($ota.LoadedModules.Count -eq 1 -and $ota.LoadedModules[0].Version -eq '2.14.0' -and $ota.LoadedModules[0].Path -match 'sl_common_0') 'OTA modules with opaque filenames retain feature folder and version'

# A middle-of-log failure must survive routine success messages and the ordinary tail cutoff.
$largeLog=Join-Path $game 'middle-failure.log'
[IO.File]::WriteAllText($largeLog, ('noise'+"`n")*20000+"`nDXGI_ERROR_DEVICE_HUNG marker-middle`n"+('DLSS-NR evaluate result 1 Success'+"`n")*40000)
$window=GetDiagnosticLogWindow $largeLog
Check (($window.FailureLines -join ' ') -match 'marker-middle') 'Reserved failure evidence survives success-message flooding'
Check ($window.Lines.Count -le 300 -and $window.FailureLines.Count -le 100 -and $window.ScannedBytes -le 16MB) 'Evidence scan and output are bounded'
Check ($window.ModifiedUtc -and $window.MatchesInWindow -gt 300) 'Log provenance and omitted match counts are retained'
Set-Content "$game/OptiScaler.ini" "[Framerate]`nFramerateLimit=70`n[DLSSG]`nAdaMfgUnlock=true`n[Reflex]`nMode=1`n[Credentials]`nToken=do-not-export"
Set-Content "$game/AsoboReport-Crash-fixture.txt" "Historical report $game $env:USERPROFILE"
$extended=GetDetailedSupportReport $game ''
Check ($extended.FeatureSettings.'Framerate.FramerateLimit' -eq '70' -and $extended.FeatureSettings.'DLSSG.AdaMfgUnlock' -eq 'true') 'Limiter and MFG settings are captured'
Check ($extended.CaptureContext.ConfigIdentity[0].SHA256 -match '^[0-9A-F]{64}$' -and $extended.CaptureContext.LauncherScripts.Count -eq 5) 'Configuration and launcher identities available for comparison'
Check ($extended.SimulatorCrashText.Count -eq 1 -and $extended.SimulatorCrashText[0].Text -match '<GAME>' -and $extended.SimulatorCrashText[0].Text -notmatch [regex]::Escape($env:USERPROFILE)) 'Simulator text reports are bounded and redacted'
ExportDiagnosticReport $extended $archive 'zip'|Out-Null
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try{
 $reader=[IO.StreamReader]::new($zip.GetEntry('Report.json').Open());try{$structured=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
 Check ($structured.SchemaVersion -eq 7 -and $structured.FeatureSettings.'DLSSG.AdaMfgUnlock' -eq 'true') 'Structured JSON retains actionable settings'
}finally{$zip.Dispose()}

[IO.File]::WriteAllText("$game/OptiShadeData/Performance.log",('Failure '+$game.ToUpperInvariant().Replace('\','/')+' '+$env:USERPROFILE.ToLowerInvariant().Replace('\','/')))
$redacted=GetDetailedSupportReport $game ''
Check ($redacted.LogTails.'OptiShadeData/Performance.log' -match '<GAME> <USERPROFILE>') 'Mixed-case and forward-slash paths are redacted'

$issue="Engine switches move after opening the menu.`r`nUnicode: café <tag> & details."
ExportDiagnosticReport $extended $archive 'zip' -IssueDescription $issue | Out-Null
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try{
 $reader=[IO.StreamReader]::new($zip.GetEntry('User-issue.txt').Open());try{$savedIssue=$reader.ReadToEnd()}finally{$reader.Dispose()}
 Check ($savedIssue.Contains($issue)) 'User issue survives ZIP export with multiline Unicode text'
 $reader=[IO.StreamReader]::new($zip.GetEntry('Report.txt').Open());try{$savedText=$reader.ReadToEnd()}finally{$reader.Dispose()}
 Check ($savedText.Contains($issue)) 'Issue included in main text report'
}finally{$zip.Dispose()}
$hashBefore=(Get-FileHash $archive).Hash
$rejected=$false;try{ExportDiagnosticReport $extended $archive 'zip' -IssueDescription ('x'*12001)|Out-Null}catch{$rejected=$true}
Check ($rejected -and (Get-FileHash $archive).Hash -eq $hashBefore) 'Oversized description rejected without damaging an existing export'
