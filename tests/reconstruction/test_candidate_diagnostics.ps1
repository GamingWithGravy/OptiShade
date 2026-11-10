$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
. "$root/Beta/installer/diagnostics.ps1"
$folder=Join-Path ([IO.Path]::GetTempPath()) ('optishade-candidate-diagnostics-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $folder 'OptiShadeData'))
try{
 $identity=[ordered]@{Version='1.0.fixture';Channel='stable';PrivateBuildLabel='Rebuild R999';PrivateTestNumber=999;SourceSHA256=('A'*64);BuildInputsSHA256=('B'*64);NativeBinaries=@{'routes/bin/fixture.dll'=('C'*64);'../bad.dll'=('D'*64);'bad.dll'='invalid'}}
 $identity|ConvertTo-Json|Set-Content (Join-Path $folder 'OptiShadeData/BuildIdentity.json') -Encoding UTF8
 $components=GetOptiShadeComponentEvidence $folder
 if($components.Build.BuildInputsSHA256 -ne ('B'*64) -or $components.Build.PrivateBuildLabel -ne 'Rebuild R999'){throw 'Candidate provenance was lost'}
 if($components.Build.NativeBinaries.Count -ne 1 -or $components.Build.IdentityFileSHA256.Length -ne 64){throw 'Build artifact allowlist/hash failed'}
 $log=Join-Path $folder 'runtime.log'
 [IO.File]::WriteAllLines($log,@('first failure original cause')+@(1..350|ForEach-Object {"later failure $_"}))
 $window=GetDiagnosticLogWindow $log
 if($window.FirstFailureInWindow -ne 'first failure original cause' -or $window.FailureLines.Count -ne 100){throw 'First failure was displaced by repeated later errors'}
 $report=[pscustomobject]@{ReportId='fixture';ComponentEvidence=$components;Processes=@();LogEvidence=[pscustomobject]@{Runtime=$window};LogTails=[pscustomobject]@{};SelectedExecutable=[pscustomobject]@{Name='Game.exe'}}
 $health=GetOptiShadeRouteHealth $folder $report
 if($health.GraphicsApi -notmatch 'Unknown' -or $health.CurrentSession -ne 'unavailable'){throw 'Missing session promoted to live evidence'}
 $report|Add-Member RouteHealth $health
 $report.Processes=@([pscustomobject]@{Name='Game';Id=4242;SelectedInstallation='Matched'})
 $report|Add-Member LoadedModules @([pscustomobject]@{Name='d3d12.dll';ProcessId=4242},[pscustomobject]@{Name='vulkan-1.dll';ProcessId=4242},[pscustomobject]@{Name='OptiShadeGeneric.dll';ProcessId=4242})
 $health=GetOptiShadeRouteHealth $folder $report
 if($health.MatchedProcess.Count -ne 1 -or $health.RouteModules.Count -ne 1 -or $health.GraphicsApi -notmatch 'active rendering API requires'){throw 'Generic route or multi-API evidence was misclassified'}
 $destination=Join-Path $folder 'report.zip'
 [void](ExportDiagnosticReport $report $destination)
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $archive=[IO.Compression.ZipFile]::OpenRead($destination)
 try{
  $reader=[IO.StreamReader]::new($archive.GetEntry('Evidence-index.json').Open())
  try{$index=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
  if($index.Build.BuildInputsSHA256 -ne ('B'*64) -or $index.FirstFailuresInCapturedWindows.Count -ne 1 -or $index.Qualification -notmatch 'Not performed'){throw 'Evidence index failed ZIP roundtrip'}
 }finally{$archive.Dispose()}
 'Candidate diagnostics passed: provenance, bounded first failure, generic/multi-API, missing session and ZIP index.'
}finally{
 $resolved=[IO.Path]::GetFullPath($folder)
 $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
