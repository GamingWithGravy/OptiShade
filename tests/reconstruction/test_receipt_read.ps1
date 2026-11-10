param([switch]$WriteFixture,[string]$WritePath='')
$ErrorActionPreference='Stop'
if($WriteFixture){Start-Sleep -Milliseconds 220;[IO.File]::WriteAllText($WritePath,'{"Game":"C:\\Fixture\\Game","Status":"Installed"}',[Text.UTF8Encoding]::new($false));exit 0}
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/Beta/installer/ownership.ps1"
$folder=Join-Path ([IO.Path]::GetTempPath()) ('OptiShade-receipt-read-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folder)
$script:checks=0
function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
try{
 $receipt=Join-Path $folder 'manifest.json'
 $json='{"Game":"C:\\Fixture\\Game","Status":"Installed"}'
 [IO.File]::WriteAllText($receipt,$json,[Text.UTF8Encoding]::new($false))
 Remove-Item -LiteralPath $receipt
 $child=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-WriteFixture',$receipt) -PassThru -WindowStyle Hidden
 try{$loaded=ReadOptiShadeState $receipt}finally{$child.WaitForExit();if($child.ExitCode -ne 0){throw 'Transient receipt writer failed.'};$child.Dispose()}
 Check ($loaded.Game -ceq 'C:\Fixture\Game') 'Receipt read did not recover from a short missing-file window.'

 $missing=Join-Path $folder 'missing.json';$failure=''
 try{[void](ReadOptiShadeState $missing)}catch{$failure=$_.Exception.Message}
 Check ($failure -match 'last error: .*ItemNotFoundException' -and $failure -match 'SHA256 unavailable') 'Missing receipt failure did not distinguish a missing file from invalid JSON.'

 $empty=Join-Path $folder 'empty.json';[IO.File]::WriteAllText($empty,'',[Text.UTF8Encoding]::new($false));$failure=''
 try{[void](ReadOptiShadeState $empty)}catch{$failure=$_.Exception.Message}
 Check ($failure -match '0 bytes' -and $failure -match 'last error: .*Invalid ownership receipt schema') 'Empty receipt failure did not report the observed schema failure.'

 function Get-Item {
  param([string]$LiteralPath,[switch]$Force,[string]$ErrorAction)
  if($LiteralPath -like 'E:\FIXTURE-DRIVE-UNAVAILABLE\*'){throw [System.Management.Automation.DriveNotFoundException]::new("Cannot find drive 'E'.")}
  if($LiteralPath -ceq 'relative-fixture\manifest.json'){throw [System.Management.Automation.DriveNotFoundException]::new('The fixture receipt path is relative.')}
  Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
 }
 $timer=[Diagnostics.Stopwatch]::StartNew();$failure=''
 try{[void](ReadOptiShadeState 'E:\FIXTURE-DRIVE-UNAVAILABLE\Games\Fixture\manifest.json')}catch{$failure=$_.Exception.Message}
 $timer.Stop()
 Check ($failure -match "saved installation data on drive 'E:\\'" -and $failure -match 'Reconnect any disconnected drive' -and $failure -match 'No receipt or original backup was changed') 'Unavailable-drive receipt reads did not identify the inaccessible data drive and give safe, actionable guidance.'
 Check ($timer.ElapsedMilliseconds -lt 500) 'An unavailable drive still incurred the transient-receipt retry delay.'
 $failure='';try{[void](ReadOptiShadeState 'relative-fixture\manifest.json')}catch{$failure=$_.Exception.Message}
 Check ($failure -match "relative receipt path 'relative-fixture\\manifest\.json'" -and $failure -notmatch 'the recorded game drive') 'A relative receipt failure was mislabeled as a missing game drive or omitted its diagnostic path.'
 Remove-Item Function:\Get-Item -ErrorAction SilentlyContinue
 "Receipt reads: $checks assertions passed, including transient replace retry, missing/empty receipts and unavailable drives."
}finally{Remove-Item -LiteralPath $folder -Recurse -Force}
